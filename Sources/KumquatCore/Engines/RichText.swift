import AppKit
import Foundation

/// Format-neutral document model. Readers (Markdown, AppKit attributed text, PDF text)
/// produce it; writers (Markdown, XHTML/EPUB, plain text, attributed text) consume it.
struct Inline: Sendable, Hashable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var link: String?

    func sameStyle(as other: Inline) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && link == other.link
    }
}

enum Block: Sendable, Hashable {
    case heading(Int, [Inline])
    case paragraph([Inline])
    case listItem(ordered: Bool, [Inline])
    case quote([Inline])
    case code(String)
    case rule
    case pageBreak
}

struct RichDocument: Sendable {
    var title: String?
    var blocks: [Block]

    var inferredTitle: String? {
        title ?? blocks.lazy.compactMap { block -> String? in
            if case .heading(_, let inlines) = block { return inlines.plainText }
            return nil
        }.first
    }
}

extension Array where Element == Inline {
    var plainText: String { map(\.text).joined() }

    /// Merges neighbouring runs with identical styling.
    var coalesced: [Inline] {
        var out: [Inline] = []
        for run in self where !run.text.isEmpty {
            if let last = out.last, last.sameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }
}

// MARK: - Markdown reader

enum MarkdownReader {
    static func parse(_ source: String) -> RichDocument {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(inlines(paragraph.joined(separator: " ")))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(inlines(quote.joined(separator: " ")))) }
            quote = []
        }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var code = codeLines {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    blocks.append(.code(code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    code.append(rawLine)
                    codeLines = code
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph(); flushQuote()
                codeLines = []
                continue
            }
            if line.isEmpty {
                flushParagraph(); flushQuote()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph(); flushQuote()
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level, inlines(text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))))
                continue
            }
            if isRule(line) {
                flushParagraph(); flushQuote()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                blocks.append(.listItem(ordered: item.ordered, inlines(item.text)))
                continue
            }
            flushQuote()
            paragraph.append(line)
        }
        if let code = codeLines { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph(); flushQuote()
        return RichDocument(title: nil, blocks: blocks)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, ".)".contains(marker), rest.dropFirst().first == " " {
                return (true, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// Inline spans: **bold**, *italic*, `code`, [text](url), <https://autolink>.
    static func inlines(_ text: String) -> [Inline] {
        var out: [Inline] = []
        var bold = false, italic = false
        var buffer = ""
        let chars = Array(text)
        var i = 0

        func flush() {
            if !buffer.isEmpty { out.append(Inline(text: buffer, bold: bold, italic: italic)) }
            buffer = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                buffer.append(chars[i + 1]); i += 2; continue
            }
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                flush()
                out.append(Inline(text: String(chars[(i + 1)..<end]), code: true))
                i = end + 1; continue
            }
            if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
               let paren = chars[(close + 2)...].firstIndex(of: ")") {
                flush()
                let label = String(chars[(i + 1)..<close])
                let url = String(chars[(close + 2)..<paren]).split(separator: " ").first.map(String.init) ?? ""
                for var run in inlines(label) {
                    run.link = url
                    run.bold = run.bold || bold
                    run.italic = run.italic || italic
                    out.append(run)
                }
                i = paren + 1; continue
            }
            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    flush()
                    out.append(Inline(text: inner, bold: bold, italic: italic, link: inner))
                    i = close + 1; continue
                }
            }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] == c {
                flush(); bold.toggle(); i += 2; continue
            }
            if c == "*" || (c == "_" && (i == 0 || !chars[i - 1].isLetter || italic)) {
                flush(); italic.toggle(); i += 1; continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out.coalesced
    }
}

// MARK: - Writers

