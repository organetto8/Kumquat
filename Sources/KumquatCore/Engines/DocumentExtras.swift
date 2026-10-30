import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Document tools added after 1.2.
extension DocumentEngine {
    /// One file per heading of `level` (1 or 2), same format as the source, named "01 <heading>.<ext>".
    /// Text before the first heading becomes "00 <baseName>".
    public static func split(_ input: URL, from source: FileFormat, level: Int, into folder: URL, baseName: String) async throws -> [URL] {
        let level = min(max(level, 1), 6)
        let noHeadings = KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no headings to split at."))
        func reserve(_ number: Int, _ title: String) throws -> URL {
            let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let name = String(format: "%02d ", number) + String((clean.isEmpty ? baseName : clean).prefix(80))
            return try OutputNaming.reserve(in: folder, base: name, ext: source.fileExtension)
        }
        switch source {
        case .md, .txt:
            let sections = TextSections.split(try readText(input), markdown: source == .md, level: level)
            guard sections.count > 1 else { throw noHeadings }
            let offset = sections[0].title == nil ? 0 : 1
            return try sections.enumerated().map { index, section in
                let url = try reserve(index + offset, section.title ?? baseName)
                try section.text.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
        case .html:
            let document = try await model(input, format: .html)
            var sections: [(title: String?, blocks: [Block])] = [(nil, [])]
            for block in document.blocks {
                if case .heading(let headingLevel, let inlines) = block, headingLevel <= level {
                    sections.append((inlines.plainText, [block]))
                } else {
                    sections[sections.count - 1].blocks.append(block)
                }
            }
            if sections[0].blocks.allSatisfy({ $0 == .pageBreak }) { sections.removeFirst() }
            guard sections.count > 1 else { throw noHeadings }
            let offset = sections[0].title == nil ? 0 : 1
            return try sections.enumerated().map { index, section in
                let url = try reserve(index + offset, section.title ?? baseName)
                let page = HTMLWriter.page(RichDocument(title: nil, blocks: section.blocks), fallbackTitle: section.title ?? baseName)
                try page.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
        case .docx, .odt, .rtf:
            // Cut the attributed text itself, so pictures, tables and styling survive.
            let text = try await attributed(input, format: source)
            let headings = AttributedBridge.headings(in: text.value).filter { $0.level <= level }
            guard !headings.isEmpty else { throw noHeadings }
            var cuts: [(title: String?, range: NSRange)] = []
            let length = text.value.length
            let preamble = NSRange(location: 0, length: headings[0].range.location)
            if !text.value.attributedSubstring(from: preamble).string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0C}\u{FFFC}"))).isEmpty {
                cuts.append((nil, preamble))
            }
            for (index, heading) in headings.enumerated() {
                let end = index + 1 < headings.count ? headings[index + 1].range.location : length
                cuts.append((heading.title, NSRange(location: heading.range.location, length: end - heading.range.location)))
            }
            guard cuts.count > 1 else { throw noHeadings }
            let type: NSAttributedString.DocumentType = switch source {
            case .docx: .officeOpenXML
            case .odt: .openDocument
            default: .rtf
            }
            let offset = cuts[0].title == nil ? 0 : 1
            var urls: [URL] = []
            for (index, cut) in cuts.enumerated() {
                let url = try reserve(index + offset, cut.title ?? baseName)
                urls.append(url)
                let part = SendableText(value: text.value.attributedSubstring(from: cut.range))
                try await runBlocking { try write(part.value, type: type, to: url) }
            }
            return urls
        default:
            throw KumquatError.unsupported(String(localized: "Splitting \(source.displayName) files"))
        }
    }

