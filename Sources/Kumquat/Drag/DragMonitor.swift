import AppKit
import KumquatCore
import os

/// `log stream --level debug --predicate 'subsystem == "app.kumquat.Kumquat"'`
let dragLog = Logger(subsystem: "app.kumquat.Kumquat", category: "drag")

/// Watches system-wide file drags. Global *mouse* monitors need no Accessibility permission;
/// wheel keys are read by polling the keyboard state (`NSEvent.modifierFlags`, and
/// `CGEventSource.keyState` for number keys), only while a file drag is actually in flight —
/// idle cost is one pasteboard check per mouse-down.
final class DragMonitor {
    var onModifierTap: (WheelKind, [URL]) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}

    private enum Phase { case idle, pressed, fileDrag, otherDrag }

    private var monitors: [Any] = []
    private var phase = Phase.idle
    private var changeCountAtPress = 0
    private var files: [URL] = []
    private var previousFlags: NSEvent.ModifierFlags = []
    private var previousKeys: Set<CGKeyCode> = []
    private var poller: Timer?

    var isDraggingFiles: Bool { phase == .fileDrag }

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, dragged, up].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        stopPolling()
        phase = .idle
    }

    private func mouseDown() {
        phase = .pressed
        changeCountAtPress = NSPasteboard(name: .drag).changeCount
    }

    private func mouseDragged() {
        guard phase == .pressed else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // The drag pasteboard only changes once a real drag session starts.
        guard pasteboard.changeCount != changeCountAtPress else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dragLog.debug("drag started: \(urls.count) file(s)")
        guard !urls.isEmpty else {
            phase = .otherDrag
            return
        }
        phase = .fileDrag
        files = urls
        previousFlags = NSEvent.modifierFlags.intersection(Prefs.wheelModifierFlags)
        previousKeys = pressedWheelKeys()
        startPolling()
    }

    private func mouseUp() {
        let wasFileDrag = phase == .fileDrag
        phase = .idle
        stopPolling()
        if wasFileDrag { onDragEnded() }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    private func poll() {
        // Safety net: if the release happened somewhere we couldn't observe, stop.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return mouseUp() }
        let flags = NSEvent.modifierFlags.intersection(Prefs.wheelModifierFlags)
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        let keys = pressedWheelKeys()
        let newKeys = keys.subtracting(previousKeys)
        previousKeys = keys
        let kind = Prefs.wheel(for: pressed) ?? Prefs.wheelKeyCodes.first { newKeys.contains($0.1) }?.0
        guard let kind else { return }
        dragLog.debug("wheel key tap → \(kind.rawValue, privacy: .public)")
        onModifierTap(kind, files)
    }

    private func pressedWheelKeys() -> Set<CGKeyCode> {
        Set(Prefs.wheelKeyCodes.map(\.1).filter { CGEventSource.keyState(.combinedSessionState, key: $0) })
    }
}
