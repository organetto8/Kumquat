import AppKit
import KumquatCore
import Observation

/// Installs engines from Settings ▸ Engines: from Kumquat's own engine pack when it has a build for
/// this Mac, otherwise with Homebrew if it's there. One at a time, as Homebrew refuses to run twice at
/// once. Shared, so an install carries on, and stays visible, when the tab or the window changes.
@Observable
final class EngineInstaller {
    static let shared = EngineInstaller()

    /// What each queued or running install is doing, for its row's caption.
    private(set) var progress: [Homebrew.Package: String] = [:]
    /// Why the last attempt failed, until the next one.
    private(set) var failures: [Homebrew.Package: String] = [:]
    /// Changes whenever engines may have come or gone, so the Engines tab looks them up again.
    private(set) var generation = 0
    @ObservationIgnored private var downloaded: [Homebrew.Package: Double] = [:]
    @ObservationIgnored private var queue: Task<Void, Never>?

    private init() {}

    /// Whether Install can do anything for `package` on this Mac.
    func canInstall(_ package: Homebrew.Package) -> Bool {
        EnginePack.asset(for: package.name) != nil || Homebrew.brew != nil
    }

    func install(_ package: Homebrew.Package) {
        guard progress[package] == nil else { return }
        failures[package] = nil
        progress[package] = String(localized: "Waiting…")
        let previous = queue
        queue = Task {
            await previous?.value
            await self.run(package)
        }
    }

    /// Forgets every lookup, e.g. after something was installed outside Kumquat.
    func recheck() {
        ExternalTool.resetCache()
        generation += 1
    }

    private func run(_ package: Homebrew.Package) async {
        do {
            if EnginePack.asset(for: package.name) != nil {
                progress[package] = String(localized: "Downloading…")
                try await EnginePack.install(package.name) { fraction in
                    Task { @MainActor [weak self] in self?.advance(package, downloaded: fraction) }
                }
            } else {
                progress[package] = String(localized: "Starting Homebrew…")
                try await Homebrew.install(package) { step in
                    Task { @MainActor [weak self] in self?.advance(package, to: step) }
                }
            }
            Sound.done()
        } catch {
            failures[package] = error.localizedDescription
            Sound.failed()
        }
        downloaded[package] = nil
        progress[package] = nil
        recheck()
    }

    private func advance(_ package: Homebrew.Package, to step: String) {
        if progress[package] != nil { progress[package] = step }
    }

    /// Only forward: a late byte count must not undo "Installing…".
    private func advance(_ package: Homebrew.Package, downloaded fraction: Double) {
        guard fraction > downloaded[package, default: 0] else { return }
        downloaded[package] = fraction
        advance(package, to: fraction < 1
                ? String(localized: "Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                : String(localized: "Installing…"))
    }
}
