import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import KumquatCore

/// End-to-end: every test goes through `Executor`, exactly like a drop on the wheel.
func run(_ operation: KumquatCore.Operation, _ inputs: [URL], _ parameters: [String: String] = [:], into directory: URL? = nil) async throws -> JobOutcome {
    let out = try directory ?? Fixtures.tempDirectory()
    let outcome = await Executor.run(JobRequest(operation: operation, inputs: inputs, parameters: parameters, destination: { _ in out })) { _ in }
    if let failure = outcome.failures.first { Issue.record("\(failure.file): \(failure.message)") }
    return outcome
}

func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

@Suite struct ImageEngineTests {
    func photo(_ dir: URL, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent("photo.jpg")
        try Fixtures.write(Fixtures.makeImage(width: 400, height: 300), to: url, type: .jpeg,
                           properties: [kCGImagePropertyOrientation: orientation, kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "kq"]])
        return url
    }

    @Test(arguments: [FileFormat.png, .heic, .tiff, .avif, .bmp, .webp, .pdf])
    func jpgConvertsTo(target: FileFormat) async throws {
        if target == .webp, Engines.cwebp == nil { return }
        let dir = try Fixtures.tempDirectory()
        let outcome = try await run(.convert(target), [try photo(dir)])
        let output = try #require(outcome.outputs.first)
        #expect(output.lastPathComponent == "photo.\(target.fileExtension)")
        if target == .pdf {
            #expect(PDFEngine.pageCount(of: output) == 1)
        } else {
            #expect(ImageProbe.orientedPixelSize(output) == CGSize(width: 400, height: 300))
        }
    }

    @Test func svgRasterisesAndStaysVectorInPDF() async throws {
        let dir = try Fixtures.tempDirectory()
        let svg = dir.appendingPathComponent("logo.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="orange"/></svg>"#.write(to: svg, atomically: true, encoding: .utf8)
        let png = try #require(try await run(.convert(.png), [svg]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(png) == CGSize(width: 1024, height: 512))
        let pdf = try #require(try await run(.convert(.pdf), [svg]).outputs.first)
        #expect(PDFDocument(url: pdf)?.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 40, height: 20))
    }

    @Test func rotateIsLosslessForJPEG() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = try photo(dir)
        let rotated = try #require(try await run(.tool(.rotate), [source]).outputs.first)
        #expect(rotated.lastPathComponent == "photo (rotated).jpg")
        #expect(ImageProbe.orientation(rotated) == 6)
        #expect(ImageProbe.orientedPixelSize(rotated) == CGSize(width: 300, height: 400))
        // Same compressed bytes: only the orientation tag changed.
        #expect(abs(size(rotated) - size(source)) < 2048)

        let png = dir.appendingPathComponent("shot.png")
        try Fixtures.write(Fixtures.makeImage(width: 200, height: 100), to: png, type: .png)
        let flipped = try #require(try await run(.tool(.flip), [png]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(flipped) == CGSize(width: 200, height: 100))
    }

    @Test func rotateAndFlipOptions() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = try photo(dir)
        let left = try #require(try await run(.tool(.rotate), [source], ["angle": "270"]).outputs.first)
        #expect(ImageProbe.orientation(left) == 8)
        let upsideDown = try #require(try await run(.tool(.rotate), [source], ["angle": "180"]).outputs.first)
        #expect(ImageProbe.orientation(upsideDown) == 3)

        // PNG has no orientation tag: pixels are redrawn. Left half red, right half blue.
        let png = dir.appendingPathComponent("halves.png")
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        try Fixtures.write(context.makeImage()!, to: png, type: .png)
        func topLeftIsRed(_ url: URL) -> Bool {
            guard let image = ImageProbe.source(url).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
                  let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
            return bytes[0] > 200 && bytes[2] < 50
        }
        let ccw = try #require(try await run(.tool(.rotate), [png], ["angle": "270"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(ccw) == CGSize(width: 10, height: 20))
        #expect(!topLeftIsRed(ccw))  // counter-clockwise: the right (blue) half moves to the top
        let cw = try #require(try await run(.tool(.rotate), [png], ["angle": "90"]).outputs.first)
        #expect(topLeftIsRed(cw))
        let mirrored = try #require(try await run(.tool(.flip), [png], ["axis": "horizontal"]).outputs.first)
        #expect(!topLeftIsRed(mirrored))
        let vertical = try #require(try await run(.tool(.flip), [png], ["axis": "vertical"]).outputs.first)
        #expect(topLeftIsRed(vertical))
    }

    @Test func cropAndStraightenOptions() async throws {
        let dir = try Fixtures.tempDirectory()
        let png = dir.appendingPathComponent("wide.png")
        try Fixtures.write(Fixtures.makeImage(width: 400, height: 200), to: png, type: .png)
        let quarter = try #require(try await run(.tool(.crop), [png], ["aspect": "free", "region": "0.5:0:0.5:0.5"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(quarter) == CGSize(width: 200, height: 100))
        let square = try #require(try await run(.tool(.crop), [png], ["aspect": "1:1"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(square) == CGSize(width: 200, height: 200))

        // The area is drawn on the upright picture, so a tagged JPEG crops what was shown.
        let tagged = try photo(dir, orientation: 6)
        let top = try #require(try await run(.tool(.crop), [tagged], ["aspect": "free", "region": "0:0:1:0.5"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(top) == CGSize(width: 300, height: 200))

        // Straightening turns, then crops to the same shape with no empty corners.
        let level = try #require(try await run(.tool(.rotate), [png], ["angle": "0", "tilt": "10"]).outputs.first)
        let levelSize = ImageProbe.orientedPixelSize(level)
        let scale = ImageEngine.straightenScale(CGSize(width: 400, height: 200), degrees: 10)
        #expect(abs(levelSize.width - 400 * scale) <= 3 && abs(levelSize.height - 200 * scale) <= 3)
        let pixels = ImageProbe.source(level).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.dataProvider?.data
        #expect(pixels.flatMap { CFDataGetBytePtr($0)?[3] } == 255)
        let turned = ImageProbe.orientedPixelSize(try #require(try await run(.tool(.rotate), [png], ["angle": "90", "tilt": "-5"]).outputs.first))
        #expect(turned.width < turned.height)
    }

    @Test func compressQualityChangesSize() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = dir.appendingPathComponent("noise.jpg")
        try Fixtures.write(Fixtures.makeImage(width: 800, height: 600), to: source, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let low = try #require(try await run(.tool(.compress), [source], ["quality": "20"]).outputs.first)
        let high = try #require(try await run(.tool(.compress), [source], ["quality": "90"]).outputs.first)
        #expect(size(low) < size(high))
    }

    @Test func toolsProduceExpectedImages() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = try photo(dir)
        let half = try #require(try await run(.tool(.resize), [source], ["percent": "50"]).outputs.first)
        #expect(ImageProbe.orientedPixelSize(half) == CGSize(width: 200, height: 150))

        let compressed = try #require(try await run(.tool(.compress), [source]).outputs.first)
        #expect(size(compressed) < size(source))

        let clean = try #require(try await run(.tool(.stripMetadata), [source]).outputs.first)
        let props = CGImageSourceCopyPropertiesAtIndex(ImageProbe.source(clean)!, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)

        // White frame around content → auto-crop removes it.
        let framed = dir.appendingPathComponent("framed.png")
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)); context.fill(CGRect(x: 50, y: 40, width: 100, height: 60))
        try Fixtures.write(context.makeImage()!, to: framed, type: .png)
        let cropped = try #require(try await run(.tool(.crop), [framed]).outputs.first)
        let croppedSize = ImageProbe.orientedPixelSize(cropped)
        #expect(abs(croppedSize.width - 100) <= 2 && abs(croppedSize.height - 60) <= 2)
    }

    @Test func ocrAndQRGoToTheClipboard() async throws {
        let dir = try Fixtures.tempDirectory()
        let text = dir.appendingPathComponent("text.png")
        try Fixtures.write(Fixtures.makeTextImage("KUMQUAT 2026"), to: text, type: .png)
        let ocr = try await run(.tool(.recognizeText), [text])
        #expect(ocr.clipboardText?.uppercased().contains("KUMQUAT") == true)
        #expect(ocr.outputs.isEmpty)

        let qr = dir.appendingPathComponent("qr.png")
        try Fixtures.write(Fixtures.makeQRCode("https://example.com/kumquat"), to: qr, type: .png)
        #expect(try await run(.tool(.readQRCode), [qr]).clipboardText == "https://example.com/kumquat")
    }

    @Test func batchKeepsEveryFile() async throws {
        let dir = try Fixtures.tempDirectory()
        var inputs: [URL] = []
        for i in 0..<10 {
            let url = dir.appendingPathComponent("img\(i).png")
            try Fixtures.write(Fixtures.makeImage(width: 120 + i, height: 80), to: url, type: .png)
            inputs.append(url)
        }
        let outcome = try await run(.convert(.heic), inputs)
        #expect(Set(outcome.outputs.map(\.lastPathComponent)) == Set((0..<10).map { "img\($0).heic" }))
    }
}

