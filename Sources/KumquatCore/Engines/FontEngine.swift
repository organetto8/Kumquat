import Compression
import Foundation

/// TTF · OTF · WOFF · WOFF2. WOFF is wrapped natively; WOFF2 uses Google's woff2 tools; TrueType ↔ CFF outlines use fontTools.
/// The outlines only change when the target says so: TTF means TrueType (glyf) outlines, OTF means CFF;
/// WOFF and WOFF2 wrap whatever the source holds.
public enum FontEngine {
    enum Outlines { case trueType, cff }

    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        var font = try await sfnt(input)
        let wanted: Outlines? = switch target {
        case .ttf: .trueType
        case .otf: .cff
        default: nil
        }
        if let wanted, outlines(of: font) != wanted {
            font = try await convertOutlines(font, to: wanted)
        }
        let data: Data
        switch target {
        case .woff: data = try woffEncode(font, name: input.lastPathComponent)
        case .woff2: data = try await woff2Encode(font)
        default: data = font
        }
        try data.write(to: output, options: .atomic)
    }

    /// What a pair needs that this Mac lacks, or `nil`. (A WOFF or WOFF2 source may still need
    /// fontTools for TTF/OTF output, but only its content can tell: that is reported when it runs.)
    static func requirement(_ input: FileFormat, _ target: FileFormat) -> String? {
        if input == .woff2, Engines.woff2Decompress == nil { return Engines.brewHint("woff2", "woff2") }
        if target == .woff2, Engines.woff2Compress == nil { return Engines.brewHint("woff2", "woff2") }
        if Set([input, target]) == [.ttf, .otf], Engines.fonttools == nil { return Engines.brewHint("fontTools", "fonttools") }
        return nil
    }

    /// The font as a plain sfnt (TrueType/OpenType), whatever wraps it; recognised by content, not name.
    static func sfnt(_ input: URL) async throws -> Data {
        let data = try Data(contentsOf: input)
        guard data.count >= 12 else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        switch readU32([UInt8](data.prefix(4)), 0) {
        case Signature.woff: return try woffDecode(data, name: input.lastPathComponent)
        case Signature.woff2: return try await woff2Decode(input)
        case Signature.collection: throw KumquatError.unsupported(String(localized: "Font collections"))
        default:
            _ = try tables(of: data, name: input.lastPathComponent)  // validates
            return data
        }
    }

    static func outlines(of font: Data) -> Outlines {
        readU32([UInt8](font.prefix(4)), 0) == Signature.cff ? .cff : .trueType
    }

    enum Signature {
        static let trueType: UInt32 = 0x0001_0000
        static let apple: UInt32 = 0x7472_7565  // "true"
        static let cff: UInt32 = 0x4F54_544F  // "OTTO"
        static let woff: UInt32 = 0x774F_4646  // "wOFF"
        static let woff2: UInt32 = 0x774F_4632  // "wOF2"
        static let collection: UInt32 = 0x7474_6366  // "ttcf"
        static let head: UInt32 = 0x6865_6164  // "head"
    }
}

// MARK: - sfnt tables

extension FontEngine {
    struct Table {
        let tag: UInt32
        let data: Data
    }

    static func tables(of font: Data, name: String) throws -> (flavor: UInt32, tables: [Table]) {
        let bytes = [UInt8](font)
        guard bytes.count >= 12 else { throw KumquatError.cannotDecode(name) }
        let flavor = readU32(bytes, 0)
        guard [Signature.trueType, Signature.apple, Signature.cff].contains(flavor) else { throw KumquatError.cannotDecode(name) }
        let count = Int(readU16(bytes, 4))
        guard count > 0, bytes.count >= 12 + 16 * count else { throw KumquatError.cannotDecode(name) }
        var tables: [Table] = []
        for index in 0..<count {
            let record = 12 + 16 * index
            let offset = Int(readU32(bytes, record + 8)), length = Int(readU32(bytes, record + 12))
            guard offset + length <= bytes.count else { throw KumquatError.cannotDecode(name) }
            tables.append(Table(tag: readU32(bytes, record), data: Data(bytes[offset..<offset + length])))
        }
        return (flavor, tables)
    }

