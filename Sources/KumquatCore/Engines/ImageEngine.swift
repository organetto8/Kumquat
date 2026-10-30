import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Raster conversions and image tools. ImageIO does the heavy lifting (hardware HEIC/JPEG
/// codecs, scaled decodes, camera RAW, icons); WebP encoding goes through `cwebp`, JPEG XL
/// through `cjxl`, tracing to SVG through `potrace`; SVG is rasterised by CoreSVG.
public enum ImageEngine {
    static func typeIdentifier(_ format: FileFormat) -> String? {
        switch format {
        case .jpg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .tiff: "public.tiff"
        case .avif: "public.avif"
        case .bmp: "com.microsoft.bmp"
        case .gif: "com.compuserve.gif"
        case .jp2: "public.jpeg-2000"
        case .ico: "com.microsoft.ico"
        case .icns: "com.apple.icns"
        default: nil
        }
    }

    static let encodable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func isLossy(_ format: FileFormat) -> Bool { [.jpg, .heic, .avif, .webp, .jp2].contains(format) }

    /// Shared Core Image context (thread-safe); intermediates aren't worth caching for one-shot jobs.
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Convert

    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, quality: Double = 0.9) async throws {
        switch target {
        case .pdf:
            if source == .svg {
                try await runBlocking { try svgToPDF(input, output: output) }
            } else {
                try await runBlocking { try PDFEngine.imagesToPDF([input], output: output) }
            }
        case .svg:
            try await vectorize(input, output: output)
        case .jxl:
            try await encodeJXL(input, from: source, output: output, quality: quality)
        case .ico, .icns:
            // Icons top out at 256 (ICO) and 1024 px (ICNS): no point decoding more than twice that.
            let image = try await runBlocking { try decode(input, maxPixelSize: 2048) }
            try await runBlocking { try target == .ico ? writeICO(image, to: output) : writeICNS(image, to: output) }
        case .webp where source != .svg:
            try await encodeWebP(input, from: source, output: output, quality: quality)
        default:
            if source == .svg {
                let image = try await runBlocking { try rasterizeSVG(input) }
                try await encode(image, as: target, to: output, quality: quality)
            } else {
                try await runBlocking { try transcode(input, to: target, output: output, options: Options(quality: quality)) }
            }
        }
    }

    struct Options: @unchecked Sendable {
        var quality = 0.9
        var maxPixelSize: Int?
        var stripMetadata = false
        /// Drops the GPS dictionary only, keeping the rest of the metadata.
        var stripLocation = false
        var extra: [CFString: Any] = [:]
    }

    /// Source → ImageIO destination. Without resizing or stripping, ImageIO transcodes
    /// directly and carries EXIF/GPS/XMP/ICC across untouched. Camera RAW always goes through
    /// a full decode: copying "the image" of a RAW container could pick its embedded preview.
    static func transcode(_ input: URL, to target: FileFormat, output: URL, options: Options = Options()) throws {
        guard let identifier = typeIdentifier(target), encodable.contains(identifier) else {
            throw KumquatError.unsupported(String(localized: "\(target.displayName) encoding"))
        }
        guard let source = ImageProbe.source(input), CGImageSourceGetCount(source) > 0 else {
            throw KumquatError.cannotDecode(input.lastPathComponent)
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, identifier as CFString, 1, nil) else {
            throw KumquatError.cannotEncode(target.displayName)
        }
        var props = options.extra
        if isLossy(target) { props[kCGImageDestinationLossyCompressionQuality] = options.quality }
        let index = ImageProbe.primaryIndex(source)
        let isRaw = FileFormat.detect(input)?.isCameraRaw == true
        if options.maxPixelSize == nil && !options.stripMetadata && !isRaw {
            // kCFNull removes a property that would otherwise be copied from the source.
            if options.stripLocation { props[kCGImagePropertyGPSDictionary] = kCFNull }
            CGImageDestinationAddImageFromSource(destination, source, index, props as CFDictionary)
        } else {
            let image = isRaw ? try decode(input, maxPixelSize: options.maxPixelSize) : try decode(source, index: index, maxPixelSize: options.maxPixelSize)
            if !options.stripMetadata {
                var metadata = uprightMetadata(source, index: index)
                if options.stripLocation { metadata.removeValue(forKey: kCGImagePropertyGPSDictionary) }
                props.merge(metadata) { current, _ in current }
            }
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode(target.displayName) }
    }

    /// Original properties minus geometry, for pixels that were already rotated upright.
    static func uprightMetadata(_ source: CGImageSource) -> [CFString: Any] {
        uprightMetadata(source, index: ImageProbe.primaryIndex(source))
    }

    static func uprightMetadata(_ source: CGImageSource, index: Int) -> [CFString: Any] {
        var meta = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        meta[kCGImagePropertyOrientation] = 1
        meta.removeValue(forKey: kCGImagePropertyPixelWidth)
        meta.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        return meta
    }

    /// Writes decoded pixels in any supported format (WebP via cwebp).
    static func encode(_ image: CGImage, as format: FileFormat, to output: URL, quality: Double = 0.9, metadata: [CFString: Any] = [:]) async throws {
        if format == .webp {
            let temp = temporaryURL("png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try write(image, as: .png, to: temp)
            try await cwebp(temp, output: output, quality: quality)
            return
        }
        let properties = Properties(metadata)
        try await runBlocking { try write(image, as: format, to: output, quality: quality, metadata: properties.value) }
    }

    /// Image properties are immutable plist values; safe to hand to a worker thread.
    struct Properties: @unchecked Sendable {
        let value: [CFString: Any]
        init(_ value: [CFString: Any]) { self.value = value }
    }

    static func write(_ image: CGImage, as format: FileFormat, to output: URL, quality: Double = 0.9, metadata: [CFString: Any] = [:]) throws {
        guard let identifier = typeIdentifier(format), encodable.contains(identifier),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, identifier as CFString, 1, nil) else {
            throw KumquatError.cannotEncode(format.displayName)
        }
        var props = metadata
        if isLossy(format) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode(format.displayName) }
    }

    static func encodeWebP(_ input: URL, from source: FileFormat, output: URL, quality: Double) async throws {
        let direct: Set<FileFormat> = [.jpg, .png, .tiff, .webp]
        if direct.contains(source), ImageProbe.orientation(input) == 1 {
            try await cwebp(input, output: output, quality: quality)
            return
        }
        let image = try await runBlocking { try decode(input, maxPixelSize: nil) }
        try await encode(image, as: .webp, to: output, quality: quality)
    }

    static func cwebp(_ input: URL, output: URL, quality: Double) async throws {
        guard let tool = Engines.cwebp else { throw KumquatError.toolMissing("cwebp") }
        try await ExternalTool.check(tool, ["-quiet", "-mt", "-q", "\(Int((quality * 100).rounded()))", "-metadata", "icc", input.path, "-o", output.path])
    }

    // MARK: - JPEG XL, icons, tracing

    /// JPEG XL through cjxl. An upright JPEG is recompressed losslessly (cjxl's default for JPEG
    /// input: about 20% smaller and bit-exact reversible, so `quality` doesn't apply); anything
    /// else goes in as a PNG.
    static func encodeJXL(_ input: URL, from source: FileFormat, output: URL, quality: Double) async throws {
        guard let tool = Engines.cjxl else { throw KumquatError.toolMissing("cjxl") }
        let upright = ImageProbe.orientation(input) == 1
        if source == .jpg, upright {
            try await ExternalTool.check(tool, [input.path, output.path, "--quiet"])
            return
        }
        let temp = temporaryURL("png")
        defer { try? FileManager.default.removeItem(at: temp) }
        var file = input
        if source != .png || !upright {
            try await runBlocking {
                let image = try decode(input, maxPixelSize: nil)
                try write(image, as: .png, to: temp, metadata: ImageProbe.source(input).map(uprightMetadata) ?? [:])
            }
            file = temp
        }
        try await ExternalTool.check(tool, [file.path, output.path, "-q", "\(Int((quality * 100).rounded()))", "--quiet"])
    }

    /// Picture fitted (never stretched) and centred on a transparent `side`×`side` square.
    static func iconImage(_ image: CGImage, side: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.cannotEncode(String(localized: "icon"))
        }
        context.interpolationQuality = .high
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw KumquatError.cannotEncode(String(localized: "icon")) }
        return result
    }

    /// Windows icon with every size in one file (256 px is the format's ceiling).
    static func writeICO(_ image: CGImage, sizes: [Int] = [16, 32, 48, 256], to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.microsoft.ico" as CFString, sizes.count, nil) else {
            throw KumquatError.cannotEncode("ICO")
        }
        for side in sizes { CGImageDestinationAddImage(destination, try iconImage(image, side: side), nil) }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("ICO") }
    }

    /// Point size and scale of every slot in a macOS icon; ImageIO tells 1× from 2× by the DPI.
    static let icnsSlots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

    /// macOS icon: ImageIO only accepts the exact standard sizes, 16 to 1024 px.
    static func writeICNS(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.apple.icns" as CFString, icnsSlots.count, nil) else {
            throw KumquatError.cannotEncode("ICNS")
        }
        for slot in icnsSlots {
            let dpi = 72 * slot.scale
            CGImageDestinationAddImage(destination, try iconImage(image, side: slot.points * slot.scale),
                                       [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("ICNS") }
    }

    /// One-bit picture for potrace, the ink colour as "#RRGGBB", and the enlargement applied.
    struct Tracing: Sendable {
        let pbm: Data
        let color: String
        let scale: Double
    }

    /// Traces the picture into SVG paths with potrace: meant for logos, signatures and line art.
    /// Ink and paper are split with Otsu's threshold, filled with the ink's average colour, and the
    /// SVG keeps the original pixel size (small pictures are traced enlarged for smoother curves).
    static func vectorize(_ input: URL, output: URL) async throws {
        guard let tool = Engines.potrace else { throw KumquatError.toolMissing("potrace") }
        let tracing = try await runBlocking { try trace(input) }
        let bitmap = temporaryURL("pbm")
        defer { try? FileManager.default.removeItem(at: bitmap) }
        try tracing.pbm.write(to: bitmap)
        try await ExternalTool.check(tool, ["-s", "-r", String(format: "%.3f", 72 * tracing.scale), "-C", tracing.color, "-o", output.path, bitmap.path])
    }

    static func trace(_ input: URL) throws -> Tracing {
        let image = try decode(input, maxPixelSize: 4096)
        let longest = max(image.width, image.height)
        let scale = longest < 1024 ? 1024 / Double(longest) : 1
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        // Transparent areas count as paper.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var luma = [UInt8](repeating: 0, count: w * h)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            let y = (r * 299 + g * 587 + b * 114) / 1000
            luma[i] = UInt8(y)
            histogram[y] += 1
        }
        let threshold = otsuThreshold(histogram)

        // P4 PBM: rows padded to whole bytes, most significant bit first, 1 = ink.
        let rowBytes = (w + 7) / 8
        var pbm = Data("P4\n\(w) \(h)\n".utf8)
        var bits = [UInt8](repeating: 0, count: rowBytes * h)
        var ink = 0, sum = (r: 0, g: 0, b: 0)
        for y in 0..<h {
            for x in 0..<w where Int(luma[y * w + x]) <= threshold {
                bits[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
                let i = (y * w + x) * 4
                ink += 1
                sum.r += Int(pixels[i]); sum.g += Int(pixels[i + 1]); sum.b += Int(pixels[i + 2])
            }
        }
        guard ink > 0, ink < w * h else { throw KumquatError.noResult(String(localized: "Nothing to trace in “\(input.lastPathComponent)”.")) }
        pbm.append(contentsOf: bits)
        let color = String(format: "#%02X%02X%02X", sum.r / ink, sum.g / ink, sum.b / ink)
        return Tracing(pbm: pbm, color: color, scale: scale)
    }

    /// Grey level that best separates a histogram into two classes (Otsu, 1979); pixels at or
    /// below it are the dark class.
    static func otsuThreshold(_ histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 127 }
        let weightedSum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundWeight = 0, backgroundSum = 0.0
        var best = 127, bestVariance = -1.0
        for level in 0..<256 {
            backgroundWeight += histogram[level]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(level * histogram[level])
            let meanBackground = backgroundSum / Double(backgroundWeight)
            let meanForeground = (weightedSum - backgroundSum) / Double(foregroundWeight)
            let variance = Double(backgroundWeight) * Double(foregroundWeight) * pow(meanBackground - meanForeground, 2)
            if variance > bestVariance { bestVariance = variance; best = level }
        }
        return best
    }

    // MARK: - Decoding

    /// Decodes upright (EXIF orientation applied), downsampling inside the codec when
    /// `maxPixelSize` is set — a 50 MP photo shown at 2000 px never materialises at full size.
    public static func decode(_ source: CGImageSource, index: Int = 0, maxPixelSize: Int?) throws -> CGImage {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw KumquatError.cannotDecode(String(localized: "image"))
        }
        return image
    }

    public static func decode(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        let format = FileFormat.detect(url)
        if format == .svg { return try rasterizeSVG(url, longSide: maxPixelSize.map(CGFloat.init)) }
        if format?.isCameraRaw == true, let image = try? developRAW(url, maxPixelSize: maxPixelSize) { return image }
        guard let source = ImageProbe.source(url) else { throw KumquatError.cannotDecode(url.lastPathComponent) }
        return try decode(source, index: ImageProbe.primaryIndex(source), maxPixelSize: maxPixelSize)
    }

    /// Camera RAW through Core Image's RAW pipeline: the same default development as Photos and
    /// Preview (lens corrections, noise reduction, orientation), in Display P3 to keep the gamut.
    /// Downscaling happens inside the pipeline, which is much cheaper than developing at full size.
    static func developRAW(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw KumquatError.cannotDecode(url.lastPathComponent) }
        let native = filter.nativeSize
        if let maxPixelSize, max(native.width, native.height) > CGFloat(maxPixelSize) {
            filter.scaleFactor = Float(CGFloat(maxPixelSize) / max(native.width, native.height))
        }
        guard let image = filter.outputImage, !image.extent.isInfinite, !image.extent.isEmpty,
              let result = ciContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else {
            throw KumquatError.cannotDecode(url.lastPathComponent)
        }
        return result
    }

    static func rasterizeSVG(_ url: URL, longSide: CGFloat? = nil) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw KumquatError.cannotDecode(url.lastPathComponent)
        }
        let size = image.size
        let longest = max(size.width, size.height)
        let target = longSide ?? min(max(longest * 2, 1024), 4096)
        let scale = target / longest
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.cannotDecode(url.lastPathComponent)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw KumquatError.cannotDecode(url.lastPathComponent) }
        return result
    }

    /// SVG → PDF keeps the drawing vector.
    static func svgToPDF(_ url: URL, output: URL) throws {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { throw KumquatError.cannotDecode(url.lastPathComponent) }
        var box = CGRect(origin: .zero, size: image.size)
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw KumquatError.cannotWrite(output.lastPathComponent) }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - Tools

    /// Formats Kumquat reads but writes as PNG after a tool: no encoder (SVG, PSD, TGA, EXR, JPEG XL),
    /// or containers of several sizes that a single edited picture doesn't fit (ICO, ICNS).
    static let pngAfterTools: Set<FileFormat> = [.svg, .psd, .tga, .exr, .ico, .icns, .jxl]

    /// Format a tool writes for `source`: camera RAW becomes a JPEG, formats without a fitting
    /// encoder become PNG, BMP compresses to PNG; everything else keeps its format.
    public static func toolOutputFormat(for source: FileFormat, tool: ToolKind) -> FileFormat {
        if tool == .removeBackground { return .png }
        if source.isCameraRaw { return .jpg }
        if pngAfterTools.contains(source) { return .png }
        if tool == .compress && source == .bmp { return .png }
        return source
    }

    /// `quality` (0…1) applies to lossy formats; lossless ones are re-encoded at maximum compression.
    public static func compress(_ input: URL, from source: FileFormat, quality: Double = 0.6, output: URL) async throws {
        guard (0.05...1).contains(quality) else { throw KumquatError.noResult(String(localized: "Quality must be between 5% and 100%.")) }
        let target = toolOutputFormat(for: source, tool: .compress)
        switch target {
        case .jpg, .heic, .avif, .jp2:
            try await runBlocking { try transcode(input, to: target, output: output, options: Options(quality: quality)) }
        case .webp:
            let image = try await runBlocking { try decode(input, maxPixelSize: nil) }
            try await encode(image, as: .webp, to: output, quality: quality)
        case .tiff:
            try await runBlocking {
                let lzw: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
                try transcode(input, to: .tiff, output: output, options: Options(extra: lzw))
            }
        default:
            // Lossless formats: cap very large images at 2560 px, re-encode with max compression.
            let longSide = Int(max(ImageProbe.orientedPixelSize(input).width, ImageProbe.orientedPixelSize(input).height))
            let options = Options(maxPixelSize: longSide > 2560 ? 2560 : longSide)
            try await runBlocking { try transcode(input, to: target, output: output, options: options) }
        }
        let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if source == target, after >= before {
            try? FileManager.default.removeItem(at: output)
            throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is already as small as it gets."))
        }
    }

    public static func resize(_ input: URL, from source: FileFormat, percent: Double, output: URL) async throws {
        guard percent > 0, percent <= 1000 else { throw KumquatError.noResult(String(localized: "Scale must be between 1 and 1000 %.")) }
        let size = source == .svg ? CGSize(width: 1024, height: 1024) : ImageProbe.orientedPixelSize(input)
        let target = max(1, Int((max(size.width, size.height) * percent / 100).rounded()))
        let format = toolOutputFormat(for: source, tool: .resize)
        if percent > 100 || source == .svg || format == .webp {
            // Upscaling needs an explicit redraw (ImageIO thumbnails never enlarge).
            let image = try await runBlocking { try scaled(input, longSide: target) }
            try await encode(image, as: format, to: output)
        } else {
            try await runBlocking { try transcode(input, to: format, output: output, options: Options(maxPixelSize: target)) }
        }
    }

    static func scaled(_ input: URL, longSide: Int) throws -> CGImage {
        let image = try decode(input, maxPixelSize: nil)
        let scale = CGFloat(longSide) / CGFloat(max(image.width, image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw KumquatError.cannotDecode(String(localized: "image")) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw KumquatError.cannotDecode(String(localized: "image")) }
        return result
    }

    public static func stripMetadata(_ input: URL, from source: FileFormat, output: URL) async throws {
        let format = toolOutputFormat(for: source, tool: .stripMetadata)
        if format == .webp {
            let image = try await runBlocking { try decode(input, maxPixelSize: nil) }
            try await encode(image, as: .webp, to: output)
        } else {
            try await runBlocking { try transcode(input, to: format, output: output, options: Options(quality: 0.95, stripMetadata: true)) }
        }
    }

    public static func removeBackground(_ input: URL, output: URL) async throws {
        let image = try await SubjectLifter.lift(input)
        try await runBlocking { try write(image, as: .png, to: output) }
    }

    // MARK: Orientation (lossless where the codec allows it)

    /// EXIF orientation as a 2×2 integer matrix mapping stored → displayed coordinates (y down).
    static let orientationMatrices: [Int: [Int]] = [
        1: [1, 0, 0, 1], 2: [-1, 0, 0, 1], 3: [-1, 0, 0, -1], 4: [1, 0, 0, -1],
        5: [0, 1, 1, 0], 6: [0, -1, 1, 0], 7: [0, -1, -1, 0], 8: [0, 1, -1, 0],
    ]
    static let rotateClockwise = [0, -1, 1, 0]
    static let rotateCounterClockwise = [0, 1, -1, 0]
    static let rotateHalf = [-1, 0, 0, -1]
    static let flipHorizontal = [-1, 0, 0, 1]
    static let flipVertical = [1, 0, 0, -1]

    static func compose(_ op: [Int], with orientation: Int) -> Int {
        let m = orientationMatrices[orientation] ?? orientationMatrices[1]!
        let product = [op[0] * m[0] + op[1] * m[2], op[0] * m[1] + op[1] * m[3],
                       op[2] * m[0] + op[3] * m[2], op[2] * m[1] + op[3] * m[3]]
        return orientationMatrices.first { $0.value == product }?.key ?? 1
    }

    /// `degrees`: 0, 90 (clockwise), 180 or 270 (counter-clockwise). `tilt` (−45…45°, clockwise) straightens
    /// on top of that: the picture is turned and cropped to the largest area of its shape with no empty corners.
    public static func rotate(_ input: URL, from source: FileFormat, degrees: Int = 90, tilt: Double = 0, output: URL) async throws {
        let op: [Int]? = switch (degrees % 360 + 360) % 360 {
        case 0: nil
        case 90: rotateClockwise
        case 180: rotateHalf
        case 270: rotateCounterClockwise
        default: throw KumquatError.noResult(String(localized: "Rotate by 90°, 180° or 270°."))
        }
        guard abs(tilt) <= 45 else { throw KumquatError.noResult(String(localized: "Straighten by up to 45°.")) }
        guard abs(tilt) >= 0.01 else {
            guard let op else { throw KumquatError.noResult(String(localized: "Pick a direction or straighten.")) }
            try await reorient(input, from: source, op: op, output: output)
            return
        }
        let format = toolOutputFormat(for: source, tool: .rotate)
        let image = try await runBlocking { () -> CGImage in
            let upright = try decode(input, maxPixelSize: nil)
            return try straightened(try op.map { try transformed(upright, op: $0) } ?? upright, degrees: tilt)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    public static func flip(_ input: URL, from source: FileFormat, vertical: Bool = false, output: URL) async throws {
        try await reorient(input, from: source, op: vertical ? flipVertical : flipHorizontal, output: output)
    }

    static func reorient(_ input: URL, from source: FileFormat, op: [Int], output: URL) async throws {
        if [.jpg, .heic, .tiff].contains(source), let sourceImage = ImageProbe.source(input),
           let type = CGImageSourceGetType(sourceImage),
           let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            // Rewrites only the orientation tag: no re-encode, no quality loss, instant.
            let next = compose(op, with: ImageProbe.orientation(input))
            let options = [kCGImageDestinationOrientation: next] as CFDictionary
            if CGImageDestinationCopyImageSource(destination, sourceImage, options, nil) { return }
        }
        let format = toolOutputFormat(for: source, tool: .rotate)
        let image = try await runBlocking { () -> CGImage in
            let upright = try decode(input, maxPixelSize: nil)
            return try transformed(upright, op: op)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    /// Applies one of the orientation matrices above to upright pixels.
    static func transformed(_ image: CGImage, op: [Int]) throws -> CGImage {
        let w = image.width, h = image.height
        let (outW, outH) = op[0] == 0 ? (h, w) : (w, h)
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw KumquatError.cannotDecode(String(localized: "image")) }
        // Bitmap contexts run bottom-up, so clockwise on screen is a negative angle here.
        switch op {
        case rotateClockwise:
            context.translateBy(x: 0, y: CGFloat(w))
            context.rotate(by: -.pi / 2)
        case rotateCounterClockwise:
            context.translateBy(x: CGFloat(h), y: 0)
            context.rotate(by: .pi / 2)
        case rotateHalf:
            context.translateBy(x: CGFloat(w), y: CGFloat(h))
            context.rotate(by: .pi)
        case flipVertical:
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
        default:
            context.translateBy(x: CGFloat(w), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw KumquatError.cannotDecode(String(localized: "image")) }
        return result
    }

    // MARK: Straighten

    /// Share of each side kept when a picture of `size` is turned by `degrees` and cropped to its shape
    /// with no empty corners.
    public static func straightenScale(_ size: CGSize, degrees: Double) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let angle = abs(degrees) * .pi / 180
        let c = cos(angle), s = sin(angle)
        return min(size.width / (size.width * c + size.height * s), size.height / (size.width * s + size.height * c))
    }

    static func straightened(_ image: CGImage, degrees: Double) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = straightenScale(CGSize(width: w, height: h), degrees: degrees)
        // A pixel less on each side keeps the anti-aliased edges out of the corners.
        let outW = max(1, Int((w * scale).rounded(.down)) - 2), outH = max(1, Int((h * scale).rounded(.down)) - 2)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw KumquatError.cannotDecode(String(localized: "image")) }
        context.interpolationQuality = .high
        // Bitmap contexts run bottom-up, so clockwise on screen is a negative angle here.
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: -degrees * .pi / 180)
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw KumquatError.cannotDecode(String(localized: "image")) }
        return result
    }

    // MARK: Crop

    /// Keeps `region` (normalised, top-left origin) of the upright picture.
    public static func crop(_ input: URL, from source: FileFormat, region: CGRect, output: URL) async throws {
        let area = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard area.width > 0.01, area.height > 0.01 else { throw KumquatError.noResult(String(localized: "Draw the area to keep.")) }
        try await crop(input, from: source, output: output) { size in
            CGRect(x: area.minX * size.width, y: area.minY * size.height, width: area.width * size.width, height: area.height * size.height)
        }
    }

    /// Keeps the largest centred area with the given shape (width / height).
    public static func crop(_ input: URL, from source: FileFormat, aspect: Double, output: URL) async throws {
        guard aspect > 0 else { throw KumquatError.noResult(String(localized: "Pick a shape.")) }
        try await crop(input, from: source, output: output) { size in
            let width = min(size.width, size.height * aspect), height = min(size.height, size.width / aspect)
            return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        }
    }

    /// `area` picks the pixels to keep (top-left origin) given the upright size.
    static func crop(_ input: URL, from source: FileFormat, output: URL, area: @escaping @Sendable (CGSize) -> CGRect) async throws {
        let format = toolOutputFormat(for: source, tool: .crop)
        let cropped = try await runBlocking { () -> CGImage in
            let full = try decode(input, maxPixelSize: nil)
            let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
            let rect = area(bounds.size).integral.intersection(bounds)
            guard rect.width >= 1, rect.height >= 1 else { throw KumquatError.noResult(String(localized: "Draw the area to keep.")) }
            guard rect != bounds else { throw KumquatError.noResult(String(localized: "The area to keep is the whole picture.")) }
            guard let result = full.cropping(to: rect) else { throw KumquatError.cannotDecode(input.lastPathComponent) }
            return result
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(cropped, as: format, to: output, metadata: metadata)
    }

    // MARK: Auto-crop

    /// Trims uniform borders (the colour of the top-left pixel, ±24 per channel).
    public static func autoCrop(_ input: URL, from source: FileFormat, output: URL) async throws {
        let format = toolOutputFormat(for: source, tool: .crop)
        let cropped = try await runBlocking { () -> CGImage in
            let full = try decode(input, maxPixelSize: nil)
            let probe = try decode(input, maxPixelSize: 1024)
            guard let box = contentBounds(probe) else { throw KumquatError.noResult(String(localized: "No borders to crop in “\(input.lastPathComponent)”.")) }
            let sx = CGFloat(full.width) / CGFloat(probe.width), sy = CGFloat(full.height) / CGFloat(probe.height)
            let rect = CGRect(x: (box.minX * sx).rounded(.down), y: (box.minY * sy).rounded(.down),
                              width: (box.width * sx).rounded(.up), height: (box.height * sy).rounded(.up))
                .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard let result = full.cropping(to: rect) else { throw KumquatError.cannotDecode(input.lastPathComponent) }
            return result
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(cropped, as: format, to: output, metadata: metadata)
    }

    static func contentBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let background = Array(pixels[0..<4])
        func differs(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            for c in 0..<4 where abs(Int(pixels[i + c]) - Int(background[c])) > 24 { return true }
            return false
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where differs(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        // Less than 1% trimmed on every side: nothing worth cropping.
        guard box.width < CGFloat(w) * 0.99 || box.height < CGFloat(h) * 0.99 else { return nil }
        return box
    }

    static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-\(UUID().uuidString).\(ext)")
    }
}

public enum ImageProbe {
    public static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// The picture a file stands for: the largest size in an icon container, else the first image.
    public static func primaryIndex(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let type = CGImageSourceGetType(source) as String?, ["com.microsoft.ico", "com.apple.icns"].contains(type) else { return 0 }
        func width(_ index: Int) -> Int {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        }
        return (0..<count).max { width($0) < width($1) } ?? 0
    }

    public static func orientation(_ url: URL) -> Int {
        guard let source = source(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex(source), nil) as? [CFString: Any] else { return 1 }
        return (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Pixel size after applying the EXIF orientation.
    public static func orientedPixelSize(_ url: URL) -> CGSize {
        guard let source = source(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex(source), nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return .zero }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
