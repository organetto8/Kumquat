import AppKit
import Foundation

struct Sheet: Sendable {
    var name: String
    var rows: [[String]]
}

/// XLSX · ODS · CSV · TSV (+ XLS/Numbers in via Numbers) and PDF export. Values travel
/// natively through a table model; workbook writers emit minimal valid OOXML/ODF packages.
public enum SheetEngine {
    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        let sheets = try await read(input, format: source)
        try write(sheets, as: target, to: output, title: input.deletingPathExtension().lastPathComponent)
    }

    static func read(_ url: URL, format: FileFormat) async throws -> [Sheet] {
        let name = url.deletingPathExtension().lastPathComponent
        switch format {
        case .csv: return [Sheet(name: name, rows: CSV.parse(try DocumentEngine.readText(url), delimiter: nil))]
        case .tsv: return [Sheet(name: name, rows: CSV.parse(try DocumentEngine.readText(url), delimiter: "\t"))]
        case .xlsx: return try await XLSX.read(url)
        case .ods: return try await ODS.read(url)
        case .xls, .numbers:
            let temp = ImageEngine.temporaryURL("xlsx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await IWork.numbers(url, exportTo: temp, as: "Microsoft Excel")
            return try await XLSX.read(temp)
        default:
            throw KumquatError.unsupported(String(localized: "\(format.displayName) spreadsheets"))
        }
    }

    static func write(_ sheets: [Sheet], as format: FileFormat, to output: URL, title: String) throws {
        switch format {
        case .csv:
            try CSV.write(sheets.first?.rows ?? [], delimiter: ",").write(to: output, atomically: true, encoding: .utf8)
        case .tsv:
            try CSV.write(sheets.first?.rows ?? [], delimiter: "\t").write(to: output, atomically: true, encoding: .utf8)
        case .xlsx:
            try XLSX.write(sheets, to: output)
        case .ods:
            try ODS.write(sheets, to: output)
        case .pdf:
            try DocumentEngine.paginate(table(sheets), to: output, paper: landscape(DocumentEngine.defaultPaperSize), margin: 36)
        case .json:
            try (JSONWriter.write(DataEngine.records(sheets)) + "\n").write(to: output, atomically: true, encoding: .utf8)
        case .md:
            try markdown(sheets).write(to: output, atomically: true, encoding: .utf8)
        case .html:
            try html(sheets, title: title).write(to: output, atomically: true, encoding: .utf8)
        case .sqlite:
            try DataEngine.writeSQLite(sheets, to: output)
        case .vcf:
            try DataEngine.vCard(from: sheets.first ?? Sheet(name: title, rows: [])).write(to: output, atomically: true, encoding: .utf8)
        case .ics:
            try DataEngine.calendar(from: sheets.first ?? Sheet(name: title, rows: [])).write(to: output, atomically: true, encoding: .utf8)
        default:
            throw KumquatError.unsupported(String(localized: "\(format.displayName) spreadsheets"))
        }
    }

    /// One pipe table per sheet (under its name when there are several); numeric columns align right.
    static func markdown(_ sheets: [Sheet]) -> String {
        sheets.map { sheet in
            let table = markdownTable(sheet.rows)
            return sheets.count > 1 ? "## \(sheet.name)\n\n\(table)" : table
        }.joined(separator: "\n")
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let width = max(1, rows.map(\.count).max() ?? 1)
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        func line(_ row: [String]) -> String {
            "| " + (0..<width).map { cell($0 < row.count ? row[$0] : "") }.joined(separator: " | ") + " |"
        }
        let body = rows.dropFirst()
        let rule = "|" + (0..<width).map { isNumericColumn(body, $0) ? " ---: |" : " --- |" }.joined()
        return ([line(header), rule] + body.map(line)).joined(separator: "\n") + "\n"
    }

    static func isNumericColumn(_ rows: ArraySlice<[String]>, _ column: Int) -> Bool {
        let values = rows.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }
        return !values.isEmpty && values.allSatisfy { numericValue($0) != nil }
    }

    /// Standalone page with one table per sheet; the first row is the header.
    static func html(_ sheets: [Sheet], title: String) -> String {
        var body = ""
        for sheet in sheets {
            if sheets.count > 1 { body += "<h2>\(xmlEscape(sheet.name))</h2>\n" }
            let width = max(1, sheet.rows.map(\.count).max() ?? 1)
            let rows = sheet.rows.dropFirst()
            func cell(_ row: [String], _ column: Int) -> String {
                xmlEscape(column < row.count ? row[column] : "").replacingOccurrences(of: "\n", with: "<br>")
            }
            body += "<table>\n"
            if let header = sheet.rows.first {
                body += "<thead><tr>" + (0..<width).map { "<th>\(cell(header, $0))</th>" }.joined() + "</tr></thead>\n"
            }
            let numeric = (0..<width).map { isNumericColumn(rows, $0) }
            body += "<tbody>\n"
            for row in rows {
                body += "<tr>" + (0..<width).map { numeric[$0] ? "<td class=\"n\">\(cell(row, $0))</td>" : "<td>\(cell(row, $0))</td>" }.joined() + "</tr>\n"
            }
            body += "</tbody>\n</table>\n"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscape(title))</title>
        <style>
        body { font: 14px/1.4 -apple-system, "Helvetica Neue", sans-serif; margin: 2em; color: #222; }
        table { border-collapse: collapse; margin-bottom: 2em; }
        th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: #f2f2f2; } td.n { text-align: right; font-variant-numeric: tabular-nums; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }

    static func landscape(_ size: CGSize) -> CGSize { CGSize(width: max(size.width, size.height), height: min(size.width, size.height)) }

    /// Grid as attributed text with real table blocks (paginates across pages, off-main safe).
    static func table(_ sheets: [Sheet]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 8.5)
        let bold = NSFont.boldSystemFont(ofSize: 8.5)
        for (index, sheet) in sheets.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\u{0C}")) }
            if sheets.count > 1 {
                out.append(NSAttributedString(string: sheet.name + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black]))
            }
            let columns = max(1, sheet.rows.map(\.count).max() ?? 1)
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.collapsesBorders = true
            for (r, row) in sheet.rows.enumerated() {
                for c in 0..<columns {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(NSColor(white: 0.75, alpha: 1))
                    block.setWidth(2, type: .absoluteValueType, for: .padding)
                    if r == 0 { block.backgroundColor = NSColor(white: 0.93, alpha: 1) }
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    let value = c < row.count ? row[c] : ""
                    out.append(NSAttributedString(string: value + "\n", attributes: [.font: r == 0 ? bold : font, .paragraphStyle: style, .foregroundColor: NSColor.black]))
                }
            }
        }
        return out
    }

    // MARK: - Tools

    /// One file per sheet, same format as the source (CSV/TSV hold a single sheet).
    public static func split(_ input: URL, from source: FileFormat, into directory: URL) async throws -> [URL] {
        let sheets = try await read(input, format: source)
        guard sheets.count > 1 else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has only one sheet.")) }
        let format: FileFormat = [.xlsx, .ods].contains(source) ? source : .xlsx
        let base = input.deletingPathExtension().lastPathComponent
        return try sheets.map { sheet in
            let output = try OutputNaming.reserve(in: directory, base: "\(base) – \(sheet.name)", ext: format.fileExtension)
            try write([sheet], as: format, to: output, title: sheet.name)
            return output
        }
    }

    /// Every input becomes one sheet (or several) of a single workbook.
    public static func merge(_ inputs: [URL], output: URL) async throws {
        var sheets: [Sheet] = []
        for url in inputs {
            guard let format = FileFormat.detect(url) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let read = try await read(url, format: format)
            sheets += read.map { Sheet(name: read.count == 1 ? base : "\(base) – \($0.name)", rows: $0.rows) }
        }
        try XLSX.write(sheets, to: output)
    }
}

