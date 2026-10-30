import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO

/// Image tools added after 1.2: merge, scan, blur, frame, looks, palette, icons, tags, watermark.
extension ImageEngine {
    /// `layout`: "pdf" (one page per image), "vertical" (stacked strip, PNG), "grid" (PNG), "gif" (animated, 1 s per image).
    public static func merge(_ inputs: [URL], layout: String, output: URL) async throws {
        guard inputs.count >= 2 else { throw KumquatError.noResult(String(localized: "Drop two or more images to merge.")) }
        switch layout {
        case "pdf":
            try await runBlocking { try PDFEngine.imagesToPDF(inputs, output: output) }
        case "vertical", "grid":
            try await runBlocking {
                let image = try layout == "grid" ? grid(inputs) : strip(inputs)
                try write(image, as: .png, to: output)
            }
        case "gif":
            try await runBlocking { try slideshowGIF(inputs, output: output) }
        default:
            throw KumquatError.noResult(String(localized: "Pick how to merge the images."))
        }
    }

    /// Pictures stacked top to bottom at a common width (the widest, within limits PNG viewers cope with).
    static func strip(_ inputs: [URL]) throws -> CGImage {
        let images = try inputs.map { try decode($0, maxPixelSize: 4096) }
        var width = Double(images.map(\.width).max() ?? 1)
        var heights = images.map { Double($0.height) * width / Double($0.width) }
        let total = heights.reduce(0, +)
        if total > 32_768 {
            let shrink = 32_768 / total
            width *= shrink
            heights = heights.map { $0 * shrink }
        }
        let context = try canvas(width: Int(width.rounded()), height: Int(heights.reduce(0, +).rounded()))
        var top = CGFloat(context.height)
        for (image, height) in zip(images, heights) {
            top -= CGFloat(height)
            context.draw(image, in: CGRect(x: 0, y: top, width: CGFloat(width), height: CGFloat(height)))
        }
        return try made(context)
    }

