import Compression
import CoreText
import Foundation
import ModelIO
import Testing
@testable import KumquatCore

/// Helpers for the archive, folder, font and 3D model tests (`run` itself lives in EngineTests).
enum AFM {
    /// Runs without recording failures, for the cases that are expected to fail.
    static func attempt(_ operation: KumquatCore.Operation, _ inputs: [URL], _ parameters: [String: String] = [:], into directory: URL) async -> JobOutcome {
        await Executor.run(JobRequest(operation: operation, inputs: inputs, parameters: parameters, destination: { _ in directory })) { _ in }
    }

    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// "orchard/a.txt" = "a", "orchard/sub/b.txt" = "b".
    static func orchard(in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent("orchard", isDirectory: true)
        try write("a", folder.appendingPathComponent("a.txt"))
        try write("b", folder.appendingPathComponent("sub/b.txt"))
        return folder
    }

    static func expectOrchard(_ extracted: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(extracted.lastPathComponent == "orchard", sourceLocation: sourceLocation)
        #expect(text(extracted.appendingPathComponent("a.txt")) == "a", sourceLocation: sourceLocation)
        #expect(text(extracted.appendingPathComponent("sub/b.txt")) == "b", sourceLocation: sourceLocation)
    }

    static func lzma(_ data: Data) throws -> Data {
        var out = Data()
        let filter = try OutputFilter(.compress, using: .lzma) { chunk in if let chunk { out.append(chunk) } }
        try filter.write(data)
        try filter.finalize()
        return out
    }

    static func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    static func signature(_ url: URL) -> UInt32 {
        guard let data = try? Data(contentsOf: url), data.count >= 4 else { return 0 }
        return data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Mounts an encrypted image with its password; returns the mount point.
    static func mount(_ image: URL, password: String, under root: URL) async throws -> String? {
        let result = try await DiskImage.hdiutil(["attach", "-nobrowse", "-readonly", "-mountrandom", root.path, "-plist", "-stdinpass", image.path],
                                                 input: Data(password.utf8))
        let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        return (plist?["system-entities"] as? [[String: Any]])?.lazy.compactMap { $0["mount-point"] as? String }.first
    }

    static func detach(_ mountPoint: String) async {
        _ = try? await DiskImage.hdiutil(["detach", "-quiet", "-force", mountPoint])
    }

    /// The name Executor gives outputs made from `input` (see OutputNaming.baseName).
    static func base(_ input: URL) -> String { OutputNaming.baseName(input) }

    static func setCreated(_ url: URL, _ date: String) throws {
        let formatter = ISO8601DateFormatter()
        try FileManager.default.setAttributes([.creationDate: formatter.date(from: date + "T12:00:00Z")!], ofItemAtPath: url.path)
    }

    static func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }
}

// MARK: - Archives

@Suite struct ArchiveConversionTests {
    /// Every archive format from a ZIP, then from it to every other one, each result unpacked again.
    @Test(arguments: Catalog.archives)
    func convertsToEveryOtherArchive(source: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let zip = try #require(try await run(.tool(.archive), [try AFM.orchard(in: dir)]).outputs.first)
        let input = source == .zip ? zip : try #require(try await run(.convert(source), [zip]).outputs.first)
        #expect(input.lastPathComponent == "orchard.\(source.fileExtension)")
        #expect(FileFormat.detect(input) == source)

        for target in Catalog.convertTargets(for: source) {
            let out = try Fixtures.tempDirectory()
            let converted = try #require(try await run(.convert(target), [input], into: out).outputs.first, "\(source) → \(target)")
            #expect(converted.lastPathComponent == "\(AFM.base(input)).\(target.fileExtension)", "\(source) → \(target)")
            #expect(FileFormat.detect(converted) == target, "\(source) → \(target)")
            let unpacked = try Fixtures.tempDirectory()
            let extracted = try #require(try await run(.tool(.extract), [converted], into: unpacked).outputs.first, "\(source) → \(target)")
            #expect(AFM.contents(unpacked) == ["orchard"], "\(source) → \(target)")
            AFM.expectOrchard(extracted)
        }
    }

