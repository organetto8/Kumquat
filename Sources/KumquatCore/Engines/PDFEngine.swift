import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

/// PDF → DOCX/Pages/PPTX/XLSX/CSV/JPG/PNG/HEIC/WebP/TIFF/EPUB/TXT/MD/HTML/RTF/ODT and the PDF tools. Rendering uses
/// CoreGraphics (thread-safe, memory-mapped); page edits use PDFKit (keeps links/outlines).
public enum PDFEngine {
    public static let rasterDPI: CGFloat = 300

    public static func pageCount(of url: URL) -> Int { CGPDFDocument(url as CFURL)?.numberOfPages ?? 0 }

    public static func convert(_ input: URL, to target: FileFormat, output: URL) async throws {
        switch target {
        case .txt:
            let pages = try await TextExtractor.pdfPages(input)
            try pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
        case .md:
            try MarkdownWriter.write(try await model(input)).write(to: output, atomically: true, encoding: .utf8)
        case .epub:
            try EPUBWriter.write(try await model(input), title: input.deletingPathExtension().lastPathComponent, to: output)
        case .docx:
            let text = try await attributed(input)
            try await runBlocking { try DocumentEngine.write(text.value, type: .officeOpenXML, to: output) }
        case .pages:
            let docx = ImageEngine.temporaryURL("docx")
            defer { try? FileManager.default.removeItem(at: docx) }
            let text = try await attributed(input)
            try await runBlocking { try DocumentEngine.write(text.value, type: .officeOpenXML, to: docx) }
            try FileManager.default.removeItem(at: output)
            try await IWork.pages(docx, saveAsPagesTo: output)
        case .pptx:
            try await runBlocking { try slides(input, to: output) }
        case .xlsx:
            let sheets = try await tables(input).enumerated().map { index, rows in Sheet(name: String(localized: "Page \(index + 1)"), rows: rows) }
            try XLSX.write(sheets, to: output)
        case .csv:
            // One table: every page's rows in reading order.
            let rows = try await tables(input).flatMap { $0 }
            guard !rows.isEmpty else { throw KumquatError.noResult(String(localized: "No text found in “\(input.lastPathComponent)”.")) }
            try CSV.write(rows, delimiter: ",").write(to: output, atomically: true, encoding: .utf8)
        case .html:
            try HTMLWriter.page(try await model(input), fallbackTitle: input.deletingPathExtension().lastPathComponent)
                .write(to: output, atomically: true, encoding: .utf8)
        case .rtf, .odt:
            let text = try await attributed(input)
            try await runBlocking { try DocumentEngine.write(text.value, type: target == .rtf ? .rtf : .openDocument, to: output) }
        case .tiff:
            try await runCancellable { flag in try multipageTIFF(input, output: output, flag: flag) }
        default:
            throw KumquatError.unsupported(String(localized: "PDF → \(target.displayName)"))
        }
    }

    /// Resolution of PDF → TIFF: sharp text, and pages a fax or archive system accepts.
    static let tiffDPI: CGFloat = 200

    /// Every page in one multi-page, LZW-compressed TIFF.
    static func multipageTIFF(_ input: URL, output: URL, flag: CancellationFlag) throws {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.tiff" as CFString, document.numberOfPages, nil) else {
            throw KumquatError.cannotEncode("TIFF")
        }
        let properties = [
            kCGImagePropertyDPIWidth: tiffDPI, kCGImagePropertyDPIHeight: tiffDPI,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
        ] as CFDictionary
        for index in 1...document.numberOfPages {
            try flag.check()
            try autoreleasepool {
                guard let page = document.page(at: index), let image = render(page, scale: tiffDPI / 72) else {
                    throw KumquatError.cannotDecode(String(localized: "page \(index)"))
                }
                CGImageDestinationAddImage(destination, image, properties)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("TIFF") }
    }