@Suite struct PDFEngineTests {
    @Test func convertsToEveryTarget() async throws {
        let dir = try Fixtures.tempDirectory()
        let pdf = dir.appendingPathComponent("brochure.pdf")
        Fixtures.makePDF(pages: 3, to: pdf)

        let txt = try #require(try await run(.convert(.txt), [pdf]).outputs.first)
        #expect(try String(contentsOf: txt, encoding: .utf8).contains("Page 3 citrus"))
        let md = try #require(try await run(.convert(.md), [pdf]).outputs.first)
        #expect(try String(contentsOf: md, encoding: .utf8).contains("Page 2 citrus"))
        let docx = try #require(try await run(.convert(.docx), [pdf]).outputs.first)
        #expect(try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string.contains("Page 1 citrus"))
        let xlsx = try #require(try await run(.convert(.xlsx), [pdf]).outputs.first)
        #expect(try await XLSX.read(xlsx).count == 3)
        let epub = try #require(try await run(.convert(.epub), [pdf]).outputs.first)
        #expect(try await DocumentEngine.model(epub, format: .epub).blocks.count >= 3)
        let pptx = try #require(try await run(.convert(.pptx), [pdf]).outputs.first)
        #expect(size(pptx) > 1000)

        let pngs = try await run(.convert(.png), [pdf]).outputs
        #expect(pngs.count == 3)
        #expect(pngs.first?.deletingLastPathComponent().lastPathComponent == "brochure")
        #expect(ImageProbe.orientedPixelSize(pngs[0]) == CGSize(width: 2479, height: 3508))
    }