    @Test func bareCompressedFiles() async throws {
        let dir = try Fixtures.tempDirectory()
        let note = Data(String(repeating: "kumquat ", count: 500).utf8)
        let gz = dir.appendingPathComponent("notes.txt.gz"), bz2 = dir.appendingPathComponent("notes.txt.bz2"), xz = dir.appendingPathComponent("notes.txt.xz")
        let plain = dir.appendingPathComponent("plain.txt")
        try note.write(to: plain)
        try (try await ExternalTool.check(ArchiveEngine.gzip, ["-c", plain.path])).stdout.write(to: gz)
        try (try await ExternalTool.check(ArchiveEngine.bzip2, ["-c", plain.path])).stdout.write(to: bz2)
        try AFM.lzma(note).write(to: xz)

        for (file, format) in [(gz, FileFormat.gzip), (bz2, .bz2), (xz, .xz)] {
            #expect(FileFormat.detect(file) == format)
            let extracted = try #require(try await run(.tool(.extract), [file], into: try Fixtures.tempDirectory()).outputs.first)
            #expect(extracted.lastPathComponent == "notes.txt")
            #expect(try Data(contentsOf: extracted) == note)

            let zip = try #require(try await run(.convert(.zip), [file], into: try Fixtures.tempDirectory()).outputs.first)
            let unzipped = try #require(try await run(.tool(.extract), [zip], into: try Fixtures.tempDirectory()).outputs.first)
            #expect(try Data(contentsOf: unzipped) == note)

            let summary = try await run(.tool(.verify), [file], into: dir).notes.first
            #expect(summary?.hasPrefix("OK · 1 files") == true, "\(format): \(summary ?? "nil")")
        }
    }

    /// Encrypt repacks any readable archive as an AES ZIP.
    @Test(arguments: [FileFormat.zip, .tar, .gzip, .xz, .bz2, .sevenZip])
    func encryptsEverySource(source: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let zip = try #require(try await run(.tool(.archive), [try AFM.orchard(in: dir)]).outputs.first)
        let input = source == .zip ? zip : try #require(try await run(.convert(source), [zip]).outputs.first)
        let locked = try #require(try await run(.tool(.encryptArchive), [input], ["password": "kq"]).outputs.first)
        #expect(locked.lastPathComponent == "\(AFM.base(input)) (encrypted).zip")
        let bytes = [UInt8](try Data(contentsOf: locked))
        let encrypted = (0..<(bytes.count - 8)).contains { i in
            bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 3 && bytes[i + 3] == 4 && bytes[i + 6] & 1 == 1
        }
        #expect(encrypted)
        if let sevenZip = Engines.sevenZip {
            #expect(try await ExternalTool.run(sevenZip, ["t", "-pkq", locked.path]).status == 0)
            #expect(try await ExternalTool.run(sevenZip, ["t", "-pwrong", locked.path]).status != 0)
        }
    }

    @Test func splitsIntoVolumes() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blob = AFM.randomData(12_500_000)  // incompressible: the ZIP stays over 10 MB
        try blob.write(to: folder.appendingPathComponent("blob.bin"))
        let zip = try #require(try await run(.tool(.archive), [folder]).outputs.first)

