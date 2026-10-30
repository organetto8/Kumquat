import Foundation

/// A verified new version, unpacked in a temporary folder on the same volume as the copy it replaces.
public struct PreparedUpdate: Sendable {
    public let version: ReleaseVersion
    let app: URL
    let staging: URL
    let target: URL
}

/// Downloads, checks and swaps in a new Kumquat. The order is the point: the archive's signature is checked
/// before anything reads inside it, and the unpacked app must be this same app, at the signed version, with a
/// code signature covering every file, before it takes the running copy's place. Nothing here asks for an
/// administrator password; where the user can't write, the update stops and they install it by hand.
public enum UpdateInstaller {
    public static func prepare(_ release: UpdateRelease, repository: String, publicKey: Data, replacing target: URL) async throws -> PreparedUpdate {
        try checkReplaceable(target)
        let identifier = try bundleInfo(target).identifier
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        do {
            let base = "https://github.com/\(repository)/releases/download/v\(release.version)/"
            guard let signatureURL = URL(string: base + release.signatureName), let archiveURL = URL(string: base + release.archiveName) else {
                throw UpdateError.unreachable
            }
            let signatureFile = staging.appendingPathComponent(release.signatureName)
            try await Transfer.run(URLRequest(url: signatureURL), to: signatureFile, limit: 1024)
            guard let signature = UpdateSignature.parse(try Data(contentsOf: signatureFile)) else { throw UpdateError.badSignature }
            let archive = staging.appendingPathComponent(release.archiveName)
            try await Transfer.run(URLRequest(url: archiveURL), to: archive, limit: Int64(UpdateFeed.maxArchiveSize))
            let app = try await unpack(archive, signature: signature, publicKey: publicKey, bundleIdentifier: identifier,
                                       version: release.version, into: staging)
            return PreparedUpdate(version: release.version, app: app, staging: staging, target: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Swaps the new app in, keeping the old one until the new one is in place. The new copy is checked once
    /// more first: it may have waited days in a temporary folder that the system cleans up.
    public static func install(_ update: PreparedUpdate) async throws {
        let identifier = try bundleInfo(update.target).identifier
        _ = try await validatedApp(in: update.app.deletingLastPathComponent(), bundleIdentifier: identifier, version: update.version)
        try checkReplaceable(update.target)
        let previous = update.staging.appendingPathComponent("Previous.app", isDirectory: true)
        // The folder is writable, so a refusal here is most likely macOS protecting apps (App Management).
        do {
            try FileManager.default.moveItem(at: update.target, to: previous)
        } catch {
            throw UpdateError.notPermitted
        }
        do {
            try FileManager.default.moveItem(at: update.app, to: update.target)
        } catch {
            try? FileManager.default.moveItem(at: previous, to: update.target)
            throw UpdateError.notPermitted
        }
    }

    /// Deletes the download, the unpacked app and, after an install, the previous version.
    public static func discard(_ update: PreparedUpdate) {
        try? FileManager.default.removeItem(at: update.staging)
    }

    /// Kumquat replaces itself only where the user can write: never inside a disk image or a translocated copy,
    /// and never in a folder that would need an administrator.
    public static func checkReplaceable(_ target: URL) throws {
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.cannotReplace }
    }

    /// Checks the signature, then unpacks: ditto only ever sees an archive the release key vouches for.
    static func unpack(_ archive: URL, signature: Data, publicKey: Data, bundleIdentifier: String, version: ReleaseVersion,
                       into staging: URL) async throws -> URL {
        let digest = try await runBlocking { try UpdateSignature.sha256(of: archive) }
        let message = UpdateSignature.message(bundleIdentifier: bundleIdentifier, version: version, archiveDigest: digest)
        guard UpdateSignature.isValid(signature, publicKey: publicKey, message: message) else { throw UpdateError.badSignature }
        let folder = staging.appendingPathComponent("Unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, folder.path])
        } catch {
            throw UpdateError.badArchive
        }
        return try await validatedApp(in: folder, bundleIdentifier: bundleIdentifier, version: version)
    }

    /// The folder must hold exactly one real app (not a link) that is this app at `version`, and its code
    /// signature must still cover every file in it.
    static func validatedApp(in folder: URL, bundleIdentifier: String, version: ReleaseVersion) async throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard items.count == 1, let app = items.first, app.lastPathComponent == "Kumquat.app",
              let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              let info = try? bundleInfo(app), info.identifier == bundleIdentifier, info.version == version.description
        else { throw UpdateError.badArchive }
        do {
            try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.badArchive
        }
        return app
    }

    static func bundleInfo(_ app: URL) throws -> (identifier: String, version: String) {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else { throw UpdateError.badArchive }
        return (identifier, version)
    }
}

/// One HTTPS download into a file, stopped as soon as it passes `limit` bytes. Redirects are followed only to
/// GitHub over HTTPS, and the session keeps no cookies or cache and sends a plain user agent, so the request
/// says nothing about the user or the Mac.
final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?

    private init(destination: URL, limit: Int64) {
        self.destination = destination
        self.limit = limit
    }

    static func run(_ request: URLRequest, to destination: URL, limit: Int64) async throws {
        guard let url = request.url, isAllowed(url) else { throw UpdateError.unreachable }
        let transfer = Transfer(destination: destination, limit: limit)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        // The session holds its delegate until it is invalidated.
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                transfer.lock.withLock {
                    transfer.task = task
                    transfer.continuation = continuation
                }
                task.resume()
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    /// GitHub's own hosts, over HTTPS on the default port, with no credentials in the URL.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.port == nil, let host = url.host()?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "Kumquat"]
        return configuration
    }

    private func cancel() {
        lock.withLock { task }?.cancel()
    }

    private func fail(_ error: any Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // Refused, the redirect itself becomes the response, and its status fails the download below.
        guard let url = request.url, Self.isAllowed(url) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > limit || totalBytesExpectedToWrite > limit else { return }
        fail(UpdateError.tooLarge)
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so it is checked and moved now.
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, Self.isAllowed(url) else { throw UpdateError.unreachable }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limit else { throw UpdateError.tooLarge }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.failure ?? error)
        }
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
}