    @Test func pageTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let pdf = dir.appendingPathComponent("doc.pdf")
        Fixtures.makePDF(pages: 4, to: pdf)

        let split = try await run(.tool(.split), [pdf]).outputs
        #expect(split.count == 4)
        let merged = try #require(try await run(.tool(.merge), [pdf, split[0]]).outputs.first)
        #expect(merged.lastPathComponent == "Merged.pdf")
        #expect(PDFEngine.pageCount(of: merged) == 5)
        let extracted = try #require(try await run(.tool(.extractPages), [pdf], ["pages": "2-3"]).outputs.first)
        #expect(PDFEngine.pageCount(of: extracted) == 2)
        let rotated = try #require(try await run(.tool(.rotate), [pdf]).outputs.first)
        #expect(PDFDocument(url: rotated)?.page(at: 0)?.rotation == 90)
        let left = try #require(try await run(.tool(.rotate), [pdf], ["angle": "270"]).outputs.first)
        #expect(PDFDocument(url: left)?.page(at: 0)?.rotation == 270)
        let cropped = try #require(try await run(.tool(.crop), [pdf]).outputs.first)
        #expect((PDFDocument(url: cropped)?.page(at: 0)?.bounds(for: .cropBox).width ?? 999) < 595)
        let drawn = try #require(try await run(.tool(.crop), [pdf], ["aspect": "free", "region": "0:0:0.5:0.5"]).outputs.first)
        #expect(PDFDocument(url: drawn)?.page(at: 3)?.bounds(for: .cropBox) == CGRect(x: 0, y: 421, width: 297.5, height: 421))
        let marked = try #require(try await run(.tool(.watermark), [pdf], ["text": "DRAFT"]).outputs.first)
        #expect(PDFEngine.pageCount(of: marked) == 4)
        let level = try #require(try await run(.tool(.watermark), [pdf], ["text": "DRAFT", "opacity": "60", "angle": "horizontal"]).outputs.first)
        #expect(PDFEngine.pageCount(of: level) == 4)