    /// A standard sfnt: tables in tag order, 4-byte aligned, fresh checksums and head.checkSumAdjustment.
    static func assemble(flavor: UInt32, tables: [Table]) -> Data {
        let sorted = tables.sorted { $0.tag < $1.tag }
        var power = 1, exponent = 0
        while power * 2 <= sorted.count { power *= 2; exponent += 1 }
        var out = Data()
        putU32(&out, flavor)
        putU16(&out, UInt16(sorted.count))
        putU16(&out, UInt16(power * 16))
        putU16(&out, UInt16(exponent))
        putU16(&out, UInt16(sorted.count * 16 - power * 16))
        var offset = 12 + 16 * sorted.count
        var headOffset: Int?
        for table in sorted {
            putU32(&out, table.tag)
            putU32(&out, checksum(table.data, isHead: table.tag == Signature.head))
            putU32(&out, UInt32(offset))
            putU32(&out, UInt32(table.data.count))
            if table.tag == Signature.head { headOffset = offset }
            offset += padded(table.data.count)
        }
        for table in sorted {
            out.append(table.data)
            out.append(Data(count: padded(table.data.count) - table.data.count))
        }
        // The adjustment makes the whole file's checksum 0xB1B0AFBA.
        if let headOffset, out.count >= headOffset + 12 {
            out.replaceSubrange(headOffset + 8..<headOffset + 12, with: [0, 0, 0, 0])
            var adjustment = Data()
            putU32(&adjustment, 0xB1B0_AFBA &- checksum(out, isHead: false))
            out.replaceSubrange(headOffset + 8..<headOffset + 12, with: adjustment)
        }
        return out
    }

    /// Sum of big-endian 32-bit words (zero-padded); head's checkSumAdjustment counts as 0.
    static func checksum(_ data: Data, isHead: Bool) -> UInt32 {
        var sum: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            while index < buffer.count {
                var word: UInt32 = 0
                for byte in 0..<4 {
                    let position = index + byte
                    let value = position < buffer.count && !(isHead && (8..<12).contains(position)) ? UInt32(buffer[position]) : 0
                    word = word << 8 | value
                }
                sum = sum &+ word
                index += 4
            }
        }
        return sum
    }

    static func padded(_ length: Int) -> Int { (length + 3) & ~3 }

    static func readU16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }

    static func readU32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard bytes.count >= at + 4 else { return 0 }
        return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    static func putU16(_ data: inout Data, _ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }

    static func putU32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}

// MARK: - WOFF 1.0

extension FontEngine {
    /// 44-byte header, a 20-byte entry per table, then each table zlib-compressed (stored as is
    /// when that isn't smaller), 4-byte aligned. No metadata or private block.
    static func woffEncode(_ font: Data, name: String) throws -> Data {
        let sfnt = try tables(of: font, name: name)
        let flavor = sfnt.flavor
        let sorted = sfnt.tables.sorted { $0.tag < $1.tag }
        var directory = Data(), body = Data()
        var offset = 44 + 20 * sorted.count
        var sfntSize = 12 + 16 * sorted.count
        for table in sorted {
            var payload = table.data
            if let packed = zlibCompress(table.data), packed.count < table.data.count { payload = packed }
            putU32(&directory, table.tag)
            putU32(&directory, UInt32(offset))
            putU32(&directory, UInt32(payload.count))
            putU32(&directory, UInt32(table.data.count))
            putU32(&directory, checksum(table.data, isHead: table.tag == Signature.head))
            body.append(payload)
            body.append(Data(count: padded(payload.count) - payload.count))
            offset += padded(payload.count)
            sfntSize += padded(table.data.count)
        }
        // The font's version (head.fontRevision, 16.16) goes into the header.
        let revision = sorted.first { $0.tag == Signature.head }.map { readU32([UInt8]($0.data), 4) } ?? 0x0001_0000
        var header = Data()
        putU32(&header, Signature.woff)
        putU32(&header, flavor)
        putU32(&header, UInt32(44 + directory.count + body.count))
        putU16(&header, UInt16(sorted.count))
        putU16(&header, 0)
        putU32(&header, UInt32(sfntSize))
        putU16(&header, UInt16(revision >> 16))
        putU16(&header, UInt16(revision & 0xFFFF))
        for _ in 0..<5 { putU32(&header, 0) }  // metaOffset, metaLength, metaOrigLength, privOffset, privLength
        return header + directory + body
    }

