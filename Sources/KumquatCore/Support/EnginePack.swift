import CryptoKit
import Foundation

/// Engines Kumquat installs by itself, so a Mac needs neither Homebrew nor an administrator password:
/// builds published as an `engines-N` release of Kumquat (by .github/workflows/engines.yml), checked
/// against the SHA-256 compiled into the app, and unpacked into one folder per engine. This is the
/// only network request Kumquat makes, and only when the user clicks Install.
public enum EnginePack {
    public struct Asset: Sendable {
        let file: String
        let sha256: String
        public let size: Int64
        /// The oldest macOS its programs run on.
        let minimumSystem: String
    }

    /// The engines the pack can hold, by their Homebrew names; each one gets its own folder.
    static let engines = ["ffmpeg", "webp", "jpeg-xl", "potrace", "pandoc", "calibre", "sevenzip", "woff2", "fonttools"]

    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kumquat/Engines", isDirectory: true)

    static func folder(_ engine: String) -> URL { directory.appendingPathComponent(engine, isDirectory: true) }

    /// Where `ExternalTool.locate` looks for the pack's programs, after the usual places.
    static var binDirectories: [String] { engines.map { folder($0).appendingPathComponent("bin").path } }

    /// Whether `url` came from the pack rather than from Homebrew or the user.
    public static func contains(_ url: URL) -> Bool { url.path.hasPrefix(directory.path + "/") }

    /// The download for this Mac, if the pack has one for its processor that runs on its macOS.
    public static func asset(for engine: String) -> Asset? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard release != nil, let asset = assets["\(engine)-\(architecture)"] else { return nil }
        let parts = asset.minimumSystem.split(separator: ".").compactMap { Int($0) }
        let needed = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.dropFirst().first ?? 0, patchVersion: 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) ? asset : nil
    }

    /// Downloads, checks and unpacks `engine`, replacing an older copy. `progress` gets the fraction
    /// downloaded, then 1 while the archive is checked and unpacked.
    public static func install(_ engine: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let tag = release, let asset = Self.asset(for: engine),
              let url = URL(string: "https://github.com/organetto8/Kumquat/releases/download/\(tag)/\(asset.file)") else {
            throw KumquatError.toolMissing(engine)
        }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent(".\(asset.file)")
        defer { try? files.removeItem(at: archive) }
        try await download(url, to: archive, size: asset.size, progress: progress)
        progress(1)
        guard try await runBlocking({ try sha256(of: archive) }) == asset.sha256 else {
            throw KumquatError.noResult(String(localized: "The download of \(engine) was damaged. Try again."))
        }
        let staging = directory.appendingPathComponent(".\(engine)-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        try await ExternalTool.check(Engines.tar, ["-xf", archive.path, "-C", staging.path])
        try? files.removeItem(at: folder(engine))
        try files.moveItem(at: staging, to: folder(engine))
        ExternalTool.resetCache()
    }

    /// URLSession's download, with the byte count read four times a second for `progress`.
    private static func download(_ url: URL, to destination: URL, size: Int64, progress: @escaping @Sendable (Double) -> Void) async throws {
        let watcher = TaskWatcher()
        let reporter = Task {
            while !Task.isCancelled {
                if let received = watcher.task.value?.countOfBytesReceived, received > 0 {
                    progress(min(Double(received) / Double(max(size, 1)), 0.99))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: watcher)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw KumquatError.noResult(String(localized: "Couldn't download \(url.lastPathComponent)."))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Hands over the task URLSession creates for a download, so its byte count can be read while it runs.
private final class TaskWatcher: NSObject, URLSessionTaskDelegate, Sendable {
    let task = LockedBox<URLSessionTask?>(nil)

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        self.task.mutate { $0 = task }
    }
}
