import AppKit
import KumquatCore
import SwiftUI

/// Wi-Fi Receive, the other way from Wi-Fi Share: a QR code opens a page on the phone that sends files
/// straight into a folder on this Mac, over the local network only. It stops when the window closes, or
/// after 15 minutes with nothing arriving. Only the private link in the QR code can send.
final class WiFiReceive {
    private var server: UploadServer?
    private var panel: NSPanel?
    private var countdown: DispatchWorkItem?
    private var state: WiFiReceiveState?
    private var finished: (([URL], URL) -> Void)?

    /// `finished` gets what arrived, once the window closes.
    func receive(into folder: URL, failure: @escaping (String) -> Void, finished: @escaping (_ files: [URL], _ folder: URL) -> Void) {
        stop()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            failure(KumquatError.cannotWrite(folder.lastPathComponent).localizedDescription)
            return
        }
        guard let address = WiFiShare.localAddress() else {
            failure(String(localized: "Connect this Mac to a Wi-Fi or wired network first."))
            return
        }
        Task {
            do {
                let token = WiFiShare.token()
                let server = try UploadServer(folder: folder, token: token) { [weak self] event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
                }
                let port = try await server.start()
                self.server = server
                self.finished = finished
                show(url: URL(string: "http://\(address):\(port)/\(token)/")!, folder: folder)
            } catch {
                failure(error.localizedDescription)
                stop()
            }
        }
    }

    func stop() {
        countdown?.cancel()
        countdown = nil
        server?.stop()
        server = nil
        panel?.orderOut(nil)
        panel = nil
        if let state, !state.received.isEmpty { finished?(state.received, state.folder) }
        state = nil
        finished = nil
    }

    private func show(url: URL, folder: URL) {
        let state = WiFiReceiveState(folder: folder)
        self.state = state
        let view = WiFiReceiveView(url: url, qr: WiFiShare.qrCode(url.absoluteString), state: state) { [weak self] in self?.stop() }
        let panel = WiFiShare.panel(title: ActionKind.wifiReceive.title, content: view) { [weak self] in self?.stop() }
        panel.orderFrontRegardless()
        self.panel = panel
        restartCountdown()
    }

    private func handle(_ event: UploadServer.Event) {
        guard let state else { return }
        switch event {
        case .started:
            state.arriving += 1
        case .received(let url):
            state.arriving = max(0, state.arriving - 1)
            state.received.append(url)
        case .failed:
            state.arriving = max(0, state.arriving - 1)
            state.failed += 1
        }
        restartCountdown()
    }

    /// Fifteen minutes from the last file; never while one is still arriving.
    private func restartCountdown() {
        countdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if (state?.arriving ?? 0) > 0 { restartCountdown() } else { stop() }
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WiFiShare.lifetime, execute: work)
    }
}

@Observable
final class WiFiReceiveState {
    let folder: URL
    var received: [URL] = []
    var arriving = 0
    var failed = 0

    init(folder: URL) { self.folder = folder }
}

private struct WiFiReceiveView: View {
    let url: URL
    let qr: NSImage
    let state: WiFiReceiveState
    let stop: () -> Void

    private var status: LocalizedStringKey {
        if state.arriving > 0 { return "Receiving…" }
        if state.received.isEmpty { return "Waiting for files from the phone…" }
        return "Received: \(state.received.count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Receive into “\(state.folder.lastPathComponent)”").font(.headline).lineLimit(1).truncationMode(.middle)
            WiFiCode(url: url, qr: qr)
            // Fixed height, so the window doesn't jump as files arrive.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if state.arriving > 0 { ProgressView().controlSize(.small) }
                    Text(status).font(.callout.weight(.medium))
                    Spacer()
                    if state.failed > 0 { Text("Didn't arrive whole: \(state.failed)").font(.caption).foregroundStyle(.red) }
                }
                ForEach(state.received.suffix(3).reversed(), id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "checkmark.circle.fill").font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("Receiving stops when you close this window, or after 15 minutes with nothing arriving.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") {
                    if state.received.isEmpty { NSWorkspace.shared.open(state.folder) } else { NSWorkspace.shared.activateFileViewerSelecting(state.received) }
                }
                Spacer()
                Button("Stop Receiving", action: stop).keyboardShortcut(.cancelAction).tint(.orange)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}
