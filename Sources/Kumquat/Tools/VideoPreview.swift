import AppKit
import AVFoundation
import KumquatCore
import Observation
import SwiftUI

/// Plays the first video of a selection so a tool's options can be judged before running:
/// speed plays at the chosen rate, trim and GIF loop over the selection, crop shows the kept area,
/// rotate turns the picture.
/// Formats AVFoundation can't open (MKV, WebM, AVI, WMV, GIF) play from a small FFmpeg proxy.
@Observable
final class VideoPreviewModel {
    enum Phase: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    let url: URL
    let player = AVPlayer()
    private(set) var phase = Phase.loading(String(localized: "Loading preview…"))
    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    /// Displayed size (after rotation) of what is playing.
    private(set) var presentationSize = CGSize(width: 16, height: 9)
    /// Playing a lower-resolution stand-in, so pixel sizes aren't the original's.
    private(set) var usesProxy = false
    private(set) var frames: [CGImage?] = []

    /// Playback stays inside this range, looping.
    var loop: ClosedRange<Double>?
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    @ObservationIgnored var autoplay = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var proxy: URL?

    static let filmstripCount = 12
    static let proxyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Kumquat Previews", isDirectory: true)

    /// Proxies left behind when the app quit with a preview open.
    static func removeLeftoverProxies() {
        try? FileManager.default.removeItem(at: proxyFolder)
    }

    init(url: URL) {
        self.url = url
        loading = Task { [weak self] in await self?.load() }
    }

    func stop() {
        loading?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        if let proxy { try? FileManager.default.removeItem(at: proxy) }
        proxy = nil
    }

    private func load() async {
        var asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) != true {
            phase = .loading(String(localized: "Preparing preview…"))
            let output = Self.proxyFolder.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try FileManager.default.createDirectory(at: Self.proxyFolder, withIntermediateDirectories: true)
                proxy = output
                try await MediaEngine.makePreviewProxy(url, output: output)
            } catch {
                if !Task.isCancelled { phase = .failed(String(localized: "No preview: \(error.localizedDescription)")) }
                return
            }
            guard !Task.isCancelled else { return }
            asset = AVURLAsset(url: output)
            usesProxy = true
        }
        do {
            let length = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                phase = .failed(String(localized: "No video to preview."))
                return
            }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = CGRect(origin: .zero, size: natural).applying(transform).size
            guard !Task.isCancelled else { return }
            duration = length.seconds.isFinite ? length.seconds : 0
            presentationSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            startPlayer(asset)
            phase = .ready
            if autoplay { play() }
            await loadFilmstrip(asset)
        } catch {
            if !Task.isCancelled { phase = .failed(String(localized: "No preview: \(error.localizedDescription)")) }
        }
    }

    private func startPlayer(_ asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral  // keeps voices natural at 0.25×…4×
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfPlaying() }
        }
    }

    private func loadFilmstrip(_ asset: AVAsset) async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let tolerance = CMTime(seconds: duration / Double(Self.filmstripCount) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let step = duration / Double(Self.filmstripCount)
        let times = (0..<Self.filmstripCount).map { CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600) }
        frames = Array(repeating: nil, count: times.count)
        var index = 0
        for await result in generator.images(for: times) {
            guard !Task.isCancelled, index < frames.count else { return }
            frames[index] = try? result.image
            index += 1
        }
    }

    // MARK: Playback

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, let loop, seconds >= loop.upperBound - 0.03 { seek(to: loop.lowerBound) }
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        seek(to: loop?.lowerBound ?? 0)
        player.rate = rate
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard phase == .ready else {
            autoplay = true
            return
        }
        if let loop, !loop.contains(currentTime) || currentTime >= loop.upperBound - 0.05 { seek(to: loop.lowerBound) }
        isPlaying = true
        player.rate = rate
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - Editor

/// The preview plus whichever controls the tool's options call for: a selectable timeline
/// (start/end), a crop frame (region) and live playback speed (factor).
struct VideoEditor: View {
    static let width: CGFloat = 568
    static let height: CGFloat = 320

    let model: VideoPreviewModel
    let parameters: [ToolParameter]
    @Binding var values: [String: String]