        let parts = try await run(.tool(.splitVolumes), [zip], ["size": "10"]).outputs
        #expect(parts.map(\.lastPathComponent) == ["big.zip", "big.z01"])
        #expect(parts.first?.deletingLastPathComponent().lastPathComponent == "big parts")
        #expect(size(parts[1]) == 10 * 1024 * 1024)
        if let sevenZip = Engines.sevenZip {
            let out = try Fixtures.tempDirectory()
            try await ExternalTool.check(sevenZip, ["x", "-y", "-bso0", "-bsp0", "-o" + out.path, parts[0].path])
            #expect(try Data(contentsOf: out.appendingPathComponent("big/blob.bin")) == blob)
        }
    }

    @Test(arguments: [FileFormat.zip, .tar, .gzip, .xz, .bz2, .sevenZip, .dmg])
    func verifiesEveryFormat(source: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        let zip = try #require(try await run(.tool(.archive), [try AFM.orchard(in: dir)]).outputs.first)
        let input = source == .zip ? zip : try #require(try await run(.convert(source), [zip]).outputs.first)
        let outcome = try await run(.tool(.verify), [input])
        #expect(outcome.outputs.isEmpty)
        let summary = try #require(outcome.notes.first)
        // ditto's ZIP may carry AppleDouble "._" files beside the two real ones.
        #expect(summary.hasPrefix("OK · "), "\(source): \(summary)")
        #expect(summary.contains(" files · "), "\(source): \(summary)")
        let files = Int(summary.split(separator: " ")[2]) ?? 0
        #expect(files >= 2, "\(source): \(summary)")
    }

    @Test func reportsDamage() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("text", isDirectory: true)
        try AFM.write(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4000), folder.appendingPathComponent("fox.txt"))
        let zip = try #require(try await run(.tool(.archive), [folder]).outputs.first)
        var bytes = [UInt8](try Data(contentsOf: zip))
        for i in (bytes.count / 3)..<(bytes.count / 3 + 64) { bytes[i] ^= 0x5A }
        try Data(bytes).write(to: zip)
        let outcome = await AFM.attempt(.tool(.verify), [zip], into: dir)
        let message = try #require(outcome.failures.first?.message)
        #expect(message.contains("damaged"), "\(message)")
    }

    @Test(.enabled(if: Engines.sevenZip != nil)) func refusesPasswordProtected7z() async throws {
        let dir = try Fixtures.tempDirectory()
        let note = dir.appendingPathComponent("note.txt")
        try AFM.write("secret", note)
        let archive = dir.appendingPathComponent("vault.7z")
        try await ExternalTool.check(Engines.sevenZip!, ["a", "-t7z", "-pkq", "-mhe=on", "-bso0", "-bsp0", archive.path, note.path])
        for operation in [KumquatCore.Operation.tool(.extract), .tool(.verify), .convert(.zip)] {
            let outcome = await AFM.attempt(operation, [archive], into: try Fixtures.tempDirectory())
            #expect(outcome.failures.first?.message.contains("password-protected") == true, "\(operation): \(outcome.failures.first?.message ?? "")")
        }
    }
}

// MARK: - Folders

@Suite struct FolderToolTests {
    @Test func locksFoldersAndFiles() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = try AFM.orchard(in: dir)
        let image = try #require(try await run(.tool(.lock), [folder], ["password": "kq secret"]).outputs.first)
        #expect(image.lastPathComponent == "orchard.dmg")
        #expect(await DiskImage.isEncrypted(image))

        let root = try Fixtures.tempDirectory()
        let wrong = try? await AFM.mount(image, password: "nope", under: root)
        #expect(wrong == nil)
        let volume = try #require(try await AFM.mount(image, password: "kq secret", under: root))
        #expect(AFM.text(URL(fileURLWithPath: volume).appendingPathComponent("sub/b.txt")) == "b")
        await AFM.detach(volume)

        // The archive tools read no password: they refuse at once instead of making macOS ask for one.
        for tool in [ToolKind.extract, .verify] {
            let outcome = await AFM.attempt(.tool(tool), [image], into: try Fixtures.tempDirectory())
            #expect(outcome.failures.first?.message.contains("password-protected") == true, "\(tool)")
        }
        let converted = await AFM.attempt(.convert(.zip), [image], into: try Fixtures.tempDirectory())
        #expect(converted.failures.first?.message.contains("password-protected") == true)

        // Several items: one image named "Locked", each item at its top level.
        let note = dir.appendingPathComponent("note.txt")
        try AFM.write("n", note)
        let both = try #require(try await run(.tool(.lock), [folder, note], ["password": "kq"]).outputs.first)
        #expect(both.lastPathComponent == "Locked.dmg")
        let mounted = try #require(try await AFM.mount(both, password: "kq", under: root))
        #expect(AFM.contents(URL(fileURLWithPath: mounted)).filter { !$0.hasPrefix(".") } == ["note.txt", "orchard"])
        await AFM.detach(mounted)

