import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Quartz

/// PDF tools added after 1.2.
extension PDFEngine {
    /// `order`: comma-separated 1-based page numbers in the new order; a page left out is deleted;
    /// "r90" / "r180" / "r270" after a number turns that page clockwise ("3,1r90,2").
    public static func reorder(_ input: URL, order: String, output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        guard let steps = parseOrder(order, pageCount: document.pageCount) else {
            throw KumquatError.noResult(String(localized: "“\(order)” isn't a valid page order for this \(document.pageCount)-page PDF."))
        }
        let result = PDFDocument()
        for step in steps {
            // Copies, so a page can appear twice.
            guard let page = document.page(at: step.index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + step.turn) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw KumquatError.noResult(String(localized: "Keep at least one page.")) }
        result.documentAttributes = document.documentAttributes
        guard result.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// "3,1r90,2" → page indexes with a clockwise turn each; `nil` when malformed or out of range.
    static func parseOrder(_ text: String, pageCount: Int) -> [(index: Int, turn: Int)]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !parts.isEmpty, pageCount > 0 else { return nil }
        var steps: [(index: Int, turn: Int)] = []
        for part in parts {
            let pieces = part.split(separator: "r", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count), let number = Int(pieces[0]), (1...pageCount).contains(number) else { return nil }
            var turn = 0
            if pieces.count == 2 {
                guard let degrees = Int(pieces[1]), [0, 90, 180, 270].contains(degrees) else { return nil }
                turn = degrees
            }
            steps.append((number - 1, turn))
        }
        return steps
    }

    /// Places the signature image on `page` ("last" or a 1-based number), in `region` (normalised, top-left
    /// origin, of that page) or, when `nil`, bottom right. The signature becomes part of the page.
    public static func sign(_ input: URL, signature: URL, page: String, region: CGRect?, output: URL) throws {
        let count = pageCount(of: input)
        guard count > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        let wanted = page.trimmingCharacters(in: .whitespaces).lowercased()
        let target: Int
        if wanted.isEmpty || wanted == "last" {
            target = count - 1
        } else {
            guard let number = Int(wanted), (1...count).contains(number) else {
                throw KumquatError.noResult(String(localized: "Page “\(page)” isn't in this \(count)-page PDF."))
            }
            target = number - 1
        }
        var area: CGRect?
        if let region {
            area = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let area, area.width > 0.005, area.height > 0.005 else { throw KumquatError.noResult(String(localized: "Draw where the signature goes.")) }
        }
        let ink = try ImageEngine.decode(signature, maxPixelSize: 2000)
        try redraw(input, output: output) { context, size, index in
            guard index == target else { return }
            let placed: CGRect
            if let area {
                let box = CGRect(x: area.minX * size.width, y: (1 - area.maxY) * size.height, width: area.width * size.width, height: area.height * size.height)
                placed = ImageEngine.fitted(ink, in: box)
            } else {
                // Bottom right: up to a third of the page wide, inside the usual margin.
                let margin = min(size.width, size.height) * 0.07
                let box = CGRect(x: size.width - margin - size.width * 0.3, y: margin, width: size.width * 0.3, height: size.height * 0.1)
                let fit = ImageEngine.fitted(ink, in: box)
                placed = CGRect(x: box.maxX - fit.width, y: box.minY, width: fit.width, height: fit.height)
            }
            context.saveGState()
            // Multiply leaves only the ink, for transparent PNGs and signatures photographed on white paper alike.
            context.setBlendMode(.multiply)
            context.interpolationQuality = .high
            context.draw(ink, in: placed)
            context.restoreGState()
        }
    }

    /// Resolution of pages rasterised by Redact.
    static let redactionDPI: CGFloat = 200

