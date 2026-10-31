import AppKit
import KumquatCore

enum OutputLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, custom, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextToOriginal: String(localized: "Next to the original")
        case .downloads: String(localized: "Downloads")
        case .custom: String(localized: "A folder I choose")
        case .ask: String(localized: "Ask every time")
        }
    }
}

/// Key that opens a wheel mid-drag: a modifier, or a number key (handy when another
/// drag-and-drop utility already claims the modifiers).
enum WheelModifier: String, CaseIterable, Identifiable {
    case shift, command, control, option, one, two, three

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        case .one, .two, .three: nil
        }
    }

    var keyCode: CGKeyCode? {
        switch self {
        case .one: 18
        case .two: 19
        case .three: 20
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        }
    }

    var title: String {
        switch self {
        case .shift: String(localized: "⇧ Shift")
        case .command: String(localized: "⌘ Command")
        case .control: String(localized: "⌃ Control")
        case .option: String(localized: "⌥ Option")
        case .one, .two, .three: String(localized: "\(symbol) key")
        }
    }
}

/// Language Kumquat shows. macOS reads it at launch from this app's own `AppleLanguages`, the same
/// value System Settings ▸ Language & Region ▸ Applications writes.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, it

    var id: String { rawValue }

    /// Language names stay in their own language, recognisable whatever Kumquat shows.
    var title: String {
        switch self {
        case .system: String(localized: "Same as the system")
        case .en: "English"
        case .it: "Italiano"
        }
    }

    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// The language this run of Kumquat shows; a new choice applies after a restart.
    static let atLaunch = current

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// UserDefaults-backed settings; SwiftUI binds to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        static let playSounds = "playSounds"
        static let dragGesture = "dragGesture"
        static let convertKey = "wheelKey.convert"
        static let toolsKey = "wheelKey.tools"
        static let actionsKey = "wheelKey.actions"
        static let outputLocation = "outputLocation"
        static let customFolder = "customFolder"
        static let revealWhenDone = "revealWhenDone"
        static let hotKey = "hotKey"
        static let terminalApp = "terminalApp"
        static let welcomed = "welcomed"
        static let favoriteFolders = "favoriteFolders"
        static let recentFolders = "recentFolders"
        static let scripts = "scripts"
        static let checkForUpdates = "checkForUpdates"
        static let betaUpdates = "betaUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    private static var defaults: UserDefaults { .standard }

    static func register() {
        defaults.register(defaults: [
            Key.playSounds: true,
            Key.dragGesture: true,
            Key.convertKey: WheelModifier.shift.rawValue,
            Key.toolsKey: WheelModifier.command.rawValue,
            Key.actionsKey: WheelModifier.control.rawValue,
            Key.outputLocation: OutputLocation.nextToOriginal.rawValue,
            Key.revealWhenDone: false,
            Key.terminalApp: "com.apple.Terminal",
            Key.welcomed: false,
            Key.checkForUpdates: true,
            Key.betaUpdates: false,
        ])
    }

    static var playSounds: Bool { defaults.bool(forKey: Key.playSounds) }
    static var dragGesture: Bool { defaults.bool(forKey: Key.dragGesture) }
    static var revealWhenDone: Bool { defaults.bool(forKey: Key.revealWhenDone) }
    static var terminalApp: String { defaults.string(forKey: Key.terminalApp) ?? "com.apple.Terminal" }

    static var welcomed: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }

    static var checkForUpdates: Bool { defaults.bool(forKey: Key.checkForUpdates) }
    static var betaUpdates: Bool { defaults.bool(forKey: Key.betaUpdates) }

    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    static var outputLocation: OutputLocation {
        OutputLocation(rawValue: defaults.string(forKey: Key.outputLocation) ?? "") ?? .nextToOriginal
    }

    static var customFolder: URL? {
        get { defaults.string(forKey: Key.customFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.customFolder) }
    }

    static func key(for kind: WheelKind) -> String {
        switch kind {
        case .convert: Key.convertKey
        case .tools: Key.toolsKey
        case .actions: Key.actionsKey
        }
    }

    static func modifier(for kind: WheelKind) -> WheelModifier {
        WheelModifier(rawValue: defaults.string(forKey: key(for: kind)) ?? "") ?? .shift
    }

    /// The wheel whose modifier appears in `flags` (Convert wins ties).
    static func wheel(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        WheelKind.allCases.first { kind in modifier(for: kind).flag.map(flags.contains) ?? false }
    }

    static func wheel(forKeyCode code: UInt16) -> WheelKind? {
        WheelKind.allCases.first { modifier(for: $0).keyCode == CGKeyCode(code) }
    }

    static var wheelModifierFlags: NSEvent.ModifierFlags {
        WheelKind.allCases.reduce(into: []) { flags, kind in
            if let flag = modifier(for: kind).flag { flags.insert(flag) }
        }
    }

    /// Wheels bound to ordinary keys, with their key codes.
    static var wheelKeyCodes: [(WheelKind, CGKeyCode)] {
        WheelKind.allCases.compactMap { kind in modifier(for: kind).keyCode.map { (kind, $0) } }
    }

    /// `nil` means the user cleared the shortcut; an absent key means the default.
    static var hotKey: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: Key.hotKey) else { return .default }
            return try? JSONDecoder().decode(KeyCombo?.self, from: data)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.hotKey) }
    }

    // MARK: Actions

    /// Folders Copy To and Move offer first.
    static var favoriteFolders: [URL] {
        get { (defaults.stringArray(forKey: Key.favoriteFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue.map(\.path), forKey: Key.favoriteFolders) }
    }

    /// The last few folders files were copied or moved to, newest first.
    static var recentFolders: [URL] {
        (defaults.stringArray(forKey: Key.recentFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func rememberFolder(_ folder: URL) {
        let paths = [folder.path] + (defaults.stringArray(forKey: Key.recentFolders) ?? []).filter { $0 != folder.path }
        defaults.set(Array(paths.prefix(5)), forKey: Key.recentFolders)
    }

    /// A shell command the Script action runs on the files.
    struct Script: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var command: String
    }

    static var scripts: [Script] {
        get { defaults.data(forKey: Key.scripts).flatMap { try? JSONDecoder().decode([Script].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.scripts) }
    }

    // MARK: Tool options

    private static func toolValuesKey(_ tool: ToolKind, _ category: FormatCategory?) -> String {
        "toolValues.\(tool.rawValue).\(category?.rawValue ?? "any")"
    }

    /// Starting values for a tool's options: the last ones used where still valid, else the defaults.
    static func toolValues(_ tool: ToolKind, category: FormatCategory?) -> [String: String] {
        let saved = defaults.dictionary(forKey: toolValuesKey(tool, category)) as? [String: String] ?? [:]
        let parameters = Catalog.parameters(for: tool, category: category)
        return Dictionary(uniqueKeysWithValues: parameters.map { parameter in
            let last = saved[parameter.key].flatMap { parameter.remembers && parameter.accepts($0) ? $0 : nil }
            return (parameter.key, last ?? parameter.defaultValue)
        })
    }

    static func saveToolValues(_ values: [String: String], tool: ToolKind, category: FormatCategory?) {
        let parameters = Catalog.parameters(for: tool, category: category).filter(\.remembers)
        let kept = values.filter { key, _ in parameters.contains { $0.key == key } }
        defaults.set(kept, forKey: toolValuesKey(tool, category))
    }

    /// ⌥ flips a tool between running at once and showing its options, unless ⌥ opens a wheel.
    static var optionFlipsPrompt: Bool {
        NSEvent.modifierFlags.contains(.option) && !WheelKind.allCases.contains { modifier(for: $0) == .option }
    }
}

enum Sound {
    static func wheel() { play("Tink", volume: 0.35) }
    static func done() { play("Glass", volume: 0.5) }
    static func failed() { play("Basso", volume: 0.5) }

    private static func play(_ name: String, volume: Float) {
        guard Prefs.playSounds, let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.stop()
        sound.play()
    }
}
