import Foundation

/// Spreadsheet tools added after 1.2.
extension SheetEngine {
    /// Format a sheet tool writes: the source's, or XLSX for formats Kumquat only reads.
    public static func toolOutputFormat(for source: FileFormat) -> FileFormat {
        source.isInputOnly || source.category != .spreadsheet ? .xlsx : source
    }

    /// One file per distinct value of `column` (header name or letter; empty = first column), named "<base> – <value>".
    /// Works on the first sheet; CSV stays CSV.
    public static func splitByColumn(_ input: URL, from source: FileFormat, column: String, into directory: URL) async throws -> [URL] {
        let sheets = try await read(input, format: source)
        guard let sheet = sheets.first, let header = sheet.rows.first, sheet.rows.count > 1 else {
            throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no rows to split."))
        }
        let index = try columnIndex(column, in: header, file: input.lastPathComponent)
        var order: [String] = []
        var groups: [String: [[String]]] = [:]
        for row in sheet.rows.dropFirst() where row.contains(where: { !$0.isEmpty }) {
            let value = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if groups[value] == nil { order.append(value) }
            groups[value, default: []].append(row)
        }
        let columnName = index < header.count && !header[index].isEmpty ? header[index] : XLSX.columnName(index)
        guard order.count > 1 else {
            throw KumquatError.noResult(String(localized: "Every row has the same “\(columnName)”: nothing to split."))
        }
        guard order.count <= 500 else {
            throw KumquatError.noResult(String(localized: "“\(columnName)” has \(order.count) different values: too many files."))
        }
        let format = toolOutputFormat(for: source)
        let base = input.deletingPathExtension().lastPathComponent
        let parts = order.map { value in (value.isEmpty ? String(localized: "(empty)") : String(value.prefix(80)), [header] + (groups[value] ?? [])) }
        return try await runBlocking {
            var outputs: [URL] = []
            do {
                for (label, rows) in parts {
                    let output = try OutputNaming.reserve(in: directory, base: "\(base) – \(label)", ext: format.fileExtension)
                    outputs.append(output)
                    try write([Sheet(name: label, rows: rows)], as: format, to: output, title: label)
                }
            } catch {
                for url in outputs { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return outputs
        }
    }

    /// CSV that Excel opens correctly in Italian/European locales: ";" separator, decimal comma, UTF-8 with BOM, CRLF.
    public static func excelCSV(_ input: URL, from source: FileFormat, output: URL) async throws {
        let rows = try await read(input, format: source).first?.rows ?? []
        guard !rows.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is empty.")) }
        let text = rows.map { row in
            row.map { field -> String in
                if let number = numericValue(field) { return number.replacingOccurrences(of: ".", with: ",") }
                let needsQuotes = field.contains(";") || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: ";")
        }.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: output, options: .atomic)
    }

    /// Removes repeated rows (whole row, or same value in `column`), keeping the header and first occurrences. Returns how many went.
    public static func dedupe(_ input: URL, from source: FileFormat, column: String, output: URL) async throws -> Int {
        let format = toolOutputFormat(for: source)
        var sheets = try await read(input, format: source)
        if format == .csv || format == .tsv { sheets = Array(sheets.prefix(1)) }
        let byColumn = !column.trimmingCharacters(in: .whitespaces).isEmpty
        var removed = 0
        var matchedColumn = false
        var firstProblem: Error?
        for (index, sheet) in sheets.enumerated() {
            guard let header = sheet.rows.first else { continue }
            var compared: Int?
            if byColumn {
                do {
                    compared = try columnIndex(column, in: header, file: input.lastPathComponent)
                    matchedColumn = true
                } catch {
                    firstProblem = firstProblem ?? error
                    continue
                }
            }
            func key(_ row: [String]) -> String {
                if let compared { return compared < row.count ? row[compared].trimmingCharacters(in: .whitespaces) : "" }
                var cells = row.map { $0.trimmingCharacters(in: .whitespaces) }
                while cells.last?.isEmpty == true { cells.removeLast() }
                return cells.joined(separator: "\u{1F}")
            }
            var seen = Set<String>()
            var kept = [header]
            for row in sheet.rows.dropFirst() {
                // Blank rows are layout, not duplicates.
                if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    kept.append(row)
                } else if seen.insert(key(row)).inserted {
                    kept.append(row)
                } else {
                    removed += 1
                }
            }
            sheets[index].rows = kept
        }
        if byColumn, !matchedColumn, let firstProblem { throw firstProblem }
        guard removed > 0 else { throw KumquatError.noResult(String(localized: "No duplicate rows in “\(input.lastPathComponent)”.")) }
        let result = sheets, title = input.deletingPathExtension().lastPathComponent
        try await runBlocking { try write(result, as: format, to: output, title: title) }
        return removed
    }