    static func woffDecode(_ woff: Data, name: String) throws -> Data {
        let bytes = [UInt8](woff)
        guard bytes.count >= 44, readU32(bytes, 0) == Signature.woff else { throw KumquatError.cannotDecode(name) }
        let flavor = readU32(bytes, 4)
        let count = Int(readU16(bytes, 12))
        guard count > 0, bytes.count >= 44 + 20 * count else { throw KumquatError.cannotDecode(name) }
        var tables: [Table] = []
        for index in 0..<count {
            let entry = 44 + 20 * index
            let offset = Int(readU32(bytes, entry + 4)), stored = Int(readU32(bytes, entry + 8)), length = Int(readU32(bytes, entry + 12))
            guard stored <= length, offset + stored <= bytes.count else { throw KumquatError.cannotDecode(name) }
            let payload = Data(bytes[offset..<offset + stored])
            let data = stored < length ? try zlibDecompress(payload, length: length, name: name) : payload
            tables.append(Table(tag: readU32(bytes, entry), data: data))
        }
        return assemble(flavor: flavor, tables: tables)
    }

    /// An RFC 1950 zlib stream (2-byte header, DEFLATE data, Adler-32), as WOFF stores tables.
    /// The Compression framework's ZLIB is the raw DEFLATE part only: the wrapper is added here.
    static func zlibCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var stream = Data([0x78, 0x9C])  // DEFLATE, 32K window, default level; header checksum
        stream.append(deflated.prefix(written))
        putU32(&stream, adler32(data))
        return stream
    }

    static func zlibDecompress(_ stream: Data, length: Int, name: String) throws -> Data {
        let bytes = [UInt8](stream)
        // Method 8 (DEFLATE), valid header check, no preset dictionary.
        guard length > 0, bytes.count > 6, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0, bytes[1] & 0x20 == 0 else {
            throw KumquatError.cannotDecode(name)
        }
        var out = Data(count: length)
        let written = out.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, length, src.baseAddress! + 2, bytes.count - 6, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == length, adler32(out) == readU32(bytes, bytes.count - 4) else { throw KumquatError.cannotDecode(name) }
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            // 5552 bytes is the longest run before the sums could overflow 32 bits.
            while index < buffer.count {
                let end = min(index + 5552, buffer.count)
                for byte in buffer[index..<end] {
                    a += UInt32(byte)
                    b += a
                }
                a %= 65521
                b %= 65521
                index = end
            }
        }
        return b << 16 | a
    }
}

// MARK: - WOFF2 (woff2 tools) and outlines (fontTools)

extension FontEngine {
    /// woff2_compress writes "<name>.woff2" next to its input, so it works in a private folder.
    static func woff2Encode(_ font: Data) async throws -> Data {
        guard let tool = Engines.woff2Compress else { throw KumquatError.noResult(Engines.brewHint("woff2", "woff2")) }
        let folder = try ArchiveEngine.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("font.ttf")
        try font.write(to: source)
        try await ExternalTool.check(tool, [source.path], timeout: 600)
        return try Data(contentsOf: folder.appendingPathComponent("font.woff2"))
    }

    static func woff2Decode(_ input: URL) async throws -> Data {
        guard let tool = Engines.woff2Decompress else { throw KumquatError.noResult(Engines.brewHint("woff2", "woff2")) }
        let folder = try ArchiveEngine.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("font.woff2")
        try FolderEngine.clone(input, to: source)
        try await ExternalTool.check(tool, [source.path], timeout: 600)
        let font = try Data(contentsOf: folder.appendingPathComponent("font.ttf"))
        guard font.count >= 12 else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        return font
    }

    /// Redraws every glyph with the other outline technology through fontTools: cubic CFF curves become
    /// quadratic TrueType ones (cu2qu, within 1 unit) or the other way round (exact). TrueType hinting is
    /// dropped; a variable font is pinned to its default instance first.
    static func convertOutlines(_ font: Data, to outlines: Outlines) async throws -> Data {
        guard let python = fontToolsPython else { throw KumquatError.noResult(Engines.brewHint("fontTools", "fonttools")) }
        let folder = try ArchiveEngine.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.font"), result = folder.appendingPathComponent("result.font")
        try font.write(to: source)
        // -I: isolated mode, nothing from the environment or the current folder is imported.
        try await ExternalTool.check(python, ["-I", "-c", outlineScript, outlines == .cff ? "cff" : "glyf", source.path, result.path], timeout: 600)
        return try Data(contentsOf: result)
    }