        let empty = await AFM.attempt(.tool(.lock), [note], into: dir)
        #expect(empty.failures.count == 1)
    }

    @Test func sortsByKindAndMonth() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("mess", isDirectory: true)
        for name in ["photo.jpg", "song.mp3", "notes.txt", "data.xyz", "Makefile"] { try AFM.write(name, folder.appendingPathComponent(name)) }
        try AFM.write("keep", folder.appendingPathComponent("keep/inside.txt"))
        let outcome = try await run(.tool(.sortFolder), [folder], ["by": "type"])
        #expect(outcome.outputs == [folder])
        #expect(outcome.notes.first == "5 files sorted")
        let other = String(localized: "Other")
        #expect(AFM.contents(folder) == [FormatCategory.audio.folderName, FormatCategory.document.folderName, FormatCategory.image.folderName, "keep", other].sorted())
        #expect(AFM.contents(folder.appendingPathComponent(other)) == ["Makefile", "data.xyz"])
        #expect(AFM.contents(folder.appendingPathComponent("keep")) == ["inside.txt"])

        let months = dir.appendingPathComponent("months", isDirectory: true)
        for (name, date) in [("a.txt", "2024-03-02"), ("b.txt", "2024-03-30"), ("c.txt", "2025-11-15")] {
            let file = months.appendingPathComponent(name)
            try AFM.write(name, file)
            try AFM.setCreated(file, date)
        }
        _ = try await run(.tool(.sortFolder), [months], ["by": "month"])
        #expect(AFM.contents(months) == ["2024-03", "2025-11"])
        #expect(AFM.contents(months.appendingPathComponent("2024-03")) == ["a.txt", "b.txt"])
    }

    @Test func movesDuplicatesKeepingTheOldest() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("photos", isDirectory: true)
        let original = folder.appendingPathComponent("z-original.txt")
        try AFM.write("same content", original)
        try AFM.setCreated(original, "2020-01-01")
        try AFM.write("same content", folder.appendingPathComponent("a-copy.txt"))
        try AFM.write("same content", folder.appendingPathComponent("trip/copy.txt"))
        try AFM.write("same length!", folder.appendingPathComponent("b-different.txt"))  // same size, other bytes
        try AFM.write("", folder.appendingPathComponent("empty1.txt"))
        try AFM.write("", folder.appendingPathComponent("empty2.txt"))

        let outcome = try await run(.tool(.findDuplicates), [folder])
        let duplicates = try #require(outcome.outputs.first)
        #expect(duplicates.lastPathComponent == String(localized: "Duplicates"))
        #expect(outcome.notes.first == "2 duplicates moved")
        #expect(AFM.contents(duplicates) == ["a-copy.txt", "copy.txt"])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b-different.txt").path))

        // Run again: the Duplicates folder itself isn't searched, so nothing is left to move.
        let again = await AFM.attempt(.tool(.findDuplicates), [folder], into: dir)
        #expect(again.failures.first?.message.contains("No duplicates") == true)
    }

    @Test func flattensNestedFiles() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("tree", isDirectory: true)
        try AFM.write("top", folder.appendingPathComponent("x.txt"))
        try AFM.write("nested", folder.appendingPathComponent("one/x.txt"))
        try AFM.write("deep", folder.appendingPathComponent("one/two/y.txt"))
        try AFM.write("hidden", folder.appendingPathComponent("three/.secret"))
        let outcome = try await run(.tool(.flatten), [folder])
        #expect(outcome.notes.first == "2 files moved up")
        #expect(AFM.contents(folder).filter { !$0.hasPrefix(".") } == ["three", "x 2.txt", "x.txt", "y.txt"])
        #expect(AFM.text(folder.appendingPathComponent("x 2.txt")) == "nested")
    }

    @Test func listsFilesAsCSV() async throws {
        let dir = try Fixtures.tempDirectory()
        let folder = dir.appendingPathComponent("docs", isDirectory: true)
        try AFM.write("12345", folder.appendingPathComponent("a.txt"))
        try AFM.write("x", folder.appendingPathComponent(#"sub/he said "hi", ok.txt"#))
        let csv = try #require(try await run(.tool(.listFiles), [folder]).outputs.first)
        #expect(csv.lastPathComponent == "docs (files).csv")
        #expect(csv.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        let raw = try #require(AFM.text(csv))
        #expect(raw.contains(#""sub/he said ""hi"", ok.txt""#))
        let rows = CSV.parse(raw, delimiter: ",")
        #expect(rows.first == ["path", "name", "kind", "size", "created", "modified"])
        #expect(rows.count == 3)
        #expect(rows[1][0] == "a.txt" && rows[1][3] == "5")
        #expect(rows[2][1] == #"he said "hi", ok.txt"#)
        #expect(rows[1][4].count == 19)  // "yyyy-MM-dd HH:mm:ss"
    }
}

// MARK: - Fonts

@Suite struct FontConversionTests {
    static func systemFont(_ ext: String, preferring names: [String]) -> URL? {
        let folders = ["/System/Library/Fonts/Supplemental", "/System/Library/Fonts", "/Library/Fonts"]
        for folder in folders {
            for name in names where FileManager.default.fileExists(atPath: "\(folder)/\(name)") { return URL(fileURLWithPath: "\(folder)/\(name)") }
        }
        // Any small one will do.
        return folders.lazy.compactMap { folder in
            (try? FileManager.default.contentsOfDirectory(atPath: folder))?
                .filter { $0.lowercased().hasSuffix("." + ext) }
                .map { URL(fileURLWithPath: "\(folder)/\($0)") }
                .min { size($0) < size($1) }
        }.first
    }

    static func sample(_ format: FileFormat, in dir: URL) throws -> URL? {
        let found = format == .ttf
            ? systemFont("ttf", preferring: ["NotoSansLydian-Regular.ttf", "Arial.ttf", "Geneva.ttf"])
            : systemFont("otf", preferring: ["NotoSerifYezidi-Regular.otf", "NotoSansTifinagh-Regular.otf"])
        guard let found else { return nil }
        let copy = dir.appendingPathComponent("sample.\(format.fileExtension)")
        try FileManager.default.copyItem(at: found, to: copy)
        return copy
    }

    static func glyphCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        return CTFontGetGlyphCount(CTFontCreateWithFontDescriptor(descriptor, 12, nil))
    }

    static let signatures: [FileFormat: UInt32] = [.ttf: FontEngine.Signature.trueType, .otf: FontEngine.Signature.cff,
                                                   .woff: FontEngine.Signature.woff, .woff2: FontEngine.Signature.woff2]

    /// TTF and OTF to every other format, and each WOFF / WOFF2 made on the way to every other format too.
    @Test(arguments: [FileFormat.ttf, .otf])
    func convertsToEveryOtherFont(source: FileFormat) async throws {
        let dir = try Fixtures.tempDirectory()
        guard let input = try Self.sample(source, in: dir) else { return }
        let glyphs = try #require(Self.glyphCount(input))
        var wrapped: [URL] = []
        for target in Catalog.convertTargets(for: source) where FontEngine.requirement(source, target) == nil {
            let output = try #require(try await run(.convert(target), [input]).outputs.first, "\(source) → \(target)")
            #expect(AFM.signature(output) == Self.signatures[target], "\(source) → \(target)")
            #expect(Self.glyphCount(output) == glyphs, "\(source) → \(target)")
            if target == .woff || target == .woff2 { wrapped.append(output) }
        }
        for font in wrapped {
            let format = try #require(FileFormat.detect(font))
            // A wrapped font keeps the source's outlines, so TrueType ↔ OpenType still needs fontTools.
            for target in Catalog.convertTargets(for: format)
            where FontEngine.requirement(format, target) == nil && FontEngine.requirement(source, target) == nil {
                let output = try #require(try await run(.convert(target), [font], into: try Fixtures.tempDirectory()).outputs.first, "\(format) → \(target)")
                #expect(AFM.signature(output) == Self.signatures[target], "\(source) → \(format) → \(target)")
                #expect(Self.glyphCount(output) == glyphs, "\(source) → \(format) → \(target)")
            }
        }
    }

    /// WOFF keeps every table byte for byte.
    @Test func woffRoundTripIsLossless() async throws {
        let dir = try Fixtures.tempDirectory()
        guard let input = try Self.sample(.ttf, in: dir) else { return }
        let woff = try #require(try await run(.convert(.woff), [input]).outputs.first)
        #expect(size(woff) < size(input))
        let original = try FontEngine.tables(of: try Data(contentsOf: input), name: "")
        let restoredFont = try await FontEngine.sfnt(woff)
        let restored = try FontEngine.tables(of: restoredFont, name: "")
        #expect(restored.flavor == original.flavor)
        // head.checkSumAdjustment (bytes 8..<12) is recomputed for the rebuilt file; everything else is identical.
        func comparable(_ tables: [FontEngine.Table]) -> [UInt32: Data] {
            Dictionary(uniqueKeysWithValues: tables.map { table in
                var data = table.data
                if table.tag == FontEngine.Signature.head { data.replaceSubrange(8..<12, with: [0, 0, 0, 0]) }
                return (table.tag, data)
            })
        }
        #expect(comparable(restored.tables) == comparable(original.tables))
        // A valid sfnt sums to 0xB1B0AFBA.
        #expect(FontEngine.checksum(restoredFont, isHead: false) == 0xB1B0_AFBA)
    }

    @Test func zlibStreamsAreStandard() throws {
        let data = Data(String(repeating: "glyph ", count: 1000).utf8)
        let stream = try #require(FontEngine.zlibCompress(data))
        #expect(stream.prefix(2) == Data([0x78, 0x9C]))
        #expect(try FontEngine.zlibDecompress(stream, length: data.count, name: "") == data)
        #expect(FontEngine.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func requirementsNameTheMissingTool() {
        #expect((FontEngine.requirement(.ttf, .woff2) == nil) == (Engines.woff2Compress != nil))
        #expect((FontEngine.requirement(.woff2, .ttf) == nil) == (Engines.woff2Decompress != nil))
        #expect((FontEngine.requirement(.ttf, .otf) == nil) == (Engines.fonttools != nil))
        #expect(FontEngine.requirement(.ttf, .woff) == nil)
    }
}

