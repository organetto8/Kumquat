import AppKit
import Foundation

/// Immutable attributed text crossing actor boundaries (NSAttributedString is not Sendable).
struct SendableText: @unchecked Sendable {
    let value: NSAttributedString
}

/// DOCX · DOC · ODT · RTF · Pages · Markdown · TXT · EPUB · HTML · PDF, plus RTFD/clipping input,
/// LaTeX/reST/AsciiDoc/Org through pandoc and MOBI/AZW3/FB2 through Calibre's ebook-convert.
/// Native AppKit text system for Word/RTF/ODT, own Markdown/EPUB/HTML writers, Pages via automation.
public enum DocumentEngine {
    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        if Catalog.ebooks.contains(source) || Catalog.ebooks.contains(target) {
            try await Ebooks.convert(input, from: source, to: target, output: output)
            return
        }
        if Catalog.markupFormats.contains(target) || (Catalog.markupFormats.contains(source) && Pandoc.writer(for: target) != nil) {
            try await Pandoc.convert(input, from: source, to: target, output: output)
            return
        }
        switch target {
        case .pdf:
            let text = try await attributed(input, format: source)
            try await runBlocking { try paginate(text.value, to: output) }
        case .docx:
            let text = try await attributed(input, format: source)
            try await runBlocking { try write(text.value, type: .officeOpenXML, to: output) }
        case .rtf, .doc, .odt:
            let text = try await attributed(input, format: source)
            let type: NSAttributedString.DocumentType = switch target {
            case .rtf: .rtf
            case .doc: .docFormat
            default: .openDocument
            }
            try await runBlocking { try write(text.value, type: type, to: output) }
        case .html:
            if source == .md || source == .txt {
                let document = try await model(input, format: source)
                try HTMLWriter.page(document, fallbackTitle: baseName(input)).write(to: output, atomically: true, encoding: .utf8)
            } else {
                let text = try await attributed(input, format: source)
                try await runBlocking { try write(text.value, type: .html, to: output) }
            }
        case .md:
            let document = try await model(input, format: source)
            try MarkdownWriter.write(document).write(to: output, atomically: true, encoding: .utf8)
        case .txt:
            if source == .md {
                let document = try await model(input, format: source)
                try PlainTextWriter.write(document).write(to: output, atomically: true, encoding: .utf8)
            } else {
                let text = try await attributed(input, format: source)
                try text.value.string.replacingOccurrences(of: "\u{FFFC}", with: "").write(to: output, atomically: true, encoding: .utf8)
            }
        case .epub:
            let document = try await model(input, format: source)
            try EPUBWriter.write(document, title: document.inferredTitle ?? baseName(input), to: output)
        case .pages:
            let docx = ImageEngine.temporaryURL("docx")
            defer { try? FileManager.default.removeItem(at: docx) }
            if source == .docx {
                try FileManager.default.copyItem(at: input, to: docx)
            } else {
                let text = try await attributed(input, format: source)
                try await runBlocking { try write(text.value, type: .officeOpenXML, to: docx) }
            }
            try FileManager.default.removeItem(at: output)
            try await IWork.pages(docx, saveAsPagesTo: output)
        default:
            throw KumquatError.unsupported("\(source.displayName) → \(target.displayName)")
        }
    }

    static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    static func write(_ text: NSAttributedString, type: NSAttributedString.DocumentType, to output: URL) throws {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        try data.write(to: output, options: .atomic)
    }

    // MARK: - Reading

    /// Model for writers that don't need AppKit fidelity. Markdown is parsed directly so
    /// MD → HTML/EPUB/TXT never takes a lossy detour.
    static func model(_ url: URL, format: FileFormat) async throws -> RichDocument {
        switch format {
        case .md: return MarkdownReader.parse(try readText(url))
        case .txt: return AttributedBridge.document(fromPlain: try readText(url))
        case .tex, .rst, .adoc, .org: return MarkdownReader.parse(try await Pandoc.render(url, from: format, as: "gfm"))
        default:
            let text = try await attributed(url, format: format)
            return AttributedBridge.document(from: text.value)
        }
    }

    static func attributed(_ url: URL, format: FileFormat) async throws -> SendableText {
        switch format {
        case .md:
            let document = MarkdownReader.parse(try readText(url))
            return SendableText(value: AttributedBridge.attributed(document))
        case .txt:
            let text = try readText(url)
            return SendableText(value: NSAttributedString(string: text, attributes: [.font: AttributedBridge.bodyFont, .foregroundColor: NSColor.black]))
        case .html:
            let data = try Data(contentsOf: url)
            return try await importHTML(data, baseURL: url.deletingLastPathComponent())
        case .epub:
            let (html, base, cleanup) = try await EPUBReader.html(url)
            defer { cleanup() }
            return try await importHTML(Data(html.utf8), baseURL: base)
        case .textClipping:
            return try SendableText(value: clipping(url))
        case .pages:
            let docx = ImageEngine.temporaryURL("docx")
            defer { try? FileManager.default.removeItem(at: docx) }
            try await IWork.pages(url, exportTo: docx, as: "Microsoft Word")
            return try await attributed(docx, format: .docx)
        case .tex, .rst, .adoc, .org:
            let body = try await Pandoc.render(url, from: format, as: "html5")
            let page = "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
            return try await importHTML(Data(page.utf8), baseURL: url.deletingLastPathComponent())
        case .mobi, .azw3, .fb2:
            let epub = try await Ebooks.epub(url)
            defer { try? FileManager.default.removeItem(at: epub) }
            return try await attributed(epub, format: .epub)
        default:
            return try await runBlocking { SendableText(value: try loadWithAppKit(url, format: format)) }
        }
    }

    static func loadWithAppKit(_ url: URL, format: FileFormat) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch format {
        case .docx: options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case .doc: options[.documentType] = NSAttributedString.DocumentType.docFormat
        case .odt: options[.documentType] = NSAttributedString.DocumentType.openDocument
        case .rtf: options[.documentType] = NSAttributedString.DocumentType.rtf
        case .rtfd: options[.documentType] = NSAttributedString.DocumentType.rtfd
        default: break
        }
        let loaded = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        return blackened(loaded)
    }

    /// AppKit's HTML importer drives WebKit and must run on the main thread.
    static func importHTML(_ data: Data, baseURL: URL) async throws -> SendableText {
        try await MainActor.run {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .baseURL: baseURL,
            ]
            let text = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return SendableText(value: blackened(text))
        }
    }

    /// Paper is white: uncoloured runs become black instead of the appearance's label colour.
    static func blackened(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value == nil { copy.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        return copy
    }

    /// Text clippings are property lists holding typed pasteboard data.
    static func clipping(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let payload = plist["UTI-Data"] as? [String: Any] else { throw KumquatError.cannotOpen(url.lastPathComponent) }
        if let rtf = payload["public.rtf"] as? Data, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return blackened(text)
        }
        let plain = (payload["public.utf8-plain-text"] as? String) ?? (payload["public.utf16-plain-text"] as? String) ?? ""
        return NSAttributedString(string: plain, attributes: [.font: AttributedBridge.bodyFont, .foregroundColor: NSColor.black])
    }

    /// Plain text with encoding sniffing and a lossy UTF-8 fallback.
    public static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tools

    /// Concatenates documents (page break between each) into one DOCX.
    public static func merge(_ inputs: [URL], output: URL) async throws {
        let combined = NSMutableAttributedString()
        for (index, url) in inputs.enumerated() {
            guard let format = FileFormat.detect(url) else { continue }
            let text = try await attributed(url, format: format)
            if index > 0 { combined.append(NSAttributedString(string: "\n\u{0C}")) }
            combined.append(text.value)
        }
        let result = SendableText(value: combined)
        try await runBlocking { try write(result.value, type: .officeOpenXML, to: output) }
    }

    // MARK: - Pagination

    public static var defaultPaperSize: CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "DO", "SV", "NI", "BO"]
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// TextKit 1 pagination straight into a PDF context: real multi-page output with
    /// selectable text, tables and inline images, safe off the main thread.
    static func paginate(_ text: NSAttributedString, to output: URL, paper: CGSize = defaultPaperSize, margin: CGFloat = 54) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let bodySize = CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2)

        var containers: [NSTextContainer] = []
        while containers.count < 20_000 {
            let container = NSTextContainer(size: bodySize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 {
                if containers.isEmpty { containers.append(container) } else { layout.removeTextContainer(at: layout.textContainers.count - 1) }
                break
            }
            containers.append(container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }

        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let origin = CGPoint(x: margin, y: margin)
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            let range = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

// MARK: - EPUB

enum EPUBWriter {
    static func write(_ document: RichDocument, title: String, to output: URL) throws {
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        var nav = ""
        var index = 0
        for block in document.blocks {
            if case .heading(let level, let inlines) = block {
                index += 1
                if level <= 2 { nav += "<li><a href=\"text.xhtml#h\(index)\">\(xmlEscape(inlines.plainText))</a></li>\n" }
            }
        }
        if nav.isEmpty { nav = "<li><a href=\"text.xhtml\">\(xmlEscape(title))</a></li>" }

        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(identifier)</dc:identifier>
            <dc:title>\(xmlEscape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="text"/></spine>
        </package>
        """)
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(xmlEscape(title))</title></head>
        <body><nav epub:type="toc"><h1>Contents</h1><ol>
        \(nav)</ol></nav></body>
        </html>
        """)
        zip.add("OEBPS/style.css", "body { font-family: serif; line-height: 1.5; } pre { white-space: pre-wrap; } blockquote { margin-left: 1.5em; font-style: italic; }")
        zip.add("OEBPS/text.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(xmlEscape(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        \(HTMLWriter.body(document))</body>
        </html>
        """)
        try zip.write(to: output)
    }
}

enum EPUBReader {
    /// Spine documents concatenated into one HTML page.
    static func html(_ url: URL) async throws -> (html: String, base: URL, cleanup: @Sendable () -> Void) {
        let root = try await PackageReader.extract(url)
        let cleanup: @Sendable () -> Void = { try? FileManager.default.removeItem(at: root) }
        guard let container = XMLElement.parse(contentsOf: root.appendingPathComponent("META-INF/container.xml")),
              let opfPath = container.all("rootfile").first?.attribute("full-path"),
              let opf = XMLElement.parse(contentsOf: root.appendingPathComponent(opfPath)) else {
            cleanup()
            throw KumquatError.cannotOpen(url.lastPathComponent)
        }
        let base = root.appendingPathComponent(opfPath).deletingLastPathComponent()
        var manifest: [String: String] = [:]
        for item in opf.all("item") {
            if let id = item.attribute("id"), let href = item.attribute("href") { manifest[id] = href }
        }
        var bodies: [String] = []
        for itemref in opf.all("itemref") {
            guard let id = itemref.attribute("idref"), let href = manifest[id]?.removingPercentEncoding,
                  let page = try? String(contentsOf: base.appendingPathComponent(href), encoding: .utf8) else { continue }
            bodies.append(bodyContent(page))
        }
        let html = "<html><head><meta charset=\"utf-8\"></head><body>" + bodies.joined(separator: "<div style=\"page-break-after: always\"></div>") + "</body></html>"
        return (html, base, cleanup)
    }

    static func bodyContent(_ page: String) -> String {
        guard let open = page.range(of: "<body", options: .caseInsensitive),
              let start = page[open.upperBound...].firstIndex(of: ">") else { return page }
        let end = page.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? page.endIndex
        return String(page[page.index(after: start)..<end])
    }
}

// MARK: - pandoc

/// LaTeX, reStructuredText, AsciiDoc and Org through pandoc, both ways.
enum Pandoc {
    /// pandoc's reader for a format Kumquat reads, `nil` when it has none.
    static func reader(for format: FileFormat) -> String? {
        switch format {
        case .md: "markdown"
        case .html: "html"
        case .docx: "docx"
        case .odt: "odt"
        case .epub: "epub"
        case .tex: "latex"
        case .rst: "rst"
        case .adoc: "asciidoc"
        case .org: "org"
        default: nil
        }
    }

    /// Targets pandoc writes straight from markup; the rest go through the attributed text.
    static func writer(for format: FileFormat) -> String? {
        switch format {
        case .md: "gfm"
        case .html: "html5"
        case .docx: "docx"
        case .odt: "odt"
        case .epub: "epub3"
        case .txt: "plain"
        case .tex: "latex"
        case .rst: "rst"
        case .adoc: "asciidoc"
        case .org: "org"
        default: nil
        }
    }

    static var tool: URL {
        get throws {
            guard let pandoc = Engines.pandoc else { throw KumquatError.toolMissing("pandoc") }
            return pandoc
        }
    }

    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        guard let writer = writer(for: target) else { throw KumquatError.unsupported("\(source.displayName) → \(target.displayName)") }
        let pandoc = try tool
        let (file, reader, cleanup) = try await readable(input, format: source)
        defer { cleanup() }
        var arguments = ["-f", reader, "-t", writer, "--resource-path", input.deletingLastPathComponent().path, "-o", output.path]
        // Full documents for the formats that have a preamble; fragments for the plain-text markups.
        if [.tex, .html].contains(target) { arguments += ["--standalone", "--metadata", "pagetitle=\(DocumentEngine.baseName(input))"] }
        try await ExternalTool.check(pandoc, arguments + [file.path], timeout: 300)
    }

    /// The input itself when pandoc reads it; otherwise plain text as HTML and everything else
    /// AppKit opens (RTF, DOC, Pages…) as a temporary DOCX.
    static func readable(_ input: URL, format: FileFormat) async throws -> (URL, String, @Sendable () -> Void) {
        if let reader = reader(for: format) { return (input, reader, {}) }
        if format == .txt {
            let html = ImageEngine.temporaryURL("html")
            let document = AttributedBridge.document(fromPlain: try DocumentEngine.readText(input))
            try HTMLWriter.page(document, fallbackTitle: DocumentEngine.baseName(input)).write(to: html, atomically: true, encoding: .utf8)
            return (html, "html", { try? FileManager.default.removeItem(at: html) })
        }
        let docx = ImageEngine.temporaryURL("docx")
        let text = try await DocumentEngine.attributed(input, format: format)
        try await runBlocking { try DocumentEngine.write(text.value, type: .officeOpenXML, to: docx) }
        return (docx, "docx", { try? FileManager.default.removeItem(at: docx) })
    }

    /// Markup rendered to `writer` (e.g. "html5" fragment, "gfm") on stdout.
    static func render(_ input: URL, from source: FileFormat, as writer: String) async throws -> String {
        guard let reader = reader(for: source) else { throw KumquatError.unsupported(source.displayName) }
        let result = try await ExternalTool.check(try tool, ["-f", reader, "-t", writer, "--wrap=none", input.path], timeout: 300)
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

// MARK: - Calibre

/// MOBI, AZW3 and FB2 through Calibre's ebook-convert.
enum Ebooks {
    /// What ebook-convert writes directly from an ebook.
    static let calibreTargets: Set<FileFormat> = [.epub, .pdf, .docx, .txt, .rtf, .mobi, .azw3]

    static var tool: URL {
        get throws {
            guard let calibre = Engines.ebookConvert else { throw KumquatError.toolMissing("Calibre") }
            return calibre
        }
    }

    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        let calibre = try tool
        if Catalog.ebooks.contains(source) {
            if calibreTargets.contains(target) {
                try await run(calibre, input, output)
                return
            }
            // HTML and the rest: through an EPUB Kumquat's own readers understand.
            let epub = try await self.epub(input)
            defer { try? FileManager.default.removeItem(at: epub) }
            try await DocumentEngine.convert(epub, from: .epub, to: target, output: output)
            return
        }
        // Into MOBI/AZW3: Calibre reads EPUB, DOCX and HTML well; Markdown and text become an EPUB first.
        if [.epub, .docx, .html].contains(source) {
            try await run(calibre, input, output)
            return
        }
        let epub = ImageEngine.temporaryURL("epub")
        defer { try? FileManager.default.removeItem(at: epub) }
        try await DocumentEngine.convert(input, from: source, to: .epub, output: epub)
        try await run(calibre, epub, output)
    }

    /// An ebook as a temporary EPUB (the caller removes it).
    static func epub(_ input: URL) async throws -> URL {
        let epub = ImageEngine.temporaryURL("epub")
        do {
            try await run(try tool, input, epub)
        } catch {
            try? FileManager.default.removeItem(at: epub)
            throw error
        }
        return epub
    }

    /// ebook-convert picks both formats from the file extensions.
    static func run(_ tool: URL, _ input: URL, _ output: URL) async throws {
        try await ExternalTool.check(tool, [input.path, output.path], timeout: 900)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw KumquatError.processFailed(String(localized: "Calibre didn't produce \(output.lastPathComponent)."))
        }
    }
}

// MARK: - iWork automation

/// Pages, Keynote and Numbers as headless engines through Apple Events (osascript),
/// serialised because each app handles one scripted export at a time.
enum IWork {
    /// One iWork automation at a time, shared with the Keynote exports in SlidesExtras.
    static let gate = AsyncGate()

    static func pages(_ input: URL, exportTo output: URL, as format: String) async throws {
        try await run(app: .pages, input: input, output: output, verb: "export theDoc to outFile as \(format)")
    }

    static func pages(_ input: URL, saveAsPagesTo output: URL) async throws {
        try await run(app: .pages, input: input, output: output, verb: "save theDoc in outFile")
    }

    static func keynote(_ input: URL, exportTo output: URL, as format: String) async throws {
        try await run(app: .keynote, input: input, output: output, verb: "export theDoc to outFile as \(format)")
    }

    static func numbers(_ input: URL, exportTo output: URL, as format: String) async throws {
        try await run(app: .numbers, input: input, output: output, verb: "export theDoc to outFile as \(format)")
    }

    private static func run(app: Engines.App, input: URL, output: URL, verb: String) async throws {
        guard app.isInstalled else { throw KumquatError.toolMissing(app.rawValue) }
        let script = [
            "on run argv",
            "set inFile to POSIX file (item 1 of argv)",
            "set outFile to POSIX file (item 2 of argv)",
            "set wasRunning to application \"\(app.rawValue)\" is running",
            "tell application \"\(app.rawValue)\"",
            "set theDoc to open inFile",
            verb,
            "close theDoc saving no",
            "if not wasRunning then quit",
            "end tell",
            "end run",
        ]
        let arguments = script.flatMap { ["-e", $0] } + [input.path, output.path]
        _ = try await gate.withLock {
            try await ExternalTool.check(Engines.osascript, arguments, timeout: 300)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw KumquatError.processFailed(String(localized: "\(app.rawValue) didn't produce \(output.lastPathComponent)."))
        }
    }
}

/// FIFO async mutex.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
