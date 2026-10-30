import Foundation
import SQLite3

/// Structured data: JSON, YAML, XML, plist, TOML, SQLite, vCard and iCalendar, to each other and to/from sheets.
/// Every text format reads into one ordered tree (`DataValue`) through its own small parser, so key
/// order survives every hop and no third-party package is needed.
public enum DataEngine {
    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        try await runBlocking { try convertNow(input, from: source, to: target, output: output) }
    }

    static func convertNow(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws {
        let name = input.deletingPathExtension().lastPathComponent
        switch source {
        case .sqlite:
            let tables = try SQLiteFile.read(input).filter { !$0.columns.isEmpty }
            guard !tables.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no tables.")) }
            if target == .json {
                let value = DataValue.object(tables.map { .init($0.name, $0.records) })
                try (JSONWriter.write(value) + "\n").write(to: output, atomically: true, encoding: .utf8)
            } else {
                // CSV and TSV hold a single table: the largest one.
                let chosen = target == .xlsx ? tables : [tables.max { $0.rows.count < $1.rows.count }!]
                try SheetEngine.write(chosen.map(\.sheet), as: target, to: output, title: name)
            }
        case .vcf:
            let rows = VCard.rows(try DocumentEngine.readText(input))
            guard rows.count > 1 else { throw KumquatError.noResult(String(localized: "No contacts found in “\(input.lastPathComponent)”.")) }
            try SheetEngine.write([Sheet(name: name, rows: rows)], as: target, to: output, title: name)
        case .ics:
            let rows = ICal.rows(try DocumentEngine.readText(input))
            guard rows.count > 1 else { throw KumquatError.noResult(String(localized: "No events found in “\(input.lastPathComponent)”.")) }
            try SheetEngine.write([Sheet(name: name, rows: rows)], as: target, to: output, title: name)
        default:
            try write(try read(input, format: source), as: target, to: output, name: name)
        }
    }

    /// JSON, YAML, TOML, XML or plist as one ordered tree.
    static func read(_ url: URL, format: FileFormat) throws -> DataValue {
        do {
            switch format {
            case .json: return try JSONReader.parse(try DocumentEngine.readText(url))
            case .yaml: return try YAMLReader.parse(try DocumentEngine.readText(url))
            case .toml: return try TOMLReader.parse(try DocumentEngine.readText(url))
            case .xml: return try XMLData.read(try Data(contentsOf: url))
            case .plist: return try PlistData.read(try Data(contentsOf: url))
            default: throw KumquatError.unsupported(format.displayName)
            }
        } catch let error as DataSyntaxError {
            let file = url.lastPathComponent, kind = format.displayName, detail = error.message
            if let line = error.line {
                throw KumquatError.noResult(String(localized: "“\(file)” isn't valid \(kind): \(detail) (line \(line))."))
            }
            throw KumquatError.noResult(String(localized: "“\(file)” isn't valid \(kind): \(detail)."))
        }
    }

    static func write(_ value: DataValue, as target: FileFormat, to output: URL, name: String) throws {
        let text: String
        switch target {
        case .json: text = JSONWriter.write(value) + "\n"
        case .yaml: text = YAMLWriter.write(value)
        case .toml: text = TOMLWriter.write(value)
        case .xml: text = XMLData.write(value)
        case .plist: text = PlistData.write(value)
        case .csv, .tsv, .xlsx:
            try SheetEngine.write(sheets(from: value, name: name), as: target, to: output, title: name)
            return
        default:
            throw KumquatError.unsupported(String(localized: "Data → \(target.displayName)"))
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    // MARK: - Sheets

    /// Tables from JSON: an array of objects becomes rows under the union of their keys, an object
    /// of such arrays one sheet each; nested values stay as compact JSON in their cell.
    static func sheets(from value: DataValue, name: String) -> [Sheet] {
        switch value {
        case .array(let items):
            return [Sheet(name: name, rows: rows(from: items))]
        case .object(let members) where !members.isEmpty && members.allSatisfy(\.value.isArray):
            return members.map { member in
                guard case .array(let items) = member.value else { return Sheet(name: member.key, rows: []) }
                return Sheet(name: member.key, rows: rows(from: items))
            }
        case .object(let members):
            return [Sheet(name: name, rows: [members.map(\.key), members.map(\.value.cellText)])]
        default:
            return [Sheet(name: name, rows: [[value.cellText]])]
        }
    }

    static func rows(from items: [DataValue]) -> [[String]] {
        if !items.isEmpty, items.allSatisfy(\.isObject) {
            var headers: [String] = []
            var seen = Set<String>()
            for case .object(let members) in items {
                for member in members where seen.insert(member.key).inserted { headers.append(member.key) }
            }
            return [headers] + items.map { item in headers.map { item[$0]?.cellText ?? "" } }
        }
        if !items.isEmpty, items.allSatisfy(\.isArray) {
            return items.map { item in
                guard case .array(let cells) = item else { return [] }
                return cells.map(\.cellText)
            }
        }
        return [["value"]] + items.map { [$0.cellText] }
    }

    /// Sheets as JSON records keyed by their header row: one sheet → array, several → object of arrays.
    static func records(_ sheets: [Sheet]) -> DataValue {
        guard sheets.count != 1 else { return records(sheets[0]) }
        var names = Set<String>()
        return .object(sheets.map { sheet in
            var name = sheet.name, counter = 2
            while !names.insert(name).inserted { name = "\(sheet.name) \(counter)"; counter += 1 }
            return .init(name, records(sheet))
        })
    }

    static func records(_ sheet: Sheet) -> DataValue {
        guard let header = sheet.rows.first else { return .array([]) }
        let width = max(header.count, sheet.rows.map(\.count).max() ?? 0)
        let keys = uniqueHeaders(header, width: width)
        return .array(sheet.rows.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            .object(keys.enumerated().map { index, key in .init(key, typed(index < row.count ? row[index] : "")) })
        })
    }

    /// Cell text as the JSON value it looks like.
    static func typed(_ cell: String) -> DataValue {
        if cell.isEmpty { return .null }
        if let number = numericValue(cell) {
            if let integer = Int(number) { return .int(integer) }
            if let real = Double(number) { return .double(real) }
        }
        switch cell.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .string(cell)
        }
    }

    /// Header names made usable as keys or SQL columns: blanks become "column N", repeats get a number.
    static func uniqueHeaders(_ header: [String], width: Int) -> [String] {
        var used = Set<String>()
        return (0..<width).map { index in
            var name = index < header.count ? header[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if name.isEmpty { name = "column \(index + 1)" }
            var candidate = name, counter = 2
            while !used.insert(candidate.lowercased()).inserted { candidate = "\(name) \(counter)"; counter += 1 }
            return candidate
        }
    }

    // MARK: - Helpers for SheetEngine

    /// vCard 3.0 contacts from a sheet whose first row names the columns (English or Italian).
    static func vCard(from sheet: Sheet) throws -> String { try VCard.write(sheet) }

    /// iCalendar events from a sheet whose first row names the columns (English or Italian).
    static func calendar(from sheet: Sheet) throws -> String { try ICal.write(sheet) }

    /// One SQLite table per sheet, columns typed from their values.
    static func writeSQLite(_ sheets: [Sheet], to output: URL) throws { try SQLiteFile.write(sheets, to: output) }
}

// MARK: - Model

/// Ordered, format-neutral tree every structured format reads into and writes from.
enum DataValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DataValue])
    case object([Member])

    struct Member: Sendable, Equatable {
        var key: String
        var value: DataValue

        init(_ key: String, _ value: DataValue) {
            self.key = key
            self.value = value
        }
    }

    subscript(key: String) -> DataValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    var isObject: Bool { if case .object = self { true } else { false } }
    var isArray: Bool { if case .array = self { true } else { false } }
    var isNull: Bool { self == .null }

    /// Text for a spreadsheet cell or an XML node; collections become compact JSON.
    var cellText: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): "\(value)"
        case .string(let value): value
        case .array, .object: JSONWriter.write(self, pretty: false)
        }
    }

    /// Foundation objects (plist, JSONSerialization); dictionaries get sorted keys.
    init(any object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let date as Date:
            self = .string(date.formatted(.iso8601))
        case let data as Data:
            self = .string(data.base64EncodedString())
        case let array as [Any]:
            self = .array(array.map(DataValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.keys.sorted().map { .init($0, DataValue(any: dictionary[$0]!)) })
        default:
            self = .null
        }
    }
}

struct DataSyntaxError: Error {
    let message: String
    var line: Int?
}

// MARK: - JSON

