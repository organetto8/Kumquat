import AppKit
import KumquatCore
import SwiftUI

/// What the menu bar panel asks the app to do.
enum StatusCommand {
    case selection(WheelKind)
    case files(WheelKind, [URL])
    case allActions, basket, settings, welcome, about, diagnostics, checkForUpdates, installUpdate, quit
}

/// The panel under the menu bar icon. Like a menu it closes on a click elsewhere, on Escape and
/// after a choice, but it can also take files dropped on its wheels.
final class StatusPanel {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 12

    private let panel = OverlayPanel(size: CGSize(width: StatusPanel.width, height: 300))
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// The status item's window: a click there toggles the panel rather than dismissing it.
    private weak var anchorWindow: NSWindow?

    var onClose: () -> Void = {}
    private(set) var isOpen = false

    init() {
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Shows the panel under `anchor` (screen coordinates). `takesKeyboard` is off while a drag is
    /// hovering, so the drag keeps going undisturbed.
    func show(_ content: StatusPanelView, below anchor: NSRect, anchorWindow: NSWindow?, takesKeyboard: Bool) {
        let host = FirstClickHostingView(rootView: content)
        let size = host.fittingSize
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.mask
        host.frame = backdrop.bounds
        host.autoresizingMask = [.width, .height]
        backdrop.addSubview(host)
        panel.contentView = backdrop
        panel.setFrame(frame(for: size, below: anchor), display: true)
        self.anchorWindow = anchorWindow

        if !isOpen {
            isOpen = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            startMonitoring()
        }
        if takesKeyboard { panel.makeKey() }
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        stopMonitoring()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
        onClose()
    }

    /// Centred under the icon, kept on its screen.
    private func frame(for size: CGSize, below anchor: NSRect) -> NSRect {
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
    }

    /// Rounded corners for the blur, stretched to any panel size.
    private static let mask: NSImage = {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }()

    // MARK: - Dismissal

    private func startMonitoring() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let outside = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel, !self.isToggleClick(event) else { return }
                self.close()
            }
            return event
        }
        monitors = [outside, inside].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// A plain click on the icon, which closes the panel through the icon's own toggle.
    private func isToggleClick(_ event: NSEvent) -> Bool {
        event.window === anchorWindow && event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
    }
}

/// Takes the first click while the panel isn't key, as after a drag opened it.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

struct StatusPanelView: View {
    let basket: BasketModel
    let basketVisible: Bool
    /// A downloaded and verified update, waiting for the user to install it.
    let update: ReleaseVersion?
    let perform: (StatusCommand) -> Void

    @AppStorage(Prefs.Key.dragGesture) private var dragGesture = true
    @State private var launchAtLogin = LoginItem.isEnabled

    private var wheelKeys: String {
        WheelKind.allCases.map { Prefs.modifier(for: $0).symbol }.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            wheels
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider().padding(.horizontal, 12)
            tips
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider().padding(.horizontal, 12)
            options
                .padding(6)
            Divider().padding(.horizontal, 12)
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: StatusPanel.width)
        // Long translations wrap and the panel grows to fit, instead of truncating to one line.
        .fixedSize(horizontal: false, vertical: true)
        .overlay(RoundedRectangle(cornerRadius: StatusPanel.cornerRadius).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .tint(.orange)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kumquat").font(.system(size: 14, weight: .semibold))
                Text("Offline, instant, unlimited.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings…", shortcut: ",") { perform(.settings) }
        }
    }

    private var wheels: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(WheelKind.allCases) { kind in
                    WheelTile(kind: kind, choose: { perform(.selection(kind)) }, drop: { perform(.files(kind, $0)) })
                }
            }
            Text("Click for the Finder selection, or drop files on a wheel.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left").frame(width: 16)
                Text("Drag a file, then tap \(wheelKeys)").fixedSize(horizontal: false, vertical: true)
            }
            // Dimmed rather than hidden, so switching the gesture doesn't resize the panel.
            .opacity(dragGesture ? 1 : 0.45)
            if let combo = Prefs.hotKey {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").frame(width: 16)
                    Text("Shortcut for the Finder selection").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    KeyCap(text: combo.display)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var options: some View {
        VStack(spacing: 2) {
            if let update {
                Button { perform(.installUpdate) } label: {
                    RowLabel(symbol: "arrow.down.circle", title: "Install Kumquat \(update.description) and Relaunch")
                }
                .buttonStyle(RowButtonStyle())
            }
            Button { perform(.allActions) } label: {
                HStack {
                    RowLabel(symbol: "list.bullet", title: "All Actions")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(RowButtonStyle())
            .help("Every conversion, tool and action, by kind of file")
            Button { perform(.basket) } label: {
                HStack {
                    RowLabel(symbol: "basket", title: basketVisible ? "Hide Basket" : "Show Basket")
                    Spacer()
                    if !basket.files.isEmpty {
                        Text(basket.files.count, format: .number)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
            SwitchRow(symbol: "hand.draw", title: "Open Wheels While Dragging", isOn: $dragGesture)
            SwitchRow(symbol: "sunrise", title: "Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LoginItem.isEnabled else { return }
                    do {
                        try LoginItem.setEnabled(enabled)
                    } catch {
                        launchAtLogin = LoginItem.isEnabled
                        NSApp.activate()
                        NSAlert(error: error).runModal()
                    }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { perform(.welcome) } label: {
                Label("How Kumquat Works", systemImage: "questionmark.circle").font(.system(size: 12))
            }
            .buttonStyle(RowButtonStyle(fillsWidth: false))
            .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("About Kumquat") { perform(.about) }
                if Updater.isAvailable { Button("Check for Updates…") { perform(.checkForUpdates) } }
                Button("Copy Diagnostic Info") { perform(.diagnostics) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("More")
            .padding(.horizontal, 4)
            IconButton(symbol: "power", help: "Quit Kumquat", shortcut: "q") { perform(.quit) }
        }
    }
}

/// One wheel: click it for the Finder selection, or drop files on it.
private struct WheelTile: View {
    let kind: WheelKind
    let choose: () -> Void
    let drop: ([URL]) -> Void
    @State private var hovering = false
    @State private var targeted = false

    private var lit: Bool { hovering || targeted }

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(lit ? Color.white : Color.orange)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(lit ? Color.orange : Color.orange.opacity(0.15)))
                Text(kind.title).font(.system(size: 12, weight: .semibold))
                KeyCap(text: Prefs.modifier(for: kind).symbol)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(lit ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.orange : Color.primary.opacity(0.06), lineWidth: targeted ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: lit)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            drop(files)
            return true
        } isTargeted: { targeted = $0 }
        .help(kind.selectionTitle)
        .accessibilityLabel(kind.selectionTitle)
    }
}

private struct RowLabel: View {
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SwitchRow: View {
    let symbol: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            RowLabel(symbol: symbol, title: title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// Lights up under the pointer, like a menu item.
private struct RowButtonStyle: ButtonStyle {
    var fillsWidth = true

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Row(configuration: configuration, fillsWidth: fillsWidth)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let fillsWidth: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}

extension WheelKind {
    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "wand.and.stars"
        case .actions: "paperplane"
        }
    }

    /// What clicking the wheel does, for the menu, tooltips and VoiceOver.
    var selectionTitle: String {
        switch self {
        case .convert: String(localized: "Convert Finder Selection…")
        case .tools: String(localized: "Edit Finder Selection…")
        case .actions: String(localized: "Send Finder Selection…")
        }
    }
}