    /// The interpreter fontTools is installed for: the one the `fonttools` script's shebang names
    /// (`#!/path/python`, `#!/usr/bin/env python3`, or pip's `#!/bin/sh` + `'''exec' "/path/python"` trampoline).
    static var fontToolsPython: URL? {
        guard let script = Engines.fonttools, let handle = try? FileHandle(forReadingFrom: script) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 1024)) ?? Data(), as: UTF8.self)
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("#!") else { return nil }
        let words = first.dropFirst(2).split(separator: " ").map(String.init)
        guard let program = words.first else { return nil }
        if program.hasSuffix("/env") {
            return words.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }.flatMap { ExternalTool.locate($0) }
        }
        if program.hasSuffix("/sh"), lines.count > 1, let start = lines[1].range(of: "exec' \"") {
            let rest = lines[1][start.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return executable(String(rest[..<end])) }
        }
        return executable(program)
    }

    private static func executable(_ path: String) -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// `python -c <script> glyf|cff <source> <destination>`.
    static let outlineScript = #"""
    import sys
    from fontTools.ttLib import TTFont, newTable

    mode, source, destination = sys.argv[1:4]
    font = TTFont(source)
    if "fvar" in font:
        from fontTools.varLib import instancer
        font = instancer.instantiateVariableFont(font, {axis.axisTag: None for axis in font["fvar"].axes})
    order = font.getGlyphOrder()
    glyphs = font.getGlyphSet()

    if mode == "glyf":
        from fontTools.pens.cu2quPen import Cu2QuPen
        from fontTools.pens.ttGlyphPen import TTGlyphPen
        quadratic = {}
        for name in order:
            pen = TTGlyphPen(glyphs)
            glyphs[name].draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
            quadratic[name] = pen.glyph()
        for tag in ("CFF ", "CFF2", "VORG"):
            if tag in font:
                del font[tag]
        font["loca"] = newTable("loca")
        font["glyf"] = glyf = newTable("glyf")
        glyf.glyphOrder = order
        glyf.glyphs = quadratic
        glyf.compile(font)
        hmtx = font["hmtx"]
        for name, glyph in glyf.glyphs.items():
            if hasattr(glyph, "xMin"):
                hmtx[name] = (hmtx[name][0], glyph.xMin)
        font["head"].glyphDataFormat = 0
        font["maxp"] = maxp = newTable("maxp")
        maxp.tableVersion = 0x00010000
        for field in ("maxTwilightPoints", "maxStorage", "maxFunctionDefs", "maxInstructionDefs", "maxStackElements", "maxSizeOfInstructions"):
            setattr(maxp, field, 0)
        maxp.maxZones = 1
        maxp.maxComponentElements = max(len(getattr(g, "components", None) or []) for g in glyf.glyphs.values())
        maxp.compile(font)
        post = font["post"]
        post.formatType = 2.0
        post.extraNames = []
        post.mapping = {}
        post.glyphOrder = order
        try:
            post.compile(font)
        except OverflowError:
            post.formatType = 3.0
        font.sfntVersion = "\0\1\0\0"
    else:
        from fontTools.fontBuilder import FontBuilder
        from fontTools.pens.t2CharStringPen import T2CharStringPen
        hmtx = font["hmtx"]
        charStrings = {}
        for name in order:
            pen = T2CharStringPen(hmtx[name][0], glyphs)
            glyphs[name].draw(pen)
            charStrings[name] = pen.getCharString()
        for tag in ("glyf", "loca", "fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "gvar", "cvar"):
            if tag in font:
                del font[tag]
        names = font["name"]
        psName = names.getDebugName(6) or "Untitled"
        info = {"FullName": names.getDebugName(4) or psName, "FamilyName": names.getDebugName(1) or psName}
        builder = FontBuilder(font=font)
        builder.isTTF = False
        builder.setupCFF(psName, info, charStrings, {})
        font["maxp"].tableVersion = 0x00005000
        font["post"].formatType = 3.0
        font.sfntVersion = "OTTO"
    font.save(destination)
    """#
}