/// Order-preserving JSON parser (JSONSerialization forgets key order).
enum JSONReader {
    static func parse(_ text: String) throws -> DataValue {
        var parser = Parser(bytes: Array(text.utf8))
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.i = 3 }
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.i >= parser.bytes.count else { throw parser.error("unexpected text after the end") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func error(_ message: String) -> DataSyntaxError {
            DataSyntaxError(message: message, line: bytes[..<min(i, bytes.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) })
        }

        mutating func skipSpace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        mutating func expect(_ literal: String, _ value: DataValue) throws -> DataValue {
            let expected = Array(literal.utf8)
            guard bytes[i...].starts(with: expected) else { throw error("unexpected “\(Character(UnicodeScalar(bytes[i])))”") }
            i += expected.count
            return value
        }

        mutating func value(depth: Int) throws -> DataValue {
            guard depth < 512 else { throw error("nested too deeply") }
            guard i < bytes.count else { throw error("unexpected end of file") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [DataValue.Member] = []
                var keys: [String: Int] = [:]
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a quoted key") }
                    let key = try string()
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected “:”") }
                    i += 1
                    skipSpace()
                    let item = try value(depth: depth + 1)
                    if let existing = keys[key] {
                        members[existing].value = item
                    } else {
                        keys[key] = members.count
                        members.append(.init(key, item))
                    }
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end of file") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    throw error("expected “,” or “}”")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [DataValue] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end of file") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw error("expected “,” or “]”")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                return try expect("true", .bool(true))
            case UInt8(ascii: "f"):
                return try expect("false", .bool(false))
            case UInt8(ascii: "n"):
                return try expect("null", .null)
            default:
                return try number()
            }
        }

        mutating func number() throws -> DataValue {
            let start = i
            while i < bytes.count, (bytes[i] >= 0x30 && bytes[i] <= 0x39) || [0x2D, 0x2B, 0x2E, 0x65, 0x45].contains(bytes[i]) { i += 1 }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            guard !token.isEmpty else { throw error("unexpected “\(Character(UnicodeScalar(bytes[i])))”") }
            if !token.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let integer = Int(token) { return .int(integer) }
            guard let real = Double(token) else { throw error("“\(token)” isn't a number") }
            return .double(real)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
                throw error("bad \\u escape")
            }
            i += 4
            return value
        }

        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    guard i + 1 < bytes.count else { break }
                    let escape = bytes[i + 1]
                    i += 2
                    switch escape {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(UnicodeScalar(code) ?? "\u{FFFD}")).utf8))
                    default: out.append(escape)
                    }
                    continue
                }
                out.append(byte)
                i += 1
            }
            throw error("unterminated string")
        }
    }
}

enum JSONWriter {
    static func write(_ value: DataValue, pretty: Bool = true) -> String {
        var out = ""
        emit(value, depth: 0, pretty: pretty, into: &out)
        return out
    }

    private static func emit(_ value: DataValue, depth: Int, pretty: Bool, into out: inout String) {
        func newline(_ level: Int) { if pretty { out += "\n" + String(repeating: "  ", count: level) } }
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let integer): out += String(integer)
        case .double(let real): out += real.isFinite ? "\(real)" : "null"
        case .string(let text): out += quote(text)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                newline(depth + 1)
                emit(item, depth: depth + 1, pretty: pretty, into: &out)
            }
            newline(depth)
            out += "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                newline(depth + 1)
                out += quote(member.key) + (pretty ? ": " : ":")
                emit(member.value, depth: depth + 1, pretty: pretty, into: &out)
            }
            newline(depth)
            out += "}"
        }
    }

    /// JSON string literal (also valid as a YAML double-quoted and a TOML basic string).
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - YAML

/// The YAML people actually write: block mappings and sequences, flow `[..]`/`{..}`, plain and quoted
/// scalars with type inference, `|`/`>` block scalars, comments, anchors/aliases and `<<` merges.
/// Only the first document of a stream is read.
enum YAMLReader {
    static func parse(_ text: String) throws -> DataValue {
        var parser = YAMLParser(text)
        return try parser.document()
    }

    /// Plain scalar → null, bool, number or string (YAML 1.2 core schema). Numbers with leading
    /// zeros ("007", zip codes) stay text.
    static func scalar(_ text: String) -> DataValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: return number(text) ?? .string(text)
        }
    }

    static func number(_ text: String) -> DataValue? {
        if text.hasPrefix("0x"), let value = Int(text.dropFirst(2), radix: 16) { return .int(value) }
        if text.hasPrefix("0o"), let value = Int(text.dropFirst(2), radix: 8) { return .int(value) }
        guard text.contains(where: \.isNumber), text.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
        let unsigned = text.drop { $0 == "-" || $0 == "+" }
        if unsigned.count > 1, unsigned.first == "0", unsigned.dropFirst().first?.isNumber == true { return nil }
        if !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let value = Int(text) { return .int(value) }
        return Double(text).map(DataValue.double)
    }
}

private struct YAMLParser {
    var lines: [String] = []
    var index = 0
    var anchors: [String: DataValue] = [:]

    init(_ text: String) {
        var all = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if all[0].hasPrefix("\u{FEFF}") { all[0].removeFirst() }
        var hasContent = false
        for line in all {
            if !hasContent, line.hasPrefix("%") { continue }
            if line == "---" || line.hasPrefix("--- ") {
                if hasContent { break }
                let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, !rest.hasPrefix("#") {
                    lines.append(rest)
                    hasContent = true
                }
                continue
            }
            if line == "..." || line.hasPrefix("... ") {
                if hasContent { break }
                continue
            }
            lines.append(line)
            if !Self.isBlank(line) { hasContent = true }
        }
    }

    func error(_ message: String) -> DataSyntaxError { DataSyntaxError(message: message, line: index + 1) }

    mutating func document() throws -> DataValue {
        skipBlank()
        guard index < lines.count else { return .null }
        let value = try block(parentIndent: -1)
        skipBlank()
        guard index >= lines.count else { throw error("unexpected indentation") }
        return value
    }

    // MARK: Lines

    static func isBlank(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.isEmpty || trimmed.first == "#"
    }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// A line without its indentation, trailing comment and trailing spaces.
    static func content(_ line: String) -> String {
        stripComment(String(line.drop { $0 == " " || $0 == "\t" }))
    }

    static func stripComment(_ text: String) -> String {
        let chars = Array(text)
        var quote: Character?
        var previous: Character = " "
        var end = chars.count
        var n = 0
        while n < chars.count {
            let c = chars[n]
            if let open = quote {
                if open == "'", c == "'" {
                    if n + 1 < chars.count, chars[n + 1] == "'" { n += 2; continue }
                    quote = nil
                } else if open == "\"", c == "\\" {
                    n += 2
                    continue
                } else if c == open {
                    quote = nil
                }
            } else if c == "'" || c == "\"", previous == " " || previous == "\t" || "[{,".contains(previous) {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" {
                end = n
                break
            }
            previous = c
            n += 1
        }
        return String(chars[..<end]).trimmingCharacters(in: .whitespaces)
    }

    mutating func skipBlank() {
        while index < lines.count, Self.isBlank(lines[index]) { index += 1 }
    }

    static func isSequenceEntry(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }

