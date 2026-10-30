import Foundation
import ModelIO

/// 3D models through Model I/O: OBJ, STL, PLY, USDZ, USD (text .usda out; .usd and binary .usdc read too).
/// Model I/O can't write USDZ, so that's a binary USD layer packed per the USDZ spec: an uncompressed ZIP
/// whose entries' data start on 64-byte boundaries, the layer first.
public enum ModelEngine {
    static let usdcat = URL(fileURLWithPath: "/usr/bin/usdcat")

    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        guard target == .usdz else {
            try await runBlocking {
                // OBJ also gets its materials as "<name>.mtl" next to it.
                try export(try load(input), to: output, as: target)
                if target == .usda { try addMetersPerUnit(output) }
            }
            return
        }
        // The layer is named after the output: that name becomes its default prim.
        let folder = try ArchiveEngine.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = output.deletingPathExtension().lastPathComponent
        let layer = folder.appendingPathComponent(name + ".usdc")
        if FileManager.default.isExecutableFile(atPath: usdcat.path) {
            // Text first, to add the stage's units, then the system's usdcat makes it binary.
            let text = folder.appendingPathComponent(name + ".usda")
            try await runBlocking {
                try export(try load(input), to: text, as: .usda)
                try addMetersPerUnit(text)
            }
            try await ExternalTool.check(usdcat, [text.path, "-o", layer.path], timeout: 300)
            try FileManager.default.removeItem(at: text)
        } else {
            try await runBlocking { try export(try load(input), to: layer, as: .usdz) }
        }
        try await runBlocking { try package(folder, layer: layer, output: output) }
    }

    static func canExport(_ format: FileFormat) -> Bool {
        MDLAsset.canExportFileExtension(format == .usdz ? "usdc" : format.fileExtension)
    }

    static func load(_ input: URL) throws -> MDLAsset {
        let asset = MDLAsset(url: input)
        // Model I/O doesn't throw on unreadable files: it just yields an empty asset.
        guard asset.count > 0 else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        return asset
    }

    static func export(_ asset: MDLAsset, to url: URL, as format: FileFormat) throws {
        do { try asset.export(to: url) } catch { throw KumquatError.cannotEncode(format.displayName) }
    }

    /// Model I/O writes no `metersPerUnit`, which USD's validator (and AR Quick Look's) asks for.
    /// 0.01 is USD's own fallback (centimetres), so nothing changes size.
    static func addMetersPerUnit(_ usda: URL) throws {
        var text = try String(contentsOf: usda, encoding: .utf8)
        guard text.hasPrefix("#usda"), !text.contains("metersPerUnit"), let firstLine = text.firstIndex(of: "\n") else { return }
        let header = text.range(of: "\n(\n")
        let firstPrim = text.range(of: "\ndef ")?.lowerBound ?? text.endIndex
        if let header, header.lowerBound == firstLine, header.upperBound <= firstPrim {
            text.insert(contentsOf: "    metersPerUnit = 0.01\n", at: header.upperBound)
        } else {
            text.insert(contentsOf: "\n(\n    metersPerUnit = 0.01\n)", at: firstLine)
        }
        try text.write(to: usda, atomically: true, encoding: .utf8)
    }

    /// Stores the layer, and anything written beside it (textures), in a 64-byte aligned ZIP, layer first.
    static func package(_ folder: URL, layer: URL, output: URL) throws {
        let others = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { name in
            var isDirectory: ObjCBool = false
            return name != layer.lastPathComponent
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
        var zip = ZipWriter()
        for name in [layer.lastPathComponent] + others {
            zip.add(name, try Data(contentsOf: folder.appendingPathComponent(name)), store: true, alignment: 64)
        }
        try zip.write(to: output)
    }
}
