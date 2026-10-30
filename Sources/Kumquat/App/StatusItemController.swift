import AppKit

/// Menu-bar icon: click toggles the panel, right-click opens the menu, files dropped on it open.
final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dropView = StatusDropView(frame: .zero)

    var onLeftClick: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    init() {
        guard let button = item.button else { return }
        button.image = StatusIcon.make()
        button.toolTip = String(localized: "Kumquat — drop files here to convert")
        button.setAccessibilityLabel("Kumquat")
        dropView.frame = button.bounds
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        dropView.onClick = { [weak self] in self?.onLeftClick() }
        dropView.onRightClick = { [weak self] in self?.showMenu() }
        dropView.onDrop = { [weak self] in self?.onDrop($0) }
        dropView.onHover = { [weak self] in self?.item.button?.highlight($0) }
    }

    var buttonFrameOnScreen: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func showMenu() {
        guard let button = item.button else { return }
        button.highlight(true)
        menuProvider().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        button.highlight(false)
    }
}

/// Overlay that owns mouse + drag handling for the status button.
final class StatusDropView: NSView {
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        event.modifierFlags.contains(.control) ? onRightClick() : onClick()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !sender.fileURLs.isEmpty else { return [] }
        onHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(false)
        let urls = sender.fileURLs
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}

extension NSDraggingInfo {
    var fileURLs: [URL] {
        draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