    /// "key: rest" → (key, rest); `nil` when the line isn't a mapping entry.
    static func splitKey(_ content: String) -> (key: String, rest: String)? {
        guard let first = content.first, !"[{#&*!|>%@`".contains(first) else { return nil }
        let chars = Array(content)
        func isSeparator(_ n: Int) -> Bool {
            chars[n] == ":" && (n + 1 == chars.count || chars[n + 1] == " " || chars[n + 1] == "\t")
        }
        if first == "\"" || first == "'" {
            guard let (key, length) = quotedPrefix(chars) else { return nil }
            var n = length
            while n < chars.count, chars[n] == " " { n += 1 }
            guard n < chars.count, isSeparator(n) else { return nil }
            return (key, String(chars[(n + 1)...]).trimmingCharacters(in: .whitespaces))
        }
        for n in chars.indices where isSeparator(n) {
            let key = String(chars[..<n]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, String(chars[(n + 1)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A quoted scalar at the start of `chars`: its value and how many characters it took.
    static func quotedPrefix(_ chars: [Character]) -> (String, Int)? {
        guard let quote = chars.first, quote == "\"" || quote == "'" else { return nil }
        var out = ""
        var n = 1
        while n < chars.count {
            let c = chars[n]
            if quote == "'" {
                if c == "'" {
                    if n + 1 < chars.count, chars[n + 1] == "'" { out.append("'"); n += 2; continue }
                    return (out, n + 1)
                }
                out.append(c)
                n += 1
                continue
            }
            if c == "\"" { return (out, n + 1) }
            guard c == "\\", n + 1 < chars.count else { out.append(c); n += 1; continue }
            let escape = chars[n + 1]
            n += 2
            switch escape {
            case "n": out.append("\n")
            case "t", "\t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "e": out.append("\u{1B}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "x", "u", "U":
                let count = escape == "x" ? 2 : escape == "u" ? 4 : 8
                let hex = String(chars[n..<min(n + count, chars.count)])
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                n += count
            default: out.append(escape)
            }
        }
        return nil
    }

    // MARK: Nodes

    /// The node starting at the current line, which must be indented deeper than its parent.
    mutating func block(parentIndent: Int) throws -> DataValue {
        skipBlank()
        guard index < lines.count else { return .null }
        let line = lines[index]
        let indent = Self.indentation(line)
        guard indent > parentIndent else { return .null }
        let content = Self.content(line)
        if Self.isSequenceEntry(content) { return try sequence(indent: indent) }
        if Self.splitKey(content) != nil { return try mapping(indent: indent) }
        index += 1
        return try value(content, parentIndent: parentIndent, inMapping: false)
    }

    mutating func mapping(indent: Int) throws -> DataValue {
        var members: [DataValue.Member] = []
        while true {
            skipBlank()
            guard index < lines.count else { break }
            let line = lines[index]
            let lineIndent = Self.indentation(line)
            if lineIndent < indent { break }
            guard lineIndent == indent else { throw error("unexpected indentation") }
            let content = Self.content(line)
            guard let (key, rest) = Self.splitKey(content) else {
                if Self.isSequenceEntry(content) { break }
                throw error("expected “key: value”")
            }
            index += 1
            let item = try value(rest, parentIndent: indent, inMapping: true)
            if key == "<<" {
                let sources: [DataValue] = if case .array(let list) = item { list } else { [item] }
                for case .object(let merged) in sources {
                    for member in merged where !members.contains(where: { $0.key == member.key }) { members.append(member) }
                }
            } else if let existing = members.firstIndex(where: { $0.key == key }) {
                members[existing].value = item
            } else {
                members.append(.init(key, item))
            }
        }
        return .object(members)
    }

    mutating func sequence(indent: Int) throws -> DataValue {
        var items: [DataValue] = []
        while true {
            skipBlank()
            guard index < lines.count else { break }
            let line = lines[index]
            guard Self.indentation(line) == indent else { break }
            let content = Self.content(line)
            guard Self.isSequenceEntry(content) else { break }
            let rest = String(content.dropFirst().drop { $0 == " " || $0 == "\t" })
            if rest.isEmpty {
                index += 1
                items.append(try value("", parentIndent: indent, inMapping: false))
            } else if Self.isSequenceEntry(rest) || Self.splitKey(rest) != nil {
                // "- key: value" / "- - x": the collection starts on the dash line, at the column after it.
                lines[index] = String(repeating: " ", count: indent + content.count - rest.count) + rest
                items.append(try block(parentIndent: indent))
            } else {
                index += 1
                items.append(try value(rest, parentIndent: indent, inMapping: false))
            }
        }
        return .array(items)
    }

    /// The value after "key:" or "- " (its line already consumed), possibly continued on deeper lines.
    mutating func value(_ raw: String, parentIndent: Int, inMapping: Bool) throws -> DataValue {
        var text = raw
        var anchor: String?
        var tag: String?
        while let first = text.first, first == "&" || first == "!" {
            let token = String(text.prefix { $0 != " " && $0 != "\t" })
            if first == "&" { anchor = String(token.dropFirst()) } else { tag = token }
            text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
        }
        let result: DataValue
        if text.hasPrefix("*") {
            let name = String(text.dropFirst())
            guard let target = anchors[name] else { throw error("unknown alias “*\(name)”") }
            result = target
        } else if text.isEmpty {
            result = try nested(parentIndent: parentIndent, inMapping: inMapping)
        } else if text.first == "|" || text.first == ">" {
            result = .string(blockScalar(header: text, parentIndent: parentIndent))
        } else if text.first == "[" || text.first == "{" {
            var flow = text
            while !Self.isBalanced(flow), index < lines.count {
                flow += " " + Self.content(lines[index])
                index += 1
            }
            result = try YAMLFlow.parse(flow, line: index)
        } else if text.first == "\"" || text.first == "'" {
            var parts = [text]
            func folded() -> String {
                var joined = parts[0], blank = 0
                for part in parts.dropFirst() {
                    if part.isEmpty { blank += 1; continue }
                    joined += blank > 0 ? String(repeating: "\n", count: blank) : " "
                    joined += part
                    blank = 0
                }
                return joined
            }
            while Self.quotedPrefix(Array(folded())) == nil, index < lines.count {
                parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            guard let (decoded, _) = Self.quotedPrefix(Array(folded())) else { throw error("unterminated quoted string") }
            result = .string(decoded)
        } else {
            var plain = text
            while index < lines.count, !Self.isBlank(lines[index]), Self.indentation(lines[index]) > parentIndent {
                plain += " " + Self.content(lines[index])
                index += 1
            }
            result = tag == "!!str" ? .string(plain) : YAMLReader.scalar(plain)
        }
        if let anchor { anchors[anchor] = result }
        return result
    }

    /// What follows an empty "key:" or "-": a deeper block, a sequence at the key's own indent, or null.
    mutating func nested(parentIndent: Int, inMapping: Bool) throws -> DataValue {
        skipBlank()
        guard index < lines.count else { return .null }
        let indent = Self.indentation(lines[index])
        if indent > parentIndent { return try block(parentIndent: parentIndent) }
        if inMapping, indent == parentIndent, Self.isSequenceEntry(Self.content(lines[index])) { return try sequence(indent: indent) }
        return .null
    }

    /// `|` keeps line breaks, `>` folds them; `-` strips the final break, `+` keeps every trailing one.
    mutating func blockScalar(header: String, parentIndent: Int) -> String {
        let literal = header.first == "|"
        var chomp: Character?
        var explicit: Int?
        for c in header.dropFirst() {
            if c == "-" || c == "+" { chomp = c } else if let digit = c.wholeNumberValue { explicit = digit } else { break }
        }
        var blockIndent = explicit.map { max(parentIndent, 0) + $0 }
        var raw: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                raw.append("")
                index += 1
                continue
            }
            let indent = Self.indentation(line)
            if blockIndent == nil {
                guard indent > parentIndent else { break }
                blockIndent = indent
            }
            guard let blockIndent, indent >= blockIndent else { break }
            raw.append(String(line.dropFirst(blockIndent)))
            index += 1
        }
        var trailing = 0
        while raw.last == "" { raw.removeLast(); trailing += 1 }
        var body: String
        if literal {
            body = raw.joined(separator: "\n")
        } else {
            body = ""
            var blank = 0
            var previous: String?
            for line in raw {
                if line.isEmpty { blank += 1; continue }
                if let previous {
                    if previous.first == " " || line.first == " " {
                        body += String(repeating: "\n", count: blank + 1)
                    } else {
                        body += blank == 0 ? " " : String(repeating: "\n", count: blank)
                    }
                } else {
                    body += String(repeating: "\n", count: blank)
                }
                body += line
                blank = 0
                previous = line
            }
        }
        switch chomp {
        case "-": return body
        case "+": return body + String(repeating: "\n", count: trailing + 1)
        default: return body.isEmpty ? "" : body + "\n"
        }
    }

    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for c in text {
            if let open = quote {
                if escaped { escaped = false } else if c == "\\", open == "\"" { escaped = true } else if c == open { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0 && quote == nil
    }
}

/// Flow collections: `[a, b]`, `{key: value}`, nested and quoted.
private struct YAMLFlow {
    let chars: [Character]
    let line: Int
    var i = 0

    static func parse(_ text: String, line: Int) throws -> DataValue {
        var parser = YAMLFlow(chars: Array(text), line: line)
        let value = try parser.node()
        return value
    }

    func error(_ message: String) -> DataSyntaxError { DataSyntaxError(message: message, line: line) }

    mutating func skipSpace() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" { i += 1 }
    }

    mutating func node() throws -> DataValue {
        skipSpace()
        guard i < chars.count else { return .null }
        switch chars[i] {
        case "[":
            i += 1
            var items: [DataValue] = []
            while true {
                skipSpace()
                guard i < chars.count else { throw error("unclosed “[”") }
                if chars[i] == "]" { i += 1; return .array(items) }
                let start = i
                let item = try node()
                skipSpace()
                if i < chars.count, chars[i] == ":" {
                    i += 1
                    items.append(.object([.init(item.cellText, try node())]))
                    skipSpace()
                } else {
                    items.append(item)
                }
                if i < chars.count, chars[i] == "," { i += 1 } else if i == start || (i < chars.count && chars[i] != "]") {
                    throw error("expected “,” or “]”")
                }
            }
        case "{":
            i += 1
            var members: [DataValue.Member] = []
            while true {
                skipSpace()
                guard i < chars.count else { throw error("unclosed “{”") }
                if chars[i] == "}" { i += 1; return .object(members) }
                let start = i
                let key: String
                if chars[i] == "\"" || chars[i] == "'" {
                    guard let (text, length) = YAMLParser.quotedPrefix(Array(chars[i...])) else { throw error("unterminated quoted string") }
                    key = text
                    i += length
                } else {
                    key = plainToken()
                }
                skipSpace()
                var item = DataValue.null
                if i < chars.count, chars[i] == ":" {
                    i += 1
                    item = try node()
                    skipSpace()
                }
                members.append(.init(key, item))
                if i < chars.count, chars[i] == "," { i += 1 } else if i == start || (i < chars.count && chars[i] != "}") {
                    throw error("expected “,” or “}”")
                }
            }
        case "\"", "'":
            guard let (text, length) = YAMLParser.quotedPrefix(Array(chars[i...])) else { throw error("unterminated quoted string") }
            i += length
            return .string(text)
        default:
            return YAMLReader.scalar(plainToken())
        }
    }

    mutating func plainToken() -> String {
        let start = i
        while i < chars.count {
            let c = chars[i]
            if ",[]{}".contains(c) { break }
            if c == ":", i + 1 == chars.count || " ,]}\t".contains(chars[i + 1]) { break }
            i += 1
        }
        return String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
    }
}

enum YAMLWriter {
    static func write(_ value: DataValue) -> String {
        guard isBlockCollection(value) else { return inline(value) + "\n" }
        return lines(value, indent: 0).joined(separator: "\n") + "\n"
    }

    static func isBlockCollection(_ value: DataValue) -> Bool {
        switch value {
        case .array(let items): !items.isEmpty
        case .object(let members): !members.isEmpty
        default: false
        }
    }

    static func lines(_ value: DataValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        func entry(_ prefix: String, _ item: DataValue) {
            if case .string(let text) = item, let (header, body) = literal(text) {
                out.append(prefix + " " + header)
                out += body.map { $0.isEmpty ? "" : pad + "  " + $0 }
            } else {
                out.append(prefix + " " + inline(item))
            }
        }
        switch value {
        case .object(let members):
            for member in members {
                let key = pad + scalar(member.key) + ":"
                if isBlockCollection(member.value) {
                    out.append(key)
                    out += lines(member.value, indent: indent + 2)
                } else {
                    entry(key, member.value)
                }
            }
        case .array(let items):
            for item in items {
                if isBlockCollection(item) {
                    var nested = lines(item, indent: indent + 2)
                    nested[0] = pad + "- " + nested[0].dropFirst(indent + 2)
                    out += nested
                } else {
                    entry(pad + "-", item)
                }
            }
        default:
            out.append(pad + inline(value))
        }
        return out
    }

    /// A multi-line string as a `|` block: (header, lines), or `nil` when it needs quoting instead.
    static func literal(_ text: String) -> (String, [String])? {
        guard text.contains("\n"), !text.hasPrefix(" "), !text.hasPrefix("\n"),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F || $0 == "\n" || $0 == "\t" }) else { return nil }
        var body = text
        let header: String
        if text.hasSuffix("\n\n") {
            header = "|+"
            body.removeLast()
        } else if text.hasSuffix("\n") {
            header = "|"
            body.removeLast()
        } else {
            header = "|-"
        }
        return (header, body.components(separatedBy: "\n"))
    }

    static func inline(_ value: DataValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .int(let integer): String(integer)
        case .double(let real): real.isNaN ? ".nan" : real.isInfinite ? (real < 0 ? "-.inf" : ".inf") : "\(real)"
        case .string(let text): scalar(text)
        case .array(let items): "[" + items.map(inline).joined(separator: ", ") + "]"
        case .object(let members): "{" + members.map { scalar($0.key) + ": " + inline($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// A string as a plain scalar when it reads back as the same string, else quoted.
    static func scalar(_ text: String) -> String {
        guard needsQuotes(text) else { return text }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return JSONWriter.quote(text) }
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func needsQuotes(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if text.contains(": ") || text.contains(" #") || last == ":" || text.contains(where: { ",[]{}".contains($0) }) { return true }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        if ["null", "~", "true", "false", "yes", "no", "on", "off", "y", "n", ".inf", ".nan"].contains(text.lowercased()) { return true }
        // Anything another YAML reader could take for a number, leading zeros included.
        if text.contains(where: \.isNumber), text.allSatisfy({ "0123456789+-.eE_xXoObB:".contains($0) }) { return true }
        return false
    }
}

// MARK: - TOML

/// TOML 1.0: tables, arrays of tables, dotted keys, inline tables, arrays, every string form,
/// integers (hex/octal/binary, underscores), floats, booleans; dates and times stay strings.
enum TOMLReader {
    static func parse(_ text: String) throws -> DataValue {
        var parser = TOMLParser(chars: Array(text.replacingOccurrences(of: "\r\n", with: "\n")))
        return try parser.document()
    }
}

private struct TOMLParser {
    let chars: [Character]
    var i = 0
    var root = DataValue.object([])
    var table: [String] = []

    var current: Character? { i < chars.count ? chars[i] : nil }

    func error(_ message: String) -> DataSyntaxError {
        DataSyntaxError(message: message, line: chars[..<min(i, chars.count)].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) })
    }

    func starts(with text: String) -> Bool {
        var n = i
        for c in text {
            guard n < chars.count, chars[n] == c else { return false }
            n += 1
        }
        return true
    }

    mutating func skipSpaces() { while let c = current, c == " " || c == "\t" { i += 1 } }

    mutating func skipComment() {
        guard current == "#" else { return }
        while let c = current, c != "\n" { i += 1 }
    }

    mutating func skipBlank() {
        while true {
            skipSpaces()
            skipComment()
            guard current == "\n" else { return }
            i += 1
        }
    }

    mutating func document() throws -> DataValue {
        if current == "\u{FEFF}" { i += 1 }
        while true {
            skipBlank()
            guard current != nil else { break }
            // Tree edits report their own problems; the parser adds the line.
            do {
                if current == "[" {
                    i += 1
                    let isArray = current == "["
                    if isArray { i += 1 }
                    let path = try keyPath()
                    guard current == "]" else { throw error("expected “]”") }
                    i += 1
                    if isArray {
                        guard current == "]" else { throw error("expected “]]”") }
                        i += 1
                        try TOMLTree.appendTable(&root, path: path)
                    } else {
                        try TOMLTree.modify(&root, path[...]) { _ in }
                    }
                    table = path
                } else {
                    let path = try keyPath()
                    guard current == "=" else { throw error("expected “=”") }
                    i += 1
                    skipSpaces()
                    let item = try value()
                    try TOMLTree.set(&root, table: table, key: path, value: item)
                }
            } catch let problem as DataSyntaxError where problem.line == nil {
                throw error(problem.message)
            }
            skipSpaces()
            skipComment()
            guard current == nil || current == "\n" else { throw error("unexpected text after a value") }
        }
        return root
    }

    mutating func keyPath() throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            switch current {
            case "\"": parts.append(try basicString())
            case "'": parts.append(try literalString())
            default:
                let start = i
                while let c = current, c.isLetter || c.isNumber || c == "_" || c == "-" { i += 1 }
                guard i > start else { throw error("expected a key") }
                parts.append(String(chars[start..<i]))
            }
            skipSpaces()
            guard current == "." else { return parts }
            i += 1
        }
    }

    mutating func value() throws -> DataValue {
        guard let c = current else { throw error("expected a value") }
        switch c {
        case "\"": return .string(starts(with: "\"\"\"") ? try multiline(literal: false) : try basicString())
        case "'": return .string(starts(with: "'''") ? try multiline(literal: true) : try literalString())
        case "[": return try array()
        case "{": return try inlineTable()
        default: break
        }
        if starts(with: "true") { i += 4; return .bool(true) }
        if starts(with: "false") { i += 5; return .bool(false) }
        let start = i
        func scan() { while let c = current, c.isLetter || c.isNumber || "+-_.:".contains(c) { i += 1 } }
        scan()
        // "1979-05-27 07:32:00": a date-time may use a space instead of "T".
        if i - start == 10, current == " ", i + 3 < chars.count, chars[i + 1].isNumber, chars[i + 2].isNumber, chars[i + 3] == ":" {
            i += 1
            scan()
        }
        let token = String(chars[start..<i])
        guard !token.isEmpty else { throw error("unexpected “\(c)”") }
        guard let scalar = Self.scalar(token) else { throw error("“\(token)” isn't a valid value") }
        return scalar
    }

    static func scalar(_ token: String) -> DataValue? {
        switch token {
        case "inf", "+inf": return .double(.infinity)
        case "-inf": return .double(-.infinity)
        case "nan", "+nan", "-nan": return .double(.nan)
        default: break
        }
        let chars = Array(token)
        let isDate = chars.count >= 10 && chars[4] == "-" && chars[0..<4].allSatisfy(\.isNumber)
        let isTime = chars.count >= 8 && chars[2] == ":" && chars[0..<2].allSatisfy(\.isNumber)
        if isDate || isTime { return .string(token) }
        let clean = token.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where clean.hasPrefix(prefix) {
            return Int(clean.dropFirst(2), radix: radix).map(DataValue.int)
        }
        if clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return Double(clean).map(DataValue.double) }
        return Int(clean).map(DataValue.int) ?? Double(clean).map(DataValue.double)
    }

    mutating func escape(into out: inout String) throws {
        guard let e = current else { throw error("unterminated string") }
        i += 1
        switch e {
        case "b": out.append("\u{08}")
        case "t": out.append("\t")
        case "n": out.append("\n")
        case "f": out.append("\u{0C}")
        case "r": out.append("\r")
        case "e": out.append("\u{1B}")
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "x", "u", "U":
            let count = e == "x" ? 2 : e == "u" ? 4 : 8
            guard i + count <= chars.count, let code = UInt32(String(chars[i..<(i + count)]), radix: 16), let scalar = Unicode.Scalar(code) else {
                throw error("bad \\\(e) escape")
            }
            out.unicodeScalars.append(scalar)
            i += count
        default: throw error("bad escape “\\\(e)”")
        }
    }

    mutating func basicString() throws -> String {
        i += 1
        var out = ""
        while let c = current {
            i += 1
            switch c {
            case "\"": return out
            case "\\": try escape(into: &out)
            case "\n": throw error("unterminated string")
            default: out.append(c)
            }
        }
        throw error("unterminated string")
    }

    mutating func literalString() throws -> String {
        i += 1
        let start = i
        while let c = current, c != "'" {
            if c == "\n" { throw error("unterminated string") }
            i += 1
        }
        guard current == "'" else { throw error("unterminated string") }
        defer { i += 1 }
        return String(chars[start..<i])
    }

    /// `"""…"""` (escapes, line-ending backslash) or `'''…'''`; a newline right after the opening is dropped.
    mutating func multiline(literal: Bool) throws -> String {
        let delimiter: Character = literal ? "'" : "\""
        let closing = String(repeating: delimiter, count: 3)
        i += 3
        if current == "\n" { i += 1 }
        var out = ""
        while let c = current {
            if starts(with: closing) {
                i += 3
                // Up to two quotes may sit right before the closing delimiter.
                var extra = 0
                while current == delimiter, extra < 2 { out.append(delimiter); i += 1; extra += 1 }
                return out
            }
            i += 1
            if !literal, c == "\\" {
                var n = i
                while n < chars.count, chars[n] == " " || chars[n] == "\t" { n += 1 }
                if n < chars.count, chars[n] == "\n" {
                    i = n
                    while let w = current, w == " " || w == "\t" || w == "\n" { i += 1 }
                    continue
                }
                try escape(into: &out)
                continue
            }
            out.append(c)
        }
        throw error("unterminated string")
    }

    mutating func array() throws -> DataValue {
        i += 1
        var items: [DataValue] = []
        while true {
            skipBlank()
            if current == "]" { i += 1; return .array(items) }
            items.append(try value())
            skipBlank()
            if current == "," { i += 1; continue }
            if current == "]" { i += 1; return .array(items) }
            throw error("expected “,” or “]”")
        }
    }

    mutating func inlineTable() throws -> DataValue {
        i += 1
        var table = DataValue.object([])
        while true {
            skipBlank()
            if current == "}" { i += 1; return table }
            let path = try keyPath()
            guard current == "=" else { throw error("expected “=”") }
            i += 1
            skipSpaces()
            let item = try value()
            do {
                try TOMLTree.set(&table, table: [], key: path, value: item)
            } catch let problem as DataSyntaxError where problem.line == nil {
                throw error(problem.message)
            }
            skipBlank()
            if current == "," { i += 1; continue }
            if current == "}" { i += 1; return table }
            throw error("expected “,” or “}”")
        }
    }
}

/// Edits on the TOML tree; an array of tables stands for its last table, as in the format.
private enum TOMLTree {
    static func modify(_ node: inout DataValue, _ path: ArraySlice<String>, _ body: (inout [DataValue.Member]) throws -> Void) throws {
        guard case .object(var members) = node else { throw DataSyntaxError(message: "not a table") }
        node = .null
        defer { node = .object(members) }
        guard let key = path.first else {
            try body(&members)
            return
        }
        let index: Int
        if let found = members.firstIndex(where: { $0.key == key }) {
            index = found
        } else {
            members.append(.init(key, .object([])))
            index = members.count - 1
        }
        var child = members[index].value
        members[index].value = .null
        defer { members[index].value = child }
        switch child {
        case .object:
            try modify(&child, path.dropFirst(), body)
        case .array(var items) where items.last?.isObject == true:
            child = .null
            var last = items.removeLast()
            defer {
                items.append(last)
                child = .array(items)
            }
            try modify(&last, path.dropFirst(), body)
        default:
            throw DataSyntaxError(message: "“\(key)” is already a value")
        }
    }

