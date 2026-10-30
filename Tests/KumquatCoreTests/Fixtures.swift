import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Fixtures {
    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KumquatTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeImage(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        if !alpha {
            context.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    /// Black text on white, large enough for reliable OCR.
    static func makeTextImage(_ text: String, size: CGSize = CGSize(width: 1400, height: 300)) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 60, y: size.height / 2 - 30)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func makeQRCode(_ message: String) -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = image.composited(over: CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -60, dy: -60)))
        return CIContext().createCGImage(padded, from: padded.extent)!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// PDF with real text on every page plus info-dictionary metadata.
    static func makePDF(pages: Int, to url: URL, title: String = "Kumquat Test", author: String = "Tester") {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextAuthor: author]
        let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let text = NSAttributedString(string: "Page \(index + 1) citrus", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Image-only PDF page (no text layer) to force the OCR path.
    static func makeScannedPDF(text: String, to url: URL) {
        let image = makeTextImage(text)
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }
}
