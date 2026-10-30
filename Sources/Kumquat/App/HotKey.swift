import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥K")

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    /// Builds a combo from a key press; plain keys need at least one modifier
    /// (function keys may stand alone).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let code = Int(event.keyCode)
        guard carbon != 0 || Self.functionKeys[code] != nil else { return nil }
        self.init(keyCode: UInt32(code), carbonModifiers: carbon, display: symbols + Self.keyName(code, event.charactersIgnoringModifiers))
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: String(localized: "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func keyName(_ code: Int, _ characters: String?) -> String {
        functionKeys[code] ?? namedKeys[code] ?? (characters ?? "?").uppercased()
    }
}

/// System-wide shortcut via Carbon `RegisterEventHotKey`: no Accessibility permission,
/// no event tap, zero cost while idle.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4B4D_5154), id: 1)  // 'KMQT'
        return RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handler)
    }
}

nonisolated private func hotKeyCallback(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKeyCenter.shared.onPress() }
    return noErr
}