    static func set(_ root: inout DataValue, table: [String], key: [String], value: DataValue) throws {
        guard let last = key.last else { return }
        try modify(&root, (table + key.dropLast())[...]) { members in
            guard !members.contains(where: { $0.key == last }) else { throw DataSyntaxError(message: "“\(last)” is defined twice") }
            members.append(.init(last, value))
        }
    }

    static func appendTable(_ root: inout DataValue, path: [String]) throws {
        guard let last = path.last else { return }
        try modify(&root, path.dropLast()[...]) { members in
            if let index = members.firstIndex(where: { $0.key == last }) {
                guard case .array(var items) = members[index].value else { throw DataSyntaxError(message: "“\(last)” isn't an array of tables") }
                items.append(.object([]))
                members[index].value = .array(items)
            } else {
                members.append(.init(last, .array([.object([])])))
            }
        }
    }
}

enum TOMLWriter {
    static func write(_ value: DataValue) -> String {
        let members: [DataValue.Member] = switch value {
        case .object(let members): members
        case .null: []
        case .array: [.init("items", value)]
        default: [.init("value", value)]
        }
        var out: [String] = []
        table(members, path: [], into: &out)
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    static func isTable(_ value: DataValue) -> Bool {
        if case .object(let members) = value { !members.isEmpty } else { false }
    }

    static func isTableArray(_ value: DataValue) -> Bool {
        if case .array(let items) = value { !items.isEmpty && items.allSatisfy(\.isObject) } else { false }
    }

    private static func table(_ members: [DataValue.Member], path: [String], into out: inout [String]) {
        for member in members where !member.value.isNull && !isTable(member.value) && !isTableArray(member.value) {
            out.append(key(member.key) + " = " + inline(member.value))
        }
        for member in members {
            let sub = path + [member.key]
            let header = sub.map(key).joined(separator: ".")
            if case .object(let children) = member.value, !children.isEmpty {
                if !out.isEmpty { out.append("") }
                out.append("[\(header)]")
                table(children, path: sub, into: &out)
            } else if isTableArray(member.value), case .array(let items) = member.value {
                for case .object(let children) in items {
                    if !out.isEmpty { out.append("") }
                    out.append("[[\(header)]]")
                    table(children, path: sub, into: &out)
                }
            }
        }
    }

    static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        return bare ? name : JSONWriter.quote(name)
    }

