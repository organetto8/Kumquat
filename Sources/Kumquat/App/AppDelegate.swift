import AppKit
import KumquatCore
import Quartz

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wheel = WheelController()
    private let dragMonitor = DragMonitor()
    private let jobs = JobCenter()
    private lazy var hud = JobHUD(center: jobs)
    private let prompt = ParameterPrompt()
    private let basket = Basket()
    private lazy var actions: ActionPerformer = {
        let performer = ActionPerformer(basket: basket, jobs: jobs, prompt: prompt)
        performer.showSettings = { [weak self] in self?.settings.show() }
        return performer
    }()
    private let services = ServiceProvider()
    private var statusItem: StatusItemController?
    private lazy var settings = WindowPresenter(title: String(localized: "Kumquat Settings")) { SettingsView() }
    private lazy var welcome = WindowPresenter(title: String(localized: "Welcome to Kumquat")) { [weak self] in
        WelcomeView { self?.finishWelcome() }
    }
    /// `.none` until the first registration, so the initial apply always registers.
    private var registeredHotKey: KeyCombo?? = .none
    private var requestedInputMonitoring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        VideoPreviewModel.removeLeftoverProxies()
        NSApp.mainMenu = MainMenu.build()
        _ = hud

        let status = StatusItemController()
        status.onLeftClick = { [weak status] in status?.showMenu() }
        status.onDrop = { [weak self, weak status] files in
            guard let self, let frame = status?.buttonFrameOnScreen else { return }
            self.wheel.present(.convert, files: files, at: NSPoint(x: frame.midX, y: frame.minY - WheelView.side / 2 + 30), keyboard: true)
        }
        status.menuProvider = { [weak self] in self?.statusMenu() ?? NSMenu() }
        statusItem = status

        dragMonitor.onModifierTap = { [weak self] kind, files in
            guard let self else { return }
            if self.wheel.isVisible {
                self.wheel.switchTo(kind)
            } else {
                self.wheel.present(kind, files: files, at: NSEvent.mouseLocation, keyboard: false)
            }
        }
        dragMonitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        wheel.onChoose = { [weak self] item, files, wheel, anchor in self?.run(item, files: files, wheel: wheel, anchor: anchor) }
        jobs.chooseFolder = { [weak self] in self?.chooseFolder() }

        HotKeyCenter.shared.onPress = { [weak self] in self?.openWheelForFinderSelection(.convert) }
        applyPreferences()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)

        services.handler = { [weak self] urls in self?.openWheel(.convert, files: urls) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        handleLaunchArguments()
        if !Prefs.welcomed { welcome.show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openWheel(.convert, files: urls)
    }

    // MARK: - Running choices

    private func run(_ item: WheelItem, files: [URL], wheel: Wheel, anchor: NSPoint) {
        switch item.operation {
        case .action(let action):
            actions.perform(action, files: files)
        case .convert:
            jobs.start(item.operation, files: files)
        case .tool(let tool):
            runTool(tool, files: files, wheel: wheel, anchor: anchor)
        }
    }

    /// Instant tools run with the last options used and the rest show their options first; ⌥ flips
    /// that, and `showsOptions` overrides it. Passwords are always asked for.
    private func runTool(_ tool: ToolKind, files: [URL], wheel: Wheel, anchor: NSPoint, showsOptions: Bool? = nil) {
        let category = wheel.category
        let operation = KumquatCore.Operation.tool(tool)
        let parameters = Catalog.parameters(for: tool, category: category)
        let values = Prefs.toolValues(tool, category: category)
        let secret = parameters.contains { $0.kind == .secure }
        let asks = !parameters.isEmpty && (secret || (showsOptions ?? (Catalog.runsInstantly(tool, category: category) == Prefs.optionFlipsPrompt)))
        guard asks else {
            jobs.start(operation, files: files, parameters: values)
            return
        }
        let preview = Catalog.previewsVideo(tool, category: category) || Catalog.previewsStill(tool, category: category)
            || Catalog.previewsPages(tool, category: category)
            ? files.first { FileFormat.detect($0)?.category == category } : nil
        prompt.ask(title: tool.title, subtitle: wheel.subject, parameters: parameters, values: values, preview: preview, at: anchor) { [weak self] values in
            Prefs.saveToolValues(values, tool: tool, category: category)
            self?.jobs.start(operation, files: files, parameters: values)
        }
    }

    private func openWheel(_ kind: WheelKind, files: [URL]) {
        guard !files.isEmpty else { return }
        wheel.present(kind, files: files, at: NSEvent.mouseLocation, keyboard: true)
    }

    private func openWheelForFinderSelection(_ kind: WheelKind) {
        let selection = FinderBridge.selection()
        guard !selection.isEmpty else {
            jobs.notice(String(localized: "Select files in Finder first"), detail: String(localized: "Then press the shortcut again"), failed: true)
            return
        }
        openWheel(kind, files: selection)
    }

    private func chooseFolder() -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose where Kumquat saves results.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Scripting entry points:
    /// `Kumquat --wheel convert|tools|actions <files…>` opens a wheel;
    /// `Kumquat --run convert:png|tool:compress|action:copy <files…>` runs straight away;
    /// `Kumquat --options trim|crop|compress… <files…>` shows that tool's options;
    /// `Kumquat --diagnostics` prints what Copy Diagnostic Info copies, then quits.
    private func handleLaunchArguments() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--diagnostics") {
            print(Diagnostics.report)
            exit(0)
        }
        func files(after index: Int) -> [URL] {
            arguments[(index + 2)...].filter { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
        }
        if let flag = arguments.firstIndex(of: "--wheel"), flag + 1 < arguments.count, let kind = WheelKind(rawValue: arguments[flag + 1]) {
            let urls = files(after: flag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openWheel(kind, files: urls) }
        }
        if let flag = arguments.firstIndex(of: "--options"), flag + 1 < arguments.count, let tool = ToolKind(rawValue: arguments[flag + 1]) {
            let urls = files(after: flag)
            let wheel = Catalog.wheel(.tools, for: urls)
            guard !urls.isEmpty, wheel.items.contains(where: { $0.operation == .tool(tool) }) else { return }
            let centre = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.runTool(tool, files: urls, wheel: wheel, anchor: centre, showsOptions: true)
            }
        }
        if let flag = arguments.firstIndex(of: "--run"), flag + 1 < arguments.count {
            let parts = arguments[flag + 1].split(separator: ":").map(String.init)
            let operation: KumquatCore.Operation? = switch (parts.first, parts.last) {
            case ("convert"?, let raw?): FileFormat(rawValue: raw).map { .convert($0) }
            case ("tool"?, let raw?): ToolKind(rawValue: raw).map { .tool($0) }
            case ("action"?, let raw?): ActionKind(rawValue: raw).map { .action($0) }
            default: nil
            }
            guard let operation else { return }
            let urls = files(after: flag)
            switch operation {
            case .action(let action):
                actions.perform(action, files: urls)
            case .tool(let tool):
                let category = Catalog.dominantCategory(of: urls.map(FileFormat.detect))
                jobs.start(operation, files: urls, parameters: Prefs.toolValues(tool, category: category))
            case .convert:
                jobs.start(operation, files: urls)
            }
        }
    }

    private func finishWelcome() {
        Prefs.welcomed = true
        welcome.close()
    }

    // MARK: - Preferences

    @objc private func defaultsChanged() { applyPreferences() }

    private func applyPreferences() {
        let combo = Prefs.hotKey
        if registeredHotKey != .some(combo) {
            HotKeyCenter.shared.register(combo)
            registeredHotKey = .some(combo)
        }
        if Prefs.dragGesture { dragMonitor.start() } else { dragMonitor.stop() }
        requestInputMonitoringIfNeeded()
    }

    /// Modifier keys are readable by any app; ordinary keys (1/2/3) need Input Monitoring.
    private func requestInputMonitoringIfNeeded() {
        guard !Prefs.wheelKeyCodes.isEmpty, !CGPreflightListenEventAccess(), !requestedInputMonitoring else { return }
        requestedInputMonitoring = true
        CGRequestListenEventAccess()
        jobs.notice(String(localized: "Allow Kumquat in Input Monitoring"), detail: String(localized: "Needed for the 1/2/3 wheel keys. Then quit and reopen Kumquat."), failed: true)
    }

    // MARK: - Menu

    @objc func convertSelection(_ sender: Any?) { openWheelForFinderSelection(.convert) }
    @objc func toolsSelection(_ sender: Any?) { openWheelForFinderSelection(.tools) }
    @objc func actionsSelection(_ sender: Any?) { openWheelForFinderSelection(.actions) }
    @objc func toggleBasket(_ sender: Any?) { basket.toggle() }
    @objc func showSettings(_ sender: Any?) { settings.show() }
    @objc func showWelcome(_ sender: Any?) { welcome.show() }

    @objc func toggleDragGesture(_ sender: Any?) {
        UserDefaults.standard.set(!Prefs.dragGesture, forKey: Prefs.Key.dragGesture)
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Quick Look (the panel asks the responder chain, which ends here)

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = actions
            panel.reloadData()
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: String(localized: "Drag-and-convert, offline, unlimited.\n\(Catalog.conversionCount) conversions · \(ToolKind.allCases.count) tools · \(ActionKind.allCases.count) actions."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    /// What a bug report needs, ready to paste into the issue form.
    @objc func copyDiagnostics(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report, forType: .string)
        jobs.notice(String(localized: "Copied diagnostic info"), detail: String(localized: "Paste it into your bug report."))
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let keys = WheelKind.allCases.map { Prefs.modifier(for: $0).symbol }.joined(separator: " / ")
        let hint = NSMenuItem(title: String(localized: "Drag a file, then tap \(keys)"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let convert = menuItem(String(localized: "Convert Finder Selection…"), #selector(convertSelection(_:)))
        if let combo = Prefs.hotKey { convert.title += "   \(combo.display)" }
        menu.addItem(convert)
        menu.addItem(menuItem(String(localized: "Edit Finder Selection…"), #selector(toolsSelection(_:))))
        menu.addItem(menuItem(String(localized: "Send Finder Selection…"), #selector(actionsSelection(_:))))
        menu.addItem(menuItem(basket.isVisible ? String(localized: "Hide Basket") : String(localized: "Show Basket"), #selector(toggleBasket(_:))))
        menu.addItem(.separator())
        let drag = menuItem(String(localized: "Open Wheels While Dragging"), #selector(toggleDragGesture(_:)))
        drag.state = Prefs.dragGesture ? .on : .off
        menu.addItem(drag)
        let login = menuItem(String(localized: "Launch at Login"), #selector(toggleLaunchAtLogin(_:)))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(menuItem(String(localized: "Settings…"), #selector(showSettings(_:)), key: ","))
        menu.addItem(menuItem(String(localized: "How Kumquat Works"), #selector(showWelcome(_:))))
        menu.addItem(menuItem(String(localized: "About Kumquat"), #selector(showAbout(_:))))
        menu.addItem(menuItem(String(localized: "Copy Diagnostic Info"), #selector(copyDiagnostics(_:))))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Kumquat"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

/// Invisible main menu: an accessory app still needs it for ⌘C / ⌘V / ⌘A / ⌘Q in its panels.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "About Kumquat"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Kumquat"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Kumquat", to: main)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: String(localized: "Edit"), to: main)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, titled: String(localized: "Window"), to: main)
        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