    private func has(_ key: String) -> Bool { parameters.contains { $0.key == key } }
    private var selects: Bool { has("start") && has("end") }
    private var crops: Bool { parameters.contains { $0.kind == .region } }
    private var shape: String { values["aspect"] ?? "auto" }
    private var speed: Double? { has("factor") ? Double(values["factor"] ?? "") : nil }
    private var turn: Int { has("angle") ? Int(values["angle"] ?? "") ?? 0 : 0 }
    /// Poster: the frame under the playhead.
    private var picksFrame: Bool { has("at") }

    private var selection: ClosedRange<Double> {
        let end = MediaEngine.parseTime(values["end"] ?? "").map { min($0, model.duration) } ?? model.duration
        let start = min(MediaEngine.parseTime(values["start"] ?? "") ?? 0, max(end - 0.1, 0))
        return start...max(end, start)
    }

    private var selectionBinding: Binding<ClosedRange<Double>> {
        Binding(get: { selection }, set: { range in
            values["start"] = Self.timecode(range.lowerBound)
            values["end"] = range.upperBound >= model.duration - 0.05 ? "" : Self.timecode(range.upperBound)
        })
    }

    private var region: Binding<CGRect> { CropOverlay.region(in: $values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                PlayerLayerView(player: model.player, turn: turn)
                if crops, shape != "auto", model.phase == .ready {
                    CropOverlay(region: region, presentationSize: model.presentationSize, aspect: Self.aspect(shape))
                }
                status
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { if !crops || shape == "auto" { model.togglePlay() } }

            HStack(spacing: 10) {
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(model.phase != .ready)
                Text("\(Self.clock(model.currentTime)) / \(Self.clock(model.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Timeline(model: model, selection: selects ? selectionBinding : nil)
                .frame(height: 44)

            if selects {
                HStack(spacing: 8) {
                    timeField("Start", key: "start")
                    timeField("End", key: "end", placeholder: Self.timecode(model.duration))
                    Spacer()
                }
            }
            if picksFrame {
                HStack(spacing: 8) {
                    timeField("Still frame", key: "at", placeholder: Self.timecode(model.duration * 0.1))
                    Button("Use This Frame") { values["at"] = Self.timecode(model.currentTime) }.controlSize(.small)
                    Spacer()
                }
            }
        }
        .onChange(of: model.currentTime) {
            if picksFrame, !model.isPlaying { values["at"] = Self.timecode(model.currentTime) }
        }
        .onAppear(perform: sync)
        .onChange(of: values) { sync() }
        .onChange(of: model.phase) {
            sync()
            applyShape(force: false)
        }
        .onChange(of: shape) { applyShape(force: true) }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .loading(let message):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding()
        case .ready:
            if crops, shape == "auto" {
                Text("Black bars are found and removed automatically")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
            }
        }
    }

    private func timeField(_ label: LocalizedStringKey, key: String, placeholder: String = "0:00") -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.medium))
            TextField(placeholder, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 70)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if selects {
            let length = selection.upperBound - selection.lowerBound
            parts.append(String(localized: "Selection \(Self.seconds(length))"))
            if let fps = Double(values["fps"] ?? ""), has("width") { parts.append(String(localized: "\(Int(length * fps)) frames")) }
        }
        if let speed, speed > 0 {
            parts.append("\(Self.clock(model.duration)) → \(Self.clock(model.duration / speed))")
        }
        if crops, shape != "auto", !model.usesProxy {
            let area = region.wrappedValue
            parts.append(String(localized: "Keeps \(Int(area.width * model.presentationSize.width)) × \(Int(area.height * model.presentationSize.height))"))
        }
        if has("angle"), !model.usesProxy {
            let size = model.presentationSize
            parts.append(turn % 180 == 0 ? "\(Int(size.width)) × \(Int(size.height))" : "\(Int(size.height)) × \(Int(size.width))")
        }
        return parts.joined(separator: " · ")
    }

    /// Pushes the options into the player: loop over the selection, speed as playback rate.
    private func sync() {
        model.loop = selects && model.duration > 0 ? selection : nil
        if let loop = model.loop, !model.isPlaying, !loop.contains(model.currentTime) { model.seek(to: loop.lowerBound) }
        if let speed, speed > 0 {
            model.rate = Float(speed)
            model.autoplay = true
            if !model.isPlaying { model.play() }
        }
    }

    /// Picking a shape frames the largest centred area of that shape; "Free" starts slightly inset.
    private func applyShape(force: Bool) {
        guard crops, model.phase == .ready else { return }
        CropOverlay.apply(shape: shape, to: $values, in: model.presentationSize, force: force)
    }

    // MARK: Formatting

    /// "16:9" → 16/9; `nil` for free-form.
    static func aspect(_ shape: String) -> Double? {
        let parts = shape.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : nil
    }

    /// Editable position: "1:05.3".
    static func timecode(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0:00" }
        let minutes = Int(seconds) / 60
        return String(format: "%d:%04.1f", minutes, seconds - Double(minutes * 60))
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func seconds(_ value: Double) -> String {
        value < 60 ? String(format: "%.1f s", value) : clock(value)
    }
}