    static func inline(_ value: DataValue) -> String {
        switch value {
        case .null: "\"\""
        case .bool(let flag): flag ? "true" : "false"
        case .int(let integer): String(integer)
        case .double(let real): real.isNaN ? "nan" : real.isInfinite ? (real < 0 ? "-inf" : "inf") : "\(real)"
        case .string(let text): JSONWriter.quote(text)
        case .array(let items): "[" + items.filter { !$0.isNull }.map(inline).joined(separator: ", ") + "]"
        case .object(let members):
            members.isEmpty ? "{}" : "{ " + members.filter { !$0.value.isNull }.map { key($0.key) + " = " + inline($0.value) }.joined(separator: ", ") + " }"
        }
    }
}

// MARK: - XML

/// XML ⇄ tree: attributes become "@name" keys, text "#text", repeated children an array.
enum XMLData {
    static func read(_ data: Data) throws -> DataValue {
        let document: Foundation.XMLDocument
        do {
            document = try Foundation.XMLDocument(data: data, options: [])
        } catch {
            throw DataSyntaxError(message: (error as NSError).localizedDescription)
        }
        guard let root = document.rootElement() else { throw DataSyntaxError(message: "no root element") }
        return .object([.init(root.name ?? "root", element(root))])
    }

    static func element(_ node: Foundation.XMLElement) -> DataValue {
        var members: [DataValue.Member] = []
        for namespace in node.namespaces ?? [] {
            let prefix = namespace.name ?? ""
            members.append(.init(prefix.isEmpty ? "@xmlns" : "@xmlns:\(prefix)", .string(namespace.stringValue ?? "")))
        }
        for attribute in node.attributes ?? [] {
            members.append(.init("@" + (attribute.name ?? ""), .string(attribute.stringValue ?? "")))
        }
        var text = ""
        var order: [String] = []
        var groups: [String: [DataValue]] = [:]
        for child in node.children ?? [] {
            switch child.kind {
            case .text:
                text += child.stringValue ?? ""
            case .element:
                guard let element = child as? Foundation.XMLElement else { continue }
                let name = element.name ?? ""
                if groups[name] == nil { order.append(name) }
                groups[name, default: []].append(self.element(element))
            default:
                continue
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if members.isEmpty, order.isEmpty { return trimmed.isEmpty ? .null : .string(trimmed) }
        if !trimmed.isEmpty { members.append(.init("#text", .string(trimmed))) }
        for name in order {
            let values = groups[name] ?? []
            members.append(.init(name, values.count == 1 ? values[0] : .array(values)))
        }
        return .object(members)
    }

    static func write(_ value: DataValue) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if case .object(let members) = value, members.count == 1, let only = members.first,
           !only.key.hasPrefix("@"), only.key != "#text", !only.value.isArray {
            element(only.key, only.value, depth: 0, into: &out)
        } else if value.isArray {
            element("root", .object([.init("item", value)]), depth: 0, into: &out)
        } else {
            element("root", value, depth: 0, into: &out)
        }
        return out
    }

    private static func element(_ name: String, _ value: DataValue, depth: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: depth)
        let tag = xmlName(name)
        switch value {
        case .array(let items):
            for item in items {
                // A list inside a list keeps its own element, or the two would merge.
                element(name, item.isArray ? .object([.init("item", item)]) : item, depth: depth, into: &out)
            }
        case .object(let members):
            var attributes = ""
            var text: String?
            var children: [DataValue.Member] = []
            for member in members {
                if member.key.hasPrefix("@") {
                    attributes += " \(xmlName(String(member.key.dropFirst())))=\"\(xmlEscape(member.value.cellText))\""
                } else if member.key == "#text" {
                    text = member.value.cellText
                } else {
                    children.append(member)
                }
            }
            if children.isEmpty {
                if let text { out += "\(pad)<\(tag)\(attributes)>\(xmlEscape(text))</\(tag)>\n" } else { out += "\(pad)<\(tag)\(attributes)/>\n" }
                return
            }
            out += "\(pad)<\(tag)\(attributes)>\n"
            if let text { out += "\(pad)  \(xmlEscape(text))\n" }
            for child in children { element(child.key, child.value, depth: depth + 1, into: &out) }
            out += "\(pad)</\(tag)>\n"
        case .null:
            out += "\(pad)<\(tag)/>\n"
        default:
            out += "\(pad)<\(tag)>\(xmlEscape(value.cellText))</\(tag)>\n"
        }
    }

