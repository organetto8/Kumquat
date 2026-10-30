import Compression
import Foundation

/// In-memory ZIP writer for the OOXML / ODF / EPUB packages Kumquat produces natively.
/// Entries are deflated with the Compression framework (raw DEFLATE) unless storing is smaller
/// or explicitly requested (EPUB/ODF `mimetype` must be stored first).
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var entries: UInt16 = 0

    mutating func add(_ path: String, _ text: String, store: Bool = false) {
        add(path, Data(text.utf8), store: store)
    }

    /// `alignment` > 0 pads the local header's extra field so the entry's data starts at a
    /// multiple of it (USDZ needs 64-byte aligned, stored entries).
    mutating func add(_ path: String, _ content: Data, store: Bool = false, alignment: Int = 0) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        var payload = content
        var method: UInt16 = 0
        if !store, content.count > 64, let deflated = Self.deflate(content), deflated.count < content.count {
            payload = deflated
            method = 8
        }
        let offset = UInt32(body.count)
        var extra = Data()
        if alignment > 0 {
            // An extra field needs a 4-byte header (id + size), so padding is 0 or at least 4 bytes.
            var padding = (alignment - (body.count + 30 + name.count) % alignment) % alignment
            if padding > 0, padding < 4 { padding += alignment }
            if padding > 0 {
                extra.append(le16: 0x1986)  // the id Pixar's usdzip uses for its padding
                extra.append(le16: UInt16(padding - 4))
                extra.append(Data(count: padding - 4))
            }
        }
        var local = Data()
        local.append(le32: 0x0403_4B50)
        local.append(le16: 20)
        local.append(le16: 0x0800)  // UTF-8 names
        local.append(le16: method)
        local.append(le16: 0)  // time
        local.append(le16: 0x21)  // date: 1980-01-01
        local.append(le32: crc)
        local.append(le32: UInt32(payload.count))
        local.append(le32: UInt32(content.count))
        local.append(le16: UInt16(name.count))
        local.append(le16: UInt16(extra.count))
        local.append(name)
        local.append(extra)
        body.append(local)
        body.append(payload)

        directory.append(le32: 0x0201_4B50)
        directory.append(le16: 20)
        directory.append(le16: 20)
        directory.append(le16: 0x0800)
        directory.append(le16: method)
        directory.append(le16: 0)
        directory.append(le16: 0x21)
        directory.append(le32: crc)
        directory.append(le32: UInt32(payload.count))
        directory.append(le32: UInt32(content.count))
        directory.append(le16: UInt16(name.count))
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le32: 0)
        directory.append(le32: offset)
        directory.append(name)
        entries += 1
    }

    func finish() -> Data {
        var out = body
        out.append(directory)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: entries)
        out.append(le16: entries)
        out.append(le32: UInt32(directory.count))
        out.append(le32: UInt32(body.count))
        out.append(le16: 0)
        return out
    }

    func write(to url: URL) throws { try finish().write(to: url, options: .atomic) }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// Unpacks ZIP-based packages (DOCX, XLSX, ODS, EPUB) through the system's libarchive.
enum PackageReader {
    static func extract(_ url: URL) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await ExternalTool.check(Engines.tar, ["-xf", url.path, "-C", directory.path])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw KumquatError.cannotOpen(url.lastPathComponent)
        }
        return directory
    }
}

// MARK: - XML

func xmlEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
        default:
            // XML 1.0 forbids most control characters.
            if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
        }
    }
    return out
}

/// Tiny DOM, enough for spreadsheet / EPUB package parts.
final class XMLElement {
    let name: String
    let attributes: [String: String]
    var children: [XMLElement] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Name without namespace prefix.
    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    func attribute(_ local: String) -> String? {
        attributes[local] ?? attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value
    }

    func child(_ local: String) -> XMLElement? { children.first { $0.localName == local } }

    func all(_ local: String) -> [XMLElement] {
        var found: [XMLElement] = []
        var stack = [self]
        while let node = stack.popLast() {
            if node.localName == local { found.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// Concatenated text of this node and its descendants, in document order.
    var deepText: String { text + children.map(\.deepText).joined() }

    static func parse(_ data: Data) -> XMLElement? {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return delegate.root
    }

    static func parse(contentsOf url: URL) -> XMLElement? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLElement?
    private var stack: [XMLElement] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let element = XMLElement(name: name, attributes: attributes)
        stack.last?.children.append(element)
        if root == nil { root = element }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Text is attached to the innermost open element (sufficient for leaf-text formats).
        stack.last?.text += string
    }
}
