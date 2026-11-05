import CoreServices
import Foundation
import Network

/// Wi-Fi Receive's server: a phone on the local network opens `/<token>/`, picks files on that page,
/// and each one streams straight into `folder`. Only paths under the random token answer, so other
/// devices on the network can neither see the page nor send anything. Nothing is ever overwritten:
/// a name already taken gets " 2", " 3"… as in Finder.
public final class UploadServer: @unchecked Sendable {
    public enum Event: Sendable {
        /// A file started arriving, under the name it will get.
        case started(String)
        /// A file arrived whole and was saved here.
        case received(URL)
        /// A file stopped halfway (connection lost, Mac stopped receiving); nothing of it is kept.
        case failed(String)
    }

    public let folder: URL
    private let token: String
    private let onEvent: @Sendable (Event) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.kumquat.wifireceive")
    /// Open connections, so stopping also cuts uploads halfway. Touched on `queue` only.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// The longest request head accepted; browsers send about 1 KB.
    static let headLimit = 64 * 1024
    /// Room left on the disk after an upload, so a phone can't fill the Mac to the last byte.
    static let spareSpace: Int64 = 200 * 1024 * 1024

    public init(folder: URL, token: String, onEvent: @escaping @Sendable (Event) -> Void) throws {
        self.folder = folder
        self.token = token
        self.onEvent = onEvent
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts listening on a free port and returns it.
    public func start() async throws -> UInt16 {
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed:
                connection?.cancel()
            case .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    /// Collects bytes up to the blank line that ends the request head; what follows is the body's start.
    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), body: Data(buffer[end.upperBound...]), on: connection)
            } else if buffer.count > Self.headLimit || isComplete || error != nil {
                connection.cancel()
            } else {
                readHead(connection, buffer: buffer)
            }
        }
    }

    private func handle(head: String, body: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count >= 2 else { return reply(connection, "400 Bad Request", body: "Bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(request[1])
        let components = URLComponents(string: "http://kumquat" + target)
        let path = components?.percentEncodedPath ?? target
        let root = "/\(token)"
        switch (String(request[0]), path) {
        case ("GET", root):
            reply(connection, "301 Moved Permanently", body: "", extra: "Location: \(root)/\r\n")
        case ("GET", root + "/"):
            reply(connection, "200 OK", type: "text/html; charset=utf-8", body: Self.page(folderName: folder.lastPathComponent))
        case ("POST", root + "/upload"):
            let name = components?.queryItems?.first { $0.name == "name" }?.value ?? ""
            upload(Self.safeName(name), headers: headers, body: body, on: connection)
        default:
            reply(connection, "404 Not Found", body: "Not found")
        }
    }

    private func reply(_ connection: NWConnection, _ status: String, type: String = "text/plain; charset=utf-8", body: String, extra: String = "") {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Uploads

    /// One file on its way in: the body streams into a hidden file in the folder, which takes its real
    /// name only once every byte is there. Touched on the server's queue only.
    private final class Transfer: @unchecked Sendable {
        let name: String
        let length: Int64
        let partial: URL
        let handle: FileHandle
        var written: Int64 = 0

        init(name: String, length: Int64, partial: URL, handle: FileHandle) {
            self.name = name
            self.length = length
            self.partial = partial
            self.handle = handle
        }

        /// Writes what belongs to this file (a client may send more than it announced).
        func write(_ data: Data) -> Bool {
            let piece = data.prefix(Int(min(Int64(data.count), length - written)))
            guard !piece.isEmpty else { return true }
            do {
                try handle.write(contentsOf: piece)
                written += Int64(piece.count)
                return true
            } catch {
                return false
            }
        }

        func discard() {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
        }
    }

    private func upload(_ name: String, headers: [String: String], body: Data, on connection: NWConnection) {
        guard let length = headers["content-length"].flatMap({ Int64($0) }), length >= 0 else {
            return reply(connection, "411 Length Required", body: "Length required")
        }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < length + Self.spareSpace {
            return reply(connection, "507 Insufficient Storage", body: String(localized: "The Mac doesn't have enough free space."))
        }
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).kumquat-part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil), let handle = try? FileHandle(forWritingTo: partial) else {
            return reply(connection, "500 Internal Server Error", body: String(localized: "Kumquat can't write to this folder."))
        }
        let transfer = Transfer(name: name, length: length, partial: partial, handle: handle)
        onEvent(.started(name))
        // curl and some apps wait for this before sending a large body; browsers don't ask.
        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        guard transfer.write(body) else { return fail(transfer, connection) }
        transfer.written >= length ? finish(transfer, connection) : receiveBody(transfer, connection)
    }

    private func receiveBody(_ transfer: Transfer, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return transfer.discard() }
            if let data, !transfer.write(data) { return fail(transfer, connection) }
            if transfer.written >= transfer.length { return finish(transfer, connection) }
            if isComplete || error != nil { return fail(transfer, connection) }
            receiveBody(transfer, connection)
        }
    }

    private func fail(_ transfer: Transfer, _ connection: NWConnection) {
        transfer.discard()
        onEvent(.failed(transfer.name))
        connection.cancel()
    }

    private func finish(_ transfer: Transfer, _ connection: NWConnection) {
        guard (try? transfer.handle.close()) != nil, let saved = Self.place(transfer.partial, as: transfer.name, in: folder) else {
            transfer.discard()
            onEvent(.failed(transfer.name))
            return reply(connection, "500 Internal Server Error", body: String(localized: "Kumquat can't write to this folder."))
        }
        Self.quarantine(saved)
        onEvent(.received(saved))
        reply(connection, "200 OK", body: saved.lastPathComponent)
    }

    // MARK: - Names

    /// A name the phone sent, made safe for the folder: no path, no control characters, not hidden,
    /// short enough for the disk.
    public static func safeName(_ raw: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        name = name.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = String(localized: "Received File") }
        // APFS allows 255 bytes per name; trim the stem, keep a normal-looking extension.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.utf8.count > 16 ? "" : ext
            var stem = keep.isEmpty ? name : (name as NSString).deletingPathExtension
            while stem.utf8.count + (keep.isEmpty ? 0 : keep.utf8.count + 1) > 200 { stem.removeLast() }
            name = keep.isEmpty ? stem : "\(stem).\(keep)"
        }
        return name
    }

    /// Moves `file` into `folder` as `name`, or "name 2", "name 3"… if taken. `RENAME_EXCL` makes each
    /// try atomic, so two uploads with the same name can't overwrite each other.
    static func place(_ file: URL, as name: String, in folder: URL) -> URL? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for counter in 1...10_000 {
            let candidate = counter == 1 ? name : ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let destination = folder.appendingPathComponent(candidate)
            if renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// Marks the file as downloaded, as AirDrop does: Gatekeeper then checks an app or script before it first runs.
    static func quarantine(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Kumquat",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? url.setResourceValues(values)
    }

    // MARK: - Page

    /// The phone's page: pick files, watch them go one by one.
    static func page(folderName: String) -> String {
        let folder = folderName.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        let texts = [
            "sending": String(localized: "Sending…"),
            "sent": String(localized: "Sent"),
            "failed": String(localized: "Didn't arrive"),
            "lost": String(localized: "The connection to the Mac was lost."),
        ]
        // JSON escapes "/" too, so no text can close the script.
        let strings = (try? JSONSerialization.data(withJSONObject: texts)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Kumquat</title><style>
        :root{color-scheme:light dark}
        body{font:17px -apple-system,system-ui,sans-serif;margin:24px auto;padding:0 20px;max-width:560px}
        h1{font-size:22px;margin:0 0 6px;overflow-wrap:anywhere}p{margin:0 0 22px;opacity:.65}
        label{display:block;text-align:center;padding:18px;border-radius:14px;background:#e66a00;color:#fff;font-weight:600;cursor:pointer}
        input{display:none}ul{list-style:none;padding:0;margin:22px 0}li{margin:0 0 16px}
        .n{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.s{font-size:14px;opacity:.65}
        progress{width:100%;height:6px;accent-color:#e66a00}.bad{color:#d33;opacity:1}
        </style></head><body>
        <h1>\(String(localized: "Send to “\(folder)”"))</h1>
        <p>\(String(localized: "Files go straight into this folder on the Mac."))</p>
        <label>\(String(localized: "Choose Files"))<input id="pick" type="file" multiple></label>
        <ul id="list"></ul>
        <script>
        const T=\(strings),pick=document.getElementById('pick'),list=document.getElementById('list');
        let line=Promise.resolve();
        pick.onchange=()=>{
          for(const file of [...pick.files]){
            const li=document.createElement('li');
            li.innerHTML='<div class="n"></div><progress max="1" value="0"></progress><div class="s"></div>';
            li.querySelector('.n').textContent=file.name;
            list.prepend(li);
            line=line.then(()=>send(file,li));
          }
          pick.value='';
        };
        function send(file,li){
          const bar=li.querySelector('progress'),state=li.querySelector('.s');
          const bad=text=>{state.textContent=text;state.className='s bad';bar.remove()};
          state.textContent=T.sending;
          return new Promise(done=>{
            const x=new XMLHttpRequest();
            x.open('POST','upload?name='+encodeURIComponent(file.name));
            x.upload.onprogress=e=>{if(e.lengthComputable)bar.value=e.loaded/e.total};
            x.onload=()=>{
              if(x.status==200){bar.value=1;state.textContent=T.sent;li.querySelector('.n').textContent=x.responseText}
              else bad(T.failed+': '+x.responseText);
              done();
            };
            x.onerror=()=>{bad(T.lost);done()};
            x.send(file);
          });
        }
        </script></body></html>
        """
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