    /// Rows of equal cells on white, shaped like the typical picture; each one fitted and centred.
    static func grid(_ inputs: [URL]) throws -> CGImage {
        let images = try inputs.map { try decode($0, maxPixelSize: 2048) }
        let columns = Int(Double(images.count).squareRoot().rounded(.up))
        let rows = (images.count + columns - 1) / columns
        let aspects = images.map { Double($0.width) / Double($0.height) }.sorted()
        let widths = images.map(\.width).sorted()
        let cellWidth = CGFloat(min(widths[widths.count / 2], 1600))
        let cellHeight = (cellWidth / CGFloat(aspects[aspects.count / 2])).rounded()
        let gap = max(8, (cellWidth * 0.03).rounded())
        let context = try canvas(width: Int(CGFloat(columns) * (cellWidth + gap) + gap), height: Int(CGFloat(rows) * (cellHeight + gap) + gap))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let cell = CGRect(x: gap + CGFloat(column) * (cellWidth + gap),
                              y: CGFloat(context.height) - CGFloat(row + 1) * (cellHeight + gap),
                              width: cellWidth, height: cellHeight)
            context.draw(image, in: fitted(image, in: cell))
        }
        return try made(context)
    }

    /// Animated GIF looping forever, one second per picture. Frames share the first picture's
    /// shape (at most 1000 px); the others are fitted on white.
    static func slideshowGIF(_ inputs: [URL], output: URL) throws {
        let images = try inputs.map { try decode($0, maxPixelSize: 2000) }
        let first = images[0]
        let scale = min(1, 1000 / CGFloat(max(first.width, first.height)))
        let width = max(1, Int((CGFloat(first.width) * scale).rounded())), height = max(1, Int((CGFloat(first.height) * scale).rounded()))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, images.count, nil) else {
            throw KumquatError.cannotEncode("GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0, kCGImagePropertyGIFUnclampedDelayTime: 1.0]] as CFDictionary
        for image in images {
            let context = try canvas(width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: fitted(image, in: CGRect(x: 0, y: 0, width: width, height: height)))
            CGImageDestinationAddImage(destination, try made(context), frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("GIF") }
    }

    /// Finds the sheet of paper in a photo, straightens its perspective and cleans it up.
    /// `look`: "color", "gray" or "bw" (high-contrast black and white).
    public static func scanDocument(_ input: URL, from source: FileFormat, look: String, output: URL) async throws {
        guard ["color", "gray", "bw"].contains(look) else { throw KumquatError.noResult(String(localized: "Pick a look.")) }
        let format = toolOutputFormat(for: source, tool: .scanDocument)
        let image = try await runBlocking { () -> CGImage in
            let photo = try decode(input, maxPixelSize: nil)
            guard let sheet = try ImageAnalysis.document(in: photo) else {
                throw KumquatError.noResult(String(localized: "No document found in “\(input.lastPathComponent)”."))
            }
            let size = CGSize(width: photo.width, height: photo.height)
            func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
            let correction = CIFilter.perspectiveCorrection()
            correction.inputImage = CIImage(cgImage: photo)
            correction.topLeft = pixel(sheet.topLeft)
            correction.topRight = pixel(sheet.topRight)
            correction.bottomRight = pixel(sheet.bottomRight)
            correction.bottomLeft = pixel(sheet.bottomLeft)
            guard var page = correction.outputImage else { throw KumquatError.cannotDecode(input.lastPathComponent) }
            // Evens out shadows and whitens the paper, like the Notes scanner.
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = page
            enhancer.amount = 1
            page = enhancer.outputImage ?? page
            if look != "color" {
                let gray = CIFilter.colorControls()
                gray.inputImage = page
                gray.saturation = 0
                gray.contrast = 1.1
                page = gray.outputImage ?? page
            }
            if look == "bw" {
                let threshold = CIFilter.colorThresholdOtsu()
                threshold.inputImage = page
                page = threshold.outputImage ?? page
            }
            return try render(page, like: photo)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    /// `region` (normalised, top-left origin) blurs that area; `nil` finds faces. `style`: "pixelate", "blur", "black".
    public static func blurFaces(_ input: URL, from source: FileFormat, region: CGRect?, style: String, output: URL) async throws {
        guard ["pixelate", "blur", "black"].contains(style) else { throw KumquatError.noResult(String(localized: "Pick a style.")) }
        let format = toolOutputFormat(for: source, tool: .blurFaces)
        let image = try await runBlocking { () -> CGImage in
            let photo = try decode(input, maxPixelSize: nil)
            let size = CGSize(width: photo.width, height: photo.height)
            let bounds = CGRect(origin: .zero, size: size)
            // Pixel rectangles with a bottom-left origin, like Core Image.
            let areas: [CGRect]
            if let region {
                let area = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard area.width > 0.002, area.height > 0.002 else { throw KumquatError.noResult(String(localized: "Draw the area to blur.")) }
                areas = [CGRect(x: area.minX * size.width, y: (1 - area.maxY) * size.height, width: area.width * size.width, height: area.height * size.height)]
            } else {
                let faces = try ImageAnalysis.faces(in: photo)
                guard !faces.isEmpty else { throw KumquatError.noResult(String(localized: "No faces found in “\(input.lastPathComponent)”.")) }
                // Vision's boxes hug eyes, nose and mouth: grow them to take in hair, ears and chin.
                areas = faces.map { face in
                    CGRect(x: (face.minX - face.width * 0.15) * size.width, y: (face.minY - face.height * 0.2) * size.height,
                           width: face.width * 1.3 * size.width, height: face.height * 1.45 * size.height).intersection(bounds)
                }
            }
            let original = CIImage(cgImage: photo)
            var result = original
            for area in areas where !area.isEmpty {
                // Coarse enough that the face can't be recognised, scaled to its size.
                let side = max(area.width, area.height)
                let patch: CIImage
                switch style {
                case "pixelate":
                    let pixellate = CIFilter.pixellate()
                    pixellate.inputImage = original.clampedToExtent()
                    pixellate.scale = Float(max(8, side / 12))
                    pixellate.center = area.origin
                    patch = pixellate.outputImage ?? original
                case "blur":
                    patch = original.clampedToExtent().applyingGaussianBlur(sigma: Double(max(6, side / 8)))
                default:
                    patch = CIImage(color: .black)
                }
                result = patch.cropped(to: area).composited(over: result)
            }
            return try render(result.cropped(to: original.extent), like: photo)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    /// Screenshot beautifier, PNG out. `padding` and `radius` are fractions of the longer side.
    /// `background`: "sunset", "ocean" (gradients), "white", "black", "clear".
    public static func frame(_ input: URL, background: String, padding: Double, radius: Double, shadow: Bool, output: URL) async throws {
        guard (0...1).contains(padding), (0...0.5).contains(radius) else { throw KumquatError.noResult(String(localized: "Margin and corners are out of range.")) }
        func rgb(_ hex: Int) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let colors: [CGColor] = switch background {
        case "sunset": [rgb(0xFFB347), rgb(0xFF5F6D), rgb(0x9B5DE5)]
        case "ocean": [rgb(0x43CEA2), rgb(0x185A9D)]
        case "white": [rgb(0xFFFFFF)]
        case "black": [rgb(0x000000)]
        case "clear": []
        default: throw KumquatError.noResult(String(localized: "Pick a background."))
        }
        let palette = SendableColors(colors)
        let image = try await runBlocking { () -> CGImage in
            let shot = try decode(input, maxPixelSize: nil)
            let w = CGFloat(shot.width), h = CGFloat(shot.height)
            let margin = (max(w, h) * padding).rounded()
            let corner = min(max(w, h) * radius, min(w, h) / 2)
            let context = try canvas(width: Int(w + 2 * margin), height: Int(h + 2 * margin))
            let all = CGRect(x: 0, y: 0, width: context.width, height: context.height)
            if palette.value.count == 1 {
                context.setFillColor(palette.value[0])
                context.fill(all)
            } else if palette.value.count > 1,
                      let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: palette.value as CFArray, locations: nil) {
                // Top-left to bottom-right.
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: all.maxY), end: CGPoint(x: all.maxX, y: 0), options: [])
            }
            let box = CGRect(x: margin, y: margin, width: w, height: h)
            let path = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
            if shadow, margin > 0 {
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -margin * 0.12), blur: margin * 0.6, color: CGColor(gray: 0, alpha: 0.45))
                context.addPath(path)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillPath()
                context.restoreGState()
            }
            context.addPath(path)
            context.clip()
            context.interpolationQuality = .high
            context.draw(shot, in: box)
            return try made(context)
        }
        try await runBlocking { try write(image, as: .png, to: output) }
    }

    /// One-click auto adjustments (exposure, contrast, red eye).
    public static func enhance(_ input: URL, from source: FileFormat, output: URL) async throws {
        try await filtered(input, from: source, tool: .enhance, output: output) { image in
            let filters = image.autoAdjustmentFilters(options: [.enhance: true, .redEye: true])
            guard !filters.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” already looks its best.")) }
            return filters.reduce(image) { current, filter in
                filter.setValue(current, forKey: kCIInputImageKey)
                return filter.outputImage ?? current
            }
        }
    }

    /// `style`: "noir", "mono", "sepia", "vivid", "fade", "instant".
    public static func filter(_ input: URL, from source: FileFormat, style: String, output: URL) async throws {
        guard ["noir", "mono", "sepia", "vivid", "fade", "instant"].contains(style) else { throw KumquatError.noResult(String(localized: "Pick a filter.")) }
        try await filtered(input, from: source, tool: .filter, output: output) { image in
            switch style {
            case "noir": return applying(CIFilter.photoEffectNoir(), to: image)
            case "mono": return applying(CIFilter.photoEffectMono(), to: image)
            case "fade": return applying(CIFilter.photoEffectFade(), to: image)
            case "instant": return applying(CIFilter.photoEffectInstant(), to: image)
            case "sepia":
                let sepia = CIFilter.sepiaTone()
                sepia.intensity = 0.85
                return applying(sepia, to: image)
            default:
                // Vivid: boosts muted colours more than saturated ones, then a touch of contrast.
                let vibrance = CIFilter.vibrance()
                vibrance.amount = 0.7
                let controls = CIFilter.colorControls()
                controls.saturation = 1.1
                controls.contrast = 1.06
                return applying(controls, to: applying(vibrance, to: image))
            }
        }
    }

    static func applying(_ filter: CIFilter, to image: CIImage) -> CIImage {
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    /// Writes a PNG swatch of the dominant colours and returns them as "#RRGGBB", most common first.
    public static func palette(_ input: URL, count: Int, output: URL) async throws -> [String] {
        guard (1...16).contains(count) else { throw KumquatError.noResult(String(localized: "Pick between 1 and 16 colors.")) }
        let (swatch, hexes) = try await runBlocking { () -> (CGImage, [String]) in
            // A thumbnail is plenty to find the main colours, and keeps k-means instant.
            let colors = try dominantColors(try decode(input, maxPixelSize: 160), count: count)
            guard !colors.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no visible colors.")) }
            return (try swatches(colors), colors.map(hex))
        }
        try await runBlocking { try write(swatch, as: .png, to: output) }
        return hexes
    }

    /// k-means (k-means++ seeding, fixed seed so the same picture always gives the same palette)
    /// over the opaque pixels, in sRGB. Fewer colours come back when the picture has fewer.
    static func dominantColors(_ image: CGImage, count: Int) throws -> [SIMD3<Double>] {
        let context = try canvas(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var points: [SIMD3<Double>] = []
        for y in 0..<context.height {
            for x in 0..<context.width {
                let i = y * context.bytesPerRow + x * 4
                let alpha = Double(bytes[i + 3])
                guard alpha >= 128 else { continue }
                // Un-premultiply.
                points.append(SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) * 255 / alpha)
            }
        }
        guard !points.isEmpty else { return [] }
        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a - b; return (d * d).sum() }

        var generator = SplitMix64(seed: 0x6B75_6D71)
        var centers = [points[Int.random(in: 0..<points.count, using: &generator)]]
        var nearest = points.map { distance($0, centers[0]) }
        while centers.count < count {
            let total = nearest.reduce(0, +)
            guard total > 0 else { break }
            var pick = Double.random(in: 0..<total, using: &generator)
            var chosen = points.count - 1
            for (index, value) in nearest.enumerated() {
                pick -= value
                if pick < 0 { chosen = index; break }
            }
            centers.append(points[chosen])
            for index in points.indices { nearest[index] = min(nearest[index], distance(points[index], points[chosen])) }
        }

        var members = [Int](repeating: 0, count: centers.count)
        var assignment = [Int](repeating: -1, count: points.count)
        for _ in 0..<25 {
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            members = [Int](repeating: 0, count: centers.count)
            var moved = false
            for (index, point) in points.enumerated() {
                var best = 0, bestDistance = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = distance(point, center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[index] != best { assignment[index] = best; moved = true }
                sums[best] += point
                members[best] += 1
            }
            for c in centers.indices where members[c] > 0 { centers[c] = sums[c] / Double(members[c]) }
            if !moved { break }
        }
        var seen = Set<String>()
        return zip(centers, members).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert(hex($0)).inserted }
    }

    static func hex(_ color: SIMD3<Double>) -> String {
        let c = color.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    /// Squares side by side, each labelled with its hex code in black or white, whichever reads better.
    static func swatches(_ colors: [SIMD3<Double>]) throws -> CGImage {
        let side = 240
        let context = try canvas(width: side * colors.count, height: side)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        for (index, color) in colors.enumerated() {
            let fill = CGColor(srgbRed: color.x / 255, green: color.y / 255, blue: color.z / 255, alpha: 1)
            context.setFillColor(fill)
            context.fill(CGRect(x: index * side, y: 0, width: side, height: side))
            let luminance = (0.299 * color.x + 0.587 * color.y + 0.114 * color.z) / 255
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: hex(color), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: luminance > 0.55 ? 0 : 1, alpha: 0.85),
            ]))
            context.textPosition = CGPoint(x: CGFloat(index * side) + 18, y: 20)
            CTLineDraw(line, context)
        }
        return try made(context)
    }

    /// `kind`: "mac" (.icns + .iconset), "web" (favicon.ico, apple-touch-icon.png, icon-192.png, icon-512.png), "all".
    public static func iconSet(_ input: URL, kind: String, into folder: URL) async throws -> [URL] {
        guard ["mac", "web", "all"].contains(kind) else { throw KumquatError.noResult(String(localized: "Pick which icons to make.")) }
        return try await runBlocking {
            // 1024 px is the largest icon; anything not square is centred on a transparent square.
            let image = try decode(input, maxPixelSize: 2048)
            var made: [URL] = []
            if kind != "web" {
                let iconset = folder.appendingPathComponent("AppIcon.iconset", isDirectory: true)
                try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
                for slot in icnsSlots {
                    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
                    try write(try iconImage(image, side: slot.points * slot.scale), as: .png, to: iconset.appendingPathComponent(name))
                }
                let icns = folder.appendingPathComponent("AppIcon.icns")
                try writeICNS(image, to: icns)
                made += [icns, iconset]
            }
            if kind != "mac" {
                let favicon = folder.appendingPathComponent("favicon.ico")
                try writeICO(image, sizes: [16, 32, 48], to: favicon)
                // iOS shows a transparent touch icon on black: give it a white background instead.
                let touch = folder.appendingPathComponent("apple-touch-icon.png")
                try write(try opaque(try iconImage(image, side: 180)), as: .png, to: touch)
                made += [favicon, touch]
                for side in [192, 512] {
                    let icon = folder.appendingPathComponent("icon-\(side).png")
                    try write(try iconImage(image, side: side), as: .png, to: icon)
                    made.append(icon)
                }
            }
            return made
        }
    }

    static func opaque(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw KumquatError.cannotEncode("PNG")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try made(context)
    }

    /// Adds Finder tags describing the picture to the original file and returns them.
    public static func autoTag(_ input: URL) async throws -> [String] {
        let labels = try await runBlocking { try ImageAnalysis.labels(in: try decode(input, maxPixelSize: 1024)) }
        guard !labels.isEmpty else { throw KumquatError.noResult(String(localized: "Nothing recognisable in “\(input.lastPathComponent)”.")) }
        try await runBlocking {
            // Tags the user already set stay; only new ones are added.
            let existing = (try? input.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let added = labels.filter { label in !existing.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
            guard !added.isEmpty else { return }
            do {
                try (input as NSURL).setResourceValue(existing + added, forKey: .tagNamesKey)
            } catch {
                throw KumquatError.cannotWrite(input.lastPathComponent)
            }
        }
        return labels
    }

    /// Text watermark like the PDF one: centred, `opacity` 0…1, diagonal or horizontal.
    public static func watermark(_ input: URL, from source: FileFormat, text: String, opacity: Double, diagonal: Bool, output: URL) async throws {
        guard (0.01...1).contains(opacity) else { throw KumquatError.noResult(String(localized: "Opacity must be between 1% and 100%.")) }
        let format = toolOutputFormat(for: source, tool: .watermark)
        let image = try await runBlocking { () -> CGImage in
            let picture = try decode(input, maxPixelSize: nil)
            let size = CGSize(width: picture.width, height: picture.height)
            let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw KumquatError.cannotDecode(input.lastPathComponent)
            }
            context.draw(picture, in: CGRect(origin: .zero, size: size))
            // Same proportions, font and grey as PDFEngine.watermark.
            let fontSize = min(size.width, size.height) / CGFloat(max(text.count, 6)) * 1.6
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: opacity),
            ]))
            let bounds = CTLineGetImageBounds(line, context)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            if diagonal { context.rotate(by: atan2(size.height, size.width)) }
            context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
            CTLineDraw(line, context)
            return try made(context)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    /// Removes only GPS data, keeping date, camera and the rest.
    public static func stripLocation(_ input: URL, from source: FileFormat, output: URL) async throws {
        guard hasLocation(input) else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no location data.")) }
        let format = toolOutputFormat(for: source, tool: .stripMetadata)
        if format == .webp {
            // cwebp keeps only the colour profile, so the location goes together with the other metadata.
            let image = try await runBlocking { try decode(input, maxPixelSize: nil) }
            try await encode(image, as: .webp, to: output)
            return
        }
        try await runBlocking {
            // Same format: rewrite only the metadata, the compressed picture is copied as is. The
            // metadata has to be handed back explicitly, or ImageIO drops all of it along with the GPS.
            // PNG ignores the GPS exclusion, hence the check (it re-encodes losslessly below).
            if format == source, let probe = ImageProbe.source(input), let type = CGImageSourceGetType(probe),
               let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
                var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
                if let metadata = CGImageSourceCopyMetadataAtIndex(probe, 0, nil) { options[kCGImageDestinationMetadata] = metadata }
                if CGImageDestinationCopyImageSource(destination, probe, options as CFDictionary, nil), !hasLocation(output) { return }
            }
            try transcode(input, to: format, output: output, options: Options(quality: 0.95, stripLocation: true))
        }
    }

    static func hasLocation(_ url: URL) -> Bool {
        guard let source = ImageProbe.source(url),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, ImageProbe.primaryIndex(source), nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    // MARK: - Helpers

    /// Decodes upright, lets Core Image `transform` the picture and writes it in the tool's output
    /// format with the original metadata.
    static func filtered(_ input: URL, from source: FileFormat, tool: ToolKind, output: URL,
                         _ transform: @escaping @Sendable (CIImage) throws -> CIImage) async throws {
        let format = toolOutputFormat(for: source, tool: tool)
        let image = try await runBlocking { () -> CGImage in
            let original = try decode(input, maxPixelSize: nil)
            return try render(try transform(CIImage(cgImage: original)).cropped(to: CGRect(x: 0, y: 0, width: original.width, height: original.height)),
                              like: original)
        }
        let metadata = ImageProbe.source(input).map(uprightMetadata) ?? [:]
        try await encode(image, as: format, to: output, metadata: metadata)
    }

    /// Renders a Core Image result in the original's colour space (sRGB for grey or CMYK originals).
    static func render(_ image: CIImage, like original: CGImage) throws -> CGImage {
        let extent = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: original.width, height: original.height) : image.extent.integral
        let space = original.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard !extent.isEmpty, let result = ciContext.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space) else {
            throw KumquatError.cannotEncode(String(localized: "image"))
        }
        return result
    }

    /// Transparent sRGB canvas.
    static func canvas(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.cannotEncode(String(localized: "image"))
        }
        context.interpolationQuality = .high
        return context
    }

    static func made(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw KumquatError.cannotEncode(String(localized: "image")) }
        return image
    }

    /// `image` scaled to fit inside `box`, centred.
    static func fitted(_ image: CGImage, in box: CGRect) -> CGRect {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }
}

/// CGColor arrays are immutable; safe to hand to a worker thread.
struct SendableColors: @unchecked Sendable {
    let value: [CGColor]
    init(_ value: [CGColor]) { self.value = value }
}

/// Small deterministic generator (Vigna's SplitMix64) so palettes are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func stub(_ name: String) -> KumquatError { .unsupported(name) }
