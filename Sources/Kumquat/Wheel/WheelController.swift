import AppKit
import KumquatCore

/// Borderless, non-activating overlay: it can take the keyboard without pulling Finder
/// (or whichever app owns the drag) out of the foreground.
final class OverlayPanel: NSPanel {
    var onCancel: () -> Void = {}

    init(size: CGSize, level: NSWindow.Level = .popUpMenu) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true  // must precede `level`: it resets the level to .floating
        self.level = level
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

final class WheelController {
    private let panel = OverlayPanel(size: CGSize(width: WheelView.side, height: WheelView.side))
    private let wheelView = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.side, height: WheelView.side))
    private(set) var files: [URL] = []
    private(set) var kind: WheelKind = .convert
    private var dismissWork: DispatchWorkItem?

    /// Runs the chosen item; the point is where follow-up UI (options) should appear.
    var onChoose: (WheelItem, [URL], Wheel, NSPoint) -> Void = { _, _, _, _ in }

    var isVisible: Bool { panel.isVisible }
    var isKeyboardMode: Bool { wheelView.keyboardMode }

    init() {
        let container = NSView(frame: wheelView.frame)
        container.wantsLayer = true
        let backdrop = NSVisualEffectView(frame: container.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.mask()
        container.addSubview(backdrop)
        container.addSubview(wheelView)
        container.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.dismiss() }

        wheelView.onCancel = { [weak self] in self?.dismiss() }
        wheelView.onSwitch = { [weak self] kind in self?.switchTo(kind) }
        wheelView.onChoose = { [weak self] item, files in
            guard let self, let wheel = self.wheelView.wheel else { return }
            let anchor = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            self.dismiss()
            self.onChoose(item, files, wheel, anchor)
        }
    }

    /// Ring + centre disc, so the blur only shows where the wheel is.
    private static func mask() -> NSImage {
        let side = WheelView.side
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = CGPoint(x: side / 2, y: side / 2)
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - WheelView.outerRadius, y: center.y - WheelView.outerRadius,
                                                   width: WheelView.outerRadius * 2, height: WheelView.outerRadius * 2))
            ring.appendOval(in: CGRect(x: center.x - WheelView.innerRadius, y: center.y - WheelView.innerRadius,
                                       width: WheelView.innerRadius * 2, height: WheelView.innerRadius * 2))
            ring.windingRule = .evenOdd
            ring.fill()
            let inner = WheelView.innerRadius - 5
            NSBezierPath(ovalIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)).fill()
            return true
        }
    }

    /// Shows the wheel centred on `point` (screen coordinates), clamped to the screen.
    func present(_ kind: WheelKind, files: [URL], at point: NSPoint, keyboard: Bool) {
        dismissWork?.cancel()
        self.files = files
        self.kind = kind
        wheelView.files = files
        wheelView.keyboardMode = keyboard
        wheelView.wheel = Catalog.wheel(kind, for: files)

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - WheelView.side / 2, y: point.y - WheelView.side / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX - 40), visible.maxX - WheelView.side + 40)
            origin.y = min(max(origin.y, visible.minY - 40), visible.maxY - WheelView.side + 40)
        }
        let wasVisible = panel.isVisible
        panel.setFrameOrigin(origin)
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            if let layer = panel.contentView?.layer {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.86
                grow.toValue = 1
                grow.duration = 0.14
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(grow, forKey: "grow")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
            Sound.wheel()
        }
        if keyboard {
            panel.makeKey()
            panel.makeFirstResponder(wheelView)
        }
    }

    func switchTo(_ kind: WheelKind) {
        guard panel.isVisible, kind != self.kind else { return }
        self.kind = kind
        wheelView.wheel = Catalog.wheel(kind, for: files)
    }

    func dismiss() {
        dismissWork?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// The drag finished somewhere else (or on the centre): close, unless keyboard-driven.
    func dragEnded() {
        guard panel.isVisible, !wheelView.keyboardMode else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
