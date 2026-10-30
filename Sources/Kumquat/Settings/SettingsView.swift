import KumquatCore
import SwiftUI

final class WindowPresenter<Content: View> {
    private var window: NSWindow?
    private let title: String
    private let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            OutputSettings().tabItem { Label("Output", systemImage: "folder") }
            ActionSettings().tabItem { Label("Send", systemImage: "paperplane") }
            EngineSettings().tabItem { Label("Engines", systemImage: "cpu") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.orange)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.dragGesture) private var dragGesture = true
    @AppStorage(Prefs.Key.convertKey) private var convertKey = WheelModifier.shift.rawValue
    @AppStorage(Prefs.Key.toolsKey) private var toolsKey = WheelModifier.command.rawValue
    @AppStorage(Prefs.Key.actionsKey) private var actionsKey = WheelModifier.control.rawValue
    @AppStorage(Prefs.Key.playSounds) private var playSounds = true
    @AppStorage(Prefs.Key.terminalApp) private var terminalApp = "com.apple.Terminal"
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var hotKey = Prefs.hotKey
    @State private var language = AppLanguage.current

    private let terminals = [("com.apple.Terminal", String(localized: "Terminal")), ("com.googlecode.iterm2", "iTerm"), ("dev.warp.Warp-Stable", "Warp"),
                             ("com.mitchellh.ghostty", "Ghostty")].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Open wheels while dragging files", isOn: $dragGesture)
                keyPicker("Convert wheel", selection: $convertKey)
                keyPicker("Edit wheel", selection: $toolsKey)
                keyPicker("Send wheel", selection: $actionsKey)
                if Set([convertKey, toolsKey, actionsKey]).count < 3 {
                    Text("Each wheel needs its own key.").font(.caption).foregroundStyle(.red)
                }
                if !Prefs.wheelKeyCodes.isEmpty, !CGPreflightListenEventAccess() {
                    HStack {
                        Text("Number keys need Kumquat enabled in Privacy & Security ▸ Input Monitoring (modifier keys don't).")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Wheel keys")
            }
            Section {
                LabeledContent("Shortcut for the Finder selection") { ShortcutRecorder(combo: $hotKey) }
                    .onChange(of: hotKey) { _, combo in Prefs.hotKey = combo }
                Text("Select files in Finder and press it: the Convert wheel opens; use arrows, Return, Escape, and the wheel keys to switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Play sounds", isOn: $playSounds)
                if terminals.count > 1 {
                    Picker("Terminal action opens", selection: $terminalApp) {
                        ForEach(terminals, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, choice in choice.save() }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("Kumquat shows the new language after it restarts.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now", action: relaunch).controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Opens a fresh copy once this one has quit, so the new language is read at launch.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func keyPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(WheelModifier.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

private struct OutputSettings: View {
    @AppStorage(Prefs.Key.outputLocation) private var location = OutputLocation.nextToOriginal.rawValue
    @AppStorage(Prefs.Key.customFolder) private var customFolder = ""
    @AppStorage(Prefs.Key.revealWhenDone) private var revealWhenDone = false

    var body: some View {
        Form {
            Section {
                Picker("Save results", selection: $location) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if location == OutputLocation.custom.rawValue {
                    LabeledContent("Folder") {
                        HStack {
                            Text(customFolder.isEmpty ? String(localized: "Not chosen") : (customFolder as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
                Toggle("Show results in Finder when done", isOn: $revealWhenDone)
            } footer: {
                Text("Originals are never modified: every conversion and tool writes a new file (“photo.png”, “clip (trimmed).mp4”). When the original's folder isn't writable, results go to Downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { customFolder = url.path }
    }
}

/// Favourite folders for Copy To and Move, and the shell scripts the Script action runs.
private struct ActionSettings: View {
    @State private var favorites = Prefs.favoriteFolders
    @State private var scripts = Prefs.scripts

    var body: some View {
        Form {
            Section {
                ForEach(favorites, id: \.self) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { favorites.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…", action: addFolder)
            } header: {
                Text("Favorite folders")
            } footer: {
                Text("Copy To and Move offer these first, then the folders you used last.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($scripts) { $script in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $script.name).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { scripts.removeAll { $0.id == script.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        TextField("Command", text: $script.command, axis: .vertical).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    }
                }
                Button("Add Script") {
                    scripts.append(Prefs.Script(name: String(localized: "Script \(scripts.count + 1)"), command: #"for f in "$@"; do echo "$f"; done"#))
                }
            } header: {
                Text("Scripts")
            } footer: {
                Text("Each command runs in zsh with the files as \"$@\" (also one per line in $KUMQUAT_FILES).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: favorites) { Prefs.favoriteFolders = favorites }
        .onChange(of: scripts) { Prefs.scripts = scripts }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !favorites.contains(url) { favorites.append(url) }
    }
}

private struct EngineSettings: View {
    private var installer: EngineInstaller { .shared }

    var body: some View {
        Form {
            Section {
                row(String(localized: "Images, PDF, documents, spreadsheets, subtitles, archives"),
                    detail: String(localized: "Built in (ImageIO, PDFKit, Vision, libarchive)"), ready: true) { EmptyView() }
                engine(String(localized: "Audio & video"), at: Engines.ffmpeg, from: .formula("ffmpeg"))
                engine(String(localized: "WebP output"), at: Engines.cwebp, from: .formula("webp"))
                engine(String(localized: "JPEG XL output"), at: Engines.cjxl, from: .formula("jpeg-xl"))
                engine(String(localized: "Pictures to SVG"), at: Engines.potrace, from: .formula("potrace"))
                engine(String(localized: "LaTeX, reST, AsciiDoc, Org"), at: Engines.pandoc, from: .formula("pandoc"))
                engine(String(localized: "Kindle e-books"), at: Engines.ebookConvert, from: .cask("calibre"))
                engine(String(localized: "7-Zip archives"), at: Engines.sevenZip, from: .formula("sevenzip"))
                engine(String(localized: "WOFF2 web fonts"), at: Engines.woff2Compress, from: .formula("woff2"))
                engine(String(localized: "TrueType ↔ OpenType outlines"), at: Engines.fonttools, from: .formula("fonttools"))
                ForEach(Engines.App.allCases, id: \.self) { app in
                    row(app.rawValue, detail: purpose(app), ready: app.isInstalled) {
                        Button("Install") { NSWorkspace.shared.open(app.appStoreURL) }
                            .controlSize(.small)
                            .help("Opens \(app.rawValue) in the App Store")
                    }
                }
            } footer: {
                HStack {
                    Text("Everything runs on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { installer.recheck() }
                }
            }
        }
        .formStyle(.grouped)
        .id(installer.generation)
        // Picks up an engine installed in Terminal while Kumquat was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in installer.recheck() }
    }

    private func purpose(_ app: Engines.App) -> String {
        switch app {
        case .pages: String(localized: "Pages documents (in and out)")
        case .keynote: String(localized: "PowerPoint and Keynote slides")
        case .numbers: String(localized: "XLS and Numbers spreadsheets")
        }
    }

    /// An optional program: where it was found, or an Install button and how far the install has got.
    private func engine(_ title: String, at location: URL?, from package: Homebrew.Package) -> some View {
        let progress = installer.progress[package], failure = installer.failures[package]
        let size = EnginePack.asset(for: package.name).map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) }
        let idle = size.map { String(localized: "\($0) download") } ?? package.command
        let available = installer.canInstall(package)
        return row(title, detail: location?.path ?? progress ?? failure ?? idle, ready: location != nil,
                   failed: location == nil && progress == nil && failure != nil) {
            if progress != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { installer.install(package) }
                    .controlSize(.small)
                    .disabled(!available)
                    .help(available ? "" : String(localized: "Not available for this Mac yet. Right-click to copy the Homebrew command."))
            }
        }
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.command, forType: .string)
            }
        }
    }

    /// `accessory` (the Install button) shows only while the engine is missing.
    private func row<Accessory: View>(_ title: String, detail: String, ready: Bool, failed: Bool = false,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ready ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ready ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                    .lineLimit(failed ? 3 : 1).truncationMode(.middle).help(detail)
            }
            Spacer()
            if !ready { accessory() }
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Kumquat").font(.title2.weight(.semibold))
            Text(version).font(.caption).foregroundStyle(.secondary)
            Text("\(Catalog.conversionCount) conversions · \(ToolKind.allCases.count) tools · \(ActionKind.allCases.count) actions\nFree and open source. No limits, no account, no cloud.")
                .multilineTextAlignment(.center)
            Text("FFmpeg, cwebp and ExifTool are separate programs used only if installed.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Kumquat").font(.title.weight(.bold))
                    Text("Convert any file by dragging it. Offline, instant, unlimited.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step("1", "Start dragging a file (or several) in Finder.")
                step(Prefs.modifier(for: .convert).symbol, "Tap \(Prefs.modifier(for: .convert).title) for the Convert wheel — \(Catalog.conversionCount) formats.")
                step(Prefs.modifier(for: .tools).symbol, "Tap \(Prefs.modifier(for: .tools).title) for Edit — compress, trim, crop, merge, OCR…")
                step(Prefs.modifier(for: .actions).symbol, "Tap \(Prefs.modifier(for: .actions).title) for Send — AirDrop, Basket, copy, move, path, Terminal.")
                step("✓", "Release the key and drop the file on a slice of the wheel. The new file is saved beside the original.")
            }
            if let combo = Prefs.hotKey {
                Text("Keyboard only? Select files in Finder and press \(combo.display).").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in try? LoginItem.setEnabled(enabled) }
                Spacer()
                Button("Start Converting", action: done).keyboardShortcut(.defaultAction).tint(.orange)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private func step(_ badge: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(badge)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.18)))
            Text(text)
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? String(localized: "Type a shortcut…") : (combo?.display ?? String(localized: "None"))) { recording ? stop() : start() }
                .frame(minWidth: 120)
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    stop()
                } else if let newCombo = KeyCombo(event: event) {
                    combo = newCombo
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeyCenter.shared.register(Prefs.hotKey)
    }
}