        let locked = try #require(try await run(.tool(.password), [pdf], ["password": "orange"]).outputs.first)
        #expect(PDFDocument(url: locked)?.isLocked == true)
        let unlocked = try #require(try await run(.tool(.password), [locked], ["password": "orange"]).outputs.first)
        #expect(unlocked.lastPathComponent.contains("(unlocked)"))
        #expect(PDFDocument(url: unlocked)?.isEncrypted == false)
    }

    @Test func scansBecomeSearchable() async throws {
        let dir = try Fixtures.tempDirectory()
        let scan = dir.appendingPathComponent("scan.pdf")
        Fixtures.makeScannedPDF(text: "ORCHARD", to: scan)
        let searchable = try #require(try await run(.tool(.recognizeText), [scan]).outputs.first)
        #expect(PDFDocument(url: searchable)?.string?.uppercased().contains("ORCHARD") == true)
    }

    @Test func compressShrinksImageHeavyPDF() async throws {
        let dir = try Fixtures.tempDirectory()
        let png = dir.appendingPathComponent("big.png")
        let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<400 {
            context.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 11) / 11, blue: CGFloat(i % 5) / 5, alpha: 1))
            context.fillEllipse(in: CGRect(x: (i * 37) % 2400, y: (i * 53) % 1600, width: 160, height: 120))
        }
        try Fixtures.write(context.makeImage()!, to: png, type: .png)
        let pdf = try #require(try await run(.convert(.pdf), [png]).outputs.first)
        let small = try #require(try await run(.tool(.compress), [pdf]).outputs.first)
        #expect(size(small) < size(pdf))
    }
}

@Suite struct DocumentEngineTests {
    let markdown = """
    # Kumquat Report

    Kumquats are **tiny** citrus fruits with *sweet* peel. See [site](https://example.com).

    - Grows in pots
    - Loves sun

    ```
    let x = 1
    ```
    """

