import AppKit
import KumquatCore
import SwiftUI

/// Options for tools that need them, pre-filled with the last values used; Return runs, Escape cancels.
/// Video tools pick their options on a playable preview of the first clip; Crop and Rotate on
/// images and PDFs on the first picture.
final class ParameterPrompt {
    private var panel: OverlayPanel?
    private var video: VideoPreviewModel?
    private var still: StillPreviewModel?
    private var pages: PageGridModel?

    func ask(title: String, subtitle: String, parameters: [ToolParameter], values: [String: String], preview url: URL?,
             at point: NSPoint, completion: @escaping ([String: String]) -> Void) {
        close()
        let isVideo = url.map { FileFormat.detect($0)?.category == .video } ?? false
        let picksPages = parameters.contains { $0.kind == .pages }
        let video = isVideo ? url.map(VideoPreviewModel.init) : nil
        let still = isVideo || picksPages ? nil : url.map(StillPreviewModel.init)
        let pages = picksPages ? url.map(PageGridModel.init) : nil
        let sheet = ToolSheet(title: title, subtitle: subtitle, parameters: parameters, initial: values, video: video, still: still, pages: pages, submit: { [weak self] values in
            self?.close()
            completion(values)
        }, cancel: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: sheet)
        let size = hosting.fittingSize
        let panel = OverlayPanel(size: size, level: .popUpMenu)
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.close() }
        panel.setFrameOrigin(Self.origin(centredOn: point, size: size))
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        self.video = video
        self.still = still
        self.pages = pages
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        video?.stop()
        video = nil
        still?.stop()
        still = nil
        pages = nil
    }

    /// Centred on the point, nudged to stay on its screen.
    private static func origin(centredOn point: NSPoint, size: CGSize) -> NSPoint {
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        guard let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return origin }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }
}

struct ToolSheet: View {
    let title: String
    let subtitle: String
    let parameters: [ToolParameter]
    let video: VideoPreviewModel?
    let still: StillPreviewModel?
    let pages: PageGridModel?
    let submit: ([String: String]) -> Void
    let cancel: () -> Void
    @State private var values: [String: String]
    @FocusState private var focused: String?

    init(title: String, subtitle: String, parameters: [ToolParameter], initial: [String: String], video: VideoPreviewModel?,
         still: StillPreviewModel?, pages: PageGridModel? = nil, submit: @escaping ([String: String]) -> Void, cancel: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.parameters = parameters
        self.video = video
        self.still = still
        self.pages = pages
        self.submit = submit
        self.cancel = cancel
        _values = State(initialValue: initial)
    }

    /// The preview draws the area and the time range itself.
    private var rows: [ToolParameter] {
        parameters.filter { parameter in
            switch parameter.kind {
            case .region, .pages: false
            case .time: video == nil
            default: true
            }
        }
    }

    private var isDefault: Bool {
        parameters.allSatisfy { !$0.remembers || values[$0.key] == $0.defaultValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !isDefault {
                    Button("Reset", action: reset).buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let video {
                VideoEditor(model: video, parameters: parameters, values: $values)
            }
            if let still {
                StillEditor(model: still, parameters: parameters, values: $values)
            }
            if let pages {
                PageGrid(model: pages, order: Binding(get: { values["order"] ?? "" }, set: { values["order"] = $0 }))
            }
            ForEach(rows) { parameter in
                VStack(alignment: .leading, spacing: 4) {
                    Text(parameter.label).font(.caption.weight(.medium))
                    field(parameter)
                    if !parameter.hint.isEmpty {
                        Text(parameter.hint).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Run", action: run).keyboardShortcut(.defaultAction).tint(.orange)
            }
        }
        .padding(16)
        .frame(width: video == nil && still == nil && pages == nil ? 320 : VideoEditor.width + 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            focused = rows.first { [.text, .number, .secure, .time].contains($0.kind) }?.key
        }
    }

    @ViewBuilder
    private func field(_ parameter: ToolParameter) -> some View {
        let text = Binding(get: { values[parameter.key] ?? "" }, set: { values[parameter.key] = $0 })
        switch parameter.kind {
        case .secure:
            SecureField(parameter.label, text: text).textFieldStyle(.roundedBorder).focused($focused, equals: parameter.key).onSubmit(run)
        case .slider(let range, let step, let unit, let presets):
            SliderField(value: text, range: range, step: step, unit: unit, presets: presets)
        case .choice(let options):
            ChoiceField(selection: text, options: options)
        case .signature:
            SignatureField(path: text)
        case .text, .number, .time, .region, .pages:
            TextField(parameter.label, text: text).textFieldStyle(.roundedBorder).focused($focused, equals: parameter.key).onSubmit(run)
        }
    }

    private func reset() {
        for parameter in parameters where parameter.remembers { values[parameter.key] = parameter.defaultValue }
    }

    private func run() { submit(values) }
}

// MARK: - Fields

/// Slider with the value spelled out and one-click presets; the value is stored as plain text ("0.5").
struct SliderField: View {
    @Binding var value: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let presets: [Double]

    private var number: Binding<Double> {
        Binding(get: { min(max(Double(value) ?? range.lowerBound, range.lowerBound), range.upperBound) },
                set: { value = Self.storage(($0 / step).rounded() * step) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Slider(value: number, in: range).controlSize(.small)
                Text(Self.display(number.wrappedValue, unit: unit))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 58, alignment: .trailing)
            }
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button(Self.display(preset, unit: unit)) { value = Self.storage(preset) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(abs(number.wrappedValue - preset) < step / 2 ? .orange : nil)
                    }
                }
            }
        }
    }

    static func storage(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    static func display(_ number: Double, unit: String) -> String {
        let text = number.formatted(.number.precision(.fractionLength(0...2)))
        switch unit {
        case "×", "%", "°": return text + unit
        case "dB": return (number > 0 ? "+" : "") + text + " dB"
        default: return text + " " + unit
        }
    }
}

/// Segmented when the options fit side by side, a menu otherwise.
struct ChoiceField: View {
    @Binding var selection: String
    let options: [ToolParameter.Option]

    var body: some View {
        let picker = Picker("", selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        if options.count <= 3 || options.reduce(0, { $0 + $1.label.count }) <= 32 {
            picker.pickerStyle(.segmented)
        } else {
            picker.pickerStyle(.menu).fixedSize()
        }
    }
}
