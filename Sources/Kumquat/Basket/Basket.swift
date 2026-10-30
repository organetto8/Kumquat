import AppKit
import KumquatCore
import Observation
@preconcurrency import QuickLookThumbnailing
import SwiftUI

// MARK: - Basket

@Observable
final class BasketModel {
    private(set) var files: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }

    func clear() { files.removeAll() }
}

/// Drop shelf: park files here, drag them out later. Holds references only — closing it
/// never touches the files.
final class Basket {
    let model = BasketModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func toggle() { isVisible ? close() : show() }

    func close() {
        panel?.orderOut(nil)
        model.clear()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Basket")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: BasketView(model: model, close: { [weak self] in self?.close() }))
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 270, y: visible.midY - 180))
        }
        panel.setFrameAutosaveName("KumquatBasket")
        return panel
    }
}

private struct BasketView: View {
    @Bindable var model: BasketModel
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.files.isEmpty ? "Basket" : "Basket · \(model.files.count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.files.isEmpty {
                    Button("Clear", action: model.clear).buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 30)
            .padding(.bottom, 6)
            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "basket").font(.system(size: 30, weight: .light))
                    Text("Drop files to keep them at hand").font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 10) {
                        ForEach(model.files, id: \.self) { url in
                            BasketItemView(url: url)
                                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Divider()
                                    Button("Remove from Basket") { model.remove(url) }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 220, minHeight: 240)
        .background(targeted ? Color.orange.opacity(0.12) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

private struct BasketItemView: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(width: 96)
        .help(url.path)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = representation.nsImage
            }
        }
    }
}
