import KumquatCore
import SwiftUI

/// The pages of the setup window, in order.
enum SetupStep: Int, CaseIterable {
    case welcome, extras, howTo
}

/// Which page the setup window shows and which extras are ticked. The app sets it before showing the
/// window, e.g. to open it straight on the extras.
@Observable
final class SetupFlow {
    var step = SetupStep.welcome
    var selected: Set<Engine> = []

    /// Starts over on `step`, with the missing recommended engines ticked.
    func start(at step: SetupStep) {
        self.step = step
        selected = Set(EngineInstaller.shared.missingRecommended)
    }
}

/// The window shown at first launch: what Kumquat does, the optional engines to install, and how to use it.
struct SetupView: View {
    /// The setup the app ships: 1 was the welcome window alone, 2 added the extras. Raise it when a page is
    /// added, so people who went through an older setup are offered what's new.
    static let version = 2

    let flow: SetupFlow
    let done: () -> Void
    private var installer: EngineInstaller { .shared }

    /// The ticked engines that still need installing, in the order they're listed.
    private var chosen: [Engine] {
        Engine.allCases.filter { flow.selected.contains($0) && $0.location == nil && $0.canInstall && installer.progress[$0] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch flow.step {
            case .welcome: WelcomePage()
            case .extras: ExtrasPage(flow: flow, chosen: chosen)
            case .howTo: HowToPage()
            }
            footer
        }
        .padding(26)
        .frame(width: 520)
        // Long translations wrap and the window grows to fit, instead of truncating to one line.
        .fixedSize(horizontal: false, vertical: true)
        .tint(.orange)
    }

    private var footer: some View {
        HStack {
            if let previous = SetupStep(rawValue: flow.step.rawValue - 1) {
                Button("Back") { flow.step = previous }
            }
            Spacer()
            switch flow.step {
            case .welcome:
                Button("Continue") { flow.step = .extras }.keyboardShortcut(.defaultAction)
            case .extras:
                if chosen.isEmpty {
                    Button("Continue") { flow.step = .howTo }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { flow.step = .howTo }
                    Button("Install and Continue") {
                        installer.install(chosen)
                        flow.step = .howTo
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .howTo:
                Button("Start Converting", action: done).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Kumquat").font(.title.weight(.bold))
                    Text("Convert any file by dragging it. Offline, instant, unlimited.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                wheel(.convert, "Turn a file into another format: HEIC to JPG, MOV to MP4, PDF to Word… \(Catalog.conversionCount) combinations in all.")
                wheel(.tools, "Change it: compress, trim, crop, merge, sign, read text with OCR.")
                wheel(.actions, "Pass it on: AirDrop, the Basket shelf, a favorite folder, Photos.")
            }
            Text("Everything happens on this Mac. No account, no uploads, no limits.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wheel(_ kind: WheelKind, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The optional engines, ticked or not, with what each adds and its download size.
private struct ExtrasPage: View {
    let flow: SetupFlow
    let chosen: [Engine]
    private var installer: EngineInstaller { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Optional extras").font(.title2.weight(.bold))
                Text("Most formats work right away. These free programs add audio and video and a few more formats. Kumquat downloads its own build of each one from GitHub and checks it before use; nothing about you or your files is sent.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            group("Recommended", .recommended)
            group("Documents and fonts", .documents)
            group("Large", .large)
            apps
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .id(installer.generation)
    }

    private var summary: String {
        let bytes = chosen.compactMap(\.asset?.size).reduce(0, +)
        let later = String(localized: "You can change this later in Settings ▸ Engines.")
        guard bytes > 0 else { return later }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "Download: \(size).") + " " + later
    }

    private func group(_ title: LocalizedStringKey, _ group: Engine.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(Engine.allCases.filter { $0.group == group }) { row($0) }
        }
    }

    private func row(_ engine: Engine) -> some View {
        let location = engine.location, progress = installer.progress[engine], failure = installer.failures[engine]
        let detail = location != nil ? String(localized: "Installed")
            : progress ?? failure ?? (engine.canInstall ? engine.purpose : String(localized: "Not available for this Mac yet"))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if location != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if progress != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Toggle(engine.title, isOn: ticked(engine)).toggleStyle(.checkbox).labelsHidden().disabled(!engine.canInstall)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.title)
                Text(detail).font(.caption).foregroundStyle(failure != nil && progress == nil ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if location == nil, let asset = engine.asset {
                Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .opacity(engine.canInstall || location != nil ? 1 : 0.6)
    }

    /// Pages, Keynote and Numbers come from the App Store, so they get a link rather than a tick.
    private var apps: some View {
        let missing = Engines.App.allCases.filter { !$0.isInstalled }
        return VStack(alignment: .leading, spacing: 6) {
            Text("From the App Store").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "bag").foregroundStyle(missing.isEmpty ? .green : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pages, Keynote and Numbers")
                    Text("Free from Apple, for Pages, Keynote, PowerPoint, Numbers and XLS files")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ForEach(missing, id: \.self) { app in
                    Button(app.rawValue) { NSWorkspace.shared.open(app.appStoreURL) }
                        .controlSize(.small)
                        .help("Opens \(app.rawValue) in the App Store")
                }
            }
        }
    }

    private func ticked(_ engine: Engine) -> Binding<Bool> {
        Binding(get: { flow.selected.contains(engine) },
                set: { if $0 { flow.selected.insert(engine) } else { flow.selected.remove(engine) } })
    }
}

private struct HowToPage: View {
    @State private var launchAtLogin = LoginItem.isEnabled
    private var installer: EngineInstaller { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How it works").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 12) {
                step("1", "Start dragging a file (or several) in Finder.")
                step(Prefs.modifier(for: .convert).symbol, "Tap \(Prefs.modifier(for: .convert).title) for the Convert wheel — \(Catalog.conversionCount) formats.")
                step(Prefs.modifier(for: .tools).symbol, "Tap \(Prefs.modifier(for: .tools).title) for Edit — compress, trim, crop, merge, OCR…")
                step(Prefs.modifier(for: .actions).symbol, "Tap \(Prefs.modifier(for: .actions).title) for Send — AirDrop, Basket, copy, move, path, Terminal.")
                step("✓", "Release the key and drop the file on a slice of the wheel. The new file is saved beside the original.")
            }
            if let combo = Prefs.hotKey {
                Text("Keyboard only? Select files in Finder and press \(combo.display).").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extras
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in try? LoginItem.setEnabled(enabled) }
        }
    }

    /// How the extras ticked on the previous page are getting on.
    @ViewBuilder private var extras: some View {
        let failed = installer.batch.filter { installer.failures[$0] != nil }
        if installer.isBusy {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: installer.overallProgress) { Text("Installing extras…") }
                Text("They carry on if you close this window.").font(.caption).foregroundStyle(.secondary)
            }
        } else if !failed.isEmpty {
            Label("\(ListFormatter.localizedString(byJoining: failed.map(\.title))) couldn't be installed. Try again in Settings ▸ Engines.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if !installer.batch.isEmpty {
            Label("Extras installed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        }
    }

    private func step(_ badge: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(badge)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.18)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
