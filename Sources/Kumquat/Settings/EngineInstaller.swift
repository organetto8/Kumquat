import AppKit
import KumquatCore
import Observation

/// Installs engines from Settings ▸ Engines, one at a time: Homebrew refuses to run twice at once.
/// Shared, so an install carries on, and stays visible, when the tab or the window changes.
@Observable
final class EngineInstaller {
    static let shared = EngineInstaller()

    /// What each queued or running install is doing, for its row's caption.
    private(set) var progress: [Homebrew.Package: String] = [:]
    /// Why the last attempt failed, until the next one.
    private(set) var failures: [Homebrew.Package: String] = [:]
    /// Changes whenever engines may have come or gone, so the Engines tab looks them up again.
    private(set) var generation = 0
    @ObservationIgnored private var queue: Task<Void, Never>?

    private init() {}

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

    /// Opens Homebrew's official installer in Terminal, where it says what it will do and asks for the
    /// administrator password. Coming back to Kumquat looks for it again.
    func installHomebrew() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Install Homebrew.command")
        let command = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        do {
            try "#!/bin/zsh\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw CocoaError(.fileNoSuchFile) }
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        }
    }

    private func run(_ package: Homebrew.Package) async {
        progress[package] = String(localized: "Starting Homebrew…")
        do {
            try await Homebrew.install(package) { step in
                Task { @MainActor [weak self] in self?.advance(package, to: step) }
            }
            Sound.done()
        } catch {
            failures[package] = error.localizedDescription
            Sound.failed()
        }
        progress[package] = nil
        recheck()
    }

    private func advance(_ package: Homebrew.Package, to step: String) {
        if progress[package] != nil { progress[package] = step }
    }
}