    /// Splits a text line into table cells on tabs or runs of 2+ spaces.
    static func cells(_ line: String) -> [String] {
        line.split(separator: /\t|\s{2,}/).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Rows of cells for every page: from glyph positions where there is a text layer, from the OCR
    /// text (split by `cells`) for scanned pages.
    static func tables(_ url: URL) async throws -> [[[String]]] {
        let text = try await TextExtractor.pdfPages(url)
        return try await runBlocking {
            guard let document = PDFDocument(url: url) else { throw KumquatError.cannotOpen(url.lastPathComponent) }
            return text.indices.map { index in
                let positioned = document.page(at: index).map(tableRows) ?? []
                return positioned.isEmpty ? text[index].components(separatedBy: .newlines).map(cells).filter { !$0.isEmpty } : positioned
            }
        }
    }

    /// A page's text layer as rows of cells. PDFKit's plain text turns the space between columns
    /// into a single space, so words are placed instead: a gap wider than most of the line height
    /// (several word spaces, even in justified text) starts a new cell, and so does a tab.
    static func tableRows(_ page: PDFPage) -> [[String]] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let string = text as NSString
        let words = try! NSRegularExpression(pattern: #"\t|[^\s]+"#)
        var rows: [[String]] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            var row: [String] = [], cell = ""
            var lastEdge: CGFloat?, lineHeight: CGFloat = 0
            func endCell() {
                if !cell.isEmpty { row.append(cell) }
                cell = ""
            }
            for match in words.matches(in: text, range: line) {
                let word = string.substring(with: match.range)
                if word == "\t" {
                    endCell()
                    lastEdge = nil
                    continue
                }
                // Selections map string ranges onto the page reliably; characterBounds drifts after line breaks.
                let bounds = page.selection(for: match.range)?.bounds(for: page) ?? .zero
                if let lastEdge, !bounds.isEmpty, bounds.minX - lastEdge > max(4, lineHeight * 0.8) { endCell() }
                cell += cell.isEmpty ? word : " " + word
                if !bounds.isEmpty {
                    lastEdge = bounds.maxX
                    lineHeight = max(lineHeight, bounds.height)
                }
            }
            endCell()
            if !row.isEmpty { rows.append(row) }
        }
        return rows
    }

