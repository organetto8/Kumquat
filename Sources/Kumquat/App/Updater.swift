import AppKit
import KumquatCore

/// Keeps Kumquat current from its GitHub releases, the one thing in it that goes online. Once a day, or when
/// asked, it reads the release list, downloads a newer version and installs it only after `UpdateInstaller` has
/// checked it against the release key in Info.plist (`KumquatUpdatePublicKey`). A build without that key never
/// looks for updates.
final class Updater {
    static let shared = Updater()
    static let repository = "organetto8/Kumquat"
    private static let interval: TimeInterval = 24 * 60 * 60

    /// The public half of the release key; only the maintainer's keychain holds the private half.
    static let publicKey: Data? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "KumquatUpdatePublicKey") as? String,
              let key = Data(base64Encoded: text), key.count == 32 else { return nil }
        return key
    }()

    static let installedVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap { ReleaseVersion($0) }

    static var isAvailable: Bool { publicKey != nil && installedVersion != nil }

    /// Hooks into the HUD and the job list.
    var notice: (_ title: String, _ detail: String, _ failed: Bool) -> Void = { _, _, _ in }
    var isBusy: () -> Bool = { false }

    /// Downloaded and verified, waiting for the user to say when.
    private(set) var pending: PreparedUpdate?
    private var checking = false
    /// The version last offered as a manual download, so the daily check doesn't repeat itself.
    private var announced: ReleaseVersion?
    private var schedule: Task<Void, Never>?

    /// The first check comes shortly after launch; then, every hour, whether a day has passed since the last one.
    func start() {
        guard Self.isAvailable, schedule == nil else { return }
        schedule = Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if Prefs.checkForUpdates, Date().timeIntervalSince(Prefs.lastUpdateCheck ?? .distantPast) >= Self.interval {
                    self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// A check the user asked for reports every outcome; the daily one speaks only when there is something to install.
    func check(userInitiated: Bool) {
        guard let publicKey = Self.publicKey, let installed = Self.installedVersion, !checking else { return }
        checking = true
        Task {
            defer { self.checking = false }
            do {
                let release = try await UpdateFeed.newestRelease(repository: Self.repository, after: installed, includingBetas: Prefs.betaUpdates)
                Prefs.lastUpdateCheck = Date()
                guard let release else {
                    self.discardPending()
                    if userInitiated {
                        self.notice(String(localized: "Kumquat is up to date"), String(localized: "Version \(installed.description)"), false)
                    }
                    return
                }
                if self.pending?.version != release.version {
                    self.discardPending()
                    do {
                        self.pending = try await UpdateInstaller.prepare(release, repository: Self.repository, publicKey: publicKey,
                                                                          replacing: Bundle.main.bundleURL)
                    } catch UpdateError.cannotReplace {
                        if userInitiated || self.announced != release.version { self.offerDownload(release.version, reason: UpdateError.cannotReplace) }
                        self.announced = release.version
                        return
                    }
                }
                // Never in the middle of a job; the menu bar menu offers it meanwhile.
                if let pending = self.pending, userInitiated || !self.isBusy() { self.offer(pending) }
            } catch {
                if userInitiated { self.notice(String(localized: "Couldn't check for updates"), error.localizedDescription, true) }
            }
        }
    }

    func installPending() {
        guard let update = pending else { return }
        guard !isBusy() else {
            notice(String(localized: "Kumquat is still working"), String(localized: "Install the update from the menu bar icon when it's done."), false)
            return
        }
        pending = nil
        Task {
            do {
                try await UpdateInstaller.install(update)
                UpdateInstaller.discard(update)
                AppRelaunch.now()
            } catch {
                UpdateInstaller.discard(update)
                self.offerDownload(update.version, reason: error)
            }
        }
    }

    func discardPending() {
        if let pending { UpdateInstaller.discard(pending) }
        pending = nil
    }

    static func releasePage(_ version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    private func offer(_ update: PreparedUpdate) {
        let installed = Self.installedVersion?.description ?? "?"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Kumquat \(update.version.description) is ready to install")
        alert.informativeText = String(localized: "You have version \(installed). The new version was downloaded from GitHub and its signature verified. Kumquat will quit and open again.")
        alert.addButton(withTitle: String(localized: "Install and Relaunch"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "What's New"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: installPending()
        case .alertThirdButtonReturn: NSWorkspace.shared.open(Self.releasePage(update.version))
        default: break
        }
    }

    private func offerDownload(_ version: ReleaseVersion, reason: any Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Kumquat \(version.description) is available")
        alert.informativeText = reason.localizedDescription
        alert.addButton(withTitle: String(localized: "Open Download Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasePage(version)) }
    }
}
