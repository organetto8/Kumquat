import AppKit
import CoreImage.CIFilterBuiltins
import KumquatCore
import Network
import SwiftUI

/// Wi-Fi Share: a tiny HTTP server on the local network plus a QR code to scan with a phone.
/// Nothing leaves the network; it stops when the window closes or after 15 minutes. Files are
/// only served under a random token in the link, so other devices on the network can't fetch them.
final class WiFiShare {
    private var server: FileServer?
    private var panel: NSPanel?
    private var stopWork: DispatchWorkItem?
    private var staging: URL?

    static let lifetime: TimeInterval = 15 * 60

    func share(_ files: [URL], failure: @escaping (String) -> Void) {
        stop()
        guard let address = Self.localAddress() else {
            failure(String(localized: "Connect this Mac to a Wi-Fi or wired network first."))
            return
        }
        Task {
            do {
                // Folders travel as zips: a phone browser can only download files.
                var items: [URL] = []
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kumquat Share \(UUID().uuidString)", isDirectory: true)
                for file in files {
                    guard Catalog.isFolder(file) else { items.append(file); continue }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let zip = folder.appendingPathComponent(file.lastPathComponent + ".zip")
                    try await ArchiveEngine.archive([file], output: zip)
                    items.append(zip)
                }
                staging = folder
                let token = Self.token()
                let server = try FileServer(files: items, token: token)
                let port = try await server.start()
                self.server = server
                show(url: URL(string: "http://\(address):\(port)/\(token)/")!, files: items)
            } catch {
                failure(error.localizedDescription)
                stop()
            }
        }
    }

    func stop() {
        stopWork?.cancel()
        server?.stop()
        server = nil
        panel?.orderOut(nil)
        panel = nil
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
    }

    private func show(url: URL, files: [URL]) {
        let view = WiFiShareView(url: url, subject: ActionPerformer.subject(files), qr: Self.qrCode(url.absoluteString)) { [weak self] in self?.stop() }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = ActionKind.wifiShare.title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 300, height: 400))
        panel.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
    }

    /// 128 random bits as hex. The link works as the password: anyone who can reach the port still
    /// needs it. `UInt8.random` draws from the system's cryptographic generator.
    static func token() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    static func qrCode(_ text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: 220, height: 220))
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet (en0 first).
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return (found.first { $0.0 == "en0" } ?? found.first)?.1
    }
}

private struct WiFiShareView: View {
    let url: URL
    let subject: String
    let qr: NSImage
    let stop: () -> Void
    @State private var copied = false

    /// The link on two lines, breaking before the token: left to itself the text hyphenates inside
    /// the token, and a hand-copied hyphen breaks the link. Copy still copies the plain link.
    private var displayedLink: String {
        let text = url.absoluteString
        guard let host = url.host, let port = url.port else { return text }
        let origin = "http://\(host):\(port)/"
        return text.hasPrefix(origin) ? origin + "\n" + text.dropFirst(origin.count) : text
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(subject).font(.headline).lineLimit(1).truncationMode(.middle)
            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
            Text("Scan with the phone's camera, on the same network.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Address unreachable? On iPhone, allow the browser in Settings ▸ Privacy & Security ▸ Local Network, or open the link in Safari. If it still fails, the Wi-Fi keeps devices apart: connect the Mac to the phone's hotspot.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: displayedLink).font(.caption.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            Text("Sharing stops when you close this window, or in 15 minutes.").font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button("Stop Sharing", action: stop).keyboardShortcut(.cancelAction).tint(.orange)
        }
        .padding(18)
        .frame(width: 300)
    }
}

/// Serves the shared files over HTTP/1.1 under `/<token>/`: one file downloads straight away,
/// several get a list page. Every other path is a 404, the same as a wrong token.
nonisolated private final class FileServer: @unchecked Sendable {
    private let files: [URL]
    private let token: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.kumquat.wifishare")

    init(files: [URL], token: String) throws {
        self.files = files
        self.token = token
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { connection.cancel(); return }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            // "/<token>" or "/<token>/…"; anything else, including a wrong token, is not found.
            let root = "/\(self.token)"
            let rest = path == root ? "" : path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
            if let rest, rest.isEmpty, self.files.count == 1 {
                self.send(self.files[0], over: connection)
            } else if let rest, rest.isEmpty {
                self.sendIndex(over: connection)
            } else if let rest, rest.hasPrefix("f/"), let index = Int(rest.dropFirst(2).prefix { $0.isNumber }), self.files.indices.contains(index) {
                self.send(self.files[index], over: connection)
            } else {
                self.reply(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    private func sendIndex(over connection: NWConnection) {
        let rows = files.enumerated().map { index, file in
            let name = file.lastPathComponent.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let link = "/\(token)/f/\(index)/" + (file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file")
            return "<li><a href=\"\(link)\">\(name)</a></li>"
        }.joined()
        let page = """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Kumquat</title><style>body{font:17px -apple-system,system-ui,sans-serif;margin:24px}a{color:#e66a00}li{margin:12px 0}</style>
        <h1>Kumquat</h1><ul>\(rows)</ul>
        """
        reply(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(page.utf8))
    }

    private func reply(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Streams the file in 1 MB chunks.
    private func send(_ file: URL, over connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            reply(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            return
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let name = file.lastPathComponent
        // Printable ASCII only: a quote or a line break in a file name must not end the header.
        let ascii = name.unicodeScalars.map { (0x20..<0x7F).contains($0.value) && $0 != "\"" ? String($0) : "_" }.joined()
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\nConnection: close\r\n\r\n"
        @Sendable func next() {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error == nil { next() } else { try? handle.close(); connection.cancel() }
            })
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error == nil { next() } else { connection.cancel() }
        })
    }
}

nonisolated private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