// MARK: - Timeline

/// Filmstrip with a playhead; drag or click to scrub. With a selection, two handles set start and end.
struct Timeline: View {
    let model: VideoPreviewModel
    var selection: Binding<ClosedRange<Double>>?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                filmstrip(width: width, height: height)
                if let selection {
                    let lower = x(selection.wrappedValue.lowerBound, width), upper = x(selection.wrappedValue.upperBound, width)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(lower, 0), height: height)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(width - upper, 0), height: height).offset(x: upper)
                    RoundedRectangle(cornerRadius: 4).strokeBorder(.orange, lineWidth: 2)
                        .frame(width: max(upper - lower, 2), height: height).offset(x: lower)
                        .allowsHitTesting(false)
                    handle(height: height).offset(x: lower - 6)
                        .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { drag in
                            let time = min(self.time(drag.location.x, width), selection.wrappedValue.upperBound - 0.1)
                            selection.wrappedValue = max(time, 0)...selection.wrappedValue.upperBound
                            model.pause()
                            model.seek(to: max(time, 0))
                        })
                    handle(height: height).offset(x: upper - 6)
                        .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { drag in
                            let time = max(self.time(drag.location.x, width), selection.wrappedValue.lowerBound + 0.1)
                            selection.wrappedValue = selection.wrappedValue.lowerBound...min(time, model.duration)
                            model.pause()
                            model.seek(to: min(time, model.duration))
                        })
                }
                Rectangle().fill(.white).frame(width: 2, height: height + 6)
                    .offset(x: x(model.currentTime, width) - 1, y: -3)
                    .shadow(radius: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { drag in
                model.seek(to: time(drag.location.x, width))
            })
        }
        .coordinateSpace(.named("timeline"))
        .disabled(model.phase != .ready)
    }

    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        let count = max(model.frames.count, VideoPreviewModel.filmstripCount)
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index < model.frames.count, let frame = model.frames[index] {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(count), height: height).clipped()
                } else {
                    Color.gray.opacity(0.25).frame(width: width / CGFloat(count), height: height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.orange)
            .frame(width: 12, height: height + 8)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 14))
            .offset(y: -4)
            .contentShape(Rectangle())
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(time / model.duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * model.duration
    }
}

// MARK: - Crop frame

/// The kept area over the video: drag inside to move it, drag a corner to resize
/// (keeping the shape when one is picked). Coordinates are normalised, top-left origin.
struct CropOverlay: View {
    @Binding var region: CGRect
    let presentationSize: CGSize
    /// Output width / height in pixels, or `nil` for free-form.
    let aspect: Double?
    @State private var dragStart: CGRect?

    private static let minimum = 0.05

    var body: some View {
        GeometryReader { geometry in
            let video = AVMakeRect(aspectRatio: presentationSize, insideRect: CGRect(origin: .zero, size: geometry.size))
            let frame = CGRect(x: video.minX + region.minX * video.width, y: video.minY + region.minY * video.height,
                               width: region.width * video.width, height: region.height * video.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(video)
                    path.addRect(frame)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle().fill(.clear).contentShape(Rectangle())
                    .overlay(thirds)
                    .overlay(Rectangle().strokeBorder(.orange, lineWidth: 2))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(DragGesture().onChanged { move($0.translation, in: video) }.onEnded { _ in dragStart = nil })

                ForEach(0..<4, id: \.self) { corner in
                    Circle().fill(.orange).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                        .offset(x: (corner % 2 == 1 ? frame.maxX : frame.minX) - 7, y: (corner >= 2 ? frame.maxY : frame.minY) - 7)
                        .gesture(DragGesture().onChanged { resize(corner, $0.translation, in: video) }.onEnded { _ in dragStart = nil })
                }
            }
        }
    }

