import CryptoKit
import Foundation

/// Engines Kumquat installs by itself, so a Mac needs neither Homebrew nor an administrator password:
/// builds published as an `engines-N` release of Kumquat (by .github/workflows/engines.yml), checked
/// against the SHA-256 compiled into the app, and unpacked into one folder per engine. Apart from the
/// update check, this is the only network request Kumquat makes, and only when the user clicks Install.
public enum EnginePack {
    public struct Asset: Sendable {
        let file: String
        let sha256: String
        public let size: Int64
        /// The oldest macOS its programs run on.
        let minimumSystem: String
    }

    /// The engines the pack can hold, by their Homebrew names; each one gets its own folder.
    static var engines: [String] { Engine.allCases.map(\.rawValue) }

    /// In each engine's folder: the engines-N release it was unpacked from.
    static let releaseMarker = ".release"

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
        try checkSpace(for: engine, size: asset.size)
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
        try recordRelease(tag, in: staging)
        try? files.removeItem(at: folder(engine))
        try files.moveItem(at: staging, to: folder(engine))
        ExternalTool.resetCache()
    }

    /// The release `engine` was installed from, or nil when the pack hasn't installed it.
    public static func installedRelease(_ engine: String) -> String? { release(in: folder(engine)) }

    /// Folders without a marker were unpacked before markers were written, from engines-1: the only pack then.
    static func release(in folder: URL) -> String? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(releaseMarker)) else { return "engines-1" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recordRelease(_ tag: String, in folder: URL) throws {
        try Data(tag.utf8).write(to: folder.appendingPathComponent(releaseMarker))
    }

    /// An xz archive unpacks to about three times its size, and the archive stays beside it until then.
    private static func checkSpace(for engine: String, size: Int64) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free < size * 4 else { return }
        let needed = ByteCountFormatter.string(fromByteCount: size * 4, countStyle: .file)
        throw KumquatError.noResult(String(localized: "Not enough free space for \(engine): it needs about \(needed)."))
    }

    /// Through the updater's `Transfer`: GitHub over HTTPS only, no cookies or cache, stopped past the pinned
    /// size. `progress` hears each new whole percent; a big engine on a slow line gets two hours.
    private static func download(_ url: URL, to destination: URL, size: Int64, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        let reported = LockedBox(0)
        do {
            try await Transfer.run(URLRequest(url: url), to: destination, limit: size, timeout: 2 * 60 * 60) { received in
                let fraction = min(Double(received) / Double(max(size, 1)), 0.99)
                let percent = Int(fraction * 100)
                let isNew = reported.mutate { (last: inout Int) -> Bool in
                    guard percent > last else { return false }
                    last = percent
                    return true
                }
                if isNew { progress(fraction) }
            }
        } catch is UpdateError {
            throw KumquatError.noResult(String(localized: "Couldn't download \(url.lastPathComponent)."))
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