// MARK: - CSV

enum CSV {
    /// RFC 4180 parsing; `delimiter == nil` sniffs `,` `;` or tab from the first line.
    static func parse(_ text: String, delimiter: Character?) -> [[String]] {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        let separator = delimiter ?? sniff(body)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = body.makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func sniff(_ text: Substring) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let candidates: [Character] = [",", ";", "\t"]
        return candidates.max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
    }

    static func write(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}

/// A cell that should be stored as a number (no leading zeros, finite).
func numericValue(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count < 20, let value = Double(trimmed), value.isFinite else { return nil }
    if trimmed.count > 1, trimmed.hasPrefix("0"), !trimmed.hasPrefix("0.") { return nil }
    if trimmed.hasPrefix("+") || trimmed.lowercased().contains("e") || trimmed.lowercased() == "nan" { return nil }
    return trimmed
}

// MARK: - XLSX

enum XLSX {
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for c in reference.uppercased() {
            guard let ascii = c.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(index - 1, 0)
    }

    static func safeSheetNames(_ sheets: [Sheet]) -> [String] {
        var used = Set<String>()
        return sheets.enumerated().map { index, sheet in
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty { name = "Sheet\(index + 1)" }
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                candidate = String(name.prefix(28)) + " \(n)"
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    static func write(_ sheets: [Sheet], to output: URL) throws {
        let sheets = sheets.isEmpty ? [Sheet(name: String(localized: "Sheet1"), rows: [])] : sheets
        let names = safeSheetNames(sheets)
        var zip = ZipWriter()
        var overrides = ""
        var workbookSheets = ""
        var rels = ""
        for index in sheets.indices {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            workbookSheets += "<sheet name=\"\(xmlEscape(names[index]))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            rels += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }
        rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(workbookSheets)</sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """)
        for (index, sheet) in sheets.enumerated() {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            xml.reserveCapacity(sheet.rows.count * 64)
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    if let number = numericValue(value) {
                        xml += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            zip.add("xl/worksheets/sheet\(index + 1).xml", xml)
        }
        try zip.write(to: output)
    }

    static func read(_ url: URL) async throws -> [Sheet] {
        let root = try await PackageReader.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let workbook = XMLElement.parse(contentsOf: root.appendingPathComponent("xl/workbook.xml")) else {
            throw KumquatError.cannotOpen(url.lastPathComponent)
        }
        var targets: [String: String] = [:]
        if let rels = XMLElement.parse(contentsOf: root.appendingPathComponent("xl/_rels/workbook.xml.rels")) {
            for rel in rels.all("Relationship") {
                if let id = rel.attribute("Id"), let target = rel.attribute("Target") { targets[id] = target }
            }
        }
        var shared: [String] = []
        if let strings = XMLElement.parse(contentsOf: root.appendingPathComponent("xl/sharedStrings.xml")) {
            shared = strings.all("si").map { item in item.all("t").map(\.text).joined() }
        }
        var sheets: [Sheet] = []
        for (index, entry) in workbook.all("sheet").enumerated() {
            let name = entry.attribute("name") ?? "Sheet\(index + 1)"
            var target = entry.attribute("id").flatMap { targets[$0] } ?? "worksheets/sheet\(index + 1).xml"
            target = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let sheetXML = XMLElement.parse(contentsOf: root.appendingPathComponent(target)) else { continue }
            var rows: [[String]] = []
            for row in sheetXML.all("row") {
                let rowIndex = (row.attribute("r").flatMap(Int.init) ?? rows.count + 1) - 1
                while rows.count < rowIndex { rows.append([]) }
                var cells: [String] = []
                for cell in row.children where cell.localName == "c" {
                    let column = cell.attribute("r").map(columnIndex) ?? cells.count
                    while cells.count < column { cells.append("") }
                    let raw = cell.child("v")?.text ?? ""
                    let value: String
                    switch cell.attribute("t") {
                    case "s": value = Int(raw).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                    case "inlineStr": value = cell.all("t").map(\.text).joined()
                    case "b": value = raw == "1" ? "TRUE" : "FALSE"
                    default: value = raw
                    }
                    cells.append(value)
                }
                rows.append(cells)
            }
            sheets.append(Sheet(name: name, rows: rows))
        }
        return sheets
    }
}

// MARK: - ODS

enum ODS {
    static func write(_ sheets: [Sheet], to output: URL) throws {
        let sheets = sheets.isEmpty ? [Sheet(name: String(localized: "Sheet1"), rows: [])] : sheets
        let names = XLSX.safeSheetNames(sheets)
        var content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>
        """
        for (index, sheet) in sheets.enumerated() {
            content += "<table:table table:name=\"\(xmlEscape(names[index]))\">"
            for row in sheet.rows {
                content += "<table:table-row>"
                for value in row {
                    if value.isEmpty {
                        content += "<table:table-cell/>"
                    } else if let number = numericValue(value) {
                        content += "<table:table-cell office:value-type=\"float\" office:value=\"\(number)\"><text:p>\(xmlEscape(value))</text:p></table:table-cell>"
                    } else {
                        content += "<table:table-cell office:value-type=\"string\"><text:p>\(xmlEscape(value))</text:p></table:table-cell>"
                    }
                }
                content += "</table:table-row>"
            }
            if sheet.rows.isEmpty { content += "<table:table-row><table:table-cell/></table:table-row>" }
            content += "</table:table>"
        }
        content += "</office:spreadsheet></office:body></office:document-content>"

        var zip = ZipWriter()
        zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", store: true)
        zip.add("META-INF/manifest.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """)
        zip.add("content.xml", content)
        try zip.write(to: output)
    }

    static func read(_ url: URL) async throws -> [Sheet] {
        let root = try await PackageReader.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let content = XMLElement.parse(contentsOf: root.appendingPathComponent("content.xml")) else {
            throw KumquatError.cannotOpen(url.lastPathComponent)
        }
        return content.all("table").filter { $0.name.hasSuffix(":table") || $0.name == "table" }.map { table in
            var rows: [[String]] = []
            for row in table.children where row.localName == "table-row" {
                var cells: [String] = []
                for cell in row.children where cell.localName == "table-cell" || cell.localName == "covered-table-cell" {
                    let repeated = min(Int(cell.attribute("number-columns-repeated") ?? "1") ?? 1, 1024)
                    let value = cell.attribute("value") ?? cell.attribute("date-value") ?? cell.attribute("boolean-value")
                        ?? cell.all("p").map(\.deepText).joined(separator: "\n")
                    cells.append(contentsOf: repeatElement(value, count: repeated))
                }
                while cells.last == "" { cells.removeLast() }
                let repeatedRows = min(Int(row.attribute("number-rows-repeated") ?? "1") ?? 1, cells.isEmpty ? 1 : 1024)
                for _ in 0..<repeatedRows { rows.append(cells) }
            }
            while rows.last?.isEmpty == true { rows.removeLast() }
            return Sheet(name: table.attribute("name") ?? "Sheet", rows: rows)
        }
    }
}