    /// Any key as a valid XML name.
    static func xmlName(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let valid = CharacterSet.alphanumerics.contains(scalar) || "_-.:".unicodeScalars.contains(scalar)
            out.unicodeScalars.append(valid ? scalar : "_")
        }
        if let first = out.unicodeScalars.first, !(CharacterSet.letters.contains(first) || first == "_" || first == ":") { out = "_" + out }
        return out.isEmpty ? "_" : out
    }
}

// MARK: - Property lists

enum PlistData {
    /// XML plists are parsed directly so dictionaries keep their order; binary and old-style ones
    /// go through PropertyListSerialization (sorted keys).
    static func read(_ data: Data) throws -> DataValue {
        if !data.starts(with: Array("bplist".utf8)), let document = try? Foundation.XMLDocument(data: data, options: []),
           let root = document.rootElement(), root.name == "plist" {
            guard let first = root.children?.compactMap({ $0 as? Foundation.XMLElement }).first else { return .null }
            return node(first)
        }
        do {
            return DataValue(any: try PropertyListSerialization.propertyList(from: data, format: nil))
        } catch {
            throw DataSyntaxError(message: String(localized: "not a property list"))
        }
    }

    private static func node(_ element: Foundation.XMLElement) -> DataValue {
        let text = element.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let children = (element.children ?? []).compactMap { $0 as? Foundation.XMLElement }
        switch element.name {
        case "dict":
            var members: [DataValue.Member] = []
            var key: String?
            for child in children {
                if child.name == "key" {
                    key = child.stringValue ?? ""
                } else if let pending = key {
                    members.append(.init(pending, node(child)))
                    key = nil
                }
            }
            return .object(members)
        case "array": return .array(children.map(node))
        case "string": return .string(text)
        case "integer": return Int(trimmed).map(DataValue.int) ?? .double(Double(trimmed) ?? 0)
        case "real": return .double(Double(trimmed) ?? 0)
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "date": return .string(trimmed)
        case "data": return .string(text.filter { !$0.isWhitespace })
        default: return .null
        }
    }

    static func write(_ value: DataValue) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        emit(value.isNull ? .object([]) : value, depth: 0, into: &out)
        return out + "</plist>\n"
    }

    private static func emit(_ value: DataValue, depth: Int, into out: inout String) {
        let pad = String(repeating: "\t", count: depth)
        switch value {
        case .null: out += "\(pad)<string></string>\n"
        case .bool(let flag): out += "\(pad)<\(flag ? "true" : "false")/>\n"
        case .int(let integer): out += "\(pad)<integer>\(integer)</integer>\n"
        case .double(let real):
            let text = real.isNaN ? "nan" : real.isInfinite ? (real < 0 ? "-infinity" : "+infinity") : "\(real)"
            out += "\(pad)<real>\(text)</real>\n"
        case .string(let text): out += "\(pad)<string>\(xmlEscape(text))</string>\n"
        case .array(let items):
            guard !items.isEmpty else { out += "\(pad)<array/>\n"; return }
            out += "\(pad)<array>\n"
            for item in items { emit(item, depth: depth + 1, into: &out) }
            out += "\(pad)</array>\n"
        case .object(let members):
            let present = members.filter { !$0.value.isNull }
            guard !present.isEmpty else { out += "\(pad)<dict/>\n"; return }
            out += "\(pad)<dict>\n"
            for member in present {
                out += "\(pad)\t<key>\(xmlEscape(member.key))</key>\n"
                emit(member.value, depth: depth + 1, into: &out)
            }
            out += "\(pad)</dict>\n"
        }
    }
}

// MARK: - SQLite

/// SQLite through the system's libsqlite3.
enum SQLiteFile {
    struct Table {
        var name: String
        var columns: [String]
        var rows: [[DataValue]]

        var sheet: Sheet { Sheet(name: name, rows: [columns] + rows.map { $0.map(\.cellText) }) }

        var records: DataValue {
            .array(rows.map { row in .object(zip(columns, row).map { .init($0, $1) }) })
        }
    }

    static func read(_ url: URL) throws -> [Table] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw KumquatError.cannotOpen(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        let names = try query(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid").rows
            .compactMap { row -> String? in if case .string(let name)? = row.first { name } else { nil } }
        return try names.map { name in
            let result = try query(db, "SELECT * FROM \(identifier(name))")
            return Table(name: name, columns: result.columns, rows: result.rows)
        }
    }

    static func query(_ db: OpaquePointer, _ sql: String) throws -> (columns: [String], rows: [[DataValue]]) {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[DataValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure(db) }
            rows.append((0..<count).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: return .string(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { return .string("") }
                    return .string(Data(bytes: bytes, count: length).base64EncodedString())
                default: return .null
                }
            })
        }
        return (columns, rows)
    }

    static func write(_ sheets: [Sheet], to url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw KumquatError.cannotWrite(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try execute(db, "BEGIN")
        var tableNames = Set<String>()
        for sheet in sheets {
            let header = sheet.rows.first ?? []
            let body = sheet.rows.dropFirst().filter { $0.contains { !$0.isEmpty } }
            let width = max(header.count, body.map(\.count).max() ?? 0)
            guard width > 0 else { continue }
            let columns = DataEngine.uniqueHeaders(header, width: width)
            let types = (0..<width).map { column -> String in
                let values = body.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }
                guard !values.isEmpty, values.allSatisfy({ numericValue($0) != nil }) else { return "TEXT" }
                return values.allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) != nil } ? "INTEGER" : "REAL"
            }
            var name = sheet.name.isEmpty ? "Sheet" : sheet.name, counter = 2
            while !tableNames.insert(name.lowercased()).inserted { name = "\(sheet.name) \(counter)"; counter += 1 }
            let definition = zip(columns, types).map { "\(identifier($0)) \($1)" }.joined(separator: ", ")
            try execute(db, "CREATE TABLE \(identifier(name)) (\(definition))")

            var handle: OpaquePointer?
            let placeholders = Array(repeating: "?", count: width).joined(separator: ", ")
            guard sqlite3_prepare_v2(db, "INSERT INTO \(identifier(name)) VALUES (\(placeholders))", -1, &handle, nil) == SQLITE_OK,
                  let insert = handle else { throw failure(db) }
            defer { sqlite3_finalize(insert) }
            for row in body {
                for column in 0..<width {
                    let index = Int32(column + 1)
                    let cell = column < row.count ? row[column].trimmingCharacters(in: .whitespaces) : ""
                    if cell.isEmpty {
                        sqlite3_bind_null(insert, index)
                    } else if types[column] == "INTEGER", let integer = Int64(cell) {
                        sqlite3_bind_int64(insert, index, integer)
                    } else if types[column] == "REAL", let real = Double(cell) {
                        sqlite3_bind_double(insert, index, real)
                    } else {
                        sqlite3_bind_text(insert, index, column < row.count ? row[column] : "", -1, transient)
                    }
                }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure(db) }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
            }
        }
        try execute(db, "COMMIT")
    }

    static func identifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }

    static func failure(_ db: OpaquePointer) -> KumquatError {
        .processFailed("SQLite: " + String(cString: sqlite3_errmsg(db)))
    }
}

// MARK: - vCard & iCalendar

/// RFC 5545 / 6350 content lines: unfolding, parameters, escapes, quoted-printable (vCard 2.1).
enum ContentLines {
    struct Line {
        var name: String
        var parameters: [String: String]
        var value: String
    }

