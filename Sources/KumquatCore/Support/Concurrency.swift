import Foundation

/// Runs blocking work (file I/O, ImageIO, Vision) on a GCD queue so long
/// operations never starve Swift's cooperative thread pool.
public func runBlocking<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

/// Thread-safe flag that blocking loops poll to honour task cancellation.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() { lock.withLock { cancelled = true } }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// `runBlocking` that bridges Swift task cancellation into the blocking work.
public func runCancellable<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable (CancellationFlag) throws -> T
) async throws -> T {
    let flag = CancellationFlag()
    return try await withTaskCancellationHandler {
        try await runBlocking(qos: qos) { try work(flag) }
    } onCancel: {
        flag.cancel()
    }
}

/// Upper bound for CPU-bound fan-out, leaving a core for the UI.
public var workerCount: Int {
    max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
}
