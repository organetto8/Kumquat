import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// Video and audio tools added after 1.2.
///
/// Everything runs on a minimal FFmpeg (no libass, drawtext, rubberband or vid.stab): text is
/// drawn with Core Text into transparent PNGs and overlaid, pitch uses asetrate + atempo, and
/// stabilising falls back to `deshake`.
extension MediaEngine {
    /// Destinations the video Compress can aim for.
    public enum SharePreset: String, Sendable {
        case whatsapp, instagram, discord, email

        public var title: String {
            switch self {
            case .whatsapp: "WhatsApp"
            case .instagram: "Instagram"
            case .discord: "Discord"
            case .email: String(localized: "Email")
            }
        }

        public var maxMegabytes: Double {
            switch self {
            case .whatsapp: 16
            case .instagram: 100
            case .discord: 10
            case .email: 18
            }
        }

        public var maxHeight: Int {
            switch self {
            case .whatsapp, .discord, .email: 720
            case .instagram: 1080
            }
        }
    }

    /// `compress` that can also cap the height (presets). Output MP4/H.264 when a preset is used:
    /// every app and browser plays it. `maxHeight` caps the short side (720 = 1280×720 or 720×1280),
    /// lowered further when the size budget leaves too few bits for it; frame rates above 30 drop to 30.
    public static func compress(_ input: URL, from source: FileFormat, quality: Quality = .balanced, maxMegabytes: Double? = nil,
                                audioBitrate: Int? = nil, maxHeight: Int?, output: URL, progress: Progress?) async throws {
        guard let maxHeight, source.category == .video else {
            try await compress(input, from: source, quality: quality, maxMegabytes: maxMegabytes, audioBitrate: audioBitrate, output: output, progress: progress)
            return
        }
        guard (144...4320).contains(maxHeight) else { throw KumquatError.noResult(String(localized: "Height must be between 144 and 4320 px.")) }
        let info = try await probe(input)
        guard info.video != nil else { throw noVideo(input) }
        let (q, crf) = switch quality {
        case .high: ("65", "21")
        case .balanced: ("55", "23")
        case .small: ("45", "27")
        }
        try await compressVideo(input, info: info, maxMegabytes: maxMegabytes, output: output, progress: progress) { videoKbps, audioKbps in
            var cap = maxHeight
            if let videoKbps { cap = min(cap, videoKbps < 450 ? 360 : videoKbps < 1000 ? 480 : videoKbps < 2500 ? 720 : maxHeight) }
            let scale = "scale='if(gte(iw,ih),-2,min(\(cap),iw))':'if(gte(iw,ih),min(\(cap),ih),-2)'"
            let filter = (info.fps > 31 ? "fps=30," : "") + scale
            let codecs: [[String]] = if let videoKbps {
                [["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-profile:v", "high"] + rateControl(videoKbps),
                 ["-c:v", "libx264", "-preset", "medium", "-profile:v", "high"] + rateControl(videoKbps)]
            } else {
                [["-c:v", "h264_videotoolbox", "-q:v", q, "-allow_sw", "1", "-profile:v", "high"],
                 ["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-profile:v", "high"]]
            }
            return codecs.enumerated().map { index, codec -> [String] in
                var args = ["-i", input.path, "-map", "0:V:0", "-map", "0:a:0?", "-map_metadata", "0", "-sn", "-dn"]
                args += codec + ["-vf", pictureFilter(info, filter), "-pix_fmt", "yuv420p"]
                if info.audio != nil { args += ["-c:a", index == 0 ? "aac_at" : "aac", "-b:a", "\(audioKbps)k"] }
                return args + ["-movflags", "+faststart", output.path]
            }
        }
    }

    // MARK: - Picture

    /// 9:16 frame with the whole video centred; `background`: "blur" (scaled-up blurred copy), "black", "white".
    /// The frame is 1080×1920 at most and never larger than the source needs.
    public static func vertical(_ input: URL, from source: FileFormat, background: String, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        guard info.video != nil, info.displayWidth > 0, info.displayHeight > 0 else { throw noVideo(input) }
        let width = max(16, min(1080, max(info.displayWidth, info.displayHeight * 9 / 16)) / 2 * 2)
        let height = width * 16 / 9 / 2 * 2
        let fit = "scale=\(width):\(height):force_original_aspect_ratio=decrease"
        let filter: String
        switch background {
        case "black", "white":
            filter = "\(fit),pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=\(background),setsar=1"
        case "blur":
            // Blurring a quarter-size copy is as good to the eye and much faster.
            let smallWidth = max(8, width / 8 * 2), smallHeight = max(8, height / 8 * 2)
            let radius = max(1, min(12, smallWidth / 4))
            filter = "split[kqbg][kqfg];[kqbg]scale=\(smallWidth):\(smallHeight):force_original_aspect_ratio=increase,crop=\(smallWidth):\(smallHeight),"
                + "boxblur=\(radius):3,scale=\(width):\(height)[kqblur];[kqfg]\(fit)[kqfit];[kqblur][kqfit]overlay=(W-w)/2:(H-h)/2,setsar=1"
        default:
            throw KumquatError.noResult(String(localized: "Pick a background: blurred, black or white."))
        }
        try await reencode(input, info: info, as: source, output: output, videoFilter: filter, audioFilter: nil, progress: progress)
    }

    public static func flip(_ input: URL, from source: FileFormat, vertical: Bool, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        guard info.video != nil else { throw noVideo(input) }
        try await reencode(input, info: info, as: source, output: output, videoFilter: vertical ? "vflip" : "hflip", audioFilter: nil, progress: progress)
    }