    static func parse(_ text: String) -> [Line] {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var unfolded: [String] = []
        for line in raw {
            if let last = unfolded.last {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    unfolded[unfolded.count - 1] = last + line.dropFirst()
                    continue
                }
                if last.hasSuffix("="), last.uppercased().contains("QUOTED-PRINTABLE") {
                    unfolded[unfolded.count - 1] = String(last.dropLast()) + line
                    continue
                }
            }
            if !line.isEmpty { unfolded.append(line) }
        }
        return unfolded.compactMap(line)
    }

    static func line(_ text: String) -> Line? {
        var inQuotes = false
        guard let colon = text.firstIndex(where: { c in
            if c == "\"" { inQuotes.toggle() }
            return c == ":" && !inQuotes
        }) else { return nil }
        let head = text[..<colon]
        var value = String(text[text.index(after: colon)...])
        let parts = head.split(separator: ";")
        guard var name = parts.first.map({ $0.uppercased() }) else { return nil }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            if let equals = part.firstIndex(of: "=") {
                let key = part[..<equals].uppercased()
                let item = part[part.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                parameters[key] = parameters[key].map { "\($0),\(item)" } ?? item
            } else if part.uppercased() == "QUOTED-PRINTABLE" || part.uppercased() == "BASE64" {
                parameters["ENCODING"] = part.uppercased()
            } else {
                parameters["TYPE"] = parameters["TYPE"].map { "\($0),\(part)" } ?? String(part)
            }
        }
        if parameters["ENCODING"]?.uppercased() == "QUOTED-PRINTABLE" { value = quotedPrintable(value) }
        return Line(name: name, parameters: parameters, value: value)
    }

    static func quotedPrintable(_ text: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(text.utf8)
        var n = 0
        while n < chars.count {
            if chars[n] == UInt8(ascii: "="), n + 2 < chars.count,
               let byte = UInt8(String(decoding: chars[(n + 1)...(n + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                n += 3
            } else {
                bytes.append(chars[n])
                n += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Text value without its backslash escapes.
    static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for c in text {
            if escaped {
                out.append(c == "n" || c == "N" ? "\n" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Structured value ("Family;Given;…") split on unescaped semicolons.
    static func components(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for c in text {
            if escaped {
                current.append("\\")
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == ";" {
                parts.append(unescape(current))
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(unescape(current))
        return parts
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 octets continue on the next line after a space.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = ""
        var count = 0
        for c in line {
            let size = String(c).utf8.count
            if count + size > 75 {
                out += "\r\n "
                count = 1
            }
            out.append(c)
            count += size
        }
        return out
    }

    static func document(_ lines: [String]) -> String {
        lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
}

/// Spreadsheet header names matched in English or Italian, ignoring case and accents.
struct ColumnMatcher {
    let headers: [String]

    init(_ header: [String]) {
        headers = header.map(ColumnMatcher.normalize)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First column named exactly like one of `names`.
    func first(_ names: [String]) -> Int? {
        for name in names {
            if let index = headers.firstIndex(of: name) { return index }
        }
        return nil
    }

    /// Every column named like one of `names`, or starting with one ("Phone (work)", "Email 2").
    func all(_ names: [String]) -> [Int] {
        headers.indices.filter { index in
            names.contains { name in
                headers[index] == name || headers[index].hasPrefix(name + " ") || headers[index].hasPrefix(name + "(")
            }
        }
    }
}

enum VCard {
    static let headers = ["Name", "Organization", "Phones", "Emails", "Address", "Birthday", "Note"]

    /// Header row plus one row per contact.
    static func rows(_ text: String) -> [[String]] {
        var rows = [headers]
        var card: [ContentLines.Line]?
        for line in ContentLines.parse(text) {
            switch (line.name, line.value.uppercased()) {
            case ("BEGIN", "VCARD"): card = []
            case ("END", "VCARD"):
                if let card { rows.append(row(card)) }
                card = nil
            default: card?.append(line)
            }
        }
        return rows
    }

    static func row(_ card: [ContentLines.Line]) -> [String] {
        func values(_ name: String) -> [String] { card.filter { $0.name == name }.map(\.value) }
        var name = values("FN").first.map(ContentLines.unescape) ?? ""
        if name.isEmpty, let structured = values("N").first {
            let parts = ContentLines.components(structured) + Array(repeating: "", count: 5)
            name = [parts[3], parts[1], parts[2], parts[0], parts[4]].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let organization = values("ORG").first.map { ContentLines.components($0).filter { !$0.isEmpty }.joined(separator: ", ") } ?? ""
        let phones = values("TEL").map(ContentLines.unescape).joined(separator: "; ")
        let emails = values("EMAIL").map(ContentLines.unescape).joined(separator: "; ")
        let addresses = values("ADR").map { value in
            ContentLines.components(value).map { $0.replacingOccurrences(of: "\n", with: ", ") }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let birthday = values("BDAY").first.map(normalizeBirthday) ?? ""
        let note = values("NOTE").map(ContentLines.unescape).joined(separator: "\n")
        return [name, organization, phones, emails, addresses.joined(separator: "; "), birthday, note]
    }

    /// "19850412" → "1985-04-12"; time parts are dropped.
    static func normalizeBirthday(_ value: String) -> String {
        let date = value.split(separator: "T").first.map(String.init) ?? value
        if date.count == 8, date.allSatisfy(\.isNumber) {
            let chars = Array(date)
            return "\(String(chars[0..<4]))-\(String(chars[4..<6]))-\(String(chars[6..<8]))"
        }
        return date
    }

    static func write(_ sheet: Sheet) throws -> String {
        guard let header = sheet.rows.first else { throw KumquatError.noResult(String(localized: "The sheet is empty.")) }
        let columns = ColumnMatcher(header)
        let last = columns.first(["last name", "surname", "family name", "cognome"])
        let full = columns.first(["name", "full name", "display name", "nome completo", "nominativo", "contact", "contatto"])
            ?? (last == nil ? columns.first(["nome"]) : nil)
        let given = columns.first(["first name", "given name"]) ?? (last != nil ? columns.first(["nome"]) : nil)
        let phones = columns.all(["phone", "phones", "telephone", "tel", "mobile", "cell", "cell phone", "telefono", "telefoni", "cellulare", "cell."])
        let emails = columns.all(["email", "emails", "e-mail", "e mail", "mail", "posta elettronica"])
        let company = columns.first(["company", "organization", "organisation", "org", "azienda", "societa", "ditta", "organizzazione"])
        let address = columns.first(["address", "home address", "indirizzo"])
        let birthday = columns.first(["birthday", "birth date", "date of birth", "compleanno", "data di nascita"])
        let note = columns.first(["note", "notes", "nota", "comment", "comments", "commento"])
        guard full != nil || given != nil || last != nil || !phones.isEmpty || !emails.isEmpty else {
            throw KumquatError.noResult(String(localized: "No Name, Phone or Email column found in the first row."))
        }
        let parser = DateParser()
        var lines: [String] = []
        for row in sheet.rows.dropFirst() {
            func cell(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let split: (String) -> [String] = { $0.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            let numbers = phones.flatMap { split(cell($0)) }
            let addresses = emails.flatMap { split(cell($0)) }
            var family = cell(last), first = cell(given)
            var name = cell(full)
            if name.isEmpty { name = [first, family].filter { !$0.isEmpty }.joined(separator: " ") }
            if family.isEmpty, first.isEmpty, !name.isEmpty {
                // "Ada Lovelace" → given "Ada", family "Lovelace".
                let words = name.split(separator: " ")
                family = words.count > 1 ? String(words.last!) : name
                first = words.count > 1 ? words.dropLast().joined(separator: " ") : ""
            }
            let organization = cell(company)
            guard !name.isEmpty || !numbers.isEmpty || !addresses.isEmpty else { continue }
            let display = !name.isEmpty ? name : !organization.isEmpty ? organization : (addresses.first ?? numbers.first ?? "")
            lines += ["BEGIN:VCARD", "VERSION:3.0",
                      "N:\(ContentLines.escape(family));\(ContentLines.escape(first));;;",
                      "FN:\(ContentLines.escape(display))"]
            if !organization.isEmpty { lines.append("ORG:\(ContentLines.escape(organization))") }
            lines += numbers.map { "TEL;TYPE=CELL:\(ContentLines.escape($0))" }
            lines += addresses.map { "EMAIL;TYPE=INTERNET:\(ContentLines.escape($0))" }
            if !cell(address).isEmpty { lines.append("ADR;TYPE=HOME:;;\(ContentLines.escape(cell(address)));;;;") }
            let born = cell(birthday)
            if !born.isEmpty {
                lines.append("BDAY:" + (parser.parse(born).map { DateParser.string($0.date, "yyyy-MM-dd") } ?? ContentLines.escape(born)))
            }
            if !cell(note).isEmpty { lines.append("NOTE:\(ContentLines.escape(cell(note)))") }
            lines.append("END:VCARD")
        }
        guard !lines.isEmpty else { throw KumquatError.noResult(String(localized: "No rows with a name, phone or email.")) }
        return ContentLines.document(lines)
    }
}

enum ICal {
    static let headers = ["Summary", "Start", "End", "Location", "Description", "All Day"]

    /// Header row plus one row per event (VEVENT), times shown in this Mac's time zone.
    static func rows(_ text: String) -> [[String]] {
        var rows = [headers]
        var event: [ContentLines.Line]?
        var depth = 0
        for line in ContentLines.parse(text) {
            let value = line.value.uppercased()
            if line.name == "BEGIN" {
                if value == "VEVENT" { event = []; depth = 0 } else if event != nil { depth += 1 }
                continue
            }
            if line.name == "END" {
                if value == "VEVENT", let current = event { rows.append(row(current)); event = nil } else if event != nil { depth -= 1 }
                continue
            }
            // Properties of nested components (alarms) don't describe the event.
            if depth == 0 { event?.append(line) }
        }
        return rows
    }

    static func row(_ event: [ContentLines.Line]) -> [String] {
        func first(_ name: String) -> ContentLines.Line? { event.first { $0.name == name } }
        func text(_ name: String) -> String { first(name).map { ContentLines.unescape($0.value) } ?? "" }
        let start = first("DTSTART").flatMap(moment)
        var end = first("DTEND").flatMap(moment)
        if end == nil, let start, let duration = first("DURATION").flatMap({ seconds(fromDuration: $0.value) }) {
            end = (start.date.addingTimeInterval(duration), start.allDay)
        }
        let allDay = start?.allDay ?? false
        func display(_ moment: (date: Date, allDay: Bool)?, inclusiveEnd: Bool = false) -> String {
            guard let moment else { return "" }
            if moment.allDay {
                // All-day ends are exclusive in iCalendar; a sheet reads better with the last day.
                let day = inclusiveEnd ? moment.date.addingTimeInterval(-86_400) : moment.date
                return DateParser.string(day, "yyyy-MM-dd")
            }
            return DateParser.string(moment.date, "yyyy-MM-dd HH:mm")
        }
        var endText = display(end, inclusiveEnd: true)
        if let start, let end, end.date <= start.date.addingTimeInterval(allDay ? 86_400 : 0) { endText = display(start) }
        return [text("SUMMARY"), display(start), endText, text("LOCATION"), text("DESCRIPTION"), allDay ? "yes" : "no"]
    }

    /// DTSTART/DTEND: dates are all-day, "Z" times UTC, TZID times in that zone, the rest local.
    static func moment(_ line: ContentLines.Line) -> (date: Date, allDay: Bool)? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let allDay = line.parameters["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && value.allSatisfy(\.isNumber))
        if allDay { return DateParser.date(value, "yyyyMMdd", zone: .current).map { ($0, true) } }
        if value.hasSuffix("Z") { return DateParser.date(String(value.dropLast()), "yyyyMMdd'T'HHmmss", zone: TimeZone(identifier: "UTC")!).map { ($0, false) } }
        let zone = line.parameters["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
        return DateParser.date(value, "yyyyMMdd'T'HHmmss", zone: zone).map { ($0, false) }
    }

    /// "P1DT2H30M" → seconds.
    static func seconds(fromDuration text: String) -> TimeInterval? {
        var total = 0.0, number = "", sign = 1.0
        for c in text.uppercased() {
            switch c {
            case "-": sign = -1
            case "+", "P", "T": continue
            case "W", "D", "H", "M", "S":
                guard let value = Double(number) else { return nil }
                let unit: Double = switch c {
                case "W": 604_800
                case "D": 86_400
                case "H": 3600
                case "M": 60
                default: 1
                }
                total += value * unit
                number = ""
            default: number.append(c)
            }
        }
        return total * sign
    }

    static func write(_ sheet: Sheet) throws -> String {
        guard let header = sheet.rows.first else { throw KumquatError.noResult(String(localized: "The sheet is empty.")) }
        let columns = ColumnMatcher(header)
        let title = columns.first(["title", "titolo", "summary", "event", "evento", "subject", "oggetto", "name", "nome", "description"])
        let start = columns.first(["start", "inizio", "start date", "data inizio", "begin", "date", "data", "from", "dal", "when", "quando", "giorno", "day"])
        let end = columns.first(["end", "fine", "end date", "data fine", "until", "to", "al"])
        let startTime = columns.first(["start time", "ora inizio", "time", "ora", "orario"])
        let endTime = columns.first(["end time", "ora fine"])
        let location = columns.first(["location", "luogo", "place", "where", "dove", "posto", "sede"])
        let description = columns.first(["description", "descrizione", "details", "dettagli", "note", "notes"]).flatMap { $0 == title ? nil : $0 }
        let allDayColumn = columns.first(["all day", "all-day", "allday", "tutto il giorno", "giornata intera"])
        guard let start else {
            throw KumquatError.noResult(String(localized: "No Start column found in the first row (Start, Date, Inizio, Data…)."))
        }
        let parser = DateParser()
        let stamp = DateParser.string(Date(), "yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(identifier: "UTC")!)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Kumquat//Kumquat//EN", "CALSCALE:GREGORIAN"]
        var count = 0
        for row in sheet.rows.dropFirst() {
            func cell(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func joined(_ date: Int?, _ time: Int?) -> String { [cell(date), cell(time)].filter { !$0.isEmpty }.joined(separator: " ") }
            guard let begin = parser.parse(joined(start, startTime)) else { continue }
            let flag = cell(allDayColumn).lowercased()
            let allDay = ["yes", "y", "true", "1", "x", "si", "sì", "vero"].contains(flag) || (!begin.hasTime && !["no", "false", "0", "falso"].contains(flag))
            var finish: (date: Date, hasTime: Bool)?
            if !cell(end).isEmpty {
                finish = parser.parse(joined(end, endTime))
            } else if !cell(endTime).isEmpty {
                finish = parser.parse(DateParser.string(begin.date, "yyyy-MM-dd") + " " + cell(endTime))
            }
            let calendar = Calendar.current
            let first = allDay ? calendar.startOfDay(for: begin.date) : begin.date
            var last: Date
            if allDay {
                // The sheet's end day is inclusive; iCalendar's is the day after.
                last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: finish?.date ?? first))!
                if last <= first { last = calendar.date(byAdding: .day, value: 1, to: first)! }
            } else {
                if finish?.hasTime == false { finish = nil }
                last = finish?.date ?? first.addingTimeInterval(3600)
                if last <= first { last = first.addingTimeInterval(3600) }
            }
            let format = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
            let prefix = allDay ? ";VALUE=DATE:" : ":"
            lines += ["BEGIN:VEVENT", "UID:\(UUID().uuidString)@kumquat", "DTSTAMP:\(stamp)",
                      "DTSTART\(prefix)\(DateParser.string(first, format))", "DTEND\(prefix)\(DateParser.string(last, format))"]
            let summary = cell(title)
            lines.append("SUMMARY:" + ContentLines.escape(summary.isEmpty ? String(localized: "Event") : summary))
            if !cell(location).isEmpty { lines.append("LOCATION:\(ContentLines.escape(cell(location)))") }
            if !cell(description).isEmpty { lines.append("DESCRIPTION:\(ContentLines.escape(cell(description)))") }
            lines.append("END:VEVENT")
            count += 1
        }
        guard count > 0 else { throw KumquatError.noResult(String(localized: "No rows with a date the calendar can read.")) }
        lines.append("END:VCALENDAR")
        return ContentLines.document(lines)
    }
}

/// Dates as people type them in sheets: ISO, European (dd/MM/yyyy first), US, with or without a
/// time, plus Excel serial numbers. Interpreted in this Mac's time zone.
struct DateParser {
    private let withTime: [DateFormatter]
    private let dateOnly: [DateFormatter]

    init() {
        func formatters(_ formats: [String], locales: [String] = ["en_US_POSIX"]) -> [DateFormatter] {
            locales.flatMap { locale in
                formats.map { format in
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: locale)
                    formatter.timeZone = .current
                    formatter.dateFormat = format
                    formatter.isLenient = false
                    return formatter
                }
            }
        }
        withTime = formatters([
            "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm",
            "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "d/M/yyyy H:mm", "dd.MM.yyyy HH:mm", "d.M.yyyy H:mm", "dd-MM-yyyy HH:mm",
            "dd/MM/yyyy HH.mm", "d/M/yyyy H.mm", "MM/dd/yyyy h:mm a", "M/d/yyyy h:mm a", "MM/dd/yyyy HH:mm", "yyyyMMdd'T'HHmmss",
        ])
        dateOnly = formatters(["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "d.M.yyyy", "dd-MM-yyyy", "d-M-yyyy",
                               "MM/dd/yyyy", "M/d/yyyy", "yyyyMMdd", "dd/MM/yy", "d/M/yy"])
            + formatters(["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy", "EEEE d MMMM yyyy"], locales: ["en_US", "it_IT"])
    }

    func parse(_ raw: String) -> (date: Date, hasTime: Bool)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Excel stores dates as days since 1899-12-30 (XLSX cells read back as these numbers).
        if let serial = Double(text) {
            // 20 000…80 000 is 1954…2119; other bare numbers aren't dates.
            guard serial >= 20_000, serial <= 80_000, let base = Calendar.current.date(from: DateComponents(year: 1899, month: 12, day: 30)),
                  let day = Calendar.current.date(byAdding: .day, value: Int(serial), to: base) else { return nil }
            let seconds = ((serial - serial.rounded(.down)) * 86_400).rounded()
            return (day.addingTimeInterval(seconds), seconds > 0)
        }
        for formatter in withTime {
            if let date = formatter.date(from: text), plausible(date) { return (date, true) }
        }
        for formatter in dateOnly {
            if let date = formatter.date(from: text), plausible(date) { return (date, false) }
        }
        return nil
    }

    private func plausible(_ date: Date) -> Bool {
        let year = Calendar.current.component(.year, from: date)
        return year >= 1000 && year <= 9999
    }

    static func string(_ date: Date, _ format: String, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func date(_ text: String, _ format: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.date(from: text)
    }
}
