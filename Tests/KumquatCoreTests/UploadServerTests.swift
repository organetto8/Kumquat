import Foundation
import Network
import Testing
@testable import KumquatCore

@Suite struct UploadServerTests {
    @Test func safeNames() {
        #expect(UploadServer.safeName("../../etc/passwd") == "passwd")
        #expect(UploadServer.safeName("C:\\Users\\me\\photo.jpg") == "photo.jpg")
        #expect(UploadServer.safeName(".zshrc") == "zshrc")
        #expect(UploadServer.safeName("a:b.txt") == "a-b.txt")
        #expect(UploadServer.safeName("bad\nname\u{0}.txt") == "badname.txt")
        #expect(UploadServer.safeName(" IMG_0001.HEIC ") == "IMG_0001.HEIC")
        #expect(!UploadServer.safeName("").isEmpty && !UploadServer.safeName("...").hasPrefix("."))
        let long = UploadServer.safeName(String(repeating: "è", count: 300) + ".jpg")
        #expect(long.utf8.count <= 200 && long.hasSuffix(".jpg"))
    }

    @Test func receivesFilesIntoTheFolder() async throws {
        let folder = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = EventLog()
        let server = try UploadServer(folder: folder, token: "0123abcd") { events.add($0) }
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)/0123abcd/")!

        let (page, pageResponse) = try await URLSession.shared.data(from: base)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains(folder.lastPathComponent))
        let (_, wrongToken) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ffff/")!)
        #expect((wrongToken as? HTTPURLResponse)?.statusCode == 404)

        let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let first = try await upload(big, name: "../photo.jpg", to: base)
        let second = try await upload(Data("x".utf8), name: "photo.jpg", to: base)
        let empty = try await upload(Data(), name: "empty.txt", to: base)
        #expect(first.status == 200 && first.text == "photo.jpg")
        #expect(second.status == 200 && second.text == "photo 2.jpg")
        #expect(empty.status == 200 && empty.text == "empty.txt")
        #expect(try Data(contentsOf: folder.appendingPathComponent("photo.jpg")) == big)
        // Nothing half-written or hidden stays behind, and nothing escaped the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["empty.txt", "photo 2.jpg", "photo.jpg"])
        let quarantine = try folder.appendingPathComponent("photo.jpg").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?["LSQuarantineAgentName"] as? String == "Kumquat")
        #expect(events.received.map(\.lastPathComponent).sorted() == ["empty.txt", "photo 2.jpg", "photo.jpg"])
    }

    @Test func dropsAFileCutHalfway() async throws {
        let folder = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = EventLog()
        let server = try UploadServer(folder: folder, token: "t") { events.add($0) }
        let port = try await server.start()
        defer { server.stop() }

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        let head = "POST /t/upload?name=video.mov HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n"
        connection.send(content: Data(head.utf8) + Data(repeating: 7, count: 5000), completion: .idempotent)
        try await wait { events.started == 1 }
        connection.cancel()
        try await wait { events.failed == 1 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    private func upload(_ body: Data, name: String, to base: URL) async throws -> (status: Int, text: String) {
        var components = URLComponents(url: base.appendingPathComponent("upload"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UploadServer.Event] = []

    func add(_ event: UploadServer.Event) { lock.withLock { events.append(event) } }

    var received: [URL] { lock.withLock { events.compactMap { if case .received(let url) = $0 { url } else { nil } } } }
    var started: Int { lock.withLock { events.filter { if case .started = $0 { true } else { false } }.count } }
    var failed: Int { lock.withLock { events.filter { if case .failed = $0 { true } else { false } }.count } }
}
