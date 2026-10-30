import AVFoundation
import KumquatCore
import Observation
import SwiftUI

/// The first picture of a selection shown upright (an image, or a PDF's first page), so Crop and
/// Rotate can be judged before running: crop draws the kept area, rotate turns the picture live.
@Observable
final class StillPreviewModel {
    let url: URL
    let isPDF: Bool
    private(set) var image: CGImage?
    private(set) var failure: String?
    /// Upright pixel size of the original image; `nil` for a PDF.
    private(set) var pixelSize: CGSize?
    @ObservationIgnored private var loading: Task<Void, Never>?

    nonisolated static let longSide = 1600

    init(url: URL) {
        self.url = url
        isPDF = FileFormat.detect(url) == .pdf
        loading = Task { [weak self] in await self?.load() }
    }

    func stop() {
        loading?.cancel()
    }

    private func load() async {
        let url = url, isPDF = isPDF
        do {
            let (image, size) = try await runBlocking { try Self.render(url, isPDF: isPDF) }
            guard !Task.isCancelled else { return }
            self.image = image
            pixelSize = size
        } catch {
            if !Task.isCancelled { failure = String(localized: "No preview: \(error.localizedDescription)") }
        }
    }

    private nonisolated static func render(_ url: URL, isPDF: Bool) throws -> (CGImage, CGSize?) {
        guard isPDF else { return (try ImageEngine.decode(url, maxPixelSize: longSide), ImageProbe.orientedPixelSize(url)) }
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { throw KumquatError.cannotOpen(url.lastPathComponent) }
        let box = page.getBoxRect(.cropBox)
        guard let image = PDFEngine.render(page, scale: CGFloat(longSide) / max(box.width, box.height, 1)) else {
            throw KumquatError.cannotDecode(url.lastPathComponent)
        }
        return (image, nil)
    }
}

// MARK: - Editor

/// The picture plus whatever the tool's options call for: a crop frame (region), or a live turn (angle, tilt).
struct StillEditor: View {
    let model: StillPreviewModel
    let parameters: [ToolParameter]
    @Binding var values: [String: String]

    private var crops: Bool { parameters.contains { $0.kind == .region } }
    private func has(_ key: String) -> Bool { parameters.contains { $0.key == key } }
    /// Blur Faces draws only in "area" mode; Sign always places a box.
    private var shape: String {
        if has("aspect") { return values["aspect"] ?? "auto" }
        if has("mode") { return values["mode"] == "area" ? "free" : "auto" }
        return "free"
    }
    private var turn: Int { Int(values["angle"] ?? "") ?? 0 }
    private var tilt: Double { Double(values["tilt"] ?? "") ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let image = model.image {
                    if crops { cropping(image) } else { turning(image) }
                } else if let failure = model.failure {
                    Text(failure).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: VideoEditor.width, height: VideoEditor.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // The signature starts as a small box at the bottom right.
            if has("signature"), (values["region"] ?? "").isEmpty { values["region"] = "0.6000:0.8000:0.3200:0.1200" }
            applyShape(force: false)
        }
        .onChange(of: model.image != nil) { applyShape(force: false) }
        .onChange(of: shape) { applyShape(force: true) }
    }

    private func cropping(_ image: CGImage) -> some View {
        ZStack {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            if shape == "auto" {
                (has("mode") ? Text("Faces are found and blurred automatically")
                    : model.isPDF ? Text("White margins are trimmed from every page") : Text("Plain borders are found and trimmed automatically"))
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
            } else {
                CropOverlay(region: CropOverlay.region(in: $values), presentationSize: CGSize(width: image.width, height: image.height),
                            aspect: VideoEditor.aspect(shape))
            }
        }
    }

    /// Turned as it will be saved: a tilt zooms in so the corners stay filled, as the output is cropped.
    private func turning(_ image: CGImage) -> some View {
        GeometryReader { geometry in
            let quarter = turn % 180 != 0
            let turned = quarter ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
            let box = AVMakeRect(aspectRatio: turned, insideRect: CGRect(origin: .zero, size: geometry.size)).size
            Image(decorative: image, scale: 1).resizable()
                .frame(width: quarter ? box.height : box.width, height: quarter ? box.width : box.height)
                .rotationEffect(.degrees(Double(turn) + tilt))
                .scaleEffect(1 / ImageEngine.straightenScale(turned, degrees: tilt))
                .frame(width: box.width, height: box.height)
                .clipped()
                .overlay { if tilt != 0 { StraightenGrid() } }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.snappy, value: turn)
    }

    private var summary: String {
        guard model.image != nil else { return "" }
        if has("signature") { return String(localized: "Drag the box to where the signature goes") }
        if has("mode") { return shape == "auto" ? "" : String(localized: "Drag the box over what to hide") }
        if crops {
            guard shape != "auto" else { return "" }
            guard let size = model.pixelSize else { return String(localized: "Applies to every page") }
            let area = CropOverlay.region(in: $values).wrappedValue
            return String(localized: "Keeps \(Int(area.width * size.width)) × \(Int(area.height * size.height))")
        }
        guard let size = model.pixelSize else { return String(localized: "Turns every page") }
        let turned = turn % 180 != 0 ? CGSize(width: size.height, height: size.width) : size
        guard abs(tilt) >= 0.01 else {
            let lossless = [.jpg, .heic, .tiff].contains(FileFormat.detect(model.url))
            return "\(Int(turned.width)) × \(Int(turned.height))" + (lossless ? " · " + String(localized: "lossless") : "")
        }
        let scale = ImageEngine.straightenScale(turned, degrees: tilt)
        return String(localized: "Keeps \(Int(turned.width * scale)) × \(Int(turned.height * scale))")
    }

    private func applyShape(force: Bool) {
        guard crops, let image = model.image else { return }
        CropOverlay.apply(shape: shape, to: $values, in: CGSize(width: image.width, height: image.height), force: force)
    }
}

/// Guides for lining up horizons and edges while straightening.
private struct StraightenGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let size = geometry.size
                for column in 1..<6 {
                    path.move(to: CGPoint(x: size.width * CGFloat(column) / 6, y: 0))
                    path.addLine(to: CGPoint(x: size.width * CGFloat(column) / 6, y: size.height))
                }
                for row in 1..<4 {
                    path.move(to: CGPoint(x: 0, y: size.height * CGFloat(row) / 4))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(row) / 4))
                }
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