    /// Fades picture and sound in and/or out over `seconds`.
    public static func fade(_ input: URL, from source: FileFormat, seconds: Double, fadeIn: Bool, fadeOut: Bool, output: URL, progress: Progress?) async throws {
        guard seconds > 0, seconds <= 30 else { throw KumquatError.noResult(String(localized: "The fade must last between 0.1 and 30 seconds.")) }
        guard fadeIn || fadeOut else { throw KumquatError.noResult(String(localized: "Pick a fade in, a fade out or both.")) }
        let info = try await probe(input)
        guard info.duration > 0 else { throw KumquatError.noResult(String(localized: "Couldn't read the length of “\(input.lastPathComponent)”.")) }
        let length = min(seconds, fadeIn && fadeOut ? info.duration / 2 : info.duration)
        var video: [String] = [], audio: [String] = []
        if fadeIn {
            video.append("fade=t=in:st=0:d=\(length)")
            audio.append("afade=t=in:st=0:d=\(length)")
        }
        if fadeOut {
            let start = max(0, info.duration - length)
            video.append("fade=t=out:st=\(start):d=\(length)")
            audio.append("afade=t=out:st=\(start):d=\(length)")
        }
        try await reencode(input, info: info, as: source, output: output, videoFilter: video.joined(separator: ","),
                           audioFilter: audio.joined(separator: ","), progress: progress)
    }

    /// Two-pass vid.stab when this FFmpeg has it, otherwise the built-in `deshake`.
    public static func stabilize(_ input: URL, from source: FileFormat, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        guard info.video != nil else { throw noVideo(input) }
        if await hasFilter("vidstabdetect"), await hasFilter("vidstabtransform") {
            let transforms = ImageEngine.temporaryURL("trf")
            defer { try? FileManager.default.removeItem(at: transforms) }
            let path = filterQuoted(transforms.path)
            try await ffmpeg(["-i", input.path, "-map", "0:V:0", "-vf", pictureFilter(info, "vidstabdetect=shakiness=6:accuracy=15:result=\(path)"),
                              "-f", "null", "/dev/null"], duration: info.duration, progress: scaled(progress, 0, 0.4))
            try await reencode(input, info: info, as: source, output: output, videoFilter: "vidstabtransform=input=\(path):smoothing=12:optzoom=1,unsharp=5:5:0.6:3:3:0.3",
                               audioFilter: nil, progress: scaled(progress, 0.4, 1))
            return
        }
        try await reencode(input, info: info, as: source, output: output, videoFilter: "deshake=rx=32:ry=32:edge=mirror", audioFilter: nil, progress: progress)
    }

    /// Text watermark burned into the picture (rendered as an image, overlaid), like the PDF and image ones.
    public static func watermark(_ input: URL, from source: FileFormat, text: String, opacity: Double, diagonal: Bool, output: URL, progress: Progress?) async throws {
        guard (0.01...1).contains(opacity) else { throw KumquatError.noResult(String(localized: "Opacity must be between 1% and 100%.")) }
        let info = try await probe(input)
        guard info.video != nil, info.displayWidth > 0, info.displayHeight > 0 else { throw noVideo(input) }
        let png = ImageEngine.temporaryURL("png")
        defer { try? FileManager.default.removeItem(at: png) }
        let width = info.displayWidth, height = info.displayHeight
        try await runBlocking {
            try writePNG(watermarkImage(text, width: width, height: height, opacity: opacity, diagonal: diagonal), to: png)
        }
        // A `movie` source keeps the graph single-input, so every container (GIF too) goes through reencode.
        let filter = "null[kqmain];movie=\(filterQuoted(png.path)),format=rgba[kqmark];[kqmain][kqmark]overlay=0:0:format=auto"
        try await reencode(input, info: info, as: source, output: output, videoFilter: filter, audioFilter: nil, progress: progress)
    }

