import AppKit
import KumquatCore

/// The radial wheel. Pure Core Graphics on top of a vibrancy backdrop; redraws only when the
/// highlighted segment changes. Accepts the in-flight drag as a drop target, and also works
/// with the mouse and the keyboard.
final class WheelView: NSView {
    static let side: CGFloat = 440
    static let outerRadius: CGFloat = 178
    static let innerRadius: CGFloat = 66

    var wheel: Wheel? {
        didSet {
            page = 0
            highlighted = keyboardMode && !(wheel?.items.isEmpty ?? true) ? 0 : nil
            needsDisplay = true
        }
    }

    /// Most segments one ring shows; longer wheels page, with "More" in the last segment.
    static let capacity = 12

    /// What a segment holds: a choice, or the "More" segment that turns to the next page.
    enum Slot {
        case item(WheelItem)
        case more(page: Int, pages: Int, hidden: Int)
    }

    private var page = 0 {
        didSet { if page != oldValue { needsDisplay = true } }
    }
    private var springWork: DispatchWorkItem?

    private var slots: [Slot] {
        guard let items = wheel?.items else { return [] }
        guard items.count > Self.capacity else { return items.map(Slot.item) }
        let perPage = Self.capacity - 1
        let pages = (items.count + perPage - 1) / perPage
        let start = min(page, pages - 1) * perPage
        let shown = items[start..<min(start + perPage, items.count)]
        return shown.map(Slot.item) + [.more(page: page, pages: pages, hidden: items.count - shown.count)]
    }

    private func turnPage() {
        guard case .more(let current, let pages, _)? = slots.last else { return }
        page = (current + 1) % pages
        highlighted = slots.count - 1
    }
    var files: [URL] = []
    var keyboardMode = false
    var onChoose: (WheelItem, [URL]) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    var onSwitch: (WheelKind) -> Void = { _ in }

    private var highlighted: Int? {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }
    private var iconCache: [String: NSImage] = [:]
    private var previousFlags: NSEvent.ModifierFlags = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: - Geometry

    private func step(_ count: Int) -> CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    /// Segment 0 sits at 12 o'clock; the rest follow clockwise.
    private func midAngle(_ index: Int, count: Int) -> CGFloat { .pi / 2 - CGFloat(index) * step(count) }

    enum Hit { case item(Int), center, outside }

    func hit(_ point: CGPoint) -> Hit {
        let count = slots.count
        guard count > 0 else { return .outside }
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance < Self.innerRadius { return .center }
        if distance > Self.outerRadius + 24 { return .outside }
        var offset = .pi / 2 - atan2(dy, dx) + step(count) / 2
        offset = offset.truncatingRemainder(dividingBy: 2 * .pi)
        if offset < 0 { offset += 2 * .pi }
        return .item(Int(offset / step(count)) % count)
    }

    private func sector(_ index: Int, count: Int) -> NSBezierPath {
        let gap: CGFloat = count > 1 ? 0.012 : 0
        let mid = midAngle(index, count: count)
        let start = (mid + step(count) / 2 - gap) * 180 / .pi
        let end = (mid - step(count) / 2 + gap) * 180 / .pi
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: Self.outerRadius - 3, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: Self.innerRadius + 5, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        return path
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let wheel else { return }
        let slots = slots
        let count = slots.count
        let accent = NSColor.systemOrange

        for (index, slot) in slots.enumerated() {
            let isHighlighted = highlighted == index
            let item = displayItem(slot)
            if isHighlighted {
                (item.isAvailable ? accent : NSColor.systemGray).withAlphaComponent(0.92).setFill()
                sector(index, count: count).fill()
            }
            if count > 1 {
                // Hairline separator on the segment's leading edge.
                let angle = midAngle(index, count: count) + step(count) / 2
                let separator = NSBezierPath()
                separator.move(to: CGPoint(x: center.x + cos(angle) * (Self.innerRadius + 8), y: center.y + sin(angle) * (Self.innerRadius + 8)))
                separator.line(to: CGPoint(x: center.x + cos(angle) * (Self.outerRadius - 8), y: center.y + sin(angle) * (Self.outerRadius - 8)))
                NSColor.labelColor.withAlphaComponent(0.08).setStroke()
                separator.lineWidth = 1
                separator.stroke()
            }
            let angle = midAngle(index, count: count)
            let radius = (Self.innerRadius + Self.outerRadius) / 2 + 4
            let anchor = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let color: NSColor = isHighlighted ? .white : (item.isAvailable ? .labelColor : .tertiaryLabelColor)
            drawItem(item, at: anchor, color: color, compact: count > 10)
        }
        drawCenter(wheel, slots: slots)
    }

    /// The "More" segment drawn like a choice.
    private func displayItem(_ slot: Slot) -> WheelItem {
        switch slot {
        case .item(let item): item
        case .more(let page, let pages, _):
            WheelItem(operation: .action(.basket), title: String(localized: "More \(page + 1)/\(pages)"), symbol: "ellipsis.circle", unavailableReason: nil)
        }
    }

