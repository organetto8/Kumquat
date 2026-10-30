import AppKit
import KumquatCore
import SwiftUI
import UniformTypeIdentifiers

/// The signature Sign places: drawn once with the mouse or trackpad, or imported from a photo of
/// one on paper (white becomes transparent). Saved as a PNG in Application Support.
struct SignatureField: View {
    @Binding var path: String
    @State private var drawing = false
    @State private var strokes: [[CGPoint]] = []
    @State private var version = 0

    static var storage: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kumquat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("signature.png")
    }

    private static let padSize = CGSize(width: 288, height: 110)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if drawing {
                pad
                HStack {
                    Button("Clear") { strokes = [] }
                    Spacer()
                    Button("Cancel") { drawing = false; strokes = [] }
                    Button("Save Signature") { save() }.disabled(strokes.isEmpty).tint(.orange)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    if let image = NSImage(contentsOfFile: Self.storage.path), FileManager.default.fileExists(atPath: Self.storage.path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 44)
                            .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 6)).id(version)
                    } else {
                        Text("No signature yet").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Draw…") { strokes = []; drawing = true }
                    Button("Import…", action: importImage)
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            if path.isEmpty, FileManager.default.fileExists(atPath: Self.storage.path) { path = Self.storage.path }
        }
    }

    private var pad: some View {
        Canvas { context, _ in
            for stroke in strokes where stroke.count > 1 {
                var line = Path()
                line.addLines(stroke)
                context.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: Self.padSize.width, height: Self.padSize.height)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 16).padding(.bottom, 24).allowsHitTesting(false)
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            if drag.translation == .zero || strokes.isEmpty { strokes.append([drag.location]) } else { strokes[strokes.count - 1].append(drag.location) }
        })
    }

    /// Renders the strokes at 3× on a transparent background, trimmed to the ink.
    private func save() {
        let scale: CGFloat = 3
        let size = Self.padSize
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(2.4)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        var ink = CGRect.null
        for stroke in strokes where stroke.count > 1 {
            context.addLines(between: stroke)
            context.strokePath()
            for point in stroke { ink = ink.union(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) }
        }
        guard var image = context.makeImage() else { return }
        let crop = CGRect(x: ink.minX * scale, y: ink.minY * scale, width: ink.width * scale, height: ink.height * scale).integral
        if let trimmed = image.cropping(to: crop) { image = trimmed }
        write(image)
        drawing = false
        strokes = []
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a photo or scan of your signature on white paper.")
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageEngine.decode(url, maxPixelSize: 1600) else { return }
        write(Self.inkOnly(image) ?? image)
    }

    /// Paper turns transparent: alpha follows how dark each pixel is.
    private static func inkOnly(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let luminance = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
            // Below 35% grey is full ink, above 75% is paper, in between fades.
            let alpha = min(max((191 - luminance) / (191 - 89), 0), 1)
            pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
            pixels[offset + 3] = UInt8(alpha * 255)
        }
        return context.makeImage()
    }

    private func write(_ image: CGImage) {
        guard let destination = CGImageDestinationCreateWithURL(Self.storage as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        path = Self.storage.path
        version += 1
    }
}