// MARK: - 3D models

@Suite struct ModelConversionTests {
    static let cube = """
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    v 0 0 1
    v 1 0 1
    v 1 1 1
    v 0 1 1
    f 1 4 3 2
    f 5 6 7 8
    f 1 2 6 5
    f 2 3 7 6
    f 3 4 8 7
    f 4 1 5 8

    """

    static func vertices(_ object: MDLObject) -> Int {
        ((object as? MDLMesh)?.vertexCount ?? 0) + object.children.objects.reduce(0) { $0 + vertices($1) }
    }

    static func check(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        let asset = MDLAsset(url: url)
        #expect(asset.count > 0, "\(url.lastPathComponent)", sourceLocation: sourceLocation)
        #expect((0..<asset.count).reduce(0) { $0 + vertices(asset.object(at: $1)) } >= 8, "\(url.lastPathComponent)", sourceLocation: sourceLocation)
        let box = asset.boundingBox
        #expect(abs(box.maxBounds.x - 1) < 1e-4 && abs(box.maxBounds.y - 1) < 1e-4 && abs(box.minBounds.z) < 1e-4,
                "\(url.lastPathComponent): \(box.minBounds) … \(box.maxBounds)", sourceLocation: sourceLocation)
    }

    /// The OBJ cube to every format, then each of those to every other.
    @Test func convertsBetweenEveryModelFormat() async throws {
        let dir = try Fixtures.tempDirectory()
        let obj = dir.appendingPathComponent("cube.obj")
        try Self.cube.write(to: obj, atomically: true, encoding: .utf8)
        var made = [obj]
        for target in Catalog.convertTargets(for: .obj) where ModelEngine.canExport(target) {
            let output = try #require(try await run(.convert(target), [obj]).outputs.first, "obj → \(target)")
            #expect(output.lastPathComponent == "cube.\(target.fileExtension)")
            Self.check(output)
            made.append(output)
        }
        #expect(made.count == 5)
        for source in made.dropFirst() {
            let format = try #require(FileFormat.detect(source))
            for target in Catalog.convertTargets(for: format) where ModelEngine.canExport(target) {
                let output = try #require(try await run(.convert(target), [source], into: try Fixtures.tempDirectory()).outputs.first, "\(format) → \(target)")
                Self.check(output)
            }
        }
    }

    /// USDZ: uncompressed ZIP, binary USD layer first, every entry's data 64-byte aligned.
    @Test func usdzFollowsThePackageRules() async throws {
        let dir = try Fixtures.tempDirectory()
        let obj = dir.appendingPathComponent("cube.obj")
        try Self.cube.write(to: obj, atomically: true, encoding: .utf8)
        let usdz = try #require(try await run(.convert(.usdz), [obj]).outputs.first)
        let bytes = [UInt8](try Data(contentsOf: usdz))
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var offset = 0
        var names: [String] = []
        while offset + 30 <= bytes.count, u32(offset) == 0x0403_4B50 {
            #expect(u16(offset + 8) == 0)  // stored
            let nameLength = u16(offset + 26), extraLength = u16(offset + 28)
            names.append(String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self))
            let data = offset + 30 + nameLength + extraLength
            #expect(data % 64 == 0)
            offset = data + u32(offset + 18)
        }
        #expect(names.first == "cube.usdc")
        #expect(Array(bytes[(64)..<(64 + 8)]) == Array("PXR-USDC".utf8))
        let checker = URL(fileURLWithPath: "/usr/bin/usdchecker")
        if FileManager.default.isExecutableFile(atPath: checker.path) {
            let result = try await ExternalTool.run(checker, [usdz.path], timeout: 120)
            #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self)) \(result.stderr)")
        }
    }
}