    private func drawItem(_ item: WheelItem, at point: CGPoint, color: NSColor, compact: Bool) {
        let iconSize: CGFloat = compact ? 17 : 20
        if let icon = icon(item.symbol, size: iconSize, color: color) {
            let size = icon.size
            icon.draw(in: CGRect(x: point.x - size.width / 2, y: point.y + 2, width: size.width, height: size.height))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 10 : 11, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        let width: CGFloat = compact ? 62 : 74
        label.draw(in: CGRect(x: point.x - width / 2, y: point.y - 16, width: width, height: 15))
    }

    private func drawCenter(_ wheel: Wheel, slots: [Slot]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let width = Self.innerRadius * 2 - 18
        var lines: [(String, NSFont, NSColor)] = []

        if let index = highlighted, index < slots.count, case .more(let page, let pages, let hidden) = slots[index] {
            lines.append((String(localized: "More"), .systemFont(ofSize: 13, weight: .bold), .labelColor))
            lines.append((String(localized: "Page \(page + 1) of \(pages) · \(hidden) more"), .systemFont(ofSize: 9.5), .secondaryLabelColor))
        } else if let index = highlighted, index < slots.count, case .item(let item) = slots[index] {
            lines.append((item.title, .systemFont(ofSize: 13, weight: .bold), .labelColor))
            lines.append((item.unavailableReason ?? description(item.operation), .systemFont(ofSize: 9.5), item.isAvailable ? .secondaryLabelColor : .systemRed))
        } else {
            let items = wheel.items
            lines.append((wheel.kind.title, .systemFont(ofSize: 14, weight: .bold), .labelColor))
            lines.append((wheel.subject, .systemFont(ofSize: 10), .secondaryLabelColor))
            lines.append((items.isEmpty ? String(localized: "Nothing for this file") : (keyboardMode ? String(localized: "↵ apply · esc cancel") : String(localized: "drop on a choice")), .systemFont(ofSize: 9), .tertiaryLabelColor))
        }
        let blocks = lines.map { text, font, color in
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let heights = blocks.map { min($0.boundingRect(with: CGSize(width: width, height: 60), options: [.usesLineFragmentOrigin]).height.rounded(.up), 28) }
        let legendHeight: CGFloat = 14
        var y = center.y + (heights.reduce(0, +) + legendHeight + 4) / 2
        for (block, height) in zip(blocks, heights) {
            y -= height
            block.draw(with: CGRect(x: center.x - width / 2, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        // Legend: which key opens which wheel, the current one in the accent colour.
        let legend = NSMutableAttributedString()
        for (index, kind) in WheelKind.allCases.enumerated() {
            if index > 0 { legend.append(NSAttributedString(string: "  ")) }
            let active = kind == wheel.kind
            legend.append(NSAttributedString(string: Prefs.modifier(for: kind).symbol, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .bold : .regular),
                .foregroundColor: active ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        legend.draw(in: CGRect(x: center.x - width / 2, y: y - legendHeight - 4, width: width, height: legendHeight))
    }

    private func description(_ operation: KumquatCore.Operation) -> String {
        switch operation {
        case .convert(let format): String(localized: "Convert to \(format.displayName)")
        case .tool(let tool):
            if Catalog.parameters(for: tool, category: wheel?.category).isEmpty {
                String(localized: "Runs instantly")
            } else if Catalog.runsInstantly(tool, category: wheel?.category) {
                String(localized: "Instant · ⌥ options")
            } else {
                String(localized: "Options · ⌥ skips")
            }
        case .action(let action): action == .basket ? String(localized: "Keep files at hand") : String(localized: "Instant")
        }
    }

    private func icon(_ symbol: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(symbol)|\(size)|\(color.description)"
        if let cached = iconCache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        iconCache[key] = image
        return image
    }

    // MARK: - Drop target (the drag that opened the wheel lands here)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .item(let index) = hit(convert(sender.draggingLocation, from: nil)) else {
            highlighted = nil
            springWork?.cancel()
            return []
        }
        if highlighted != index { springWork?.cancel() }
        highlighted = index
        switch slots[index] {
        case .more:
            // Spring-loaded: resting on "More" turns the page, again and again while the drag stays.
            if springWork == nil || springWork?.isCancelled == true {
                let work = DispatchWorkItem { [weak self] in
                    self?.springWork = nil
                    self?.turnPage()
                }
                springWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            return []
        case .item(let item):
            return item.isAvailable ? .copy : []
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        springWork?.cancel()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springWork?.cancel()
        guard case .item(let index) = hit(convert(sender.draggingLocation, from: nil)),
              case .item(let item) = slots[index], item.isAvailable else { return false }
        let dropped = sender.fileURLs
        onChoose(item, dropped.isEmpty ? files : dropped)
        return true
    }

    // MARK: - Mouse & keyboard

    override func mouseMoved(with event: NSEvent) {
        if case .item(let index) = hit(convert(event.locationInWindow, from: nil)) {
            highlighted = index
        } else if !keyboardMode {
            highlighted = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        switch hit(convert(event.locationInWindow, from: nil)) {
        case .item(let index): choose(index)
        case .center, .outside: onCancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        let count = slots.count
        switch event.keyCode {
        case 53: onCancel()
        case 36, 76: if let highlighted { choose(highlighted) }
        case 123, 126: if count > 0 { highlighted = ((highlighted ?? 0) - 1 + count) % count }
        case 124, 125, 48: if count > 0 { highlighted = ((highlighted ?? -1) + 1) % count }
        default:
            if let kind = Prefs.wheel(forKeyCode: event.keyCode) { onSwitch(kind) } else { super.keyDown(with: event) }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(Prefs.wheelModifierFlags)
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        if !pressed.isEmpty, let kind = Prefs.wheel(for: pressed) { onSwitch(kind) }
    }

    private func choose(_ index: Int) {
        guard index < slots.count else { return }
        guard case .item(let item) = slots[index] else {
            turnPage()
            return
        }
        guard item.isAvailable else {
            NSSound.beep()
            return
        }
        onChoose(item, files)
    }
}
