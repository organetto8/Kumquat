import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
}

/// Out-of-process engines (ffmpeg, cwebp, bsdtar, osascript): crash-isolated, cancellable,
/// with optional per-line streaming for progress parsing.
public enum ExternalTool {
    /// The usual install locations, then the engines Kumquat installed itself.
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
        + EnginePack.binDirectories

    private static let cache = LockedBox<[String: URL?]>([:])

    /// Bundled helper (Contents/Helpers) first, then the usual install locations.
    public static func locate(_ name: String) -> URL? {
        if let cached = cache.value[name] { return cached }
        var candidates: [URL] = []
        if let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) as URL? {
            candidates.append(helpers.appendingPathComponent(name))
        }
        candidates += searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        cache.mutate { $0[name] = .some(found) }
        return found
    }

    /// Forgets lookups so newly installed engines are picked up.
    public static func resetCache() { cache.mutate { $0.removeAll() } }

    /// `input` is fed to the tool's stdin (then closed), e.g. a password for `-stdinpass`
    /// that must never appear in the argument list; without it stdin is /dev/null.
    public static func run(
        _ tool: URL,
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = tool
        process.arguments = arguments
        // An explicit copy: left unset, the spawn reads the global `environ`, and a library calling
        // setenv on another thread at that moment (USD inside Model I/O does) fails it with EFAULT.
        process.environment = ProcessInfo.processInfo.environment
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // One blocking reader per pipe, each running to EOF; the result is only assembled
        // once both have drained, so no trailing output can be lost to a race with exit.
        let drained = DispatchGroup()
        for (pipe, isStdout) in [(out, true), (err, false)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if isStdout { box.appendStdout(data, onLine: onStdoutLine) } else { box.appendStderr(data) }
                }
                drained.leave()
            }
        }

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    drained.notify(queue: .global()) { continuation.resume(returning: box.result(status: status)) }
                }
                do {
                    try box.process.run()
                } catch {
                    // Unblock the readers: nothing will ever write to these pipes.
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    try? stdin?.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                if let input, let stdin { feed(input, to: stdin.fileHandleForWriting) }
                if box.isCancelled { box.process.terminate() }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if box.process.isRunning {
                            box.markTimedOut()
                            box.process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
        if box.isCancelled { throw CancellationError() }
        if box.timedOut { throw KumquatError.processFailed(String(localized: "\(tool.lastPathComponent) stopped: it exceeded its time limit.")) }
        return result
    }

    /// Writes `data` to the child's stdin off-thread, then closes it (EOF). A child that exits
    /// without reading gets EPIPE here, never a SIGPIPE that would take the app down.
    private static func feed(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    offset += written
                }
            }
            try? handle.close()
        }
    }

    /// Runs and throws with the tool's last error lines when it exits non-zero.
    @discardableResult
    public static func check(
        _ tool: URL,
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(tool, arguments, input: input, timeout: timeout, onStdoutLine: onStdoutLine)
        guard result.status == 0 else {
            let lines = result.stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw KumquatError.processFailed(lines.isEmpty ? String(localized: "\(tool.lastPathComponent) failed (exit \(result.status)).") : lines)
        }
        return result
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pendingLine = Data()
    private var cancelled = false
    private var timeoutHit = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var timedOut: Bool { lock.withLock { timeoutHit } }

    func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }

    func markTimedOut() { lock.withLock { timeoutHit = true } }

    func appendStdout(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            stdout.append(data)
            guard onLine != nil else { return }
            pendingLine.append(data)
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                pendingLine.removeSubrange(pendingLine.startIndex...newline)
            }
        }
        if let onLine { lines.forEach(onLine) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            stderr.append(data)
            // Keep memory bounded for chatty tools; only the tail matters for errors.
            if stderr.count > 256_000 { stderr.removeFirst(stderr.count - 128_000) }
        }
    }

    func result(status: Int32) -> ProcessResult {
        lock.withLock { ProcessResult(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self)) }
    }
}

/// Minimal lock-protected value for caches shared across threads.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}
