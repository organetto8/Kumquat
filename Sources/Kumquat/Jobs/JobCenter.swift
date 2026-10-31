import AppKit
import KumquatCore
import Observation
import SwiftUI

/// Runs operations through the core `Executor` and keeps the list the HUD shows.
@Observable
final class JobCenter {
    enum State: Equatable { case running, done, failed }

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var detail = ""
        var progress = 0.0
        var state = State.running
        var outputs: [URL] = []
    }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var onListChange: () -> Void = {}
    @ObservationIgnored var chooseFolder: () -> URL? = { nil }

    var isEmpty: Bool { jobs.isEmpty }
    var isRunning: Bool { jobs.contains { $0.state == .running } }

    // MARK: - Running

    func start(_ operation: KumquatCore.Operation, files: [URL], parameters: [String: String] = [:]) {
        guard let destination = resolveDestination() else { return }
        let job = Job(title: title(operation, files: files))
        jobs.append(job)
        onListChange()
        let id = job.id
        let request = JobRequest(operation: operation, inputs: files, parameters: parameters, destination: destination)
        tasks[id] = Task {
            let outcome = await Executor.run(request) { fraction in
                Task { @MainActor [weak self] in self?.update(id) { $0.progress = max($0.progress, fraction) } }
            }
            self.finish(id, outcome)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
        onListChange()
    }

    func reveal(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
    }

    /// A finished entry for instant actions (copy, move, OCR…).
    func notice(_ title: String, detail: String = "", outputs: [URL] = [], failed: Bool = false) {
        let job = Job(title: title, detail: detail, progress: 1, state: failed ? .failed : .done, outputs: outputs)
        jobs.append(job)
        onListChange()
        failed ? Sound.failed() : Sound.done()
        scheduleRemoval(job.id, after: failed ? 8 : 4)
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func finish(_ id: UUID, _ outcome: JobOutcome) {
        tasks[id] = nil
        if let text = outcome.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let failed = outcome.outputs.isEmpty && outcome.clipboardText == nil && outcome.notes.isEmpty
        update(id) { job in
            job.progress = 1
            job.outputs = outcome.outputs
            job.state = outcome.cancelled ? .failed : (failed ? .failed : .done)
            job.detail = Self.summary(outcome)
        }
        if outcome.cancelled {
            remove(id)
            return
        }
        failed ? Sound.failed() : Sound.done()
        if !failed, Prefs.revealWhenDone, !outcome.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outcome.outputs)
        }
        scheduleRemoval(id, after: failed ? 10 : outcome.notes.isEmpty ? 6 : 10)
    }

    private func scheduleRemoval(_ id: UUID, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.remove(id)
        }
    }

    static func summary(_ outcome: JobOutcome) -> String {
        var parts: [String] = outcome.notes.prefix(2).map { $0 }
        if let text = outcome.clipboardText {
            let lines = text.split(separator: "\n").count
            parts.append(String(localized: "Copied \(lines) lines of text"))
        }
        switch outcome.outputs.count {
        case 0: break
        case 1: parts.append(String(localized: "Saved “\(outcome.outputs[0].lastPathComponent)”"))
        case let count: parts.append(String(localized: "Saved \(count) files"))
        }
        if let failure = outcome.failures.first {
            let more = outcome.failures.count > 1 ? String(localized: " (+\(outcome.failures.count - 1) more)") : ""
            parts.append(failure.message + more)
        }
        if outcome.skipped > 0 { parts.append(String(localized: "skipped \(outcome.skipped)")) }
        return parts.joined(separator: " · ")
    }

    private func title(_ operation: KumquatCore.Operation, files: [URL]) -> String {
        let subject = files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) files")
        switch operation {
        case .convert(let format): return "\(subject) → \(format.displayName)"
        case .tool(let tool): return "\(tool.title) · \(subject)"
        case .action(let action): return "\(action.title) · \(subject)"
        }
    }

    private func resolveDestination() -> (@Sendable (URL) -> URL)? {
        switch Prefs.outputLocation {
        case .nextToOriginal:
            return { OutputNaming.defaultDirectory(for: $0) }
        case .downloads:
            let folder = OutputNaming.downloads
            return { _ in folder }
        case .custom:
            guard let folder = Prefs.customFolder ?? chooseFolder() else { return nil }
            Prefs.customFolder = folder
            return { _ in folder }
        case .ask:
            guard let folder = chooseFolder() else { return nil }
            return { _ in folder }
        }
    }
}

// MARK: - HUD

/// Small floating stack of job cards in the top-right corner.
final class JobHUD {
    private let center: JobCenter
    private let panel = OverlayPanel(size: CGSize(width: 340, height: 80), level: .floating)
    static let rowHeight: CGFloat = 66

    init(center: JobCenter) {
        self.center = center
        let host = NSHostingView(rootView: JobListView(center: center))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        center.onListChange = { [weak self] in self?.layout() }
    }

    private func layout() {
        let count = min(center.jobs.count, 6)
        guard count > 0 else {
            panel.orderOut(nil)
            return
        }
        let height = CGFloat(count) * Self.rowHeight + 16
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - 352, y: visible.maxY - height - 6, width: 340, height: height), display: true)
        panel.orderFrontRegardless()
    }
}

private struct JobListView: View {
    let center: JobCenter

    var body: some View {
        VStack(spacing: 6) {
            ForEach(center.jobs.suffix(6)) { job in
                JobRow(job: job, center: center)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct JobRow: View {
    let job: JobCenter.Job
    let center: JobCenter

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch job.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if job.state == .running {
                    ProgressView(value: job.progress).progressViewStyle(.linear).tint(.orange)
                } else {
                    Text(job.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if job.state == .running {
                Button { center.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
            } else {
                if !job.outputs.isEmpty {
                    Button("Show") { center.reveal(job.id) }.controlSize(.small)
                }
                Button { center.remove(job.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: JobHUD.rowHeight - 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}