    /// Writes a copy with every match replaced and returns the count; throws `noResult` when nothing matches.
    public static func findReplace(_ input: URL, from source: FileFormat, find: String, replace: String, regex: Bool, output: URL) async throws -> Int {
        let count: Int
        switch source {
        case .docx:
            count = try await WordReplace.run(input, find: find, replace: replace, regex: regex, output: output)
        case .rtf:
            count = try await runBlocking {
                var attributes: NSDictionary?
                let original = try NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: &attributes)
                let found = try TextMatch.all(in: original.string, find: find, replace: replace, regex: regex)
                guard !found.isEmpty else { return 0 }
                let text = NSMutableAttributedString(attributedString: original)
                for match in found.reversed() { text.replaceCharacters(in: match.range, with: match.replacement) }
                var options = (attributes as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:]
                options[.documentType] = NSAttributedString.DocumentType.rtf
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: options).write(to: output, options: .atomic)
                return found.count
            }
        case .html:
            // Only the text between tags (and outside scripts and styles) changes.
            func replaced(_ text: String, _ total: inout Int, hidden: Bool) throws -> String {
                guard !hidden, !text.isEmpty else { return text }
                let found = try TextMatch.all(in: text, find: find, replace: replace, regex: regex)
                total += found.count
                return TextMatch.apply(found, to: text)
            }
            let html = try readText(input)
            var total = 0
            var out = ""
            var hidden = false
            var rest = Substring(html)
            while !rest.isEmpty {
                guard let open = rest.firstIndex(of: "<") else {
                    out += try replaced(String(rest), &total, hidden: hidden)
                    break
                }
                out += try replaced(String(rest[..<open]), &total, hidden: hidden)
                let close = rest[open...].firstIndex(of: ">").map { rest.index(after: $0) } ?? rest.endIndex
                let tag = rest[open..<close].lowercased()
                if tag.hasPrefix("<script") || tag.hasPrefix("<style") { hidden = true }
                if tag.hasPrefix("</script") || tag.hasPrefix("</style") { hidden = false }
                out += rest[open..<close]
                rest = rest[close...]
            }
            count = total
            if count > 0 { try out.write(to: output, atomically: true, encoding: .utf8) }
        case .txt, .md, .tex, .rst, .adoc, .org:
            let text = try readText(input)
            let found = try TextMatch.all(in: text, find: find, replace: replace, regex: regex)
            count = found.count
            if count > 0 { try TextMatch.apply(found, to: text).write(to: output, atomically: true, encoding: .utf8) }
        default:
            throw KumquatError.unsupported(String(localized: "Replacing text in \(source.displayName) files"))
        }
        guard count > 0 else { throw KumquatError.noResult(String(localized: "No matches for “\(find)” in “\(input.lastPathComponent)”.")) }
        return count
    }

    /// UTF-8, LF line endings, no trailing spaces or doubled spaces/blank lines, straight → typographic quotes left alone.
    public static func clean(_ input: URL, from source: FileFormat, output: URL) async throws {
        try TextCleaner.clean(try readText(input), format: source).write(to: output, atomically: true, encoding: .utf8)
    }

    /// DOCX/PPTX/XLSX with their embedded pictures re-encoded at `quality` (0…1) and capped at 2560 px; throws when nothing shrinks.
    public static func compressOffice(_ input: URL, quality: Double, output: URL) async throws {
        let root = try await PackageReader.extract(input)
        defer { try? FileManager.default.removeItem(at: root) }
        let quality = min(max(quality, 0.05), 1)
        let (pictures, shrunk) = try await runBlocking { () -> (Int, Int) in
            var pictures = 0, shrunk = 0
            for folder in ["word/media", "ppt/media", "xl/media"] {
                let directory = root.appendingPathComponent(folder)
                for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    switch OfficePictures.recompress(file, quality: quality) {
                    case nil: continue
                    case false?: pictures += 1
                    case true?: pictures += 1; shrunk += 1
                    }
                }
            }
            return (pictures, shrunk)
        }
        guard pictures > 0 else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no pictures to compress.")) }
        guard shrunk > 0 else { throw KumquatError.noResult(String(localized: "The pictures in “\(input.lastPathComponent)” can't get any smaller.")) }
        try await runBlocking { try OfficePackage.zip(root, to: output) }
    }

    /// PPTX: "<baseName> notes.txt" (one section per slide) plus every media file, into `folder`.
    public static func extractNotes(_ input: URL, into folder: URL, baseName: String) async throws -> [URL] {
        let root = try await PackageReader.extract(input)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = input.lastPathComponent
        return try await runBlocking {
            var sections: [String] = []
            var hasNotes = false
            for (index, slide) in PowerPoint.slidePaths(root).enumerated() {
                let title = PowerPoint.title(of: root.appendingPathComponent(slide))
                let notes = PowerPoint.notes(for: slide, root: root)
                hasNotes = hasNotes || !notes.isEmpty
                let number = index + 1
                let heading = title.isEmpty ? String(localized: "Slide \(number)") : String(localized: "Slide \(number): \(title)")
                sections.append(notes.isEmpty ? heading : heading + "\n" + notes)
            }
            var outputs: [URL] = []
            if hasNotes {
                let notesFile = try OutputNaming.reserve(in: folder, base: "\(baseName) notes", ext: "txt")
                try (sections.joined(separator: "\n\n") + "\n").write(to: notesFile, atomically: true, encoding: .utf8)
                outputs.append(notesFile)
            }
            let media = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ppt/media"), includingPropertiesForKeys: nil)) ?? []
            for file in media.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let target = OutputNaming.unique(in: folder, name: file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: target)
                outputs.append(target)
            }
            guard !outputs.isEmpty else { throw KumquatError.noResult(String(localized: "“\(name)” has no speaker notes or media.")) }
            return outputs
        }
    }
}

