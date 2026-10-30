import KumquatCore
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnails of every page of the first PDF, rendered once in the background.
@Observable
final class PageGridModel {
    let url: URL
    private(set) var thumbnails: [NSImage] = []
    private(set) var failure: String?

    init(url: URL) {
        self.url = url
        Task { [weak self] in await self?.load() }
    }

    private func load() async {
        let url = url
        do {
            let images = try await runBlocking {
                guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw KumquatError.cannotOpen(url.lastPathComponent) }
                return (0..<document.pageCount).compactMap { index -> SendableImage? in
                    document.page(at: index).map { SendableImage(image: $0.thumbnail(of: NSSize(width: 200, height: 260), for: .cropBox)) }
                }
            }
            thumbnails = images.map(\.image)
        } catch {
            failure = String(localized: "No preview: \(error.localizedDescription)")
        }
    }
}

/// NSImage built off the main thread and handed over once, never mutated.
private struct SendableImage: @unchecked Sendable { let image: NSImage }

/// Reorder, delete and turn pages; the result is the `order` value ("3,1r90,2").
struct PageGrid: View {
    let model: PageGridModel
    @Binding var order: String
    @State private var pages: [Page] = []
    @State private var selected: Set<Int> = []
    @State private var dragging: Page?

    struct Page: Identifiable, Hashable {
        let index: Int
        var turn = 0
        var id: Int { index }
    }

    private let columns = Array(repeating: GridItem(.fixed(122), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(pages) { page in cell(page) }
                }
                .padding(10)
            }
            .frame(width: VideoEditor.width, height: VideoEditor.height + 60)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let failure = model.failure {
                    Text(failure).font(.caption).foregroundStyle(.white.opacity(0.8))
                } else if model.thumbnails.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                Button("Turn", systemImage: "rotate.right") { turnSelected() }.disabled(selected.isEmpty)
                Button("Delete", systemImage: "trash") { deleteSelected() }.disabled(selected.isEmpty || selected.count == pages.count)
                Button("Restore") { reset() }
                Spacer()
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .onChange(of: model.thumbnails.count) { reset() }
        .onAppear { if pages.isEmpty { reset() } }
        .onKeyPress(.delete) {
            deleteSelected()
            return .handled
        }
        .onKeyPress("r") {
            turnSelected()
            return .handled
        }
    }

    private func cell(_ page: Page) -> some View {
        let isSelected = selected.contains(page.index)
        return VStack(spacing: 4) {
            Group {
                if page.index < model.thumbnails.count {
                    Image(nsImage: model.thumbnails[page.index]).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.gray.opacity(0.3))
                }
            }
            .rotationEffect(.degrees(Double(page.turn)))
            .frame(width: 110, height: 140)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.orange : .clear, lineWidth: 3))
            Text("\(page.index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if isSelected { selected.remove(page.index) } else { selected.insert(page.index) }
            } else {
                selected = [page.index]
            }
        }
        .onDrag {
            dragging = page
            return NSItemProvider(object: String(page.index) as NSString)
        }
        .onDrop(of: [.text], delegate: Reorder(target: page, pages: $pages, dragging: $dragging, commit: commit))
    }

    private var summary: String {
        let removed = model.thumbnails.count - pages.count
        let turned = pages.filter { $0.turn != 0 }.count
        var parts = [String(localized: "\(pages.count) pages")]
        if removed > 0 { parts.append(String(localized: "\(removed) deleted")) }
        if turned > 0 { parts.append(String(localized: "\(turned) turned")) }
        return parts.joined(separator: " · ")
    }

    private func reset() {
        pages = model.thumbnails.indices.map { Page(index: $0) }
        selected = []
        commit()
    }

    private func turnSelected() {
        for position in pages.indices where selected.contains(pages[position].index) {
            pages[position].turn = (pages[position].turn + 90) % 360
        }
        commit()
    }

    private func deleteSelected() {
        guard selected.count < pages.count else { return }
        pages.removeAll { selected.contains($0.index) }
        selected = []
        commit()
    }

    private func commit() {
        order = pages.map { "\($0.index + 1)" + ($0.turn == 0 ? "" : "r\($0.turn)") }.joined(separator: ",")
    }

    /// Moves the dragged page to the spot under the pointer as it passes over the others.
    private struct Reorder: DropDelegate {
        let target: Page
        @Binding var pages: [Page]
        @Binding var dragging: Page?
        let commit: () -> Void

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging != target,
                  let from = pages.firstIndex(of: dragging), let to = pages.firstIndex(of: target) else { return }
            withAnimation(.snappy) { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            commit()
            return true
        }
    }
}