    /// Real redaction: pages with a match are rasterised with black boxes over every match, so the text is gone.
    /// `patterns`: "none", "email", "iban", "phone" or "all". Throws `noResult` when nothing matches.
    public static func redact(_ input: URL, terms: [String], patterns: String, output: URL) throws {
        guard let document = PDFDocument(url: input), let pages = CGPDFDocument(input as CFURL) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        var boxes: [Int: [CGRect]] = [:]
        func cover(_ selection: PDFSelection) {
            // Line by line: a match wrapping onto the next line gets two tight boxes, not one huge one.
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let index = document.index(for: page)
                    let rect = line.bounds(for: page)
                    guard index != NSNotFound, !rect.isEmpty else { continue }
                    boxes[index, default: []].append(rect.insetBy(dx: -1, dy: -1))
                }
            }
        }
        for term in terms {
            for selection in document.findString(term, withOptions: [.caseInsensitive]) { cover(selection) }
        }
        let expressions = redactionPatterns(patterns)
        if !expressions.isEmpty {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let text = page.string, !text.isEmpty else { continue }
                let whole = NSRange(location: 0, length: (text as NSString).length)
                for pattern in expressions {
                    for match in pattern.expression.matches(in: text, range: whole) where pattern.accepts((text as NSString).substring(with: match.range)) {
                        if let selection = page.selection(for: match.range) { cover(selection) }
                    }
                }
            }
        }
        guard !boxes.isEmpty else { throw KumquatError.noResult(String(localized: "Nothing to hide in “\(input.lastPathComponent)”.")) }
        // The one-page documents holding the pictures must outlive the write: their pages read from them.
        var holders: [PDFDocument] = []
        for (index, rects) in boxes {
            guard let page = pages.page(at: index + 1), let holder = try rasterized(page, covering: rects), let flat = holder.page(at: 0) else { continue }
            holder.removePage(at: 0)
            holders.append(holder)
            document.removePage(at: index)
            document.insert(flat, at: index)
        }
        guard document.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        withExtendedLifetime(holders) {}
    }

    struct RedactionPattern {
        let expression: NSRegularExpression
        /// Second look at a match, for what a regular expression can't say.
        let accepts: (String) -> Bool
    }

    static func redactionPatterns(_ which: String) -> [RedactionPattern] {
        func digits(_ text: String) -> Int { text.filter(\.isNumber).count }
        var result: [RedactionPattern] = []
        if which == "email" || which == "all" {
            result.append(RedactionPattern(expression: try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive),
                                           accepts: { _ in true }))
        }
        if which == "iban" || which == "all" {
            // Country, check digits, then 11–30 letters and digits, optionally in groups; mostly digits in practice.
            result.append(RedactionPattern(expression: try! NSRegularExpression(pattern: #"\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}\b"#),
                                           accepts: { digits($0) >= 10 }))
        }
        if which == "phone" || which == "all" {
            // 9–15 digits (the international maximum) with the usual separators, but not dates.
            let date = try! NSRegularExpression(pattern: #"\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}"#)
            result.append(RedactionPattern(expression: try! NSRegularExpression(pattern: #"\+?\(?\d[\d ()./-]{6,}\d"#),
                                           accepts: { match in
                                               (9...15).contains(digits(match))
                                                   && date.firstMatch(in: match, range: NSRange(location: 0, length: (match as NSString).length)) == nil
                                           }))
        }
        return result
    }

    /// A one-page document: the page as a picture with black boxes over `rects` (page space), so
    /// nothing underneath survives.
    static func rasterized(_ page: CGPDFPage, covering rects: [CGRect]) throws -> PDFDocument? {
        let size = uprightSize(page)
        let scale = redactionDPI / 72
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw KumquatError.cannotDecode(String(localized: "page"))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // Same transform as the page drawing, so the boxes land in page space.
        drawUpright(page, in: context)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rects)
        guard let image = context.makeImage() else { throw KumquatError.cannotDecode(String(localized: "page")) }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw KumquatError.cannotWrite(String(localized: "page"))
        }
        pdf.beginPage(mediaBox: &box)
        pdf.draw(image, in: box)
        pdf.endPage()
        pdf.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// `position`: "bottomCenter", "bottomRight", "topRight". `skipFirst` leaves the cover unnumbered (numbering starts on page 2 at `start`).
    public static func pageNumbers(_ input: URL, position: String, start: Int, skipFirst: Bool, output: URL) throws {
        guard ["bottomCenter", "bottomRight", "topRight"].contains(position) else { throw KumquatError.noResult(String(localized: "Pick where the numbers go.")) }
        try redraw(input, output: output) { context, size, index in
            if skipFirst, index == 0 { return }
            let number = start + index - (skipFirst ? 1 : 0)
            let short = min(size.width, size.height)
            let fontSize = min(max(short / 55, 8), 14)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1),
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let margin = short * 0.05
            let x = position == "bottomCenter" ? (size.width - width) / 2 : size.width - margin - width
            let y = position == "topRight" ? size.height - margin - fontSize : margin
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
    }

    /// Burns form fields and annotations into the page content.
    public static func flatten(_ input: URL, output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        // Links have nothing to burn in.
        let annotated = (0..<document.pageCount).contains { index in
            document.page(at: index)?.annotations.contains { $0.type != "Link" } == true
        }
        guard annotated else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no form fields or annotations to flatten.")) }
        guard document.write(to: output, withOptions: [.burnInAnnotationsOption: true]) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }

    /// `layout`: "2" or "4" pages per landscape/portrait A4 sheet, or "booklet" (2-up in saddle-stitch order).
    public static func nUp(_ input: URL, layout: String, output: URL) throws {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        let count = document.numberOfPages
        // The paper of the user's region (A4, or Letter in the Americas).
        let portrait = DocumentEngine.defaultPaperSize
        let landscape = CGSize(width: portrait.height, height: portrait.width)
        let sheet: CGSize, columns: Int, rows: Int
        let sides: [[Int?]]
        switch layout {
        case "2":
            (sheet, columns, rows) = (landscape, 2, 1)
            sides = stride(from: 0, to: count, by: 2).map { first in [first, first + 1 < count ? first + 1 : nil] }
        case "4":
            (sheet, columns, rows) = (portrait, 2, 2)
            sides = stride(from: 0, to: count, by: 4).map { first in (first..<first + 4).map { $0 < count ? $0 : nil } }
        case "booklet":
            // Folded sheets, printed on both sides: sheet n carries pages (last − 2n, 1 + 2n) on the
            // front and (2 + 2n, last − 1 − 2n) on the back, padded with blanks to a multiple of four.
            (sheet, columns, rows) = (landscape, 2, 1)
            let padded = (count + 3) / 4 * 4
            var order: [[Int]] = []
            for n in 0..<padded / 4 {
                order.append([padded - 1 - 2 * n, 2 * n])
                order.append([2 * n + 1, padded - 2 - 2 * n])
            }
            sides = order.map { side in side.map { $0 < count ? $0 : nil } }
        default:
            throw KumquatError.noResult(String(localized: "Pick a layout."))
        }
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        let gap: CGFloat = 18
        let cellWidth = (sheet.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (sheet.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for side in sides {
            var box = CGRect(origin: .zero, size: sheet)
            context.beginPage(mediaBox: &box)
            for (slot, index) in side.enumerated() {
                guard let index, let page = document.page(at: index + 1) else { continue }
                let column = slot % columns, row = slot / columns
                let cell = CGRect(x: gap + CGFloat(column) * (cellWidth + gap), y: sheet.height - CGFloat(row + 1) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
                let size = uprightSize(page)
                let scale = min(cell.width / size.width, cell.height / size.height)
                context.saveGState()
                context.translateBy(x: cell.midX - size.width * scale / 2, y: cell.midY - size.height * scale / 2)
                context.scaleBy(x: scale, y: scale)
                context.clip(to: CGRect(origin: .zero, size: size))
                drawUpright(page, in: context)
                context.restoreGState()
            }
            context.endPage()
        }
        context.closePDF()
    }

    /// Saves every embedded image at its original resolution; throws `noResult` when there are none.
    public static func extractImages(_ input: URL, into folder: URL, baseName: String) throws -> [URL] {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        let digits = String(document.numberOfPages).count
        var seen = Set<UnsafeRawPointer>()
        var outputs: [URL] = []
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            var streams: [CGPDFStreamRef] = []
            collectImages(resources: inheritedResources(dictionary), into: &streams, seen: &seen, depth: 0)
            var written = 0
            for stream in streams {
                try autoreleasepool {
                    guard let file = EmbeddedImage.export(stream) else { return }
                    written += 1
                    let output = try OutputNaming.reserve(in: folder, base: "\(baseName) p\(String(format: "%0\(digits)d", number))-\(written)", ext: file.ext)
                    try file.data.write(to: output)
                    outputs.append(output)
                }
            }
        }
        guard !outputs.isEmpty else { throw KumquatError.noResult(String(localized: "No images in “\(input.lastPathComponent)”.")) }
        return outputs
    }

    /// A page's resources, which may live on an ancestor in the page tree.
    static func inheritedResources(_ page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        for _ in 0..<32 {
            guard let current = node else { return nil }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { return resources }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    /// Image XObjects in `resources`, including those inside form XObjects; each image once per document.
    static func collectImages(resources: CGPDFDictionaryRef?, into streams: inout [CGPDFStreamRef], seen: inout Set<UnsafeRawPointer>, depth: Int) {
        guard let resources, depth < 8 else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        var found: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { found.append(stream) }
            return true
        }, nil)
        for stream in found where seen.insert(UnsafeRawPointer(stream.rawValue)).inserted {
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { continue }
            switch String(cString: subtype) {
            case "Image":
                streams.append(stream)
            case "Form":
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner) {
                    collectImages(resources: inner, into: &streams, seen: &seen, depth: depth + 1)
                }
            default:
                break
            }
        }
    }

    /// Converts the page content to grey. The system's "Gray Tone" Quartz filter keeps text and
    /// drawings vector; if it isn't available, every page becomes a grey picture.
    public static func grayscale(_ input: URL, output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        if let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")),
           document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) {
            return
        }
        guard let pages = CGPDFDocument(input as CFURL), pages.numberOfPages > 0,
              let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        let scale = redactionDPI / 72
        for index in 1...pages.numberOfPages {
            try autoreleasepool {
                guard let page = pages.page(at: index) else { return }
                let size = uprightSize(page)
                let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
                guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    throw KumquatError.cannotDecode(String(localized: "page \(index)"))
                }
                gray.setFillColor(CGColor(gray: 1, alpha: 1))
                gray.fill(CGRect(x: 0, y: 0, width: width, height: height))
                gray.scaleBy(x: scale, y: scale)
                drawUpright(page, in: gray)
                guard let image = gray.makeImage() else { throw KumquatError.cannotDecode(String(localized: "page \(index)")) }
                var box = CGRect(origin: .zero, size: size)
                context.beginPage(mediaBox: &box)
                context.draw(image, in: box)
                context.endPage()
            }
        }
        context.closePDF()
    }

    /// Sets the title and author, or removes them (and the rest of the document info and XMP) when `nil`.
    public static func setMetadata(_ input: URL, title: String?, author: String?, output: URL) throws {
        guard let original = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
        // PDFKit carries the original's XMP packet over on save; a fresh document doesn't. Moving the
        // pages (rather than copying them) keeps links and the outline pointing at them.
        let clean = PDFDocument()
        while original.pageCount > 0, let page = original.page(at: 0) {
            original.removePage(at: 0)
            clean.insert(page, at: clean.pageCount)
        }
        clean.outlineRoot = original.outlineRoot
        var attributes: [AnyHashable: Any] = [:]
        if let title { attributes[PDFDocumentAttribute.titleAttribute] = title }
        if let author { attributes[PDFDocumentAttribute.authorAttribute] = author }
        clean.documentAttributes = attributes
        guard clean.write(to: output) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
    }
}