// MARK: - Matching

enum TextMatch {
    struct Match {
        var range: NSRange
        var replacement: String
    }

    /// Every match (UTF-16 ranges) with its replacement; regex templates may use $1….
    static func all(in text: String, find: String, replace: String, regex: Bool) throws -> [Match] {
        let length = (text as NSString).length
        if regex {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(pattern: find, options: [.anchorsMatchLines])
            } catch {
                throw KumquatError.noResult(String(localized: "“\(find)” isn't a valid regular expression."))
            }
            return expression.matches(in: text, range: NSRange(location: 0, length: length)).map {
                Match(range: $0.range, replacement: expression.replacementString(for: $0, in: text, offset: 0, template: replace))
            }
        }
        guard !find.isEmpty else { return [] }
        var found: [Match] = []
        let ns = text as NSString
        var location = 0
        while location < length {
            let range = ns.range(of: find, options: [], range: NSRange(location: location, length: length - location))
            guard range.location != NSNotFound else { break }
            found.append(Match(range: range, replacement: replace))
            location = NSMaxRange(range)
        }
        return found
    }

    static func apply(_ matches: [Match], to text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + match.replacement
            cursor = NSMaxRange(match.range)
        }
        return out + ns.substring(from: cursor)
    }
}

/// Find & Replace inside a DOCX: the text of each paragraph's runs is matched as one string, so a
/// match may span runs; its replacement goes in the run where it starts. Formatting stays put.
enum WordReplace {
    static func run(_ input: URL, find: String, replace: String, regex: Bool, output: URL) async throws -> Int {
        let root = try await PackageReader.extract(input)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await runBlocking {
            var total = 0
            let parts = (FileManager.default.subpaths(atPath: root.appendingPathComponent("word").path) ?? []).filter { path in
                !path.contains("/") && path.hasSuffix(".xml") && ["document", "header", "footer", "footnotes", "endnotes"].contains { path.hasPrefix($0) }
            }
            for part in parts {
                let url = root.appendingPathComponent("word").appendingPathComponent(part)
                let xml = try String(contentsOf: url, encoding: .utf8)
                let (edited, count) = try replaceRuns(xml, find: find, replace: replace, regex: regex)
                guard count > 0 else { continue }
                total += count
                try edited.write(to: url, atomically: true, encoding: .utf8)
            }
            if total > 0 { try OfficePackage.zip(root, to: output) }
            return total
        }
    }