enum MarkdownWriter {
    static func write(_ document: RichDocument) -> String {
        var lines: [String] = []
        var previousWasList = false
        for block in document.blocks {
            let isList: Bool
            if case .listItem = block { isList = true } else { isList = false }
            if !lines.isEmpty, !(isList && previousWasList) { lines.append("") }
            previousWasList = isList
            switch block {
            case .heading(let level, let inlines): lines.append(String(repeating: "#", count: min(level, 6)) + " " + render(inlines))
            case .paragraph(let inlines): lines.append(render(inlines))
            case .listItem(let ordered, let inlines): lines.append((ordered ? "1. " : "- ") + render(inlines))
            case .quote(let inlines): lines.append("> " + render(inlines))
            case .code(let code): lines.append("```\n\(code)\n```")
            case .rule, .pageBreak: lines.append("---")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func render(_ inlines: [Inline]) -> String {
        inlines.coalesced.map { run in
            if run.code { return "`\(run.text)`" }
            let text = escape(run.text)
            // Markers must hug the text: move surrounding spaces outside them.
            let leading = String(text.prefix { $0 == " " }), trailing = String(text.reversed().prefix { $0 == " " })
            var core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            if run.italic { core = "*\(core)*" }
            if run.bold { core = "**\(core)**" }
            if let link = run.link { core = "[\(core)](\(link))" }
            return leading + core + trailing
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\`*_[]".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

enum HTMLWriter {
    /// Well-formed XHTML body content (valid inside EPUB).
    static func body(_ document: RichDocument) -> String {
        var html = ""
        var openList: Bool?
        func closeList() {
            if let ordered = openList { html += ordered ? "</ol>\n" : "</ul>\n" }
            openList = nil
        }
        var headingIndex = 0
        for block in document.blocks {
            if case .listItem(let ordered, _) = block {
                if openList != ordered { closeList(); html += ordered ? "<ol>\n" : "<ul>\n"; openList = ordered }
            } else {
                closeList()
            }
            switch block {
            case .heading(let level, let inlines):
                headingIndex += 1
                let tag = "h\(min(max(level, 1), 6))"
                html += "<\(tag) id=\"h\(headingIndex)\">\(render(inlines))</\(tag)>\n"
            case .paragraph(let inlines): html += "<p>\(render(inlines))</p>\n"
            case .listItem(_, let inlines): html += "<li>\(render(inlines))</li>\n"
            case .quote(let inlines): html += "<blockquote><p>\(render(inlines))</p></blockquote>\n"
            case .code(let code): html += "<pre><code>\(xmlEscape(code))</code></pre>\n"
            case .rule: html += "<hr/>\n"
            case .pageBreak: html += "<div style=\"page-break-after: always\"></div>\n"
            }
        }
        closeList()
        return html
    }

    static func page(_ document: RichDocument, fallbackTitle: String) -> String {
        let title = xmlEscape(document.inferredTitle ?? fallbackTitle)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <title>\(title)</title>
        <style>
        body { font: 16px/1.6 -apple-system, "Helvetica Neue", sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #222; }
        pre, code { font-family: ui-monospace, Menlo, monospace; background: #f5f5f5; }
        pre { padding: .8em; overflow-x: auto; } blockquote { border-left: 4px solid #ddd; margin-left: 0; padding-left: 1em; color: #555; }
        </style>
        </head>
        <body>
        \(body(document))</body>
        </html>
        """
    }

    static func render(_ inlines: [Inline]) -> String {
        inlines.coalesced.map { run in
            var text = xmlEscape(run.text)
            if run.code { text = "<code>\(text)</code>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if let link = run.link { text = "<a href=\"\(xmlEscape(link))\">\(text)</a>" }
            return text
        }.joined()
    }
}

enum PlainTextWriter {
    static func write(_ document: RichDocument) -> String {
        document.blocks.map { block -> String in
            switch block {
            case .heading(_, let inlines), .paragraph(let inlines), .quote(let inlines): inlines.plainText
            case .listItem(_, let inlines): "• " + inlines.plainText
            case .code(let code): code
            case .rule: "———"
            case .pageBreak: "\u{0C}"
            }
        }.joined(separator: "\n\n") + "\n"
    }
}

// MARK: - AppKit bridge

enum AttributedBridge {
    static var bodyFont: NSFont { .systemFont(ofSize: 12) }

    /// Model → attributed text with real fonts (for DOCX/RTF/PDF output). Thread-safe.
    static func attributed(_ document: RichDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headingSizes: [CGFloat] = [24, 19, 16, 14, 13, 12]
        var listCounter = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            switch block {
            case .heading(let level, let inlines):
                style.paragraphSpacingBefore = 10
                let size = headingSizes[min(max(level, 1), 6) - 1]
                out.append(runs(inlines, base: NSFont.boldSystemFont(ofSize: size), style: style))
            case .paragraph(let inlines):
                out.append(runs(inlines, base: bodyFont, style: style))
            case .listItem(let ordered, let inlines):
                // A real text list, so DOCX/RTF writers emit native numbering.
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                if case .listItem(let previousOrdered, _)? = index > 0 ? document.blocks[index - 1] : nil, previousOrdered == ordered {
                    listCounter += 1
                } else {
                    listCounter = 1
                }
                style.textLists = [list]
                style.headIndent = 22
                style.firstLineHeadIndent = 0
                style.tabStops = [NSTextTab(textAlignment: .left, location: 8), NSTextTab(textAlignment: .left, location: 22)]
                let marker = "\t\(list.marker(forItemNumber: listCounter))\t"
                out.append(NSAttributedString(string: marker, attributes: [.font: bodyFont, .paragraphStyle: style, .foregroundColor: NSColor.black]))
                out.append(runs(inlines, base: bodyFont, style: style))
            case .quote(let inlines):
                style.headIndent = 20
                style.firstLineHeadIndent = 20
                out.append(runs(inlines, base: italic(bodyFont), style: style, color: .darkGray))
            case .code(let code):
                let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
                out.append(NSAttributedString(string: code, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black,
                                                                         .backgroundColor: NSColor(white: 0.95, alpha: 1)]))
            case .rule:
                out.append(NSAttributedString(string: "———", attributes: [.font: bodyFont, .foregroundColor: NSColor.gray, .paragraphStyle: style]))
            case .pageBreak:
                out.append(NSAttributedString(string: "\u{0C}", attributes: [.font: bodyFont]))
            }
        }
        return out
    }

    private static func runs(_ inlines: [Inline], base: NSFont, style: NSParagraphStyle, color: NSColor = .black) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in inlines.coalesced {
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular) : base
            if run.bold { font = bold(font) }
            if run.italic { font = italic(font) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: color]
            if let link = run.link, let url = URL(string: link) { attributes[.link] = url }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    static func bold(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.bold)), size: font.pointSize) ?? font
    }

    static func italic(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
    }

    /// Attributed text (DOCX, RTF, HTML import, PDF text) → model, inferring headings from
    /// font size, lists from paragraph styles and inline styles from font traits.
    static func document(from text: NSAttributedString) -> RichDocument {
        let string = text.string as NSString
        let full = NSRange(location: 0, length: string.length)
        let body = bodySize(of: text)

        var blocks: [Block] = []
        string.enumerateSubstrings(in: full, options: [.byParagraphs]) { paragraph, range, _, _ in
            guard let paragraph else { return }
            if paragraph.contains("\u{0C}") { blocks.append(.pageBreak) }
            let trimmed = paragraph.replacingOccurrences(of: "\u{0C}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            var inlines: [Inline] = []
            var maxSize: CGFloat = 0
            var allBold = true
            var allMono = true
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                let piece = string.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{0C}", with: "")
                guard !piece.isEmpty else { return }
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                maxSize = max(maxSize, font?.pointSize ?? body)
                let isBold = traits.contains(.bold), isMono = font?.isFixedPitch ?? false
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    allBold = allBold && isBold
                    allMono = allMono && isMono
                }
                let link: String? = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
                inlines.append(Inline(text: piece, bold: isBold, italic: traits.contains(.italic), code: isMono, link: link))
            }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let bulletPrefix = /^\s*[•◦▪●‣⁃]\s+/
            if let level = style?.headerLevel, level > 0, trimmed.count < 200 {
                // HTML/EPUB imports say which paragraphs were <h1>…<h6>.
                blocks.append(.heading(min(level, 6), inlines.map { var r = $0; r.bold = false; return r }.coalesced))
            } else if allMono {
                blocks.append(.code(paragraph))
            } else if let list = style?.textLists.last {
                let marker = /^\s*([•◦▪︎●○‣⁃–\-*]|\(?[0-9a-zA-Z]{1,4}[.)])\s+/
                let clean = inlines.coalesced
                var stripped = clean
                if let first = stripped.first, let match = first.text.firstMatch(of: marker) {
                    stripped[0].text.removeSubrange(match.range)
                }
                let ordered = list.markerFormat == .decimal || list.markerFormat == .lowercaseAlpha || list.markerFormat == .uppercaseAlpha
                    || list.markerFormat == .lowercaseRoman || list.markerFormat == .uppercaseRoman
                blocks.append(.listItem(ordered: ordered, stripped))
            } else if var first = inlines.first, let match = first.text.firstMatch(of: bulletPrefix) {
                // Bullets typed as characters (plain-text style lists).
                first.text.removeSubrange(match.range)
                blocks.append(.listItem(ordered: false, ([first] + inlines.dropFirst()).coalesced))
            } else if trimmed.count < 200, maxSize >= body * 1.6 {
                blocks.append(.heading(1, inlines.map { var r = $0; r.bold = false; return r }.coalesced))
            } else if trimmed.count < 200, maxSize >= body * 1.25 {
                blocks.append(.heading(2, inlines.map { var r = $0; r.bold = false; return r }.coalesced))
            } else if trimmed.count < 120, maxSize > body, allBold {
                blocks.append(.heading(3, inlines.map { var r = $0; r.bold = false; return r }.coalesced))
            } else {
                blocks.append(.paragraph(inlines.coalesced))
            }
        }
        return RichDocument(title: nil, blocks: blocks)
    }

    /// The most used font size: the body text that headings are measured against.
    static func bodySize(of text: NSAttributedString) -> CGFloat {
        var sizeWeights: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            sizeWeights[size.rounded(), default: 0] += range.length
        }
        return sizeWeights.max { $0.value < $1.value }?.key ?? 12
    }

    /// Paragraphs that `document(from:)` reads as headings, with their range in `text` (for cutting
    /// the attributed text itself). An explicit HTML header level wins over font sizes.
    static func headings(in text: NSAttributedString) -> [(range: NSRange, level: Int, title: String)] {
        let string = text.string as NSString
        let body = bodySize(of: text)
        var out: [(range: NSRange, level: Int, title: String)] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { paragraph, range, _, _ in
            guard let paragraph, range.length > 0 else { return }
            let title = paragraph.replacingOccurrences(of: "\u{0C}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, title.count < 200 else { return }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if let level = style?.headerLevel, level > 0 {
                out.append((range, level, title))
                return
            }
            guard style?.textLists.isEmpty ?? true, title.firstMatch(of: /^[•◦▪●‣⁃]\s+/) == nil else { return }
            var maxSize: CGFloat = 0
            var allBold = true, allMono = true
            text.enumerateAttribute(.font, in: range) { value, runRange, _ in
                guard !string.substring(with: runRange).trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let font = value as? NSFont
                maxSize = max(maxSize, font?.pointSize ?? body)
                allBold = allBold && (font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
                allMono = allMono && (font?.isFixedPitch ?? false)
            }
            guard !allMono else { return }
            if maxSize >= body * 1.6 {
                out.append((range, 1, title))
            } else if maxSize >= body * 1.25 {
                out.append((range, 2, title))
            } else if title.count < 120, maxSize > body, allBold {
                out.append((range, 3, title))
            }
        }
        return out
    }

    /// Plain text → model; every line keeps its own paragraph so layout survives.
    static func document(fromPlain text: String) -> RichDocument {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").compactMap { line -> Block? in
            if line.contains("\u{0C}") { return .pageBreak }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .paragraph([Inline(text: line)])
        }
        return RichDocument(title: nil, blocks: blocks)
    }
}