    private var thirds: some View {
        GeometryReader { geometry in
            Path { path in
                for third in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * third, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * third, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * third))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * third))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func move(_ translation: CGSize, in video: CGRect) {
        let start = dragStart ?? region
        dragStart = start
        let x = min(max(start.minX + translation.width / video.width, 0), 1 - start.width)
        let y = min(max(start.minY + translation.height / video.height, 0), 1 - start.height)
        region = CGRect(x: x, y: y, width: start.width, height: start.height)
    }

    /// Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right. The opposite corner stays put.
    private func resize(_ corner: Int, _ translation: CGSize, in video: CGRect) {
        let start = dragStart ?? region
        dragStart = start
        let right = corner % 2 == 1, bottom = corner >= 2
        let fixedX = right ? start.minX : start.maxX
        let fixedY = bottom ? start.minY : start.maxY
        let movedX = (right ? start.maxX : start.minX) + translation.width / video.width
        let movedY = (bottom ? start.maxY : start.minY) + translation.height / video.height
        let maxWidth = right ? 1 - fixedX : fixedX
        let maxHeight = bottom ? 1 - fixedY : fixedY
        var width = min(max(abs(movedX - fixedX), Self.minimum), maxWidth)
        var height = min(max(abs(movedY - fixedY), Self.minimum), maxHeight)
        if right ? movedX < fixedX : movedX > fixedX { width = Self.minimum }
        if bottom ? movedY < fixedY : movedY > fixedY { height = Self.minimum }
        if let ratio = normalised(aspect) {
            // Follow whichever side the pointer pulled further, then fit inside the frame.
            if width / height > ratio { height = width / ratio } else { width = height * ratio }
            if width > maxWidth { width = maxWidth; height = width / ratio }
            if height > maxHeight { height = maxHeight; width = height * ratio }
        }
        region = CGRect(x: right ? fixedX : fixedX - width, y: bottom ? fixedY : fixedY - height, width: width, height: height)
    }

    /// Pixel aspect → width/height in normalised units of this video.
    private func normalised(_ aspect: Double?) -> Double? {
        guard let aspect, presentationSize.width > 0, presentationSize.height > 0 else { return nil }
        return aspect * presentationSize.height / presentationSize.width
    }

    /// The tool's "region" value as a rectangle; the whole frame while none is drawn.
    static func region(in values: Binding<[String: String]>) -> Binding<CGRect> {
        Binding(get: {
            let parts = (values.wrappedValue["region"] ?? "").split(separator: ":").compactMap { Double($0) }
            return parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : CGRect(x: 0, y: 0, width: 1, height: 1)
        }, set: { rect in
            values.wrappedValue["region"] = [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.4f", $0) }.joined(separator: ":")
        })
    }

    /// Picking a shape frames the largest centred area of that shape; "Free" starts slightly inset, "Auto" clears the area.
    static func apply(shape: String, to values: Binding<[String: String]>, in size: CGSize, force: Bool) {
        let drawn = !(values.wrappedValue["region"] ?? "").isEmpty
        switch shape {
        case "auto":
            values.wrappedValue["region"] = ""
        case "free":
            if !drawn { region(in: values).wrappedValue = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        default:
            guard force || !drawn, let aspect = VideoEditor.aspect(shape) else { return }
            region(in: values).wrappedValue = largest(aspect: aspect, in: size)
        }
    }

    /// Largest centred area with the given pixel aspect.
    static func largest(aspect: Double, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let ratio = aspect * size.height / size.width
        let (width, height) = ratio <= 1 ? (ratio, 1.0) : (1.0, 1 / ratio)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

// MARK: - Player surface

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var turn = 0

    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = player
        view.turn = turn
        return view
    }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.player = player
        view.turn = turn
    }
}

final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    /// Clockwise turn shown on screen (0, 90, 180, 270), to preview Rotate.
    var turn = 0 {
        didSet { if turn != oldValue { needsLayout = true } }
    }
    private var laidOut = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        // Turns animate; the first placement doesn't.
        CATransaction.begin()
        CATransaction.setDisableActions(!laidOut)
        let quarter = turn % 180 != 0
        playerLayer.bounds = CGRect(origin: .zero, size: quarter ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Layer space runs bottom-up, so clockwise on screen is a negative angle.
        playerLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turn) * .pi / 180))
        CATransaction.commit()
        laidOut = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
