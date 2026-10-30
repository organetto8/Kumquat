import Foundation
import Testing
@testable import KumquatCore

@Suite struct CatalogTests {
    @Test func catalogSize() {
        #expect(Catalog.conversionCount >= 900)
        let tools = Set(FormatCategory.allCases.flatMap { Catalog.tools(for: $0) } + Catalog.tools(for: nil))
        #expect(tools.count == ToolKind.allCases.count)
        #expect(Catalog.actions.count == 27)
        #expect(Catalog.actions(for: .audio).contains(.addToLibrary) && !Catalog.actions(for: .audio).contains(.wallpaper))
    }

    @Test(arguments: zip(
        ["a.JPEG", "b.heif", "c.tgz", "d.tar.gz", "e.m4v", "f.aif", "g.markdown", "h.textClipping", "i.ppsx", "j.xlsm", "k.vtt", "l.rar", "m",
         "n.CR3", "o.m2ts", "p.3gp", "q.yml", "r.tar.xz", "s.tbz2", "t.7z", "u.ssa", "v.usd", "w.woff2", "x.ts"],
        [FileFormat.jpg, .heic, .gzip, .gzip, .mp4, .aiff, .md, .textClipping, .pptx, .xlsx, .vtt, .rar, nil,
         .cr3, .mts, .threeGP, .yaml, .xz, .bz2, .sevenZip, .ass, .usdc, .woff2, nil]
    ))
    func detectsFormats(name: String, expected: FileFormat?) {
        #expect(FileFormat.detect(URL(fileURLWithPath: "/tmp/\(name)")) == expected)
    }

    @Test func wheelsFollowTheSelection() {
        let photos = [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.png")]
        let convert = Catalog.wheel(.convert, for: photos)
        #expect(convert.subject == "2 images")
        #expect(convert.items.map(\.operation).contains(.convert(.heic)))
        #expect(convert.items.map(\.operation).contains(.convert(.pdf)))

        let mixed = Catalog.wheel(.tools, for: [URL(fileURLWithPath: "/tmp/a.mp3"), URL(fileURLWithPath: "/tmp/b.mp3"), URL(fileURLWithPath: "/tmp/c.pdf")])
        #expect(mixed.category == .audio)
        #expect(mixed.items.first?.operation == .tool(.trim))

        let folder = Catalog.wheel(.tools, for: [URL(fileURLWithPath: "/tmp/folder")])
        #expect(folder.items.map(\.operation) == [.tool(.sortFolder), .tool(.findDuplicates), .tool(.flatten), .tool(.listFiles), .tool(.lock), .tool(.archive)])
        #expect(Catalog.wheel(.actions, for: photos).items.count == 27)

        let clip = [URL(fileURLWithPath: "/tmp/talk.srt"), URL(fileURLWithPath: "/tmp/talk.mp4")]
        #expect(Catalog.wheel(.tools, for: clip).category == .video)
        #expect(Catalog.applies(.tool(.addSubtitles), to: clip[0]))
        #expect(!Catalog.applies(.tool(.compress), to: URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(Catalog.applies(.tool(.compress), to: URL(fileURLWithPath: "/tmp/deck.pptx")))
        let markdown = Catalog.wheel(.tools, for: [URL(fileURLWithPath: "/tmp/notes.md")])
        #expect(markdown.items.first { $0.operation == .tool(.compress) }?.isAvailable == false)
    }

    @Test func inputOnlyFormatsAreNeverTargets() {
        let targets = Set(FileFormat.allCases.flatMap(Catalog.convertTargets(for:)))
        for format in FileFormat.allCases where format.isInputOnly { #expect(!targets.contains(format)) }
        for format in FileFormat.allCases { #expect(!Catalog.convertTargets(for: format).contains(format)) }
    }

    @Test func pageRanges() {
        #expect(PDFEngine.parsePageRange("1-3, 5, 8-", pageCount: 10) == [0, 1, 2, 4, 7, 8, 9])
        #expect(PDFEngine.parsePageRange("4-2", pageCount: 5) == nil)
        #expect(PDFEngine.parsePageRange("9", pageCount: 5) == nil)
        #expect(MediaEngine.parseTime("1:05") == 65)
        #expect(MediaEngine.parseTime("0:01:05.5") == 65.5)
    }

    @Test func orientationAlgebra() {
        #expect(ImageEngine.compose(ImageEngine.rotateClockwise, with: 1) == 6)
        #expect(ImageEngine.compose(ImageEngine.rotateClockwise, with: 6) == 3)
        #expect(ImageEngine.compose(ImageEngine.rotateClockwise, with: 8) == 1)
        #expect(ImageEngine.compose(ImageEngine.flipHorizontal, with: 1) == 2)
        #expect(ImageEngine.compose(ImageEngine.flipHorizontal, with: 2) == 1)
        #expect(ImageEngine.compose(ImageEngine.rotateCounterClockwise, with: 1) == 8)
        #expect(ImageEngine.compose(ImageEngine.rotateHalf, with: 1) == 3)
        #expect(ImageEngine.compose(ImageEngine.flipVertical, with: 1) == 4)
    }

    @Test func toolOptionsAreConsistent() {
        for category in FormatCategory.allCases {
            for tool in Catalog.tools(for: category) {
                let parameters = Catalog.parameters(for: tool, category: category)
                #expect(Set(parameters.map(\.key)).count == parameters.count, "\(tool) has duplicate keys")
                for parameter in parameters where !parameter.defaultValue.isEmpty {
                    #expect(parameter.accepts(parameter.defaultValue), "\(tool).\(parameter.key) rejects its default")
                }
                if Catalog.previewsVideo(tool, category: category) || Catalog.previewsStill(tool, category: category) { #expect(!parameters.isEmpty) }
            }
        }
        let quality = Catalog.parameters(for: .compress, category: .image)[0]
        #expect(quality.accepts("80") && !quality.accepts("200") && !quality.accepts("high"))
        let angle = Catalog.parameters(for: .rotate, category: .image)[0]
        #expect(angle.accepts("270") && !angle.accepts("45"))
        let tilt = Catalog.parameters(for: .rotate, category: .image)[1]
        #expect(tilt.accepts("-12.5") && !tilt.accepts("60") && !tilt.remembers)
        #expect(!ToolParameter("p", "P", default: "", kind: .secure).remembers)
        #expect(!ToolParameter("r", "R", default: "", kind: .region).remembers)
    }

    @Test func instantToolsStayInstant() {
        #expect(Catalog.runsInstantly(.compress, category: .video))
        #expect(Catalog.runsInstantly(.flip, category: .image))
        #expect(!Catalog.runsInstantly(.crop, category: .image))
        #expect(!Catalog.runsInstantly(.rotate, category: .pdf))
        #expect(Catalog.runsInstantly(.mute, category: .video))
        #expect(!Catalog.runsInstantly(.trim, category: .video))
        #expect(!Catalog.runsInstantly(.password, category: .pdf))
        #expect(Catalog.previewsVideo(.changeSpeed, category: .video))
        #expect(Catalog.previewsVideo(.rotate, category: .video))
        #expect(!Catalog.previewsVideo(.compress, category: .video))
        #expect(Catalog.previewsStill(.crop, category: .pdf))
        #expect(!Catalog.previewsStill(.resize, category: .image))
    }
}
