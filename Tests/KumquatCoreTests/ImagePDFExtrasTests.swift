import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import KumquatCore

/// Runs without recording failures, for the cases that are meant to fail.
private func attempt(_ operation: KumquatCore.Operation, _ inputs: [URL], _ parameters: [String: String] = [:]) async throws -> JobOutcome {
    let out = try Fixtures.tempDirectory()
    return await Executor.run(JobRequest(operation: operation, inputs: inputs, parameters: parameters, destination: { _ in out })) { _ in }
}

private enum Extras {
    static func png(_ dir: URL, _ name: String = "shot.png", width: Int = 200, height: Int = 100, alpha: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Fixtures.write(Fixtures.makeImage(width: width, height: height, alpha: alpha), to: url, type: .png)
        return url
    }

    static func jpeg(_ dir: URL, _ name: String = "photo.jpg", gps: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "kq"]]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.46, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 9.19, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        try Fixtures.write(Fixtures.makeImage(width: 400, height: 300), to: url, type: .jpeg, properties: properties)
        return url
    }

    static func properties(_ url: URL, index: Int = 0) -> [CFString: Any] {
        ImageProbe.source(url).flatMap { CGImageSourceCopyPropertiesAtIndex($0, index, nil) as? [CFString: Any] } ?? [:]
    }

    static func widths(_ url: URL) -> Set<Int> {
        guard let source = ImageProbe.source(url) else { return [] }
        return Set((0..<CGImageSourceGetCount(source)).compactMap { (properties(url, index: $0)[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue })
    }

    /// RGBA of a pixel, `y` from the top.
    static func pixel(_ url: URL, x: Int, y: Int) -> [Int] {
        guard let image = try? ImageEngine.decode(url, maxPixelSize: nil) else { return [] }
        return pixel(image, x: x, y: y)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[i + $0]) }
    }

    /// One PDF page per entry; each line's cells ("|"-separated) are drawn in columns 200 pt apart.
    static func textPDF(_ url: URL, pages: [[String]], color: CGColor? = nil) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Extras", kCGPDFContextAuthor: "Tester"] as CFDictionary)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            if let color {
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: 0, width: 595, height: 300))
            }
            for (row, line) in lines.enumerated() {
                for (column, cell) in line.split(separator: "|").enumerated() {
                    let text = NSAttributedString(string: String(cell), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                    context.textPosition = CGPoint(x: 72 + CGFloat(column) * 200, y: 760 - CGFloat(row) * 30)
                    CTLineDraw(CTLineCreateWithAttributedString(text), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func pageText(_ url: URL, _ index: Int) -> String { PDFDocument(url: url)?.page(at: index)?.string ?? "" }

    /// Minimal camera RAW: a LinearRaw DNG (16-bit RGB, uncompressed), warm orange with a dark green square.
    static func dng(width: Int, height: Int) -> Data {
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func shorts(_ values: [UInt16]) -> Data { values.reduce(into: Data()) { $0 += le16($1) } }
        func ascii(_ text: String) -> Data { Data(text.utf8) + Data([0]) }
        func rationals(_ values: [Double], signed: Bool) -> Data {
            values.reduce(into: Data()) { data, value in
                let numerator = Int32((value * 10000).rounded())
                data += le32(signed ? UInt32(bitPattern: numerator) : UInt32(numerator)) + le32(10000)
            }
        }
        var pixels = Data(capacity: width * height * 6)
        for y in 0..<height {
            for x in 0..<width {
                let inside = (width / 4..<width * 3 / 4).contains(x) && (height / 4..<height * 3 / 4).contains(y)
                pixels += shorts((inside ? [0.02, 0.15, 0.04] : [0.9, 0.35, 0.02]).map { UInt16($0 * 65535) })
            }
        }
        // XYZ → linear sRGB, so the "camera" sees sRGB primaries under D65.
        let colorMatrix = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, payload: Data)] = [
            (254, 4, 1, le32(0)), (256, 4, 1, le32(UInt32(width))), (257, 4, 1, le32(UInt32(height))),
            (258, 3, 3, shorts([16, 16, 16])), (259, 3, 1, shorts([1])), (262, 3, 1, shorts([34892])),
            (271, 2, 8, ascii("Kumquat")), (272, 2, 5, ascii("Test")), (273, 4, 1, le32(0)),
            (274, 3, 1, shorts([1])), (277, 3, 1, shorts([3])), (278, 4, 1, le32(UInt32(height))),
            (279, 4, 1, le32(UInt32(pixels.count))), (284, 3, 1, shorts([1])),
            (50706, 1, 4, Data([1, 4, 0, 0])), (50707, 1, 4, Data([1, 1, 0, 0])), (50708, 2, 13, ascii("Kumquat Test")),
            (50717, 4, 1, le32(65535)), (50721, 10, 9, rationals(colorMatrix, signed: true)),
            (50728, 5, 3, rationals([1, 1, 1], signed: false)), (50778, 3, 1, shorts([21])),
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        let extraSize = entries.reduce(0) { $0 + ($1.payload.count > 4 ? ($1.payload.count + 1) / 2 * 2 : 0) }
        entries[8].payload = le32(UInt32(8 + ifdSize + extraSize))  // StripOffsets: right after the values
        var table = le16(UInt16(entries.count)), extra = Data()
        for entry in entries {
            table += le16(entry.tag) + le16(entry.type) + le32(entry.count)
            if entry.payload.count <= 4 {
                table += entry.payload + Data(count: 4 - entry.payload.count)
            } else {
                table += le32(UInt32(8 + ifdSize + extra.count))
                extra += entry.payload + Data(count: entry.payload.count % 2)
            }
        }
        table += le32(0)
        return Data("II".utf8) + le16(42) + le32(8) + table + extra + pixels
    }

    /// `Fixtures.makeImage` colours in sRGB (they're given in generic RGB).
    static let orange = [255, 169, 31], green = [27, 119, 66]

    /// "#RRGGBB" within a few levels of `rgb`.
    static func close(_ hex: String, to rgb: [Int], tolerance: Int = 12) -> Bool {
        guard let value = Int(hex.dropFirst(), radix: 16) else { return false }
        let channels = [value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]
        return zip(channels, rgb).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// A white sheet with printed lines, turned a little, on a dark desk.
    static func documentPhoto(_ dir: URL) throws -> URL {
        let width = 1600, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.18, green: 0.15, blue: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 800, y: 600)
        context.rotate(by: 0.08)
        let sheet = CGRect(x: -380, y: -500, width: 760, height: 1000)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(sheet)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for row in 0..<14 { context.fill(CGRect(x: -320, y: 400 - CGFloat(row) * 60, width: row % 3 == 2 ? 380 : 640, height: 16)) }
        let url = dir.appendingPathComponent("desk.jpg")
        try Fixtures.write(context.makeImage()!, to: url, type: .jpeg)
        return url
    }

    /// Black scribble on transparent, like a drawn signature.
    static func signature(_ dir: URL) throws -> URL {
        let context = CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(18)
        context.move(to: CGPoint(x: 20, y: 100))
        context.addCurve(to: CGPoint(x: 580, y: 100), control1: CGPoint(x: 200, y: 260), control2: CGPoint(x: 400, y: -60))
        context.strokePath()
        let url = dir.appendingPathComponent("signature.png")
        try Fixtures.write(context.makeImage()!, to: url, type: .png)
        return url
    }

    /// Darkness of a page region (0 white … 1 black) after rendering, `rect` normalised with a top-left origin.
    static func ink(_ pdf: URL, page: Int, in rect: CGRect) -> Double {
        guard let document = CGPDFDocument(pdf as CFURL), let page = document.page(at: page + 1),
              let image = PDFEngine.render(page, scale: 2) else { return 0 }
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let x0 = Int(rect.minX * CGFloat(image.width)), x1 = Int(rect.maxX * CGFloat(image.width))
        let y0 = Int(rect.minY * CGFloat(image.height)), y1 = Int(rect.maxY * CGFloat(image.height))
        var total = 0.0, count = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * image.width + x) * 4
                total += 1 - Double(Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 765
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }
}

@Suite struct ImageConversionExtrasTests {
    @Test(arguments: [FileFormat.gif, .jp2, .jxl])
    func jpgConvertsToRasterTargets(target: FileFormat) async throws {
        if target == .jxl, Engines.cjxl == nil { return }
        let dir = try Fixtures.tempDirectory()
        let output = try #require(try await run(.convert(target), [try Extras.jpeg(dir)]).outputs.first)
        #expect(output.lastPathComponent == "photo.\(target.fileExtension)")
        #expect(ImageProbe.orientedPixelSize(output) == CGSize(width: 400, height: 300))
    }

    @Test func pngWithAlphaGoesToJXLThroughCjxl() async throws {
        if Engines.cjxl == nil { return }
        let dir = try Fixtures.tempDirectory()
        let jxl = try #require(try await run(.convert(.jxl), [try Extras.png(dir, alpha: true)]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(jxl) == CGSize(width: 200, height: 100))
        // And back: ImageIO decodes JPEG XL, tools write PNG for it.
        let png = try #require(try await run(.convert(.png), [jxl]).outputs.first)
        #expect(Extras.pixel(png, x: 2, y: 2)[3] == 0)
        #expect(ImageEngine.toolOutputFormat(for: .jxl, tool: .resize) == .png)
    }

    @Test func icoHoldsEveryWindowsSize() async throws {
        let dir = try Fixtures.tempDirectory()
        let ico = try #require(try await run(.convert(.ico), [try Extras.png(dir, width: 300, height: 120)]).outputs.first)
        #expect(Extras.widths(ico) == [16, 32, 48, 256])
        // Padded to a square, not stretched: the corners stay transparent.
        let source = try #require(ImageProbe.source(ico))
        let largest = try ImageEngine.decode(source, index: ImageProbe.primaryIndex(source), maxPixelSize: nil)
        #expect(largest.width == 256 && largest.height == 256)
        #expect(Extras.pixel(largest, x: 128, y: 2)[3] == 0)
        // Reading an icon picks its largest picture.
        #expect(ImageProbe.orientedPixelSize(ico) == CGSize(width: 256, height: 256))
        let png = try #require(try await run(.convert(.png), [ico]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(png) == CGSize(width: 256, height: 256))
    }

    @Test func icnsHoldsEveryMacSize() async throws {
        let dir = try Fixtures.tempDirectory()
        let icns = try #require(try await run(.convert(.icns), [try Extras.jpeg(dir)]).outputs.first)
        let source = try #require(ImageProbe.source(icns))
        #expect(CGImageSourceGetCount(source) == 10)
        #expect(Extras.widths(icns) == [16, 32, 64, 128, 256, 512, 1024])
    }

    @Test func logoTracesToSVG() async throws {
        if Engines.potrace == nil { return }
        let dir = try Fixtures.tempDirectory()
        // Green disc on orange: Otsu puts the darker green on the ink side.
        let svg = try #require(try await run(.convert(.svg), [try Extras.png(dir, width: 300, height: 200)]).outputs.first)
        let text = try String(contentsOf: svg, encoding: .utf8)
        #expect(text.contains("<svg") && text.contains("<path"))
        // Filled with the disc's green.
        let fill = try #require(text.firstMatch(of: /fill="(#[0-9A-Fa-f]{6})"/)).1
        #expect(Extras.close(String(fill), to: Extras.green))
        // Same size as the source, in points.
        let image = try #require(NSImage(contentsOf: svg))
        #expect(abs(image.size.width - 300) < 2 && abs(image.size.height - 200) < 2)

        let blank = dir.appendingPathComponent("blank.png")
        let context = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try Fixtures.write(context.makeImage()!, to: blank, type: .png)
        let failed = try await attempt(.convert(.svg), [blank])
        #expect(failed.failures.first?.message == "Nothing to trace in “blank.png”.")
    }

    @Test(arguments: [("tga", "com.truevision.tga-image"), ("psd", "com.adobe.photoshop-image"), ("exr", "com.ilm.openexr-image")])
    func readOnlyFormatsConvertAndToolsWritePNG(ext: String, identifier: String) async throws {
        let dir = try Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("art.\(ext)")
        try Fixtures.write(Fixtures.makeImage(width: 120, height: 80), to: url, type: UTType(identifier)!)
        let jpg = try #require(try await run(.convert(.jpg), [url]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(jpg) == CGSize(width: 120, height: 80))
        let resized = try #require(try await run(.tool(.resize), [url], ["percent": "50"]).outputs.first)
        #expect(resized.lastPathComponent == "art (50%).png")
        #expect(ImageProbe.orientedPixelSize(resized) == CGSize(width: 60, height: 40))
    }

    @Test func cameraRawDevelopsToJPEG() async throws {
        let dir = try Fixtures.tempDirectory()
        let raw = dir.appendingPathComponent("IMG_0001.dng")
        try Extras.dng(width: 320, height: 240).write(to: raw)
        let jpg = try #require(try await run(.convert(.jpg), [raw]).outputs.first)
        #expect(jpg.lastPathComponent == "IMG_0001.jpg")
        #expect(ImageProbe.orientedPixelSize(jpg) == CGSize(width: 320, height: 240))
        let corner = Extras.pixel(jpg, x: 5, y: 5), centre = Extras.pixel(jpg, x: 160, y: 120)
        #expect(corner[0] > corner[2] + 60)  // warm background
        #expect(centre[1] > centre[0] && centre[1] > centre[2])  // green square
        // Tools on RAW write JPEG; resizing develops at the smaller size directly.
        let resized = try #require(try await run(.tool(.resize), [raw], ["percent": "50"]).outputs.first)
        #expect(resized.lastPathComponent == "IMG_0001 (50%).jpg")
        #expect(ImageProbe.orientedPixelSize(resized) == CGSize(width: 160, height: 120))
        let mono = try #require(try await run(.tool(.filter), [raw], ["style": "mono"]).outputs.first)
        #expect(mono.lastPathComponent == "IMG_0001 (mono).jpg")
        if Engines.cwebp != nil {
            let webp = try #require(try await run(.convert(.webp), [raw]).outputs.first)
            #expect(ImageProbe.orientedPixelSize(webp) == CGSize(width: 320, height: 240))
        }
    }

    @Test func toolOutputFormats() {
        #expect(ImageEngine.toolOutputFormat(for: .cr3, tool: .crop) == .jpg)
        #expect(ImageEngine.toolOutputFormat(for: .dng, tool: .removeBackground) == .png)
        for format in [FileFormat.psd, .tga, .exr, .svg, .ico, .icns, .jxl] {
            #expect(ImageEngine.toolOutputFormat(for: format, tool: .filter) == .png)
        }
        #expect(ImageEngine.toolOutputFormat(for: .jp2, tool: .filter) == .jp2)
        #expect(ImageEngine.toolOutputFormat(for: .heic, tool: .watermark) == .heic)
    }
}

@Suite struct ImageToolExtrasTests {
    @Test func mergeLayouts() async throws {
        let dir = try Fixtures.tempDirectory()
        let a = try Extras.png(dir, "a.png"), b = try Extras.png(dir, "b.png")
        let pdf = try #require(try await run(.tool(.merge), [a, b], ["layout": "pdf"]).outputs.first)
        #expect(PDFEngine.pageCount(of: pdf) == 2)
        let strip = try #require(try await run(.tool(.merge), [a, b], ["layout": "vertical"]).outputs.first)
        #expect(strip.lastPathComponent == "Merged.png")
        #expect(ImageProbe.orientedPixelSize(strip) == CGSize(width: 200, height: 200))
        let grid = try #require(try await run(.tool(.merge), [a, b], ["layout": "grid"]).outputs.first)
        let gridSize = ImageProbe.orientedPixelSize(grid)
        #expect(gridSize.width > 400 && gridSize.height > 100 && gridSize.height < 200)
        let gif = try #require(try await run(.tool(.merge), [a, b], ["layout": "gif"]).outputs.first)
        let frames = try #require(ImageProbe.source(gif))
        #expect(CGImageSourceGetCount(frames) == 2)
        let delay = (Extras.properties(gif, index: 1)[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double
        #expect(delay == 1)
    }

    @Test func scanDocumentStraightensTheSheet() async throws {
        let dir = try Fixtures.tempDirectory()
        let photo = try Extras.documentPhoto(dir)
        let scan = try #require(try await run(.tool(.scanDocument), [photo], ["look": "bw"]).outputs.first)
        #expect(scan.lastPathComponent == "desk (scanned).jpg")
        let size = ImageProbe.orientedPixelSize(scan)
        // The sheet is 760×1000: portrait, about that shape, and none of the desk left.
        #expect(abs(size.width / size.height - 0.76) < 0.08)
        #expect(size.width < 1000 && size.height < 1150)
        let corner = Extras.pixel(scan, x: 8, y: 8)
        #expect(corner[0] > 200)

        let nothing = try await attempt(.tool(.scanDocument), [try Extras.png(dir, width: 64, height: 64)])
        #expect(nothing.failures.first?.message == "No document found in “shot.png”.")
    }

    @Test func blurDrawnAreaAndFaces() async throws {
        let dir = try Fixtures.tempDirectory()
        let png = try Extras.png(dir)
        let boxed = try #require(try await run(.tool(.blurFaces), [png], ["mode": "area", "style": "black", "region": "0:0:0.5:0.5"]).outputs.first)
        #expect(boxed.lastPathComponent == "shot (blurred).png")
        #expect(Array(Extras.pixel(boxed, x: 10, y: 10).prefix(3)) == [0, 0, 0])
        #expect(Extras.pixel(boxed, x: 190, y: 90)[0] > 200)  // the orange corner is untouched
        let pixelated = try #require(try await run(.tool(.blurFaces), [png], ["mode": "area", "style": "pixelate", "region": "0.25:0.25:0.5:0.5"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(pixelated) == CGSize(width: 200, height: 100))
        let blurred = try #require(try await run(.tool(.blurFaces), [png], ["mode": "area", "style": "blur", "region": "0.25:0.25:0.5:0.5"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(blurred) == CGSize(width: 200, height: 100))

        let noFaces = try await attempt(.tool(.blurFaces), [png], ["mode": "faces"])
        #expect(noFaces.failures.first?.message == "No faces found in “shot.png”.")
    }

    @Test func frameAddsMarginAndBackground() async throws {
        let dir = try Fixtures.tempDirectory()
        let png = try Extras.png(dir)
        let framed = try #require(try await run(.tool(.frame), [png], ["background": "ocean", "padding": "10", "radius": "4"]).outputs.first)
        #expect(framed.lastPathComponent == "shot (framed).png")
        #expect(ImageProbe.orientedPixelSize(framed) == CGSize(width: 240, height: 140))
        #expect(Extras.pixel(framed, x: 1, y: 1)[3] == 255)
        let clear = try #require(try await run(.tool(.frame), [png], ["background": "clear", "padding": "10", "shadow": "no"]).outputs.first)
        #expect(Extras.pixel(clear, x: 1, y: 1)[3] == 0)
        #expect(Extras.pixel(clear, x: 120, y: 70)[3] == 255)
    }

    @Test func enhanceAndFilters() async throws {
        let dir = try Fixtures.tempDirectory()
        let photo = try Extras.jpeg(dir)
        let enhanced = try await attempt(.tool(.enhance), [photo])
        if let failure = enhanced.failures.first {
            #expect(failure.message.contains("already looks its best"))
        } else {
            #expect(enhanced.outputs.first?.lastPathComponent == "photo (enhanced).jpg")
        }
        for style in ["noir", "mono", "sepia", "vivid", "fade", "instant"] {
            let output = try #require(try await run(.tool(.filter), [photo], ["style": style]).outputs.first)
            #expect(output.lastPathComponent == "photo (\(style)).jpg")
            #expect(ImageProbe.orientedPixelSize(output) == CGSize(width: 400, height: 300))
            #expect((Extras.properties(output)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String == "kq")
        }
        let noir = try #require(try await run(.tool(.filter), [photo], ["style": "noir"]).outputs.first)
        let gray = Extras.pixel(noir, x: 20, y: 20)
        #expect(abs(gray[0] - gray[1]) < 6 && abs(gray[1] - gray[2]) < 6)
    }

    @Test func paletteFindsTheMainColors() async throws {
        let dir = try Fixtures.tempDirectory()
        let outcome = try await run(.tool(.palette), [try Extras.png(dir, width: 300, height: 300)], ["count": "4"])
        let swatch = try #require(outcome.outputs.first)
        let colors = try #require(outcome.clipboardText).split(separator: " ").map(String.init)
        // Orange background first (three quarters of the picture), then the green disc.
        #expect(colors.first.map { Extras.close($0, to: Extras.orange) } == true)
        #expect(colors.contains { Extras.close($0, to: Extras.green) })
        #expect(colors.allSatisfy { $0.wholeMatch(of: /#[0-9A-F]{6}/) != nil })
        #expect(ImageProbe.orientedPixelSize(swatch) == CGSize(width: 240 * colors.count, height: 240))
    }

    @Test func iconSetForMacAndWeb() async throws {
        let dir = try Fixtures.tempDirectory()
        let outputs = try await run(.tool(.iconSet), [try Extras.png(dir, width: 300, height: 200)], ["kind": "all"]).outputs
        #expect(outputs.map(\.lastPathComponent) == ["AppIcon.icns", "AppIcon.iconset", "favicon.ico", "apple-touch-icon.png", "icon-192.png", "icon-512.png"])
        #expect(outputs.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "shot icons" })
        let iconset = try FileManager.default.contentsOfDirectory(atPath: outputs[1].path)
        #expect(iconset.count == 10 && iconset.contains("icon_512x512@2x.png"))
        #expect(ImageProbe.orientedPixelSize(outputs[1].appendingPathComponent("icon_512x512@2x.png")) == CGSize(width: 1024, height: 1024))
        #expect(Extras.widths(outputs[2]) == [16, 32, 48])
        #expect(ImageProbe.orientedPixelSize(outputs[3]) == CGSize(width: 180, height: 180))
        #expect(Extras.pixel(outputs[3], x: 90, y: 2) == [255, 255, 255, 255])  // opaque on white
        #expect(ImageProbe.orientedPixelSize(outputs[5]) == CGSize(width: 512, height: 512))

        let web = try await run(.tool(.iconSet), [try Extras.png(dir, "web.png")], ["kind": "web"]).outputs
        #expect(web.count == 4)
    }

    @Test func autoTagAddsFinderTagsKeepingExistingOnes() async throws {
        let dir = try Fixtures.tempDirectory()
        let photo = try Extras.documentPhoto(dir)
        try (photo as NSURL).setResourceValue(["Kumquat"], forKey: .tagNamesKey)
        let outcome = try await attempt(.tool(.autoTag), [photo])
        let tags = (try photo.resourceValues(forKeys: [.tagNamesKey])).tagNames ?? []
        #expect(tags.first == "Kumquat")
        if let text = outcome.clipboardText {
            let labels = text.components(separatedBy: ", ")
            #expect(!labels.isEmpty && labels.count <= 5)
            #expect(labels.allSatisfy { tags.contains($0) && !$0.contains("_") })
        } else {
            #expect(outcome.failures.first?.message.hasPrefix("Nothing recognisable") == true)
        }
    }

    @Test func watermarkDrawsOverThePicture() async throws {
        let dir = try Fixtures.tempDirectory()
        let png = try Extras.png(dir, width: 400, height: 400)
        let marked = try #require(try await run(.tool(.watermark), [png], ["text": "KUMQUAT", "opacity": "80", "angle": "horizontal"]).outputs.first)
        #expect(marked.lastPathComponent == "shot (watermarked).png")
        // Somewhere along the middle row the grey text replaced the green disc.
        let changed = stride(from: 40, to: 360, by: 4).contains { x in Extras.pixel(marked, x: x, y: 200) != Extras.pixel(png, x: x, y: 200) }
        #expect(changed)
    }

    @Test func stripLocationKeepsTheRest() async throws {
        let dir = try Fixtures.tempDirectory()
        let photo = try Extras.jpeg(dir, gps: true)
        #expect(Extras.properties(photo)[kCGImagePropertyGPSDictionary] != nil)
        let clean = try #require(try await run(.tool(.stripMetadata), [photo], ["what": "location"]).outputs.first)
        #expect(clean.lastPathComponent == "photo (no location).jpg")
        let properties = Extras.properties(clean)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String == "kq")
        // Lossless: the compressed picture is copied as is.
        let before = try ImageEngine.decode(photo, maxPixelSize: nil), after = try ImageEngine.decode(clean, maxPixelSize: nil)
        #expect(before.dataProvider?.data == after.dataProvider?.data)

        let png = dir.appendingPathComponent("map.png")
        try Fixtures.write(Fixtures.makeImage(width: 50, height: 50), to: png, type: .png, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        if Extras.properties(png)[kCGImagePropertyGPSDictionary] != nil {
            let cleanPNG = try #require(try await run(.tool(.stripMetadata), [png], ["what": "location"]).outputs.first)
            #expect(Extras.properties(cleanPNG)[kCGImagePropertyGPSDictionary] == nil)
        }

        let none = try await attempt(.tool(.stripMetadata), [try Extras.jpeg(dir, "plain.jpg")], ["what": "location"])
        #expect(none.failures.first?.message == "“plain.jpg” has no location data.")
    }
}

@Suite struct PDFConversionExtrasTests {
    func pdf(_ dir: URL, pages: Int = 3) -> URL {
        let url = dir.appendingPathComponent("doc.pdf")
        Fixtures.makePDF(pages: pages, to: url)
        return url
    }

    @Test func tiffKeepsEveryPage() async throws {
        let dir = try Fixtures.tempDirectory()
        let tiff = try #require(try await run(.convert(.tiff), [pdf(dir)]).outputs.first)
        #expect(tiff.lastPathComponent == "doc.tiff")
        let source = try #require(ImageProbe.source(tiff))
        #expect(CGImageSourceGetCount(source) == 3)
        let width = (Extras.properties(tiff)[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        #expect(abs(width - Int(595 * PDFEngine.tiffDPI / 72)) <= 1)
    }

    @Test(arguments: [FileFormat.html, .rtf, .odt])
    func textFormats(target: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let output = try #require(try await run(.convert(target), [pdf(dir)]).outputs.first)
        #expect(output.lastPathComponent == "doc.\(target.fileExtension)")
        let text: String
        switch target {
        case .html: text = try String(contentsOf: output, encoding: .utf8)
        case .rtf: text = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        default: text = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
        }
        #expect(text.contains("Page 2 citrus"))
    }

    @Test func csvFromTableRows() async throws {
        let dir = try Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("table.pdf")
        Extras.textPDF(url, pages: [["Fruit|Price", "Kumquat|3"], ["Lime|2"]])
        let csv = try #require(try await run(.convert(.csv), [url]).outputs.first)
        let rows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(rows == ["Fruit,Price", "Kumquat,3", "Lime,2"])
    }

    @Test func pagesBecomeHEICAndWebP() async throws {
        let dir = try Fixtures.tempDirectory()
        let heic = try await run(.convert(.heic), [pdf(dir, pages: 2)]).outputs
        #expect(heic.map(\.lastPathComponent) == ["doc p1.heic", "doc p2.heic"])
        #expect(ImageProbe.orientedPixelSize(heic[0]).width > 2000)
        if Engines.cwebp == nil { return }
        let webp = try await run(.convert(.webp), [pdf(dir, pages: 2)]).outputs
        #expect(webp.map(\.lastPathComponent) == ["doc p1.webp", "doc p2.webp"])
        #expect(webp.allSatisfy { size($0) > 0 && ImageProbe.orientedPixelSize($0).width > 2000 })
        let single = try #require(try await run(.convert(.webp), [pdf(dir, pages: 1)]).outputs.first)
        #expect(single.lastPathComponent == "doc.webp")
    }
}

@Suite struct PDFToolExtrasTests {
    func pdf(_ dir: URL, pages: Int = 3) -> URL {
        let url = dir.appendingPathComponent("doc.pdf")
        Fixtures.makePDF(pages: pages, to: url)
        return url
    }

    @Test func reorderMovesTurnsAndDrops() async throws {
        let dir = try Fixtures.tempDirectory()
        let output = try #require(try await run(.tool(.reorderPages), [pdf(dir)], ["order": "3, 1r90"]).outputs.first)
        #expect(output.lastPathComponent == "doc (rearranged).pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("Page 3") == true)
        #expect(document.page(at: 1)?.rotation == 90)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Kumquat Test")
        let wrong = try await attempt(.tool(.reorderPages), [pdf(dir)], ["order": "1,7"])
        #expect(wrong.failures.first?.message == "“1,7” isn't a valid page order for this 3-page PDF.")
    }

    @Test func signLandsOnTheChosenPage() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = pdf(dir, pages: 2)
        let signature = try Extras.signature(dir)
        let signed = try #require(try await run(.tool(.sign), [source], ["signature": signature.path, "page": "last"]).outputs.first)
        #expect(signed.lastPathComponent == "doc (signed).pdf")
        #expect(PDFEngine.pageCount(of: signed) == 2)
        let corner = CGRect(x: 0.6, y: 0.8, width: 0.35, height: 0.15)
        #expect(Extras.ink(signed, page: 1, in: corner) > 0.01)
        #expect(Extras.ink(signed, page: 0, in: corner) < 0.005)
        // A drawn area on page 1, top left.
        let placed = try #require(try await run(.tool(.sign), [source], ["signature": signature.path, "page": "1", "region": "0.05:0.02:0.4:0.1"]).outputs.first)
        #expect(Extras.ink(placed, page: 0, in: CGRect(x: 0.05, y: 0.02, width: 0.4, height: 0.1)) > 0.01)
        let missing = try await attempt(.tool(.sign), [source], ["signature": signature.path, "page": "9"])
        #expect(missing.failures.first?.message == "Page “9” isn't in this 2-page PDF.")
    }

    @Test func redactRemovesTheText() async throws {
        let dir = try Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("letter.pdf")
        Extras.textPDF(url, pages: [["Write to mario.rossi@example.com", "IBAN IT60 X054 2811 1010 0000 0123 456", "Call +39 333 123 4567"],
                                    ["Nothing secret here", "Kumquat season"]])
        let redacted = try #require(try await run(.tool(.redact), [url], ["find": "kumquat", "also": "all"]).outputs.first)
        #expect(redacted.lastPathComponent == "letter (redacted).pdf")
        #expect(PDFEngine.pageCount(of: redacted) == 2)
        // Both pages had a match: no text left anywhere, and black boxes where it was.
        #expect(Extras.pageText(redacted, 0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(Extras.pageText(redacted, 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(Extras.ink(redacted, page: 0, in: CGRect(x: 0.25, y: 0.083, width: 0.25, height: 0.014)) > 0.5)

        // Only the page with a match is rasterised.
        let email = try #require(try await run(.tool(.redact), [url], ["also": "email"]).outputs.first)
        #expect(Extras.pageText(email, 1).contains("Nothing secret here"))
        #expect(!Extras.pageText(email, 0).contains("example.com"))

        let none = try await attempt(.tool(.redact), [url], ["find": "banana"])
        #expect(none.failures.first?.message == "Nothing to hide in “letter.pdf”.")
    }

    @Test func redactionPatternsMatchWhatTheySay() {
        func matches(_ which: String, _ text: String) -> [String] {
            PDFEngine.redactionPatterns(which).flatMap { pattern in
                pattern.expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                    .map { (text as NSString).substring(with: $0.range) }.filter(pattern.accepts)
            }
        }
        #expect(matches("email", "write to a.b@c.it now") == ["a.b@c.it"])
        #expect(matches("iban", "IBAN DE89 3704 0044 0532 0130 00 ok").first?.hasPrefix("DE89 3704") == true)
        #expect(matches("phone", "call (555) 123-4567 today") == ["(555) 123-4567"])
        #expect(matches("phone", "on 2024-01-15 10:30 and 15/01/2024").isEmpty)
    }

    @Test func pageNumbersAndCover() async throws {
        let dir = try Fixtures.tempDirectory()
        let numbered = try #require(try await run(.tool(.pageNumbers), [pdf(dir)], ["start": "5"]).outputs.first)
        #expect(numbered.lastPathComponent == "doc (numbered).pdf")
        #expect(Extras.pageText(numbered, 0).contains("5") && Extras.pageText(numbered, 2).contains("7"))
        let covered = try #require(try await run(.tool(.pageNumbers), [pdf(dir)], ["skipFirst": "yes", "position": "topRight"]).outputs.first)
        #expect(Extras.pageText(covered, 0).trimmingCharacters(in: .whitespacesAndNewlines) == "Page 1 citrus")
        #expect(Extras.pageText(covered, 1).replacingOccurrences(of: "Page 2 citrus", with: "").contains("1"))
        // Top right, inside the margin.
        #expect(Extras.ink(covered, page: 1, in: CGRect(x: 0.9, y: 0.025, width: 0.06, height: 0.03)) > 0.004)
        #expect(Extras.ink(covered, page: 1, in: CGRect(x: 0.4, y: 0.94, width: 0.2, height: 0.04)) == 0)
    }

    @Test func flattenBurnsAnnotationsIn() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = pdf(dir, pages: 1)
        let document = try #require(PDFDocument(url: source))
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 200, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Approved"
        note.font = NSFont(name: "Helvetica", size: 18)
        note.fontColor = .black
        document.page(at: 0)?.addAnnotation(note)
        let annotated = dir.appendingPathComponent("annotated.pdf")
        #expect(document.write(to: annotated))
        let flat = try #require(try await run(.tool(.flatten), [annotated]).outputs.first)
        #expect(flat.lastPathComponent == "annotated (flattened).pdf")
        let page = try #require(PDFDocument(url: flat)?.page(at: 0))
        #expect(page.annotations.isEmpty)
        #expect(page.string?.contains("Approved") == true)
        let plain = try await attempt(.tool(.flatten), [source])
        #expect(plain.failures.first?.message == "“doc.pdf” has no form fields or annotations to flatten.")
    }

    @Test func nUpLayouts() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = pdf(dir, pages: 3)
        let two = try #require(try await run(.tool(.nUp), [source], ["layout": "2"]).outputs.first)
        #expect(two.lastPathComponent == "doc (2-up).pdf")
        let sheet = try #require(PDFDocument(url: two)?.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(PDFEngine.pageCount(of: two) == 2 && sheet.width > sheet.height)
        #expect(Extras.pageText(two, 0).contains("Page 1") && Extras.pageText(two, 0).contains("Page 2"))
        let four = try #require(try await run(.tool(.nUp), [source], ["layout": "4"]).outputs.first)
        #expect(PDFEngine.pageCount(of: four) == 1)
        let booklet = try #require(try await run(.tool(.nUp), [source], ["layout": "booklet"]).outputs.first)
        #expect(booklet.lastPathComponent == "doc (booklet).pdf")
        // Three pages pad to four: front (blank, 1), back (2, 3).
        #expect(PDFEngine.pageCount(of: booklet) == 2)
        #expect(Extras.pageText(booklet, 0).trimmingCharacters(in: .whitespacesAndNewlines) == "Page 1 citrus")
        let back = Extras.pageText(booklet, 1)
        #expect(back.contains("Page 2") && back.contains("Page 3"))
        #expect(PDFEngine.parseOrder("2r180, 1", pageCount: 2)?.map(\.turn) == [180, 0])
    }

    @Test func extractImagesAtOriginalSize() async throws {
        let dir = try Fixtures.tempDirectory()
        let photo = try Extras.jpeg(dir)
        let logo = try Extras.png(dir, "logo.png", width: 64, height: 48, alpha: true)
        let source = try #require(try await run(.tool(.merge), [photo, logo], ["layout": "pdf"]).outputs.first)
        let images = try await run(.tool(.extractImages), [source]).outputs
        #expect(images.count == 2)
        #expect(images.map(\.lastPathComponent).first?.hasPrefix("Merged p1-1.") == true)
        #expect(images.first.map(ImageProbe.orientedPixelSize) == CGSize(width: 400, height: 300))
        let png = try #require(images.last)
        #expect(ImageProbe.orientedPixelSize(png) == CGSize(width: 64, height: 48))
        #expect(Extras.pixel(png, x: 1, y: 1)[3] == 0)  // the soft mask came back as transparency
        let none = try await attempt(.tool(.extractImages), [pdf(dir, pages: 1)])
        #expect(none.failures.first?.message == "No images in “doc.pdf”.")
    }

    @Test func grayscaleKeepsTextVector() async throws {
        let dir = try Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("color.pdf")
        Extras.textPDF(url, pages: [["Orange page"]], color: CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        let gray = try #require(try await run(.tool(.grayscale), [url]).outputs.first)
        #expect(gray.lastPathComponent == "color (grayscale).pdf")
        #expect(Extras.pageText(gray, 0).contains("Orange page"))
        let page = try #require(CGPDFDocument(gray as CFURL)?.page(at: 1))
        let pixel = Extras.pixel(try #require(PDFEngine.render(page, scale: 1)), x: 100, y: 800)
        #expect(abs(pixel[0] - pixel[1]) < 4 && abs(pixel[1] - pixel[2]) < 4 && pixel[0] < 240)
    }

    @Test func metadataIsReplacedOrRemoved() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = pdf(dir, pages: 2)
        let removed = try #require(try await run(.tool(.stripMetadata), [source]).outputs.first)
        #expect(removed.lastPathComponent == "doc (clean).pdf")
        let attributes = PDFDocument(url: removed)?.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil && attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(PDFEngine.pageCount(of: removed) == 2)
        let titled = try #require(try await run(.tool(.stripMetadata), [source], ["title": "Report", "author": "Ada"]).outputs.first)
        let set = PDFDocument(url: titled)?.documentAttributes ?? [:]
        #expect(set[PDFDocumentAttribute.titleAttribute] as? String == "Report" && set[PDFDocumentAttribute.authorAttribute] as? String == "Ada")
    }
}