    static func replaceRuns(_ xml: String, find: String, replace: String, regex: Bool) throws -> (String, Int) {
        let ns = xml as NSString
        let all = NSRange(location: 0, length: ns.length)
        let runs = try NSRegularExpression(pattern: #"<w:t(?:\s[^>]*)?>([^<]*)</w:t>"#).matches(in: xml, range: all)
        guard !runs.isEmpty else { return (xml, 0) }
        let paragraphEnds = try NSRegularExpression(pattern: "</w:p>").matches(in: xml, range: all).map(\.range.location)
        var paragraphs: [[NSTextCheckingResult]] = []
        var current: [NSTextCheckingResult] = []
        var next = 0
        for run in runs {
            while next < paragraphEnds.count, paragraphEnds[next] < run.range.location {
                next += 1
                if !current.isEmpty { paragraphs.append(current); current = [] }
            }
            current.append(run)
        }
        if !current.isEmpty { paragraphs.append(current) }

        var edits: [(range: NSRange, xml: String)] = []
        var count = 0
        for paragraph in paragraphs {
            let texts = paragraph.map { xmlUnescape(ns.substring(with: $0.range(at: 1))) }
            let joined = texts.joined()
            let found = try TextMatch.all(in: joined, find: find, replace: replace, regex: regex)
            guard !found.isEmpty else { continue }
            count += found.count
            let whole = joined as NSString
            var start = 0
            for (index, text) in texts.enumerated() {
                let runStart = start, runEnd = start + (text as NSString).length
                start = runEnd
                let isLast = index == texts.count - 1
                var out = ""
                var cursor = runStart
                for match in found {
                    let matchStart = match.range.location, matchEnd = NSMaxRange(match.range)
                    if matchStart > runEnd || (matchStart == runEnd && !isLast) { break }
                    if matchEnd <= runStart, matchStart < runStart { continue }
                    let keep = max(min(matchStart, runEnd), cursor)
                    if keep > cursor { out += whole.substring(with: NSRange(location: cursor, length: keep - cursor)) }
                    if matchStart >= runStart { out += match.replacement }
                    cursor = max(cursor, min(matchEnd, runEnd))
                }
                if cursor < runEnd { out += whole.substring(with: NSRange(location: cursor, length: runEnd - cursor)) }
                if out != text { edits.append((paragraph[index].range, "<w:t xml:space=\"preserve\">\(xmlEscape(out))</w:t>")) }
            }
        }
        let edited = NSMutableString(string: xml)
        for edit in edits.reversed() { edited.replaceCharacters(in: edit.range, with: edit.xml) }
        return (edited as String, count)
    }

    static func xmlUnescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semicolon) <= 10 else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                let code = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16) : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
                if let code, let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) } else { out += "&\(entity);" }
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return out + rest
    }
}

// MARK: - Splitting text

enum TextSections {
    struct Section {
        /// `nil` for the text before the first heading.
        var title: String?
        var text: String
    }