/// An image XObject as a file: JPEG and JPEG 2000 streams byte for byte, everything else as PNG.
enum EmbeddedImage {
    static func export(_ stream: CGPDFStreamRef) -> (data: Data, ext: String)? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var stencil: CGPDFBoolean = 0
        // Stencil masks are shapes painted in the current colour, not pictures.
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil), stencil != 0 { return nil }
        var width = 0, height = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width >= 4, height >= 4 else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        switch format {
        case .jpegEncoded: return (data, "jpg")
        case .JPEG2000: return (data, "jp2")
        default: break
        }
        guard let image = samples(data, dictionary: dictionary, width: width, height: height) else { return nil }
        let alpha = softMask(of: dictionary, width: width, height: height)
        let picture: CGImage?
        if alpha != nil || image.colorSpace?.model == .cmyk {
            picture = flattened(image, alpha: alpha)
        } else {
            picture = image
        }
        guard let picture, let png = pngData(picture) ?? flattened(picture, alpha: nil).flatMap(pngData) else { return nil }
        return (png, "png")
    }

    /// Decoded samples as a CGImage, following the stream's colour space, bit depth and Decode array.
    static func samples(_ data: Data, dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> CGImage? {
        var bits = 8
        _ = CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object), let object, let (space, components) = colorSpace(object, depth: 0) else { return nil }
        let bytesPerRow = (width * components * bits + 7) / 8
        guard [1, 2, 4, 8, 16].contains(bits), data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        var decode: [CGFloat]?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array {
            decode = (0..<CGPDFArrayGetCount(array)).map { index in
                var value: CGPDFReal = 0
                _ = CGPDFArrayGetNumber(array, index, &value)
                return value
            }
        }
        func make(_ decode: UnsafePointer<CGFloat>?) -> CGImage? {
            CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: components * bits, bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: decode,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
        if let decode, decode.count == components * 2 { return decode.withUnsafeBufferPointer { make($0.baseAddress) } }
        return make(nil)
    }

    /// Colour space and samples per pixel; `nil` for spaces without a faithful CoreGraphics match (Lab, spot colours).
    static func colorSpace(_ object: CGPDFObjectRef, depth: Int) -> (CGColorSpace, Int)? {
        guard depth < 4 else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return device(String(cString: name)) }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) >= 1 else { return nil }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "ICCBased":
            var profile: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &profile), let profile else { return nil }
            var count = 0
            if let info = CGPDFStreamGetDictionary(profile) { _ = CGPDFDictionaryGetInteger(info, "N", &count) }
            var format = CGPDFDataFormat.raw
            if let icc = CGPDFStreamCopyData(profile, &format), let space = CGColorSpace(iccData: icc), count == 0 || space.numberOfComponents == count {
                return (space, space.numberOfComponents)
            }
            return device(count == 1 ? "DeviceGray" : count == 4 ? "DeviceCMYK" : "DeviceRGB")
        case "Indexed", "I":
            guard CGPDFArrayGetCount(array) >= 4 else { return nil }
            var baseObject: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, 1, &baseObject), let baseObject, let (base, baseComponents) = colorSpace(baseObject, depth: depth + 1) else { return nil }
            var high = 0
            guard CGPDFArrayGetInteger(array, 2, &high), (0...255).contains(high) else { return nil }
            var table = Data()
            var string: CGPDFStringRef?
            var tableStream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            } else if CGPDFArrayGetStream(array, 3, &tableStream), let tableStream {
                var format = CGPDFDataFormat.raw
                table = (CGPDFStreamCopyData(tableStream, &format) as Data?) ?? Data()
            }
            guard table.count >= (high + 1) * baseComponents else { return nil }
            let space = table.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt8.self).baseAddress.flatMap { CGColorSpace(indexedBaseSpace: base, last: high, colorTable: $0) }
            }
            return space.map { ($0, 1) }
        case "CalRGB": return device("DeviceRGB")
        case "CalGray": return device("DeviceGray")
        default: return device(String(cString: family))
        }
    }

    static func device(_ name: String) -> (CGColorSpace, Int)? {
        switch name {
        case "DeviceRGB", "RGB": (CGColorSpace(name: CGColorSpace.sRGB)!, 3)
        case "DeviceGray", "G": (CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, 1)
        case "DeviceCMYK", "CMYK": (CGColorSpaceCreateDeviceCMYK(), 4)
        default: nil
        }
    }

    /// The 8-bit soft mask (transparency) of the image, when it has one of the same size.
    static func softMask(of dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> Data? {
        var mask: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "SMask", &mask), let mask, let info = CGPDFStreamGetDictionary(mask) else { return nil }
        var maskWidth = 0, maskHeight = 0, bits = 8
        _ = CGPDFDictionaryGetInteger(info, "Width", &maskWidth)
        _ = CGPDFDictionaryGetInteger(info, "Height", &maskHeight)
        _ = CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits)
        var format = CGPDFDataFormat.raw
        guard maskWidth == width, maskHeight == height, bits == 8, let data = CGPDFStreamCopyData(mask, &format) as Data?,
              format == .raw, data.count >= width * height else { return nil }
        return data
    }

    /// Redrawn as sRGB with optional alpha: CMYK has no place in a PNG, and the soft mask becomes transparency.
    static func flattened(_ image: CGImage, alpha: Data?) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let alpha {
            // Both run top row first in memory.
            alpha.withUnsafeBytes { raw in
                let mask = raw.bindMemory(to: UInt8.self)
                for i in 0..<(width * height) {
                    let a = UInt16(mask[i])
                    for c in 0..<3 { pixels[i * 4 + c] = UInt8(UInt16(pixels[i * 4 + c]) * a / 255) }
                    pixels[i * 4 + 3] = UInt8(a)
                }
            }
        }
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