    /// Page text with fonts (headings survive) plus OCR for scanned pages.
    static func attributed(_ url: URL) async throws -> SendableText {
        let ocr = try await TextExtractor.pdfPages(url)
        return try await runBlocking {
            guard let document = PDFDocument(url: url) else { throw KumquatError.cannotOpen(url.lastPathComponent) }
            let out = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                if index > 0 { out.append(NSAttributedString(string: "\n\u{0C}")) }
                if let page = document.page(at: index), let text = page.attributedString, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(DocumentEngine.blackened(text))
                } else {
                    out.append(NSAttributedString(string: ocr[index], attributes: [.font: AttributedBridge.bodyFont, .foregroundColor: NSColor.black]))
                }
            }
            return SendableText(value: out)
        }
    }

    static func model(_ url: URL) async throws -> RichDocument {
        let text = try await attributed(url)
        var document = AttributedBridge.document(from: text.value)
        document.blocks.removeAll { $0 == .pageBreak }
        return document
    }

    // MARK: - Rendering

    /// Renders a page upright into an opaque sRGB bitmap.
    public static func render(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let size = uprightSize(page)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 300_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        drawUpright(page, in: context)
        return context.makeImage()
    }

    static func uprightSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func drawUpright(_ page: CGPDFPage, in context: CGContext) {
        let size = uprightSize(page)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
    }

    /// Every page to image files in parallel; each worker opens its own memory-mapped document.
    public static func renderPages(of url: URL, pages: [Int]? = nil, dpi: CGFloat = rasterDPI, format: FileFormat, into directory: URL, baseName: String) async throws -> [URL] {
        if format == .webp { return try await renderWebP(of: url, pages: pages, dpi: dpi, into: directory, baseName: baseName) }
        let count = pageCount(of: url)
        guard count > 0 else { throw KumquatError.cannotOpen(url.lastPathComponent) }
        let indexes = (pages ?? Array(0..<count)).filter { $0 >= 0 && $0 < count }
        let digits = String(count).count
        let workers = min(indexes.count, workerCount, 6)
        return try await withThrowingTaskGroup(of: [(Int, URL)].self) { group in
            for worker in 0..<workers {
                let mine = stride(from: worker, to: indexes.count, by: workers).map { indexes[$0] }
                group.addTask {
                    try await runCancellable { flag in
                        guard let document = CGPDFDocument(url as CFURL) else { throw KumquatError.cannotOpen(url.lastPathComponent) }
                        var written: [(Int, URL)] = []
                        for index in mine {
                            try flag.check()
                            try autoreleasepool {
                                guard let page = document.page(at: index + 1), let image = render(page, scale: dpi / 72) else { return }
                                let name = count == 1 ? baseName : "\(baseName) p\(String(format: "%0\(digits)d", index + 1))"
                                let output = try OutputNaming.reserve(in: directory, base: name, ext: format.fileExtension)
                                try ImageEngine.write(image, as: format, to: output, quality: 0.92,
                                                      metadata: [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi])
                                written.append((index, output))
                            }
                        }
                        return written
                    }
                }
            }
            var all: [(Int, URL)] = []
            for try await chunk in group { all += chunk }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// WebP has no ImageIO encoder: pages are rendered to PNG in a scratch folder, then cwebp
    /// encodes a few at a time (each run is already multi-threaded).
    static func renderWebP(of url: URL, pages: [Int]?, dpi: CGFloat, into directory: URL, baseName: String) async throws -> [URL] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pngs = try await renderPages(of: url, pages: pages, dpi: dpi, format: .png, into: scratch, baseName: baseName)
        let outputs = try pngs.map { try OutputNaming.reserve(in: directory, base: $0.deletingPathExtension().lastPathComponent, ext: "webp") }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var queue = zip(pngs, outputs).makeIterator()
                func schedule() {
                    guard let (png, output) = queue.next() else { return }
                    group.addTask { try await ImageEngine.cwebp(png, output: output, quality: 0.92) }
                }
                for _ in 0..<4 { schedule() }
                while try await group.next() != nil { schedule() }
            }
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        return outputs
    }

    // MARK: - Images → PDF

    /// One page per image. Scans (≥150 dpi) keep their physical size; photos and screenshots
    /// are fitted onto the default paper size.
    public static func imagesToPDF(_ urls: [URL], output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        var pages = 0
        for url in urls {
            try autoreleasepool {
                let image = try ImageEngine.decode(url, maxPixelSize: nil)
                var dpi = 72.0
                if let source = ImageProbe.source(url), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
                }
                drawImagePage(image, dpi: dpi, in: context)
                pages += 1
            }
        }
        context.closePDF()
        guard pages > 0 else { throw KumquatError.noResult(String(localized: "No readable images.")) }
    }

    static func drawImagePage(_ image: CGImage, dpi: Double, in context: CGContext) {
        let pixels = CGSize(width: image.width, height: image.height)
        var page: CGRect
        let target: CGRect
        if dpi >= 150 {
            page = CGRect(x: 0, y: 0, width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi)
            target = page
        } else {
            var paper = DocumentEngine.defaultPaperSize
            if pixels.width > pixels.height { paper = CGSize(width: paper.height, height: paper.width) }
            page = CGRect(origin: .zero, size: paper)
            let box = page.insetBy(dx: 36, dy: 36)
            let scale = min(box.width / pixels.width, box.height / pixels.height, 1)
            let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
            target = CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
        }
        context.beginPage(mediaBox: &page)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        context.endPage()
    }

    /// PDF → PPTX: one full-bleed picture slide per page.
    static func slides(_ input: URL, to output: URL) throws {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        var images: [PPTXWriter.Picture] = []
        for index in 1...document.numberOfPages {
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let size = uprightSize(page)
                let scale = min(2000 / max(size.width, size.height), 200 / 72)
                guard let image = render(page, scale: scale) else { return }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("JPEG") }
                images.append(PPTXWriter.Picture(jpeg: data as Data, size: size))
            }
        }
        try PPTXWriter.write(images, to: output)
    }

    // MARK: - Tools

    /// Concatenates PDFs and images (in order) into one PDF.
    public static func merge(_ urls: [URL], output: URL) throws {
        let result = PDFDocument()
        let scratch = ImageEngine.temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        for url in urls {
            let source: PDFDocument?
            if FileFormat.detect(url) == .pdf {
                source = PDFDocument(url: url)
            } else {
                try imagesToPDF([url], output: scratch)
                source = PDFDocument(url: scratch)
            }
            guard let source else { continue }
            for index in 0..<source.pageCount {
                if let page = source.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        guard result.pageCount > 0 else { throw KumquatError.noResult(String(localized: "Nothing to merge.")) }
        guard result.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// One PDF per page.
    public static func split(_ input: URL, into directory: URL, baseName: String) throws -> [URL] {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        guard document.pageCount > 1 else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has a single page.")) }
        let digits = String(document.pageCount).count
        return try (0..<document.pageCount).map { index in
            let single = PDFDocument()
            if let page = document.page(at: index)?.copy() as? PDFPage { single.insert(page, at: 0) }
            let output = try OutputNaming.reserve(in: directory, base: "\(baseName) p\(String(format: "%0\(digits)d", index + 1))", ext: "pdf")
            guard single.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
            return output
        }
    }

    public static func extractPages(_ input: URL, pages: [Int], output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        let result = PDFDocument()
        for index in pages {
            if let page = document.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        guard result.pageCount > 0 else { throw KumquatError.noResult(String(localized: "No pages in range.")) }
        guard result.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// `degrees`: 90 (clockwise), 180 or 270 (counter-clockwise).
    public static func rotate(_ input: URL, degrees: Int = 90, output: URL) throws {
        guard degrees % 90 == 0 else { throw KumquatError.noResult(String(localized: "Rotate by 90°, 180° or 270°.")) }
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        guard document.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// Re-encodes embedded images as screen-resolution JPEG.
    public static func compress(_ input: URL, output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before {
            try? FileManager.default.removeItem(at: output)
            throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is already as small as it gets."))
        }
    }

    /// Keeps `region` of every page: normalised, top-left origin, as drawn on the first page shown upright.
    public static func crop(_ input: URL, region: CGRect, output: URL) throws {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let area = region.intersection(unit)
        guard area.width > 0.01, area.height > 0.01 else { throw KumquatError.noResult(String(localized: "Draw the area to keep.")) }
        guard area != unit else { throw KumquatError.noResult(String(localized: "The area to keep is the whole page.")) }
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(pageRect(area, in: page.bounds(for: .cropBox), rotation: page.rotation), for: .cropBox)
        }
        guard document.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// A normalised area of a page as shown (turned clockwise by `rotation`), in the page's own space.
    static func pageRect(_ area: CGRect, in box: CGRect, rotation: Int) -> CGRect {
        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch (rotation % 360 + 360) % 360 {
            case 90: CGPoint(x: box.minX + v * box.width, y: box.minY + u * box.height)
            case 180: CGPoint(x: box.maxX - u * box.width, y: box.minY + v * box.height)
            case 270: CGPoint(x: box.maxX - v * box.width, y: box.maxY - u * box.height)
            default: CGPoint(x: box.minX + u * box.width, y: box.maxY - v * box.height)
            }
        }
        let a = point(area.minX, area.minY), b = point(area.maxX, area.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Crops every page to its visible content plus a small margin.
    public static func autoCrop(_ input: URL, output: URL) throws {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        var changed = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.rotation == 0, let cgPage = cg.page(at: index + 1),
                  let image = render(cgPage, scale: 1), let content = ImageEngine.contentBounds(image) else { continue }
            let crop = page.bounds(for: .cropBox)
            // Bitmap rows run top-down; PDF space runs bottom-up.
            let rect = CGRect(x: crop.minX + content.minX, y: crop.maxY - content.maxY, width: content.width, height: content.height)
                .insetBy(dx: -8, dy: -8).intersection(crop)
            page.setBounds(rect, for: .cropBox)
            changed = true
        }
        guard changed else { throw KumquatError.noResult(String(localized: "No margins to crop in “\(input.lastPathComponent)”.")) }
        guard document.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// Encrypts with a password, or unlocks when the PDF is already protected.
    /// Returns `true` when it unlocked.
    public static func password(_ input: URL, password: String, output: URL) throws -> Bool {
        guard !password.isEmpty else { throw KumquatError.noResult(String(localized: "Enter a password.")) }
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        if document.isEncrypted {
            guard document.unlock(withPassword: password) else { throw KumquatError.noResult(String(localized: "Wrong password for “\(input.lastPathComponent)”.")) }
            let plain = PDFDocument()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { plain.insert(page, at: plain.pageCount) }
            }
            guard plain.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
            return true
        }
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard document.write(to: output, withOptions: options) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        return false
    }

    /// Semi-transparent text across the middle of every page, diagonal or level.
    public static func watermark(_ input: URL, text: String, opacity: Double = 0.28, diagonal: Bool = true, output: URL) throws {
        guard (0.01...1).contains(opacity) else { throw KumquatError.noResult(String(localized: "Opacity must be between 1% and 100%.")) }
        try redraw(input, output: output) { context, size, _ in
            let fontSize = min(size.width, size.height) / CGFloat(max(text.count, 6)) * 1.6
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: opacity),
            ]))
            let bounds = CTLineGetImageBounds(line, context)
            context.saveGState()
            context.translateBy(x: size.width / 2, y: size.height / 2)
            if diagonal { context.rotate(by: atan2(size.height, size.width)) }
            context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// Adds an invisible OCR text layer to pages that have no text, so scans become
    /// searchable and copyable. Pages that already have text are kept as they are.
    public static func makeSearchable(_ input: URL, output: URL) async throws {
        let needsOCR: [Bool] = try await runBlocking {
            guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
            return (0..<document.pageCount).map { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard needsOCR.contains(true) else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” already has selectable text.")) }
        var lines = [[RecognizedLine]](repeating: [], count: needsOCR.count)
        try await withThrowingTaskGroup(of: (Int, [RecognizedLine]).self) { group in
            var queue = needsOCR.indices.filter { needsOCR[$0] }.makeIterator()
            func schedule() {
                guard let index = queue.next() else { return }
                group.addTask {
                    try await runBlocking {
                        guard let document = CGPDFDocument(input as CFURL), let page = document.page(at: index + 1),
                              let image = render(page, scale: 2.5) else { return (index, []) }
                        return (index, try TextExtractor.lines(in: image))
                    }
                }
            }
            for _ in 0..<4 { schedule() }
            while let (index, found) = try await group.next() {
                lines[index] = found
                schedule()
            }
        }
        let recognized = lines
        try await runBlocking {
            try redraw(input, output: output) { context, size, index in
                context.saveGState()
                context.setTextDrawingMode(.invisible)
                for line in recognized[index] {
                    let box = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                                     width: line.box.width * size.width, height: line.box.height * size.height)
                    let font = CTFontCreateWithName("Helvetica" as CFString, max(box.height * 0.85, 1), nil)
                    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                    let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                    context.saveGState()
                    context.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
                    if width > 0 { context.scaleBy(x: box.width / CGFloat(width), y: 1) }
                    context.textPosition = .zero
                    CTLineDraw(ctLine, context)
                    context.restoreGState()
                }
                context.restoreGState()
            }
        }
    }

    /// Re-draws each page upright into a new PDF and lets `overlay` paint on top.
    static func redraw(_ input: URL, output: URL, overlay: (CGContext, CGSize, Int) throws -> Void) throws {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        for index in 0..<document.numberOfPages {
            guard let page = document.page(at: index + 1) else { continue }
            var box = CGRect(origin: .zero, size: uprightSize(page))
            context.beginPage(mediaBox: &box)
            context.saveGState()
            drawUpright(page, in: context)
            context.restoreGState()
            try overlay(context, box.size, index)
            context.endPage()
        }
        context.closePDF()
    }

    /// Parses "1-3, 5, 8-" into 0-based page indexes; `nil` when malformed or out of range.
    public static func parsePageRange(_ text: String, pageCount: Int) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(0..<pageCount) }
        var seen = Set<Int>()
        var result: [Int] = []
        for part in trimmed.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let range: ClosedRange<Int>
            switch bounds.count {
            case 1:
                guard let page = Int(bounds[0]) else { return nil }
                range = page...page
            case 2:
                guard let start = bounds[0].isEmpty ? 1 : Int(bounds[0]), let end = bounds[1].isEmpty ? pageCount : Int(bounds[1]), start <= end else { return nil }
                range = start...end
            default:
                return nil
            }
            guard range.lowerBound >= 1, range.upperBound <= pageCount else { return nil }
            for page in range where seen.insert(page - 1).inserted { result.append(page - 1) }
        }
        return result
    }
}

// MARK: - Slides

/// PPTX/PPT/Keynote via Keynote (exported to PDF, then rendered natively).
public enum SlidesEngine {
    public static func toPDF(_ input: URL, output: URL) async throws {
        try FileManager.default.removeItem(at: output)
        try await IWork.keynote(input, exportTo: output, as: "PDF")
    }

    public static func toPowerPoint(_ input: URL, output: URL) async throws {
        try FileManager.default.removeItem(at: output)
        try await IWork.keynote(input, exportTo: output, as: "Microsoft PowerPoint")
    }

    public static func toImages(_ input: URL, format: FileFormat, into directory: URL, baseName: String) async throws -> [URL] {
        let pdf = ImageEngine.temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        try await IWork.keynote(input, exportTo: pdf, as: "PDF")
        // Slides export at their native point size (e.g. 1920×1080): render at ≥1920 px wide.
        let width = CGPDFDocument(pdf as CFURL)?.page(at: 1).map { PDFEngine.uprightSize($0).width } ?? 1920
        return try await PDFEngine.renderPages(of: pdf, dpi: max(72, 72 * 1920 / width), format: format, into: directory, baseName: baseName)
    }
}

/// Minimal valid PresentationML package: one picture per slide.
enum PPTXWriter {
    struct Picture {
        let jpeg: Data
        let size: CGSize
    }

    static func write(_ pictures: [Picture], to output: URL) throws {
        guard let first = pictures.first else { throw KumquatError.noResult(String(localized: "No pages to convert.")) }
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let slideWidth = 12_192_000
        let slideHeight = min(max(Int(Double(slideWidth) * Double(first.size.height / first.size.width)), 914_400), 51_206_400)
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        let relsNS = "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\""
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

        var zip = ZipWriter()
        var overrides = ""
        var slideIDs = ""
        var presentationRels = "<Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"theme/theme1.xml\"/>"
        for (index, picture) in pictures.enumerated() {
            let n = index + 1
            overrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            slideIDs += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 2)\"/>"
            presentationRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"\(relType)/slide\" Target=\"slides/slide\(n).xml\"/>"
            // Fit the picture inside the slide, centred.
            let scale = min(Double(slideWidth) / Double(picture.size.width), Double(slideHeight) / Double(picture.size.height))
            let cx = Int(Double(picture.size.width) * scale), cy = Int(Double(picture.size.height) * scale)
            let x = (slideWidth - cx) / 2, y = (slideHeight - cy) / 2
            zip.add("ppt/slides/slide\(n).xml", header + """
            <p:sld \(ns)><p:cSld><p:spTree>\(emptyTree)<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", header + "<Relationships \(relsNS)><Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relType)/image\" Target=\"../media/image\(n).jpeg\"/></Relationships>")
            zip.add("ppt/media/image\(n).jpeg", picture.jpeg, store: true)
        }

        zip.add("[Content_Types].xml", header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(overrides)</Types>
        """)
        zip.add("_rels/.rels", header + "<Relationships \(relsNS)><Relationship Id=\"rId1\" Type=\"\(relType)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        zip.add("ppt/presentation.xml", header + """
        <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        zip.add("ppt/_rels/presentation.xml.rels", header + "<Relationships \(relsNS)>\(presentationRels)</Relationships>")
        zip.add("ppt/slideMasters/slideMaster1.xml", header + """
        <p:sldMaster \(ns)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", header + "<Relationships \(relsNS)><Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        zip.add("ppt/slideLayouts/slideLayout1.xml", header + """
        <p:sldLayout \(ns) preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", header + "<Relationships \(relsNS)><Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        zip.add("ppt/theme/theme1.xml", header + theme)
        try zip.write(to: output)
    }

    private static let theme: String = {
        func colors() -> String {
            let pairs = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F497D"), ("lt2", "EEECE1"), ("accent1", "F28C28"), ("accent2", "4F81BD"),
                         ("accent3", "9BBB59"), ("accent4", "8064A2"), ("accent5", "4BACC6"), ("accent6", "C0504D"), ("hlink", "0000FF"), ("folHlink", "800080")]
            return pairs.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        }
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        return """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Kumquat"><a:themeElements><a:clrScheme name="Kumquat">\(colors())</a:clrScheme><a:fontScheme name="Kumquat"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Kumquat"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }()
}