    /// Markdown (ATX/setext headings, fences respected) or plain text (Markdown-like headings,
    /// underlines, "Chapter 3" lines, short ALL-CAPS lines), cut before each heading up to `level`.
    static func split(_ text: String, markdown: Bool, level: Int) -> [Section] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var starts: [(line: Int, title: String)] = []
        var inCode = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if markdown, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            guard !inCode, let heading = heading(lines, index, markdown: markdown), heading.level <= level else { continue }
            starts.append((index, heading.title))
        }
        guard let first = starts.first else { return [] }
        func body(_ range: Range<Int>) -> String {
            var part = Array(lines[range])
            while part.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { part.removeFirst() }
            while part.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { part.removeLast() }
            return part.joined(separator: "\n") + "\n"
        }
        var sections: [Section] = []
        let preamble = body(0..<first.line)
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(Section(title: nil, text: preamble)) }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].line : lines.count
            sections.append(Section(title: start.title, text: body(start.line..<end)))
        }
        return sections
    }

    static func heading(_ lines: [String], _ index: Int, markdown: Bool) -> (level: Int, title: String)? {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, line.prefix(while: { $0 == " " }).count < 4 else { return nil }
        func title(_ text: String) -> String { markdown ? MarkdownReader.inlines(text).plainText : text }
        let hashes = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first.map({ $0 == " " }) ?? true {
            let text = trimmed.dropFirst(hashes).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return (hashes, title(text))
        }
        let previousBlank = index == 0 || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty
        if index + 1 < lines.count, previousBlank, !"-*+>|".contains(trimmed.first!) {
            let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if underline.count >= 3, underline.allSatisfy({ $0 == "=" }) { return (1, title(trimmed)) }
            if underline.count >= 3, underline.allSatisfy({ $0 == "-" }) { return (2, title(trimmed)) }
        }
        guard !markdown else { return nil }
        if trimmed.range(of: #"^(chapter|capitolo|part|parte|book|libro)\s+[\p{L}\d]+\b"#, options: [.regularExpression, .caseInsensitive]) != nil, trimmed.count <= 80 {
            return (1, trimmed)
        }
        if trimmed.range(of: #"^(section|sezione)\s+[\p{L}\d.]+\b"#, options: [.regularExpression, .caseInsensitive]) != nil, trimmed.count <= 80 {
            return (2, trimmed)
        }
        let nextBlank = index + 1 >= lines.count || lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty
        let letters = trimmed.filter(\.isLetter)
        if previousBlank, nextBlank, letters.count >= 3, trimmed.count <= 60, letters.allSatisfy(\.isUppercase) {
            return (1, trimmed)
        }
        return nil
    }
}

// MARK: - Cleaning text

enum TextCleaner {
    static func clean(_ text: String, format: FileFormat) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\u{200B}", with: "")
        let lines = normalized.components(separatedBy: "\n")
        var out: [String] = []
        var inCode = false
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            let fence = format == .md && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
            if format == .html, lowered.contains("<pre") || lowered.contains("<textarea") { inCode = true }
            var line = raw
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            // Markdown's two-space line break becomes a backslash break, which survives trimming.
            if format == .md, !inCode, !fence, raw.hasSuffix("  "), !line.isEmpty,
               index + 1 < lines.count, !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                line += "\\"
            }
            if !inCode, !fence, let first = line.first, first != " ", first != "\t", !looksTabular(line) {
                line = line.replacingOccurrences(of: #"(?<=\S) {2,}"#, with: " ", options: .regularExpression)
            }
            if fence { inCode.toggle() }
            if format == .html, lowered.contains("</pre") || lowered.contains("</textarea") { inCode = false }
            if line.isEmpty, !inCode, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// Tables keep their alignment spaces (Markdown/Org pipes, reST grid and simple tables).
    static func looksTabular(_ line: String) -> Bool {
        line.contains("|") || line.hasPrefix("+-") || line.hasPrefix("+=") || (line.hasPrefix("==") && line.contains(" "))
    }
}

// MARK: - Office packages

enum OfficePackage {
    /// Zips an unpacked OOXML/ODF folder back up: mimetype, [Content_Types].xml and the root
    /// relationships first, as Office and LibreOffice expect.
    static func zip(_ root: URL, to output: URL) throws {
        var isDirectory: ObjCBool = false
        let paths = (FileManager.default.subpaths(atPath: root.path) ?? []).filter { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        func rank(_ path: String) -> Int {
            switch path {
            case "mimetype": 0
            case "[Content_Types].xml": 1
            case "_rels/.rels": 2
            default: 3
            }
        }
        var zip = ZipWriter()
        for path in paths.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
            zip.add(path, try Data(contentsOf: root.appendingPathComponent(path)), store: path == "mimetype")
        }
        try zip.write(to: output)
    }
}