    /// Markdown table per sheet: per column type, empty cells, distinct values, min, max, mean.
    public static func columnStats(_ input: URL, from source: FileFormat, output: URL) async throws {
        let sheets = try await read(input, format: source).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is empty.")) }
        let dates = DateParser()
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        var out = "# \(input.deletingPathExtension().lastPathComponent)\n"
        for sheet in sheets {
            let header = sheet.rows[0]
            let body = Array(sheet.rows.dropFirst())
            let width = sheet.rows.map(\.count).max() ?? 0
            if sheets.count > 1 { out += "\n## \(sheet.name)\n" }
            out += "\n" + String(localized: "\(body.count) rows · \(width) columns") + "\n\n"
            var table = [[String(localized: "Column"), String(localized: "Type"), String(localized: "Empty"), String(localized: "Distinct"),
                          String(localized: "Min"), String(localized: "Max"), String(localized: "Mean")]]
            for column in 0..<width {
                let values = body.map { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
                let filled = values.filter { !$0.isEmpty }
                let name = column < header.count && !header[column].isEmpty ? header[column] : XLSX.columnName(column)
                var row = [name, "", "\(values.count - filled.count)", "\(Set(filled).count)", "—", "—", "—"]
                let numbers = filled.compactMap { numericValue($0).flatMap(Double.init) }
                if filled.isEmpty {
                    row[1] = String(localized: "Empty")
                } else if numbers.count == filled.count {
                    row[1] = String(localized: "Number")
                    row[4] = number(numbers.min()!)
                    row[5] = number(numbers.max()!)
                    row[6] = number(numbers.reduce(0, +) / Double(numbers.count))
                } else if filled.allSatisfy({ ["true", "false", "yes", "no"].contains($0.lowercased()) }) {
                    row[1] = String(localized: "Boolean")
                } else if case let parsed = filled.compactMap({ dates.parse($0)?.date }), parsed.count == filled.count {
                    row[1] = String(localized: "Date")
                    row[4] = parsed.min()!.formatted(date: .numeric, time: .omitted)
                    row[5] = parsed.max()!.formatted(date: .numeric, time: .omitted)
                } else {
                    row[1] = String(localized: "Text")
                }
                table.append(row)
            }
            out += markdownTable(table)
        }
        try out.write(to: output, atomically: true, encoding: .utf8)
    }

    /// Rows become columns (every sheet).
    public static func transpose(_ input: URL, from source: FileFormat, output: URL) async throws {
        let format = toolOutputFormat(for: source)
        let flipped = try await read(input, format: source).map { sheet in
            let width = sheet.rows.map(\.count).max() ?? 0
            return Sheet(name: sheet.name, rows: (0..<width).map { column in sheet.rows.map { column < $0.count ? $0[column] : "" } })
        }
        guard flipped.contains(where: { !$0.rows.isEmpty }) else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is empty.")) }
        let title = input.deletingPathExtension().lastPathComponent
        try await runBlocking { try write(flipped, as: format, to: output, title: title) }
    }

    /// A column from its header name (any case), letter ("B", "AA") or 1-based number; empty = the first.
    static func columnIndex(_ reference: String, in header: [String], file: String) throws -> Int {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return 0 }
        let normalized = ColumnMatcher.normalize(wanted)
        if let index = header.firstIndex(where: { ColumnMatcher.normalize($0) == normalized }) { return index }
        if wanted.count <= 3, wanted.allSatisfy({ $0.isASCII && $0.isLetter }) { return XLSX.columnIndex(wanted) }
        if let number = Int(wanted), number >= 1 { return number - 1 }
        throw KumquatError.noResult(String(localized: "No column “\(wanted)” in “\(file)”."))
    }
}