    static func watermarkImage(_ text: String, width: Int, height: Int, opacity: Double, diagonal: Bool) throws -> CGImage {
        let context = try transparentContext(width: width, height: height)
        let size = CGSize(width: width, height: height)
        let fontSize = min(size.width, size.height) / CGFloat(max(text.count, 6)) * 1.6
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: opacity),
        ]))
        let bounds = CTLineGetImageBounds(line, context)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        if diagonal { context.rotate(by: atan2(size.height, size.width)) }
        // A soft dark halo keeps white text readable on bright frames.
        context.setShadow(offset: .zero, blur: fontSize / 8, color: CGColor(gray: 0, alpha: opacity * 0.8))
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw KumquatError.cannotEncode("PNG") }
        return image
    }

    /// Frame at `at` seconds (`nil` = 10% in) as a JPG, or embedded as the cover art of a copy of the video (`embed`).
    public static func poster(_ input: URL, from source: FileFormat, at: Double?, embed: Bool, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        guard info.video != nil else { throw noVideo(input) }
        let time = min(max(0, at ?? info.duration * 0.1), max(0, info.duration - 0.1))
        func grab(_ jpg: URL) async throws {
            try await ffmpeg(["-ss", String(time), "-i", input.path, "-map", "0:V:0", "-frames:v", "1", "-q:v", "2", "-update", "1", jpg.path],
                             duration: 0, progress: nil)
            guard ((try? jpg.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                throw KumquatError.noResult(String(localized: "No frame at \(Self.timecode(time)) in “\(input.lastPathComponent)”."))
            }
        }
        guard embed else {
            try await grab(output)
            return
        }
        let target = FileFormat.detect(output) ?? .mp4
        let jpg = ImageEngine.temporaryURL("jpg")
        defer { try? FileManager.default.removeItem(at: jpg) }
        try await grab(jpg)
        // The cover is stream-copied next to the video: anything the container can't take as is
        // gets converted first.
        var base = input
        let converted = ImageEngine.temporaryURL(target.fileExtension)
        defer { try? FileManager.default.removeItem(at: converted) }
        if !copiesVideo(info.video, into: target) || (info.audio != nil && !copiesAudio(info.audio, into: target)) {
            try await video(input, info: info, to: target, output: converted, progress: scaled(progress, 0, 0.9))
            base = converted
        }
        let hevcTag = info.video == "hevc" ? ["-tag:v:0", "hvc1"] : []
        try await ffmpeg(["-i", base.path, "-i", jpg.path, "-map", "0:V:0", "-map", "0:a?", "-map", "1:0", "-map_metadata", "0", "-c", "copy"]
                         + hevcTag + ["-disposition:v:1", "attached_pic"] + containerFlags(target) + [output.path],
                         duration: info.duration, progress: scaled(progress, 0.9, 1))
    }

    /// Grid of `count` evenly spaced frames, `columns` wide, each with its timecode, as one JPG.
    /// Frames are grabbed by seeking (fast on long videos) and laid out with Core Graphics.
    public static func contactSheet(_ input: URL, count: Int, columns: Int, output: URL, progress: Progress?) async throws {
        guard (1...100).contains(count) else { throw KumquatError.noResult(String(localized: "Choose between 1 and 100 frames.")) }
        guard (1...12).contains(columns) else { throw KumquatError.noResult(String(localized: "Choose between 1 and 12 columns.")) }
        let info = try await probe(input)
        guard info.video != nil, info.displayWidth > 0, info.displayHeight > 0 else { throw noVideo(input) }
        guard info.duration > 0 else { throw KumquatError.noResult(String(localized: "Couldn't read the length of “\(input.lastPathComponent)”.")) }
        let columns = min(columns, count)
        let gap = 12
        let tileWidth = max(64, (1920 - gap * (columns + 1)) / columns / 2 * 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let times = (0..<count).map { info.duration * (Double($0) + 0.5) / Double(count) }
        let done = LockedBox(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func schedule() {
                guard next < times.count else { return }
                let index = next, time = times[index]
                next += 1
                group.addTask {
                    let frame = folder.appendingPathComponent(String(format: "%03d.png", index))
                    // A frame that can't be decoded (past the last keyframe of a broken file) stays a dark tile.
                    try? await ffmpeg(["-ss", String(time), "-i", input.path, "-map", "0:V:0", "-frames:v", "1",
                                       "-vf", pictureFilter(info, "scale=\(tileWidth):-2"), "-update", "1", frame.path], duration: 0, progress: nil)
                    try Task.checkCancellation()
                    let finished = done.mutate { $0 += 1; return $0 }
                    progress?(Double(finished) / Double(times.count) * 0.9)
                }
            }
            for _ in 0..<min(4, times.count) { schedule() }
            while try await group.next() != nil { schedule() }
        }
        let name = input.lastPathComponent
        let size = (info.displayWidth, info.displayHeight)
        let duration = info.duration
        try await runBlocking {
            let frames = times.indices.map { ImageProbe.source(folder.appendingPathComponent(String(format: "%03d.png", $0))).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
            let sheet = try contactSheetImage(frames: frames, times: times, columns: columns, tileWidth: tileWidth, gap: gap,
                                              title: "\(name)  ·  \(timecode(duration))  ·  \(size.0)×\(size.1)", aspect: Double(size.1) / Double(size.0))
            try writeJPEG(sheet, to: output)
        }
        progress?(1)
    }

    static func contactSheetImage(frames: [CGImage?], times: [Double], columns: Int, tileWidth: Int, gap: Int, title: String, aspect: Double) throws -> CGImage {
        let tileHeight = frames.lazy.compactMap { $0?.height }.first ?? max(16, Int(Double(tileWidth) * aspect))
        let rows = (frames.count + columns - 1) / columns
        let header = 64
        let width = columns * tileWidth + (columns + 1) * gap
        let height = header + rows * tileHeight + (rows + 1) * gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw KumquatError.cannotEncode("JPG")
        }
        context.setFillColor(CGColor(gray: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(title, in: context, at: CGPoint(x: CGFloat(gap) + 4, y: CGFloat(height - header / 2 - 8)), size: 22, color: CGColor(gray: 0.95, alpha: 1))
        let labelSize = max(11, CGFloat(tileWidth) / 16)
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            // Core Graphics counts from the bottom: row 0 sits under the header.
            let rect = CGRect(x: gap + column * (tileWidth + gap), y: height - header - (row + 1) * (tileHeight + gap),
                              width: tileWidth, height: tileHeight)
            if let frame {
                context.draw(frame, in: rect)
            } else {
                context.setFillColor(CGColor(gray: 0.2, alpha: 1))
                context.fill(rect)
            }
            let label = timecode(times[index])
            let line = CTLineCreateWithAttributedString(textAttributes(label, size: labelSize, color: CGColor(gray: 1, alpha: 1)))
            let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
            let badge = CGRect(x: rect.maxX - CGFloat(bounds) - labelSize * 1.1, y: rect.minY + labelSize * 0.4,
                               width: CGFloat(bounds) + labelSize * 0.8, height: labelSize * 1.5)
            context.setFillColor(CGColor(gray: 0, alpha: 0.6))
            context.addPath(CGPath(roundedRect: badge, cornerWidth: labelSize / 3, cornerHeight: labelSize / 3, transform: nil))
            context.fillPath()
            context.textPosition = CGPoint(x: badge.minX + labelSize * 0.4, y: badge.minY + labelSize * 0.42)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw KumquatError.cannotEncode("JPG") }
        return image
    }

    // MARK: - Subtitles

    /// SRT/VTT (any format SubtitleEngine reads) burned into the picture, or added as a switchable track (mov_text in MP4, srt in MKV).
    public static func addSubtitles(_ video: URL, from source: FileFormat, subtitles: URL, burn: Bool, output: URL, progress: Progress?) async throws {
        let info = try await probe(video)
        guard info.video != nil else { throw noVideo(video) }
        let cues = try readCues(subtitles)
        guard !cues.isEmpty else { throw KumquatError.noResult(String(localized: "No subtitles in “\(subtitles.lastPathComponent)”.")) }
        let target = FileFormat.detect(output) ?? .mp4
        if burn {
            try await burnSubtitles(cues, into: video, info: info, target: target, output: output, progress: progress)
        } else {
            try await addSubtitleTrack(cues, to: video, source: source, info: info, target: target, output: output, progress: progress)
        }
    }

    /// Any subtitle format, through SubtitleEngine's SRT.
    static func readCues(_ url: URL) throws -> [Cue] {
        let srt = ImageEngine.temporaryURL("srt")
        defer { try? FileManager.default.removeItem(at: srt) }
        try SubtitleEngine.convert(url, from: FileFormat.detect(url) ?? .srt, to: .srt, output: srt)
        return SubtitleEngine.parse(try DocumentEngine.readText(srt))
    }

    static func addSubtitleTrack(_ cues: [Cue], to video: URL, source: FileFormat, info: Info, target: FileFormat, output: URL, progress: Progress?) async throws {
        let srt = ImageEngine.temporaryURL("srt")
        defer { try? FileManager.default.removeItem(at: srt) }
        try SubtitleEngine.render(cues, as: .srt).write(to: srt, atomically: true, encoding: .utf8)
        let codec = target == .mkv ? "srt" : "mov_text"
        let language = "language=\(languageCode(cues.map(\.text).joined(separator: "\n")) ?? "und")"
        let hevcTag = info.video == "hevc" && target != .mkv ? ["-tag:v:0", "hvc1"] : []
        var alternatives: [[String]] = []
        if source == target {
            // Same container: every stream stays as it is, the new track goes last.
            let index = info.subtitles.count
            alternatives.append(["-i", video.path, "-i", srt.path, "-map", "0:V", "-map", "0:a?", "-map", "0:s?", "-map", "1:0", "-map_metadata", "0",
                                 "-c", "copy", "-c:s:\(index)", codec, "-metadata:s:s:\(index)", language] + hevcTag + containerFlags(target) + [output.path])
        }
        let copyVideo = copiesVideo(info.video, into: target), copyAudio = copiesAudio(info.audio, into: target)
        alternatives += encoders(for: target).map { encoder -> [String] in
            var args = ["-i", video.path, "-i", srt.path, "-map", "0:V:0", "-map", "0:a:0?", "-map", "1:0", "-map_metadata", "0"]
            args += copyVideo ? ["-c:v", "copy"] + hevcTag : encoder.video + ["-vf", pictureFilter(info), "-pix_fmt", "yuv420p"]
            if info.audio != nil { args += copyAudio ? ["-c:a", "copy"] : encoder.audio }
            return args + ["-c:s", codec, "-metadata:s:s:0", language] + containerFlags(target) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// Each cue becomes a transparent PNG the size of the picture; a concat list shows each one for
    /// its time and a single overlay lays the track over the video, so hundreds of cues cost one
    /// input instead of hundreds of overlays.
    static func burnSubtitles(_ cues: [Cue], into video: URL, info: Info, target: FileFormat, output: URL, progress: Progress?) async throws {
        guard info.displayWidth > 0, info.displayHeight > 0 else { throw noVideo(video) }
        let width = info.displayWidth, height = info.displayHeight
        // Text is drawn at most ~1080p and scaled up by FFmpeg: 4K PNGs would only cost time.
        let scale = min(1, 1920 / Double(max(width, height)))
        let drawWidth = max(2, Int(Double(width) * scale) / 2 * 2), drawHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-subs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Overlapping cues: each one ends where the next begins.
        var timeline = cues.sorted { $0.start < $1.start }.filter { $0.end > $0.start }
        for index in timeline.indices.dropLast() where timeline[index].end > timeline[index + 1].start {
            timeline[index].end = timeline[index + 1].start
        }
        timeline = timeline.filter { $0.end - $0.start > 0.01 }
        guard !timeline.isEmpty else { throw KumquatError.noResult(String(localized: "No subtitles to show.")) }
        let cueTexts = timeline.map(\.text)
        try await runCancellable { flag in
            try writePNG(transparentContext(width: drawWidth, height: drawHeight).makeImage()!, to: folder.appendingPathComponent("blank.png"))
            let failures = LockedBox<Error?>(nil)
            DispatchQueue.concurrentPerform(iterations: cueTexts.count) { index in
                guard !flag.isCancelled, failures.value == nil else { return }
                do {
                    let image = try subtitleImage(cueTexts[index], width: drawWidth, height: drawHeight)
                    try writePNG(image, to: folder.appendingPathComponent(String(format: "cue%05d.png", index)))
                } catch {
                    failures.mutate { $0 = $0 ?? error }
                }
            }
            try flag.check()
            if let error = failures.value { throw error }
        }
        progress?(0.1)
        var list = "ffconcat version 1.0\n"
        var clock = 0.0
        func show(_ file: String, until end: Double) {
            guard end - clock > 0.0005 else { return }
            list += "file '\(folder.appendingPathComponent(file).path)'\nduration \(String(format: "%.3f", end - clock))\n"
            clock = end
        }
        for (index, cue) in timeline.enumerated() {
            show("blank.png", until: cue.start)
            show(String(format: "cue%05d.png", index), until: cue.end)
        }
        show("blank.png", until: clock + 1)
        // The concat demuxer only honours the last duration when the file is listed once more.
        list += "file '\(folder.appendingPathComponent("blank.png").path)'\n"
        let listFile = folder.appendingPathComponent("subtitles.txt")
        try list.write(to: listFile, atomically: true, encoding: .utf8)

        let upscale = drawWidth == width && drawHeight == height ? "" : ",scale=\(width):\(height)"
        let graph = "[1:v]format=rgba\(upscale)[kqsubs];[0:V:0]\(info.interlaced ? "yadif=deint=interlaced," : "")null[kqmain];"
            + "[kqmain][kqsubs]overlay=0:0:eof_action=pass:format=auto[v]"
        try await encodeGraph(inputs: ["-i", video.path, "-f", "concat", "-safe", "0", "-i", listFile.path], graph: graph,
                              audio: info.audio == nil ? nil : "0:a:0", copyAudio: copiesAudio(info.audio, into: target),
                              target: target, output: output, duration: info.duration, progress: scaled(progress, 0.1, 1))
    }

    /// White text with a dark outline and shadow, centred near the bottom, wrapped to 90% of the width.
    static func subtitleImage(_ text: String, width: Int, height: Int) throws -> CGImage {
        let context = try transparentContext(width: width, height: height)
        let clean = text
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Sized on the short side so portrait videos don't get huge text.
        let fontSize = max(10, CGFloat(min(width, height)) * 0.055)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let style = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)], 1)
        }
        func attributed(_ extra: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ]
            attributes.merge(extra) { _, new in new }
            return NSAttributedString(string: clean, attributes: attributes)
        }
        let fill = attributed([NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
        // Positive stroke width: outline only, as a percentage of the font size.
        let outline = attributed([NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                                  NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 16.0])
        let boxWidth = CGFloat(width) * 0.9
        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: boxWidth, height: CGFloat(height)), nil)
        let box = CGRect(x: (CGFloat(width) - boxWidth) / 2, y: CGFloat(height) * 0.06, width: boxWidth, height: ceil(fitted.height) + 4)
        let path = CGPath(rect: box, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.2, color: CGColor(gray: 0, alpha: 0.7))
        CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(outline), CFRange(location: 0, length: 0), path, nil), context)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        guard let image = context.makeImage() else { throw KumquatError.cannotEncode("PNG") }
        return image
    }

    /// Every subtitle track as "<base> (<language>).srt"; throws `noResult` when there are none.
    public static func extractSubtitles(_ input: URL, into directory: URL, baseName: String, progress: Progress?) async throws -> [URL] {
        let info = try await probe(input)
        guard !info.subtitles.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no subtitles.")) }
        let textCodecs: Set<String> = ["subrip", "srt", "mov_text", "ass", "ssa", "webvtt", "text", "microdvd", "subviewer", "jacosub", "sami", "realtext", "mpl2", "stl"]
        let tracks = info.subtitles.enumerated().filter { textCodecs.contains($0.element.codec) }
        guard !tracks.isEmpty else {
            throw KumquatError.noResult(String(localized: "The subtitles in “\(input.lastPathComponent)” are pictures (DVD or Blu-ray) and can't become text."))
        }
        var produced: [URL] = []
        do {
            for (position, (index, track)) in tracks.enumerated() {
                let label = languageName(track.language) ?? track.title ?? String(localized: "track \(index + 1)")
                let file = try OutputNaming.reserve(in: directory, base: "\(baseName) (\(label))", ext: "srt")
                produced.append(file)
                try await ffmpeg(["-i", input.path, "-map", "0:s:\(index)", "-c:s", "srt", file.path], duration: info.duration,
                                 progress: scaled(progress, Double(position) / Double(tracks.count), Double(position + 1) / Double(tracks.count)))
            }
        } catch {
            for file in produced { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        return produced
    }

    // MARK: - Sound

    /// New soundtrack (`mix == false`) or music mixed under the original audio at `musicDecibels`; trimmed to the video's length.
    /// A video without sound just gets the music as it is; music longer than the video fades out at the end.
    public static func replaceAudio(_ video: URL, from source: FileFormat, audio: URL, mix: Bool, musicDecibels: Double, output: URL, progress: Progress?) async throws {
        guard (-60...20).contains(musicDecibels) else { throw KumquatError.noResult(String(localized: "Music volume must be between −60 and +20 dB.")) }
        let info = try await probe(video)
        guard info.video != nil else { throw noVideo(video) }
        let music = try await probe(audio)
        guard music.audio != nil else { throw KumquatError.noResult(String(localized: "“\(audio.lastPathComponent)” has no audio track.")) }
        let target = FileFormat.detect(output) ?? .mp4
        guard target != .gif else { throw KumquatError.noResult(String(localized: "GIFs can't carry sound.")) }
        guard info.duration > 0 else { throw KumquatError.noResult(String(localized: "Couldn't read the length of “\(video.lastPathComponent)”.")) }
        let length = info.duration
        let fadeOut = music.duration > length + 0.5 && length > 4 ? ",afade=t=out:st=\(length - 2):d=2" : ""
        var graph: String?
        var copyAudio = false
        if mix, info.audio != nil {
            // normalize=0 keeps both at their level instead of halving them.
            graph = "[1:a:0]volume=\(musicDecibels)dB\(fadeOut),apad[kqmusic];[0:a:0][kqmusic]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
        } else if !fadeOut.isEmpty {
            graph = "[1:a:0]anull\(fadeOut)[a]"
        } else {
            copyAudio = copiesAudio(music.audio, into: target)
        }
        let copyVideo = copiesVideo(info.video, into: target)
        let alternatives = encoders(for: target).map { encoder -> [String] in
            var args = ["-i", video.path, "-i", audio.path]
            if let graph { args += ["-filter_complex", graph] }
            args += ["-map", "0:V:0", "-map", graph == nil ? "1:a:0" : "[a]", "-map_metadata", "0", "-t", String(length)]
            args += copyVideo ? ["-c:v", "copy"] + (info.video == "hevc" ? ["-tag:v", "hvc1"] : []) : encoder.video + ["-vf", pictureFilter(info), "-pix_fmt", "yuv420p"]
            args += copyAudio ? ["-c:a", "copy"] : encoder.audio
            return args + containerFlags(target) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: length, progress: progress)
    }

    /// Plays backwards, or forwards then backwards (`boomerang`).
    ///
    /// FFmpeg's `reverse` keeps every decoded frame in memory, so longer clips are reversed in
    /// pieces of a few seconds (≈600 MB of frames each) that are then joined last to first.
    public static func reverse(_ input: URL, from source: FileFormat, boomerang: Bool, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        guard info.video != nil else { throw noVideo(input) }
        guard info.duration > 0 else { throw KumquatError.noResult(String(localized: "Couldn't read the length of “\(input.lastPathComponent)”.")) }
        let target = container(source, output: output)
        let reversed = ImageEngine.temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: reversed) }
        try await reversedCopy(input, info: info, output: reversed, progress: scaled(progress, 0, 0.7))
        let rest = scaled(progress, 0.7, 1)
        if boomerang {
            let sound = info.audio != nil
            let graph = "[0:V:0]\(pictureFilter(info)),setsar=1[kqforward];[1:v:0]setsar=1[kqbackward];"
                + (sound ? "[kqforward][0:a:0][kqbackward][1:a:0]concat=n=2:v=1:a=1[v][a]" : "[kqforward][kqbackward]concat=n=2:v=1:a=0[v]")
            try await encodeGraph(inputs: ["-i", input.path, "-i", reversed.path], graph: graph, audio: sound ? "[a]" : nil, copyAudio: false,
                                  target: target, output: output, duration: info.duration * 2, progress: rest)
            return
        }
        var reversedInfo = try await probe(reversed)
        reversedInfo.interlaced = false
        if target == .gif {
            try await gif(reversed, info: reversedInfo, output: output, progress: rest)
        } else if copiesVideo(reversedInfo.video, into: target) {
            // The pieces are already H.264: only the sound (PCM in between) needs encoding.
            let alternatives = encoders(for: target).map { encoder -> [String] in
                ["-i", reversed.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"] + (reversedInfo.audio != nil ? encoder.audio : [])
                    + containerFlags(target) + [output.path]
            }
            try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: rest)
        } else {
            try await video(reversed, info: reversedInfo, to: target, output: output, progress: rest)
        }
    }

    /// H.264 + PCM copy of `input` played backwards. `memoryBudget`: bytes of decoded frames held at once.
    static func reversedCopy(_ input: URL, info: Info, output: URL, progress: Progress?, memoryBudget: Double = 600_000_000) async throws {
        let pixels = Double(max(info.displayWidth * info.displayHeight, 1))
        let fps = info.fps > 0 ? info.fps : 30
        // Decoded frames are ~2 bytes a pixel (10-bit sources).
        let piece = min(30, max(1, memoryBudget / (pixels * 2 * fps)))
        func encode(_ inputArgs: [String], _ out: URL, _ duration: Double, _ progress: Progress?) async throws {
            let audio = info.audio != nil ? ["-map", "0:a:0", "-af", "areverse", "-c:a", "pcm_s16le"] : ["-an"]
            let alternatives = [["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1"], ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]].map {
                inputArgs + ["-map", "0:V:0", "-vf", pictureFilter(info, "reverse"), "-pix_fmt", "yuv420p"] + $0 + audio + ["-sn", "-dn", out.path]
            }
            try await ffmpeg(alternatives: alternatives, duration: duration, progress: progress)
        }
        if info.duration <= piece * 1.5 {
            try await encode(["-i", input.path], output, info.duration, progress)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-reverse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let count = Int((info.duration / piece).rounded(.up))
        var pieces: [URL] = []
        for index in 0..<count {
            let start = Double(index) * piece
            let part = folder.appendingPathComponent("piece \(index).mov")
            try await encode(["-ss", String(start), "-t", String(piece), "-i", input.path], part, min(piece, info.duration - start),
                             scaled(progress, Double(index) / Double(count) * 0.95, Double(index + 1) / Double(count) * 0.95))
            pieces.append(part)
        }
        let list = folder.appendingPathComponent("pieces.txt")
        try pieces.reversed().map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
            .write(to: list, atomically: true, encoding: .utf8)
        try await ffmpeg(["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy", output.path], duration: info.duration, progress: nil)
        progress?(1)
    }

    /// `strength`: "light", "medium", "strong". Video keeps its picture untouched.
    public static func denoise(_ input: URL, from source: FileFormat, strength: String, output: URL, progress: Progress?) async throws {
        let filter = switch strength {
        case "light": "afftdn=nr=10:nf=-50:tn=1"
        case "medium": "highpass=f=70,afftdn=nr=18:nf=-45:tn=1"
        case "strong": "highpass=f=90,afftdn=nr=30:nf=-38:tn=1"
        default: throw KumquatError.noResult(String(localized: "Pick a strength: light, medium or strong."))
        }
        let info = try await probe(input)
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        let target = container(source, output: output)
        if target.category == .audio || info.video == nil {
            try await audio(input, info: info, to: target.category == .audio ? target : .m4a, output: output, filters: filter, progress: progress)
            return
        }
        let copyVideo = copiesVideo(info.video, into: target)
        let alternatives = encoders(for: target).map { encoder -> [String] in
            var args = ["-i", input.path, "-map", "0:V:0", "-map", "0:a:0", "-map_metadata", "0", "-sn", "-dn"]
            args += copyVideo ? ["-c:v", "copy"] + (info.video == "hevc" && [.mp4, .mov].contains(target) ? ["-tag:v", "hvc1"] : [])
                : encoder.video + ["-vf", pictureFilter(info), "-pix_fmt", "yuv420p"]
            return args + ["-af", filter] + encoder.audio + containerFlags(target) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// Shortens every pause quieter than `thresholdDB` to at most `pause` seconds.
    public static func removeSilence(_ input: URL, from source: FileFormat, thresholdDB: Double, pause: Double, output: URL, progress: Progress?) async throws {
        guard (-90 ... -10).contains(thresholdDB) else { throw KumquatError.noResult(String(localized: "The silence threshold must be between −90 and −10 dB.")) }
        guard (0.05...10).contains(pause) else { throw KumquatError.noResult(String(localized: "The pause kept must be between 0.05 and 10 seconds.")) }
        let info = try await probe(input)
        // silenceremove keeps stop_duration + stop_silence of each pause: all of it in stop_duration.
        let filter = "silenceremove=start_periods=1:start_duration=0:start_threshold=\(thresholdDB)dB:start_silence=\(pause):"
            + "stop_periods=-1:stop_duration=\(pause):stop_threshold=\(thresholdDB)dB:stop_silence=0"
        try await audio(input, info: info, to: source, output: output, filters: filter, progress: progress)
    }

    /// Audio speed with an optional pitch shift in semitones (0 keeps the pitch).
    /// Without rubberband: asetrate shifts pitch and speed together, atempo then sets the speed.
    public static func changeSpeed(_ input: URL, from source: FileFormat, factor: Double, semitones: Double, output: URL, progress: Progress?) async throws {
        guard abs(semitones) <= 24 else { throw KumquatError.noResult(String(localized: "Pitch must be between −24 and +24 semitones.")) }
        guard semitones != 0 else {
            try await changeSpeed(input, from: source, factor: factor, output: output, progress: progress)
            return
        }
        guard factor >= 0.25, factor <= 16 else { throw KumquatError.noResult(String(localized: "Speed must be between 0.25× and 16×.")) }
        var info = try await probe(input)
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        let rate = info.sampleRate > 0 ? info.sampleRate : 44100
        let pitch = pow(2, semitones / 12)
        let filter = "asetrate=\(Int((Double(rate) * pitch).rounded())),aresample=\(rate),\(tempoChain(factor / pitch))"
        info.duration /= factor
        try await audio(input, info: info, to: source, output: output, filters: filter, progress: progress)
    }

    /// Title/artist/album (`nil` keeps what is there) and an optional cover image, without re-encoding the audio.
    /// Covers go in as an attached picture (MP3 ID3v2, M4A/M4B/M4R `covr`, FLAC, AIFF) or as a
    /// METADATA_BLOCK_PICTURE comment (Ogg, Opus); WAV, CAF, AC3 and WMA take the text only.
    public static func tags(_ input: URL, from source: FileFormat, title: String?, artist: String?, album: String?, cover: URL?, output: URL, progress: Progress?) async throws {
        guard title != nil || artist != nil || album != nil || cover != nil else {
            throw KumquatError.noResult(String(localized: "Enter a title, an artist or an album, or drop a cover image too."))
        }
        let info = try await probe(input)
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        let target = container(source, output: output)
        let pictureFormats: Set<FileFormat> = [.mp3, .m4a, .m4b, .m4r, .flac, .aiff]
        let commentFormats: Set<FileFormat> = [.ogg, .opus]
        let jpeg = ImageEngine.temporaryURL("jpg")
        defer { try? FileManager.default.removeItem(at: jpeg) }
        var picture: (width: Int, height: Int)?
        if let cover, pictureFormats.contains(target) || commentFormats.contains(target) {
            picture = try await runBlocking { try coverJPEG(cover, to: jpeg) }
        }
        var args = ["-i", input.path]
        if picture != nil, pictureFormats.contains(target) {
            args += ["-i", jpeg.path, "-map", "0:a:0", "-map", "1:0", "-c:v", "copy", "-disposition:v:0", "attached_pic",
                     "-metadata:s:v:0", "title=Cover", "-metadata:s:v:0", "comment=Cover (front)"]
        } else {
            args += ["-map", "0:a:0"]
            // The cover already there stays, where the container can hold it.
            if info.hasCover, pictureFormats.contains(target) { args += ["-map", "0:v?", "-c:v", "copy"] }
        }
        args += ["-map_metadata", "0"]
        for (key, value) in [("title", title), ("artist", artist), ("album", album)] {
            if let value { args += ["-metadata", "\(key)=\(value)"] }
        }
        if let picture, commentFormats.contains(target) {
            args += ["-metadata", "METADATA_BLOCK_PICTURE=\(try flacPictureBlock(jpeg, width: picture.width, height: picture.height).base64EncodedString())"]
        }
        if target == .mp3 { args += ["-id3v2_version", "3"] }
        if target == .aiff { args += ["-write_id3v2", "1"] }
        let copy = (source == target && !source.isInputOnly) || copiesAudio(info.audio, into: target)
        let codecs = copy ? [["-c:a", "copy"]] : audioEncoders(for: target, bits: info.audioBits, channels: info.channels)
        try await ffmpeg(alternatives: codecs.map { args + $0 + containerFlags(target) + [output.path] }, duration: info.duration, progress: progress)
    }

    /// Any image as a JPEG of at most 1400 px, the size music apps expect.
    static func coverJPEG(_ image: URL, to output: URL) throws -> (width: Int, height: Int) {
        guard let source = ImageProbe.source(image),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else {
            throw KumquatError.cannotDecode(image.lastPathComponent)
        }
        try writeJPEG(thumbnail, to: output, quality: 0.9)
        return (thumbnail.width, thumbnail.height)
    }

    /// FLAC PICTURE block (front cover), which Ogg and Opus carry base64-encoded in a comment.
    static func flacPictureBlock(_ jpeg: URL, width: Int, height: Int) throws -> Data {
        let image = try Data(contentsOf: jpeg)
        var block = Data()
        func append(_ value: Int) { withUnsafeBytes(of: UInt32(value).bigEndian) { block.append(contentsOf: $0) } }
        let mime = Data("image/jpeg".utf8)
        append(3)
        append(mime.count)
        block.append(mime)
        append(0)
        append(width)
        append(height)
        append(24)
        append(0)
        append(image.count)
        block.append(image)
        return block
    }

    /// Waveform picture (PNG, 1920×480, transparent background). `color`: "orange", "black", "white".
    public static func waveform(_ input: URL, color: String, output: URL, progress: Progress?) async throws {
        let hex = switch color {
        case "black": "0x000000"
        case "white": "0xFFFFFF"
        default: "0xFF9F0A"
        }
        let info = try await probe(input)
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        try await ffmpeg(["-i", input.path, "-filter_complex", "[0:a:0]aformat=channel_layouts=mono,showwavespic=s=1920x480:colors=\(hex):scale=sqrt:draw=full",
                          "-frames:v", "1", "-update", "1", output.path], duration: info.duration, progress: progress)
    }

    /// `channels`: "keep", "mono", "stereo"; `rate`: "keep", "44100", "48000".
    public static func channels(_ input: URL, from source: FileFormat, channels: String, rate: String, output: URL, progress: Progress?) async throws {
        var filters: [String] = []
        switch rate {
        case "keep": break
        case "44100", "48000": filters.append("aresample=\(rate)")
        default: throw KumquatError.noResult(String(localized: "Pick 44.1 or 48 kHz."))
        }
        switch channels {
        case "keep": break
        case "mono", "stereo": filters.append("aformat=channel_layouts=\(channels)")
        default: throw KumquatError.noResult(String(localized: "Pick mono or stereo."))
        }
        guard !filters.isEmpty else { throw KumquatError.noResult(String(localized: "Pick mono, stereo or a sample rate.")) }
        let info = try await probe(input)
        try await audio(input, info: info, to: source, output: output, filters: filters.joined(separator: ","), progress: progress)
    }

    // MARK: - Helpers

    /// Encodes a filter graph whose picture comes out as `[v]` into `target` (GIF gets its palette).
    /// `audio`: stream or graph label to map, `nil` for none.
    static func encodeGraph(inputs: [String], graph: String, audio: String?, copyAudio: Bool, target: FileFormat, output: URL,
                            duration: Double, progress: Progress?) async throws {
        if target == .gif {
            let palette = graph + ";[v]fps=12,scale='min(640,iw)':-2:flags=lanczos,split[kqg1][kqg2];[kqg1]palettegen=stats_mode=diff[kqp];"
                + "[kqg2][kqp]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[kqgif]"
            try await ffmpeg(inputs + ["-filter_complex", palette, "-map", "[kqgif]", "-loop", "0", output.path], duration: duration, progress: progress)
            return
        }
        let full = graph + ";[v]\(evenDimensions),format=yuv420p[kqout]"
        let alternatives = encoders(for: target).map { encoder -> [String] in
            var args = inputs + ["-filter_complex", full, "-map", "[kqout]"]
            if let audio { args += ["-map", audio] + (copyAudio ? ["-c:a", "copy"] : encoder.audio) }
            return args + ["-map_metadata", "0"] + encoder.video + containerFlags(target) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: duration, progress: progress)
    }

    static func noVideo(_ url: URL) -> KumquatError {
        .noResult(String(localized: "“\(url.lastPathComponent)” has no video track."))
    }

    /// A path as a quoted filter-graph option value.
    static func filterQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\\\\\''") + "'"
    }

    private static let filters = LockedBox<[String: Bool]>([:])

    /// Whether this FFmpeg build has the filter (vid.stab, libass… are optional).
    static func hasFilter(_ name: String) async -> Bool {
        if let known = filters.value[name] { return known }
        guard let tool = Engines.ffmpeg, let result = try? await ExternalTool.run(tool, ["-hide_banner", "-h", "filter=\(name)"]) else { return false }
        let text = String(decoding: result.stdout, as: UTF8.self) + result.stderr
        let available = result.status == 0 && !text.contains("Unknown filter") && text.contains("Filter \(name)")
        filters.mutate { $0[name] = available }
        return available
    }

    /// "1:05" or "1:02:03".
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// ISO 639-2 code ("ita") of the text's language, for subtitle track tags.
    static func languageCode(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        guard let language = recognizer.dominantLanguage?.rawValue, language != "und" else { return nil }
        let base = String(language.split(separator: "-").first ?? Substring(language))
        return Locale.LanguageCode(base).identifier(.alpha3)
    }

    /// "eng" → "English" in the user's language.
    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) ?? code
        return Locale.current.localizedString(forLanguageCode: alpha2)?.localizedCapitalized
    }

    static func transparentContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.cannotEncode("PNG")
        }
        return context
    }

    static func textAttributes(_ text: String, size: CGFloat, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    static func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat, color: CGColor) {
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(textAttributes(text, size: size, color: color)), context)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw KumquatError.cannotWrite(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("PNG") }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw KumquatError.cannotWrite(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.cannotEncode("JPG") }
    }
}