    @Test func markdownToEverything() async throws {
        let dir = try Fixtures.tempDirectory()
        let md = dir.appendingPathComponent("report.md")
        try markdown.write(to: md, atomically: true, encoding: .utf8)

        let html = try String(contentsOf: try #require(try await run(.convert(.html), [md]).outputs.first), encoding: .utf8)
        #expect(html.contains("<h1 id=\"h1\">Kumquat Report</h1>"))
        #expect(html.contains("<strong>tiny</strong>"))
        #expect(html.contains("<li>Grows in pots</li>"))

        let docx = try #require(try await run(.convert(.docx), [md]).outputs.first)
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        #expect(text.string.contains("Loves sun"))

        let txt = try String(contentsOf: try #require(try await run(.convert(.txt), [md]).outputs.first), encoding: .utf8)
        #expect(txt.contains("• Grows in pots") && !txt.contains("**"))

        let epub = try #require(try await run(.convert(.epub), [md]).outputs.first)
        let back = try await DocumentEngine.model(epub, format: .epub)
        #expect(back.blocks.contains { if case .heading(_, let inlines) = $0 { inlines.plainText == "Kumquat Report" } else { false } })

        let pdf = try #require(try await run(.convert(.pdf), [md]).outputs.first)
        #expect(PDFDocument(url: pdf)?.string?.contains("citrus fruits") == true)
    }

    @Test func docxRoundTripsThroughMarkdown() async throws {
        let dir = try Fixtures.tempDirectory()
        let md = dir.appendingPathComponent("report.md")
        try markdown.write(to: md, atomically: true, encoding: .utf8)
        let docx = try #require(try await run(.convert(.docx), [md]).outputs.first)
        let back = try String(contentsOf: try #require(try await run(.convert(.md), [docx], into: try Fixtures.tempDirectory()).outputs.first), encoding: .utf8)
        #expect(back.contains("# Kumquat Report"))
        #expect(back.contains("**tiny**"))
        #expect(back.contains("- Grows in pots"))
    }

    @Test func richInputsConvert() async throws {
        let dir = try Fixtures.tempDirectory()
        let rtf = dir.appendingPathComponent("letter.rtf")
        try #"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs24 Dear reader,\par Kumquats ripen in winter.}"#.write(to: rtf, atomically: true, encoding: .utf8)
        let docx = try #require(try await run(.convert(.docx), [rtf]).outputs.first)
        #expect(try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string.contains("ripen in winter"))

        let txt = dir.appendingPathComponent("notes.txt")
        try (1...300).map { "Line \($0) of the orchard log." }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        let pdf = try #require(try await run(.convert(.pdf), [txt]).outputs.first)
        #expect(PDFEngine.pageCount(of: pdf) > 1)

        let html = dir.appendingPathComponent("page.html")
        try "<html><body><h1>Title</h1><p>Hello <b>world</b></p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let fromHTML = try String(contentsOf: try #require(try await run(.convert(.md), [html]).outputs.first), encoding: .utf8)
        #expect(fromHTML.contains("Title") && fromHTML.contains("**world**"))

        let merged = try #require(try await run(.tool(.merge), [rtf, txt]).outputs.first)
        #expect(merged.lastPathComponent == "Merged.docx")
    }
}

@Suite struct SheetSubtitleArchiveTests {
    @Test func spreadsheetsRoundTrip() async throws {
        let dir = try Fixtures.tempDirectory()
        let csv = dir.appendingPathComponent("fruit.csv")
        try "name,kg,note\nkumquat,12.5,\"sweet, tart\"\nlime,007,\"multi\nline\"\n".write(to: csv, atomically: true, encoding: .utf8)
        let expected = [["name", "kg", "note"], ["kumquat", "12.5", "sweet, tart"], ["lime", "007", "multi\nline"]]

        let xlsx = try #require(try await run(.convert(.xlsx), [csv]).outputs.first)
        #expect(try await XLSX.read(xlsx).first?.rows == expected)
        let ods = try #require(try await run(.convert(.ods), [xlsx]).outputs.first)
        #expect(try await ODS.read(ods).first?.rows == expected)
        let tsv = try #require(try await run(.convert(.tsv), [ods]).outputs.first)
        #expect(CSV.parse(try String(contentsOf: tsv, encoding: .utf8), delimiter: "\t") == expected)
        let pdf = try #require(try await run(.convert(.pdf), [csv]).outputs.first)
        #expect(PDFDocument(url: pdf)?.string?.contains("kumquat") == true)

        let merged = try #require(try await run(.tool(.merge), [csv, tsv]).outputs.first)
        #expect(try await XLSX.read(merged).count == 2)
        let parts = try await run(.tool(.split), [merged]).outputs
        #expect(parts.count == 2)
    }

    @Test func subtitles() async throws {
        let dir = try Fixtures.tempDirectory()
        let srt = dir.appendingPathComponent("movie.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello <i>there</i>\n\n2\n00:01:00,250 --> 00:01:03,000\nSecond line\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try #require(try await run(.convert(.vtt), [srt]).outputs.first)
        let vttText = try String(contentsOf: vtt, encoding: .utf8)
        #expect(vttText.hasPrefix("WEBVTT"))
        #expect(vttText.contains("00:01:00.250 --> 00:01:03.000"))
        let txt = try String(contentsOf: try #require(try await run(.convert(.txt), [vtt]).outputs.first), encoding: .utf8)
        #expect(txt == "Hello there\nSecond line\n")
        let shifted = try String(contentsOf: try #require(try await run(.tool(.shiftTiming), [srt], ["seconds": "-1.5"]).outputs.first), encoding: .utf8)
        #expect(shifted.contains("00:00:00,000 --> 00:00:01,000"))
    }

    @Test func archives() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let zip = try #require(try await run(.tool(.archive), [folder]).outputs.first)
        #expect(zip.lastPathComponent == "orchard.zip")
        let tgz = try #require(try await run(.convert(.gzip), [zip]).outputs.first)
        #expect(tgz.lastPathComponent == "orchard.tar.gz")
        let tar = try #require(try await run(.convert(.tar), [tgz]).outputs.first)
        let out = try Fixtures.tempDirectory()
        let extracted = try #require(try await run(.tool(.extract), [tar], into: out).outputs.first)
        #expect(extracted.lastPathComponent == "orchard")
        #expect(try String(contentsOf: extracted.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "b")

        let locked = try #require(try await run(.tool(.encryptArchive), [zip], ["password": "kq"]).outputs.first)
        // Some ZIP local header (file entries, not folders) has general-purpose flag bit 0 = encrypted.
        let bytes = [UInt8](try Data(contentsOf: locked))
        let encrypted = (0..<(bytes.count - 8)).contains { i in
            bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 3 && bytes[i + 3] == 4 && bytes[i + 6] & 1 == 1
        }
        #expect(encrypted)
    }
}

@Suite(.enabled(if: Engines.ffmpeg != nil)) struct MediaEngineTests {
    /// 2 s test pattern with a tone; `letterbox` adds black bars for crop detection.
    static func clip(_ dir: URL, name: String = "clip.mp4", letterbox: Bool = false, audio: Bool = true) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"] }
        if letterbox { args += ["-vf", "pad=320:320:0:40:black"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] + (audio ? ["-c:a", "aac"] : []) + ["-shortest", url.path]
        try await ExternalTool.check(Engines.ffmpeg!, args)
        return url
    }

    static func tone(_ dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("tone.wav")
        try await ExternalTool.check(Engines.ffmpeg!, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=0.5",
                                                       "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-filter_complex", "[0][1]concat=n=2:v=0:a=1",
                                                       url.path])
        return url
    }

    @Test(arguments: [FileFormat.mp3, .m4a, .flac, .ogg, .opus, .aiff, .wma])
    func audioConverts(target: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let output = try #require(try await run(.convert(target), [try await Self.tone(dir)]).outputs.first)
        let info = try await MediaEngine.probe(output)
        #expect(info.audio != nil)
        #expect(abs(info.duration - 2.5) < 0.2)
    }

    @Test(arguments: [FileFormat.mov, .mkv, .webm, .avi, .wmv, .gif, .mp3])
    func videoConverts(target: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let output = try #require(try await run(.convert(target), [try await Self.clip(dir)]).outputs.first)
        let info = try await MediaEngine.probe(output)
        if target == .mp3 { #expect(info.audio == "mp3") } else { #expect(info.video != nil) }
    }

    @Test func remuxIsCopy() async throws {
        let dir = try Fixtures.tempDirectory()
        let mov = try #require(try await run(.convert(.mov), [try await Self.clip(dir)]).outputs.first)
        #expect(try await MediaEngine.probe(mov).video == "h264")
    }

    @Test func videoTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await Self.clip(dir)
        let trimmed = try #require(try await run(.tool(.trim), [clip], ["start": "0.5", "end": "1.5"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(trimmed).duration - 1) < 0.2)
        let fast = try #require(try await run(.tool(.changeSpeed), [clip], ["factor": "2"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(fast).duration - 1) < 0.2)
        let small = try #require(try await run(.tool(.resize), [clip], ["height": "120"]).outputs.first)
        #expect(try await MediaEngine.probe(small).height == 120)
        let muted = try #require(try await run(.tool(.mute), [clip]).outputs.first)
        #expect(try await MediaEngine.probe(muted).audio == nil)
        let audio = try #require(try await run(.tool(.extractAudio), [clip]).outputs.first)
        #expect(audio.pathExtension == "m4a")
        let frames = try await run(.tool(.extractFrames), [clip], ["fps": "1"]).outputs
        #expect(frames.count >= 2)
        let gif = try #require(try await run(.tool(.makeGIF), [clip]).outputs.first)
        #expect(gif.pathExtension == "gif")
        let parts = try await run(.tool(.split), [clip], ["parts": "2"]).outputs
        #expect(parts.count >= 2)
        let compressed = try #require(try await run(.tool(.compress), [clip]).outputs.first)
        #expect(try await MediaEngine.probe(compressed).video == "hevc")

        let other = try await Self.clip(dir, name: "other.mp4", audio: false)
        let merged = try #require(try await run(.tool(.merge), [clip, other]).outputs.first)
        #expect(abs(try await MediaEngine.probe(merged).duration - 4) < 0.3)

        let boxed = try await Self.clip(dir, name: "boxed.mp4", letterbox: true)
        let cropped = try #require(try await run(.tool(.crop), [boxed]).outputs.first)
        #expect(try await MediaEngine.probe(cropped).height == 240)
    }

    @Test func drawnAreaFollowsPageRotation() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 200)
        let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.25)
        #expect(PDFEngine.pageRect(topLeft, in: box, rotation: 0) == CGRect(x: 0, y: 150, width: 50, height: 50))
        // Turned clockwise, the top-left of what is shown is the page's bottom-left.
        #expect(PDFEngine.pageRect(topLeft, in: box, rotation: 90) == CGRect(x: 0, y: 0, width: 25, height: 100))
        #expect(PDFEngine.pageRect(topLeft, in: box, rotation: 180) == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(PDFEngine.pageRect(topLeft, in: box, rotation: 270) == CGRect(x: 75, y: 100, width: 25, height: 100))
    }

    @Test func videoRotates() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await Self.clip(dir)
        // MP4 only gets a new rotation flag: the stream is copied.
        let right = try #require(try await run(.tool(.rotate), [clip], ["angle": "90"]).outputs.first)
        let flagged = try await MediaEngine.probe(right)
        #expect(flagged.width == 320 && flagged.rotation == -90)
        let back = try await MediaEngine.probe(try #require(try await run(.tool(.rotate), [right], ["angle": "270"]).outputs.first))
        #expect(back.rotation % 360 == 0)
        // MKV has no rotation flag: the pixels are turned.
        let mkv = try #require(try await run(.convert(.mkv), [clip]).outputs.first)
        let turned = try await MediaEngine.probe(try #require(try await run(.tool(.rotate), [mkv], ["angle": "270"]).outputs.first))
        #expect(turned.width == 240 && turned.height == 320)
    }

    @Test func videoToolOptions() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await Self.clip(dir)

        let quarter = try await MediaEngine.probe(try #require(try await run(.tool(.crop), [clip], ["aspect": "free", "region": "0.5:0:0.5:0.5"]).outputs.first))
        #expect(quarter.width == 160 && quarter.height == 120)
        let square = try await MediaEngine.probe(try #require(try await run(.tool(.crop), [clip], ["aspect": "1:1"]).outputs.first))
        #expect(square.width == 240 && square.height == 240)
        let unfinished = await Executor.run(JobRequest(operation: .tool(.crop), inputs: [clip], parameters: ["aspect": "free"],
                                                       destination: { _ in dir })) { _ in }
        #expect(unfinished.failures.first?.message == "Draw the area to keep.")

        let gif = try #require(try await run(.tool(.makeGIF), [clip], ["start": "0.5", "end": "1.5", "fps": "10", "width": "160"]).outputs.first)
        let gifInfo = try await MediaEngine.probe(gif)
        #expect(gifInfo.width == 160)
        #expect(abs(gifInfo.duration - 1) < 0.2)

        let small = try #require(try await run(.tool(.compress), [clip], ["quality": "small"]).outputs.first)
        let high = try #require(try await run(.tool(.compress), [clip], ["quality": "high"]).outputs.first)
        #expect(size(small) < size(high))
        let capped = try #require(try await run(.tool(.compress), [clip], ["maxMB": "0.2"]).outputs.first)
        #expect(size(capped) < 300_000)
    }

    @Test func previewProxyPlaysInAVFoundation() async throws {
        let dir = try Fixtures.tempDirectory()
        let mkv = try #require(try await run(.convert(.mkv), [try await Self.clip(dir)]).outputs.first)
        let proxy = dir.appendingPathComponent("proxy.mp4")
        try await MediaEngine.makePreviewProxy(mkv, output: proxy)
        let info = try await MediaEngine.probe(proxy)
        #expect(info.video == "h264")
        #expect(info.height <= 480)
    }

    @Test func audioTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let tone = try await Self.tone(dir)
        let trimmed = try #require(try await run(.tool(.trim), [tone]).outputs.first)
        #expect(try await MediaEngine.probe(trimmed).duration < 2.3)
        let louder = try #require(try await run(.tool(.adjustVolume), [tone], ["db": "+3"]).outputs.first)
        #expect(louder.lastPathComponent == "tone (+3 dB).wav")
        _ = try #require(try await run(.tool(.normalizeVolume), [tone]).outputs.first)
        _ = try #require(try await run(.tool(.normalizeVolume), [tone], ["lufs": "-14"]).outputs.first)
        let mp3 = try #require(try await run(.convert(.mp3), [tone]).outputs.first)
        let tiny = try #require(try await run(.tool(.compress), [mp3], ["bitrate": "64"]).outputs.first)
        #expect(size(tiny) < size(mp3))
        let flac = try #require(try await run(.tool(.compress), [tone]).outputs.first)
        #expect(flac.pathExtension == "flac" && size(flac) < size(tone))
    }
}