enum OfficePictures {
    /// Re-encodes one embedded picture in place, same name and type. `nil` when it isn't a picture
    /// Kumquat re-encodes, `false` when the result wouldn't be smaller.
    static func recompress(_ url: URL, quality: Double) -> Bool? {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "png": type = .png
        case "tif", "tiff": type = .tiff
        case "bmp": type = .bmp
        default: return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxSide = 2560
        let image: CGImage?
        if max(width, height) > maxSide {
            // Raw pixel orientation is kept (the tag is copied below), so Office shows it as before.
            let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                              kCGImageSourceCreateThumbnailWithTransform: false]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary)
        } else if type == .jpeg || type == .tiff {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // Lossless pictures only get smaller by getting smaller.
            return false
        }
        guard let image else { return false }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
        if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .tiff { options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        let original = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard data.length < original else { return false }
        return (try? (data as Data).write(to: url, options: .atomic)) != nil
    }
}

/// Reading PresentationML parts: slide order, titles and speaker notes.
enum PowerPoint {
    static func relationships(_ url: URL) -> [String: (type: String, target: String)] {
        guard let rels = XMLElement.parse(contentsOf: url) else { return [:] }
        var out: [String: (type: String, target: String)] = [:]
        for rel in rels.all("Relationship") {
            if let id = rel.attribute("Id"), let target = rel.attribute("Target") { out[id] = (rel.attribute("Type") ?? "", target) }
        }
        return out
    }

    /// Package path of `target` as written in a relationship of a part in `directory`.
    static func resolve(_ target: String, relativeTo directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = directory.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }

    /// "ppt/slides/slide1.xml"… in presentation order.
    static func slidePaths(_ root: URL) -> [String] {
        let rels = relationships(root.appendingPathComponent("ppt/_rels/presentation.xml.rels"))
        if let presentation = XMLElement.parse(contentsOf: root.appendingPathComponent("ppt/presentation.xml")) {
            let ordered = presentation.all("sldId").compactMap { slide -> String? in
                guard let id = slide.attributes.first(where: { $0.key.hasSuffix(":id") })?.value, let rel = rels[id] else { return nil }
                return resolve(rel.target, relativeTo: "ppt")
            }
            if !ordered.isEmpty { return ordered }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ppt/slides").path)) ?? []
        return files.filter { $0.hasSuffix(".xml") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { "ppt/slides/\($0)" }
    }

    static func paragraphs(_ shapes: [XMLElement]) -> String {
        shapes.flatMap { $0.all("p") }.map { paragraph in paragraph.all("t").map(\.text).joined().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func placeholderType(_ shape: XMLElement) -> String? { shape.all("ph").first.map { $0.attribute("type") ?? "body" } }

    static func title(of slide: URL) -> String {
        guard let xml = XMLElement.parse(contentsOf: slide) else { return "" }
        let titles = xml.all("sp").filter { ["title", "ctrTitle"].contains(placeholderType($0) ?? "") }
        return paragraphs(titles).replacingOccurrences(of: "\n", with: " ")
    }

    static func notes(for slide: String, root: URL) -> String {
        let directory = (slide as NSString).deletingLastPathComponent
        let relsPath = directory + "/_rels/" + (slide as NSString).lastPathComponent + ".rels"
        guard let rel = relationships(root.appendingPathComponent(relsPath)).values.first(where: { $0.type.hasSuffix("/notesSlide") }),
              let xml = XMLElement.parse(contentsOf: root.appendingPathComponent(resolve(rel.target, relativeTo: directory))) else { return "" }
        // The body placeholder holds the notes; the others are the slide picture, number, header…
        let bodies = xml.all("sp").filter { placeholderType($0) == "body" }
        return paragraphs(bodies)
    }
}
