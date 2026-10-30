import AppKit

/// Menu-bar icon: click toggles the panel, right-click opens the menu, files dropped on it open.
/// A file drag resting on it opens the panel, so the drop can pick a wheel.
final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dropView = StatusDropView(frame: .zero)

    var onLeftClick: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var onDragRest: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }

    /// Keeps the icon lit while the panel is open, as it is while a menu is.
    var isPanelOpen = false {
        didSet { item.button?.highlight(isPanelOpen) }
    }

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
        dropView.onDragRest = { [weak self] in self?.onDragRest() }
        dropView.onHover = { [weak self] in
            guard let self else { return }
            self.item.button?.highlight($0 || self.isPanelOpen)
        }
    }

    var buttonFrameOnScreen: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var buttonWindow: NSWindow? { item.button?.window }

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
    var onDragRest: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private var restWork: DispatchWorkItem?

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
        restWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onDragRest() }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        restWork?.cancel()
        onHover(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        restWork?.cancel()
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
