import AppKit
import KumquatCore
import Observation

/// Installs engines from the setup window and Settings ▸ Engines: from Kumquat's own engine pack when it
/// has a build for this Mac, otherwise with Homebrew if it's there. Two pack downloads run at once, Homebrew
/// one install at a time, as it refuses to run twice. Shared, so an install carries on, and stays visible,
/// when the window changes; what is left is saved, so an install a quit cut short resumes at the next launch.
@Observable
final class EngineInstaller {
    static let shared = EngineInstaller()

    /// What each queued or running install is doing, for its row's caption.
    private(set) var progress: [Engine: String] = [:]
    /// Why the last attempt failed, until the next one.
    private(set) var failures: [Engine: String] = [:]
    /// Changes whenever engines may have come or gone, so the lists look them up again.
    private(set) var generation = 0
    /// Everything asked for since the installer was last idle, for the overall progress.
    private(set) var batch: [Engine] = []
    /// How far each running pack download has got, from 0 to 1.
    private var downloaded: [Engine: Double] = [:]
    @ObservationIgnored private var waiting: [Engine] = []
    @ObservationIgnored private var running: Set<Engine> = []

    private init() {}

    /// Whether an install is queued or running, which an app update waits for.
    var isBusy: Bool { !progress.isEmpty }

    /// The recommended engines still missing that Install can add to this Mac.
    var missingRecommended: [Engine] {
        Engine.allCases.filter { $0.group == .recommended && $0.location == nil && $0.canInstall }
    }

    /// Engines unpacked from an older engine pack than the one this version installs from.
    var outdated: [Engine] { Engine.allCases.filter(\.needsUpdate) }

    /// How far the batch has got, from 0 to 1, weighed by download size. A Homebrew install, whose size
    /// isn't known, weighs as much as 10 MB; a finished or failed engine counts as done.
    var overallProgress: Double {
        let weights = batch.map { Double($0.asset?.size ?? 10_000_000) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let done = zip(batch, weights).reduce(0.0) { sum, item in
            sum + item.1 * (progress[item.0] == nil ? 1 : downloaded[item.0, default: 0])
        }
        return done / total
    }

    func install(_ engines: [Engine]) {
        let new = engines.filter { progress[$0] == nil }
        guard !new.isEmpty else { return }
        if progress.isEmpty { batch = [] }
        for engine in new {
            failures[engine] = nil
            progress[engine] = String(localized: "Waiting…")
            waiting.append(engine)
            batch.append(engine)
        }
        savePending()
        startWaiting()
    }

    /// Carries on with the installs the last quit cut short.
    func resumePending() {
        install(Prefs.pendingEngines.filter { $0.location == nil || $0.needsUpdate })
    }

    /// Forgets every lookup, e.g. after something was installed outside Kumquat.
    func recheck() {
        ExternalTool.resetCache()
        generation += 1
    }

    /// Starts whatever is waiting, as far as two pack downloads and one Homebrew install allow.
    private func startWaiting() {
        for engine in waiting {
            let fromPack = engine.asset != nil
            guard running.count(where: { ($0.asset != nil) == fromPack }) < (fromPack ? 2 : 1) else { continue }
            waiting.removeAll { $0 == engine }
            running.insert(engine)
            Task {
                let succeeded = await run(engine)
                running.remove(engine)
                savePending()
                if !succeeded {
                    Sound.failed()
                } else if running.isEmpty, waiting.isEmpty {
                    Sound.done()
                }
                startWaiting()
            }
        }
    }

    private func run(_ engine: Engine) async -> Bool {
        defer {
            downloaded[engine] = nil
            progress[engine] = nil
            recheck()
        }
        do {
            if engine.asset != nil {
                progress[engine] = String(localized: "Downloading…")
                try await EnginePack.install(engine.rawValue) { fraction in
                    Task { @MainActor [weak self] in self?.advance(engine, downloaded: fraction) }
                }
            } else {
                progress[engine] = String(localized: "Starting Homebrew…")
                try await Homebrew.install(engine.package) { step in
                    Task { @MainActor [weak self] in self?.advance(engine, to: step) }
                }
            }
            return true
        } catch {
            failures[engine] = error.localizedDescription
            return false
        }
    }

    private func savePending() {
        Prefs.pendingEngines = Engine.allCases.filter { waiting.contains($0) || running.contains($0) }
    }

    private func advance(_ engine: Engine, to step: String) {
        if progress[engine] != nil { progress[engine] = step }
    }

    /// Only forward: a late byte count must not undo "Installing…".
    private func advance(_ engine: Engine, downloaded fraction: Double) {
        guard fraction > downloaded[engine, default: 0] else { return }
        downloaded[engine] = fraction
        advance(engine, to: fraction < 1
                ? String(localized: "Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                : String(localized: "Installing…"))
    }
}
