import Foundation

/// Audio and video through FFmpeg. Speed comes from never doing more work than needed:
/// streams the target container accepts are copied (remux, near-instant); video that must be
/// re-encoded uses the VideoToolbox hardware encoders, with software x264 as fallback.
public enum MediaEngine {
    public typealias Progress = @Sendable (Double) -> Void

    struct Info: Sendable {
        var duration: Double = 0
        var video: String?
        var audio: String?
        var width = 0
        var height = 0
        /// Counter-clockwise turn the player applies when showing the video (display matrix).
        var rotation = 0
        var audioBits = 16
        /// Average frame rate of the video track; 0 when unknown.
        var fps: Double = 0
        /// Fields instead of frames (camcorder MTS, DVD VOB, broadcast TS).
        var interlaced = false
        var sampleRate = 0
        var channels = 0
        /// ISO 639-2 tag of the first audio track ("eng"), when the file says.
        var audioLanguage: String?
        /// Cover art: an attached-picture stream.
        var hasCover = false
        var subtitles: [SubtitleTrack] = []

        /// Size as shown, after the rotation flag.
        var displayWidth: Int { abs(rotation) % 180 == 90 ? height : width }
        var displayHeight: Int { abs(rotation) % 180 == 90 ? width : height }
    }

    struct SubtitleTrack: Sendable {
        var codec: String
        var language: String?
        var title: String?
    }

    // MARK: - Running FFmpeg

    static func probe(_ url: URL) async throws -> Info {
        guard let ffprobe = Engines.ffprobe else { throw KumquatError.toolMissing("FFmpeg") }
        let result = try await ExternalTool.check(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else { throw KumquatError.cannotOpen(url.lastPathComponent) }
        var info = Info()
        if let format = json["format"] as? [String: Any] { info.duration = Double(format["duration"] as? String ?? "") ?? 0 }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let codec = stream["codec_name"] as? String
            let attachedPicture = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            let tags = stream["tags"] as? [String: Any] ?? [:]
            switch stream["codec_type"] as? String {
            case "video" where attachedPicture:
                info.hasCover = true
            case "video" where info.video == nil:
                info.video = codec
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
                info.rotation = (stream["side_data_list"] as? [[String: Any]] ?? []).lazy.compactMap { ($0["rotation"] as? NSNumber)?.intValue }.first
                    ?? Int(tags["rotate"] as? String ?? "").map { -$0 } ?? 0
                info.fps = [stream["avg_frame_rate"], stream["r_frame_rate"]].lazy.compactMap { rate($0 as? String) }.first ?? 0
                info.interlaced = ["tt", "bb", "tb", "bt"].contains(stream["field_order"] as? String ?? "")
            case "audio" where info.audio == nil:
                info.audio = codec
                let bits = Int(stream["bits_per_raw_sample"] as? String ?? "") ?? 0
                let sampleFormat = stream["sample_fmt"] as? String ?? ""
                info.audioBits = bits > 16 || sampleFormat.hasPrefix("s32") || sampleFormat.hasPrefix("flt") ? 24 : 16
                info.sampleRate = Int(stream["sample_rate"] as? String ?? "") ?? 0
                info.channels = stream["channels"] as? Int ?? 0
                info.audioLanguage = (tags["language"] as? String).flatMap { $0 == "und" ? nil : $0 }
            case "subtitle":
                info.subtitles.append(SubtitleTrack(codec: codec ?? "", language: (tags["language"] as? String).flatMap { $0 == "und" ? nil : $0 },
                                                    title: tags["title"] as? String))
            default:
                break
            }
        }
        if info.duration == 0, info.video == nil, info.audio == nil { throw KumquatError.cannotDecode(url.lastPathComponent) }
        return info
    }

    /// "30000/1001" → 29.97; `nil` for "0/0".
    private static func rate(_ text: String?) -> Double? {
        let parts = (text ?? "").split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        let value = parts[0] / parts[1]
        return value < 1000 ? value : nil
    }

    static func ffmpeg(_ arguments: [String], duration: Double, progress: Progress?) async throws {
        guard let tool = Engines.ffmpeg else { throw KumquatError.toolMissing("FFmpeg") }
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        try await ExternalTool.check(tool, full) { line in
            guard duration > 0, let progress, line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) else { return }
            progress(min(max(micros / 1_000_000 / duration, 0), 1))
        }
    }

    /// Maps a step's 0…1 onto `from…to` of the whole job.
    static func scaled(_ progress: Progress?, _ from: Double, _ to: Double) -> Progress? {
        guard let progress else { return nil }
        return { progress(from + (to - from) * $0) }
    }

    /// Tries encoder setups in order (hardware first) until one succeeds.
    static func ffmpeg(alternatives: [[String]], duration: Double, progress: Progress?) async throws {
        var lastError: Error = KumquatError.noResult(String(localized: "Nothing to encode."))
        for arguments in alternatives {
            do {
                try await ffmpeg(arguments, duration: duration, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Codec policy

    static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    struct Encoder {
        var video: [String]
        var audio: [String]
    }

    /// Encoder setups per container, hardware first.
    static func encoders(for target: FileFormat) -> [Encoder] {
        switch target {
        case .webm:
            [Encoder(video: ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"],
                     audio: ["-c:a", "libopus", "-b:a", "128k"])]
        case .avi:
            [Encoder(video: ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "XVID"], audio: ["-c:a", "libmp3lame", "-q:a", "2"])]
        case .wmv:
            [Encoder(video: ["-c:v", "wmv2", "-q:v", "3"], audio: ["-c:a", "wmav2", "-b:a", "192k"])]
        default:
            [Encoder(video: ["-c:v", "h264_videotoolbox", "-q:v", "62", "-allow_sw", "1"], audio: ["-c:a", "aac_at", "-b:a", "192k"]),
             Encoder(video: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"], audio: ["-c:a", "aac", "-b:a", "192k"])]
        }
    }

    static func copiesVideo(_ codec: String?, into target: FileFormat) -> Bool {
        guard let codec else { return false }
        switch target {
        case .mp4: return ["h264", "hevc", "av1", "mpeg4"].contains(codec)
        case .mov: return ["h264", "hevc", "prores", "mpeg4", "mjpeg"].contains(codec)
        case .mkv: return ["h264", "hevc", "vp8", "vp9", "av1", "mpeg4", "prores", "mjpeg"].contains(codec)
        case .webm: return ["vp8", "vp9", "av1"].contains(codec)
        case .avi: return ["mpeg4", "mjpeg", "msmpeg4v3"].contains(codec)
        case .wmv: return ["wmv1", "wmv2", "wmv3"].contains(codec)
        default: return false
        }
    }

    static func copiesAudio(_ codec: String?, into target: FileFormat) -> Bool {
        guard let codec else { return false }
        switch target {
        case .mp4: return ["aac", "mp3", "alac", "ac3", "eac3"].contains(codec)
        case .mov: return ["aac", "mp3", "alac", "ac3", "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be"].contains(codec)
        case .mkv: return ["aac", "mp3", "opus", "vorbis", "flac", "ac3", "eac3", "alac", "pcm_s16le", "pcm_s24le"].contains(codec)
        case .webm: return ["opus", "vorbis"].contains(codec)
        case .avi: return ["mp3", "ac3", "pcm_s16le"].contains(codec)
        case .wmv: return ["wmav1", "wmav2"].contains(codec)
        case .mp3: return codec == "mp3"
        case .m4a: return ["aac", "alac"].contains(codec)
        case .flac: return codec == "flac"
        case .ogg: return ["opus", "vorbis"].contains(codec)
        case .opus: return codec == "opus"
        case .wma: return ["wmav1", "wmav2"].contains(codec)
        case .m4b, .m4r: return codec == "aac"
        case .caf: return codec == "alac"
        case .ac3: return codec == "ac3"
        default: return false
        }
    }

    /// Codecs that lose nothing: CAF keeps them lossless (ALAC).
    static func isLossless(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "ape", "tta", "truehd", "mlp"].contains(codec)
    }

    /// Audio encoder setups for an audio-only target, best first.
    /// CAF: ALAC here (FFmpeg can't put AAC in CAF); `audio()` sends lossy sources (MP3, AAC, Opus…)
    /// to AAC 256 kbps through afconvert instead, since storing them losslessly only makes them bigger.
    static func audioEncoders(for target: FileFormat, bits: Int = 16, lossyBitrate: String? = nil, channels: Int = 2) -> [[String]] {
        func aac(_ fallback: String) -> [[String]] {
            [["-c:a", "aac_at", "-b:a", lossyBitrate ?? fallback], ["-c:a", "aac", "-b:a", lossyBitrate ?? fallback]]
        }
        return switch target {
        case .mp3: lossyBitrate.map { [["-c:a", "libmp3lame", "-b:a", $0]] } ?? [["-c:a", "libmp3lame", "-q:a", "2"]]
        case .m4a, .m4r: aac("256k")
        // Audiobooks: speech needs far less than music.
        case .m4b: aac("128k")
        case .caf: [["-c:a", "alac"]]
        case .ac3: [["-c:a", "ac3", "-b:a", lossyBitrate ?? (channels > 2 ? "448k" : "192k")]]
        case .wav: [["-c:a", bits > 16 ? "pcm_s24le" : "pcm_s16le"]]
        case .aiff: [["-c:a", bits > 16 ? "pcm_s24be" : "pcm_s16be"]]
        case .flac: [["-c:a", "flac", "-compression_level", "8"]]
        case .ogg: [["-c:a", "libopus", "-b:a", lossyBitrate ?? "160k"], ["-c:a", "libvorbis", "-q:a", "5"]]
        case .opus: [["-c:a", "libopus", "-b:a", lossyBitrate ?? "128k"]]
        case .wma: [["-c:a", "wmav2", "-b:a", lossyBitrate ?? "192k"]]
        default: [["-c:a", "aac", "-b:a", "192k"]]
        }
    }

    static func containerFlags(_ target: FileFormat) -> [String] {
        switch target {
        case .mp4, .mov: ["-movflags", "+faststart"]
        // FFmpeg doesn't know .m4r: name the iTunes flavour of MP4 explicitly.
        case .m4a, .m4b, .m4r: ["-f", "ipod", "-movflags", "+faststart"]
        default: []
        }
    }

    /// Container a tool writes: the source's own, or what the executor chose (MP4/M4A) for
    /// formats Kumquat only reads.
    static func container(_ format: FileFormat, output: URL) -> FileFormat {
        guard format.isInputOnly else { return format }
        return FileFormat.detect(output) ?? (format.category == .audio ? .m4a : .mp4)
    }

    // MARK: - Convert

    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        switch target {
        case .gif:
            try await gif(input, info: info, output: output, progress: progress)
        case .webp:
            try await animatedWebP(input, info: info, output: output, progress: progress)
        case .mp4 where source.category == .audio:
            try await audiogram(input, info: info, output: output, progress: progress)
        case .m4r:
            // Ringtones stop at 40 s; a longer song fades out instead of being cut mid-note.
            let fade = info.duration > ringtoneLength ? "afade=t=out:st=\(ringtoneLength - 3):d=3" : nil
            try await audio(input, info: info, to: .m4r, output: output, filters: fade, limit: ringtoneLength, progress: progress)
        case .mp3 where source.category == .video:
            guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
            try await ffmpeg(["-i", input.path, "-map", "0:a:0", "-vn", "-map_metadata", "0", "-c:a", "libmp3lame", "-q:a", "2", output.path],
                             duration: info.duration, progress: progress)
        default:
            if target.category == .audio {
                try await audio(input, info: info, to: target, output: output, filters: nil, progress: progress)
            } else {
                try await video(input, info: info, to: target, output: output, progress: progress)
            }
        }
    }

    static func video(_ input: URL, info: Info, to target: FileFormat, output: URL, progress: Progress?) async throws {
        guard info.video != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no video track.")) }
        let copyVideo = copiesVideo(info.video, into: target)
        let copyAudio = copiesAudio(info.audio, into: target)
        let base = ["-i", input.path, "-map", "0:V:0", "-map", "0:a:0?", "-map_metadata", "0", "-sn", "-dn"]
        let alternatives = encoders(for: target).map { encoder -> [String] in
            var args = base
            if copyVideo {
                args += ["-c:v", "copy"] + (info.video == "hevc" && [.mp4, .mov].contains(target) ? ["-tag:v", "hvc1"] : [])
            } else {
                args += encoder.video + ["-vf", pictureFilter(info), "-pix_fmt", "yuv420p"]
            }
            if info.audio != nil { args += copyAudio ? ["-c:a", "copy"] : encoder.audio }
            return args + containerFlags(target) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// Even dimensions for the encoders, deinterlaced first when the source is made of fields.
    static func pictureFilter(_ info: Info, _ filter: String? = nil) -> String {
        [info.interlaced ? "yadif=deint=interlaced" : nil, filter, evenDimensions].compactMap { $0 }.joined(separator: ",")
    }

    static let ringtoneLength = 40.0

    /// `limit`: seconds to keep from the start.
    static func audio(_ input: URL, info: Info, to target: FileFormat, output: URL, filters: String?, bitrate: String? = nil,
                      limit: Double? = nil, progress: Progress?) async throws {
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        let target = container(target, output: output)
        if target == .caf, info.audio != "alac", bitrate != nil || !isLossless(info.audio) {
            try await cafAAC(input, info: info, output: output, filters: filters, bitrate: bitrate, limit: limit, progress: progress)
            return
        }
        let base = ["-i", input.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"] + (limit.map { ["-t", String($0)] } ?? [])
        let tail = containerFlags(target) + [output.path]
        let alternatives: [[String]]
        if filters == nil, bitrate == nil, copiesAudio(info.audio, into: target) {
            alternatives = [base + ["-c:a", "copy"] + tail]
        } else {
            let filterArgs = filters.map { ["-af", $0] } ?? []
            alternatives = audioEncoders(for: target, bits: info.audioBits, lossyBitrate: bitrate, channels: info.channels)
                .map { base + filterArgs + $0 + tail }
        }
        let length = limit.map { min($0, info.duration) } ?? info.duration
        try await ffmpeg(alternatives: alternatives, duration: length, progress: progress)
    }

    /// FFmpeg's CAF muxer can't hold AAC: FFmpeg decodes, Core Audio's afconvert (on every Mac) encodes.
    static func cafAAC(_ input: URL, info: Info, output: URL, filters: String?, bitrate: String?, limit: Double?, progress: Progress?) async throws {
        let wav = ImageEngine.temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await audio(input, info: info, to: .wav, output: wav, filters: filters, limit: limit, progress: scaled(progress, 0, 0.6))
        let kbps = bitrate.flatMap { Int($0.filter(\.isNumber)) } ?? (info.channels == 1 ? 128 : 256)
        let encode = ["-f", "caff", "-d", "aac"]
        do {
            try await ExternalTool.check(afconvert, encode + ["-b", String(kbps * 1000), wav.path, output.path])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Narrowband sources (8 kHz voice memos) only take low bitrates: Core Audio picks one.
            try await ExternalTool.check(afconvert, encode + [wav.path, output.path])
        }
        progress?(1)
    }

    static var afconvert: URL { URL(fileURLWithPath: "/usr/bin/afconvert") }

    // MARK: - Animated WebP and audiograms

    /// FFmpeg rarely has libwebp: it writes PNG frames (≤15 fps, ≤640 px wide) that img2webp
    /// packs into a lossy animation.
    static func animatedWebP(_ input: URL, info: Info, output: URL, progress: Progress?) async throws {
        guard info.video != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no video track.")) }
        guard let img2webp = Engines.img2webp else { throw KumquatError.toolMissing("img2webp") }
        var fps = min(15, info.fps > 0 ? info.fps : 15)
        // Long clips get fewer frames per second so the frames (and img2webp's memory) stay bounded.
        if info.duration > 0 { fps = min(fps, max(0.5, 2400 / info.duration)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-webp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await ffmpeg(["-i", input.path, "-map", "0:V:0", "-vf", "fps=\(fps),scale='min(640,iw)':-2:flags=lanczos", "-pix_fmt", "rgba",
                          folder.appendingPathComponent("f%06d.png").path],
                         duration: info.duration, progress: scaled(progress, 0, 0.6))
        let frames = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !frames.isEmpty else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        var arguments = ["-loop", "0", "-lossy", "-q", "75", "-m", "4", "-d", String(Int((1000 / fps).rounded()))]
        arguments += frames.map(\.path) + ["-o", output.path]
        // Thousands of frames overflow the command line: img2webp reads its arguments from a file
        // (split on white space, so only when the paths have none).
        if frames.count > 300, !folder.path.contains(where: \.isWhitespace), !output.path.contains(where: \.isWhitespace) {
            let list = folder.appendingPathComponent("arguments.txt")
            try arguments.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            arguments = [list.path]
        }
        try await ExternalTool.check(img2webp, arguments)
        progress?(1)
    }

    /// Audio as an MP4 for sharing: the cover art (when there is one) over a dark background with
    /// the moving waveform, and the sound as AAC.
    static func audiogram(_ input: URL, info: Info, output: URL, progress: Progress?) async throws {
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        let waves = "showwaves=s=1200x%d:mode=cline:rate=25:scale=sqrt:colors=0xFF9F0A"
        var graph = "color=c=0x1C1C1E:s=1280x720:r=25[kqbg];"
        if info.hasCover {
            graph += "[0:v:0]scale=420:420:force_original_aspect_ratio=decrease,setsar=1[kqcover];[kqbg][kqcover]overlay=(W-w)/2:64[kqbase];"
            graph += "[0:a:0]aformat=channel_layouts=mono,\(String(format: waves, 150))[kqwave];[kqbase][kqwave]overlay=40:520:shortest=1"
        } else {
            graph += "[0:a:0]aformat=channel_layouts=mono,\(String(format: waves, 320))[kqwave];[kqbg][kqwave]overlay=40:200:shortest=1"
        }
        graph += ",format=yuv420p[v]"
        let copyAudio = copiesAudio(info.audio, into: .mp4)
        let alternatives = encoders(for: .mp4).map { encoder -> [String] in
            ["-i", input.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a:0", "-map_metadata", "0"]
                + encoder.video + (copyAudio ? ["-c:a", "copy"] : encoder.audio) + ["-shortest"] + containerFlags(.mp4) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// Palette-optimised GIF: per-clip palette, Bayer dithering, ≤640 px at 12 fps.
    /// `before` runs ahead of the GIF filters (a crop, a rotation).
    static func gif(_ input: URL, info: Info, output: URL, width: Int = 640, fps: Int = 12, start: Double = 0, length: Double? = nil,
                    before: String? = nil, progress: Progress?) async throws {
        let filter = (before.map { $0 + "," } ?? "") + "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        let seek = start > 0 ? ["-ss", String(start)] : []
        let limit = length.map { ["-t", String($0)] } ?? []
        try await ffmpeg(seek + ["-i", input.path] + limit + ["-vf", filter, "-loop", "0", output.path],
                         duration: length ?? info.duration - start, progress: progress)
    }

    // MARK: - Tools

    /// Re-encodes in the source container with optional video/audio filters.
    static func reencode(_ input: URL, info: Info, as format: FileFormat, output: URL, videoFilter: String?, audioFilter: String?,
                         inputArgs: [String] = [], outputArgs: [String] = [], progress: Progress?) async throws {
        let format = container(format, output: output)
        if format.category == .audio || info.video == nil {
            let target = format.category == .audio ? format : .m4a
            try await audio(input, info: info, to: target, output: output, filters: audioFilter, progress: progress)
            return
        }
        if format == .gif {
            try await gif(input, info: info, output: output, before: videoFilter, progress: progress)
            return
        }
        let alternatives = encoders(for: format).map { encoder -> [String] in
            var args = inputArgs + ["-i", input.path, "-map", "0:V:0", "-map", "0:a:0?", "-map_metadata", "0", "-sn", "-dn"] + outputArgs
            args += encoder.video + ["-vf", pictureFilter(info, videoFilter), "-pix_fmt", "yuv420p"]
            if info.audio != nil { args += (audioFilter.map { ["-af", $0] } ?? []) + encoder.audio }
            return args + containerFlags(format) + [output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// "1:05", "65", "0:01:05.5" → seconds.
    public static func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var total = 0.0
        for part in trimmed.split(separator: ":") {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func trim(_ input: URL, from source: FileFormat, start: String, end: String, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        if source.category == .audio {
            // Zero-click: cut silent lead-in and tail.
            let silence = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1"
            try await audio(input, info: info, to: source, output: output, filters: "\(silence),areverse,\(silence),areverse", progress: progress)
            return
        }
        let from = parseTime(start) ?? 0
        let to = parseTime(end)
        if let to, to <= from { throw KumquatError.noResult(String(localized: "End must come after start.")) }
        var outputArgs: [String] = []
        if let to { outputArgs = ["-t", String(to - from)] }
        var trimmed = info
        trimmed.duration = (to ?? info.duration) - from
        try await reencode(input, info: trimmed, as: source, output: output, videoFilter: nil, audioFilter: nil,
                           inputArgs: from > 0 ? ["-ss", String(from)] : [], outputArgs: outputArgs, progress: progress)
    }

    /// Detects letterbox/pillarbox bars and removes them.
    public static func autoCrop(_ input: URL, from source: FileFormat, output: URL, progress: Progress?) async throws {
        guard let tool = Engines.ffmpeg else { throw KumquatError.toolMissing("FFmpeg") }
        let info = try await probe(input)
        let start = info.duration > 30 ? info.duration * 0.1 : 0
        let scan = try await ExternalTool.run(tool, ["-hide_banner", "-nostdin", "-ss", String(start), "-i", input.path, "-t", "20",
                                                     "-vf", "fps=2,cropdetect=limit=24:round=2:reset=0", "-an", "-f", "null", "-"])
        guard let match = scan.stderr.matches(of: /crop=(\d+):(\d+):(\d+):(\d+)/).last,
              let w = Int(match.output.1), let h = Int(match.output.2) else {
            throw KumquatError.noResult(String(localized: "Couldn't analyse “\(input.lastPathComponent)”."))
        }
        guard w < info.width - 4 || h < info.height - 4 else { throw KumquatError.noResult(String(localized: "No black borders in “\(input.lastPathComponent)”.")) }
        let crop = "crop=\(match.output.1):\(match.output.2):\(match.output.3):\(match.output.4)"
        try await reencode(input, info: info, as: source, output: output, videoFilter: crop, audioFilter: nil, progress: progress)
    }

    /// Draws the region to keep, normalised "x:y:w:h" with a top-left origin. FFmpeg applies it after
    /// auto-rotation, so it matches what the preview showed.
    public static func crop(_ input: URL, from source: FileFormat, region: CGRect, output: URL, progress: Progress?) async throws {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let area = region.intersection(unit)
        guard area.width > 0.01, area.height > 0.01 else { throw KumquatError.noResult(String(localized: "Draw the area to keep.")) }
        guard area != unit else { throw KumquatError.noResult(String(localized: "The area to keep is the whole frame.")) }
        let info = try await probe(input)
        let crop = "crop=trunc(iw*\(area.width)/2)*2:trunc(ih*\(area.height)/2)*2:trunc(iw*\(area.minX)):trunc(ih*\(area.minY))"
        try await reencode(input, info: info, as: source, output: output, videoFilter: crop, audioFilter: nil, progress: progress)
    }

    /// Keeps the largest centred area with the given shape (width / height).
    public static func crop(_ input: URL, from source: FileFormat, aspect: Double, output: URL, progress: Progress?) async throws {
        guard aspect > 0 else { throw KumquatError.noResult(String(localized: "Pick a shape.")) }
        let info = try await probe(input)
        let crop = "crop='trunc(min(iw,ih*\(aspect))/2)*2':'trunc(min(ih,iw/\(aspect))/2)*2'"
        try await reencode(input, info: info, as: source, output: output, videoFilter: crop, audioFilter: nil, progress: progress)
    }

    /// `degrees`: 90 (clockwise), 180 or 270 (counter-clockwise), on top of how the video already shows.
    /// MP4 and MOV only get a new rotation flag (instant, lossless); other containers re-encode.
    public static func rotate(_ input: URL, from source: FileFormat, degrees: Int, output: URL, progress: Progress?) async throws {
        let turn = (degrees % 360 + 360) % 360
        let filter = switch turn {
        case 90: "transpose=clock"
        case 180: "hflip,vflip"
        case 270: "transpose=cclock"
        default: throw KumquatError.noResult(String(localized: "Rotate by 90°, 180° or 270°."))
        }
        let info = try await probe(input)
        guard info.video != nil else { throw KumquatError.noResult(String(localized: "No video to rotate in “\(input.lastPathComponent)”.")) }
        if [.mp4, .mov].contains(source) {
            // -display_rotation turns counter-clockwise and replaces the flag already there.
            let rotation = ((info.rotation - turn) % 360 + 360) % 360
            let copy = ["-display_rotation:v:0", String(rotation), "-i", input.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c", "copy", "-map_metadata", "0"] + containerFlags(source) + [output.path]
            if (try? await ffmpeg(copy, duration: info.duration, progress: progress)) != nil { return }
        }
        try await reencode(input, info: info, as: source, output: output, videoFilter: filter, audioFilter: nil, progress: progress)
    }

    public enum Quality: String, Sendable {
        case high, balanced, small
    }

    /// Video: HEVC at the chosen quality, or at the bitrate that fits `maxMegabytes`.
    /// Audio: `audioBitrate` (kbps) for lossy targets.
    public static func compress(_ input: URL, from source: FileFormat, quality: Quality = .balanced, maxMegabytes: Double? = nil,
                                audioBitrate: Int? = nil, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        if source.category == .audio {
            let target = compressedFormat(source)
            let fallback: String? = switch target {
            case .flac: nil
            case .opus, .ogg: "64k"
            case .m4a where source == .flac: "256k"
            // AMR is already tiny (≈12 kbps speech).
            case .m4a where source == .amr: "32k"
            default: "128k"
            }
            let bitrate = target == .flac ? nil : audioBitrate.map { "\($0)k" } ?? fallback
            try await audio(input, info: info, to: target, output: output, filters: nil, bitrate: bitrate, progress: progress)
            return
        }
        // HEVC at ≤1080p (long side ≤1920) roughly halves H.264 sizes.
        let scale = "scale='if(gte(iw,ih),min(1920,iw),-2)':'if(gte(iw,ih),-2,min(1920,ih))'"
        let (q, crf) = switch quality {
        case .high: ("62", "24")
        case .balanced: ("50", "28")
        case .small: ("38", "32")
        }
        try await compressVideo(input, info: info, maxMegabytes: maxMegabytes, output: output, progress: progress) { videoKbps, audioKbps in
            let codecs: [[String]] = if let videoKbps {
                [["-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-tag:v", "hvc1"] + rateControl(videoKbps),
                 ["-c:v", "libx265", "-preset", "fast", "-tag:v", "hvc1"] + rateControl(videoKbps)]
            } else {
                [["-c:v", "hevc_videotoolbox", "-q:v", q, "-allow_sw", "1", "-tag:v", "hvc1"],
                 ["-c:v", "libx265", "-preset", "fast", "-crf", crf, "-tag:v", "hvc1"]]
            }
            return codecs.map { codec -> [String] in
                var args = ["-i", input.path, "-map", "0:V:0", "-map", "0:a:0?", "-map_metadata", "0", "-sn", "-dn"]
                args += codec + ["-vf", pictureFilter(info, scale), "-pix_fmt", "yuv420p"]
                if info.audio != nil { args += ["-c:a", "aac_at", "-b:a", "\(audioKbps)k"] }
                return args + ["-movflags", "+faststart", output.path]
            }
        }
    }

    static func rateControl(_ kbps: Int) -> [String] {
        ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
    }

    /// Runs the encoder setups `alternatives(videoKbps, audioKbps)` builds: at a fixed quality
    /// without `maxMegabytes`, otherwise at the bitrate that fits, encoding again at a lower one
    /// when the encoder overshoots (short or very still clips).
    static func compressVideo(_ input: URL, info: Info, maxMegabytes: Double?, output: URL, progress: Progress?,
                              alternatives: (_ videoKbps: Int?, _ audioKbps: Int) -> [[String]]) async throws {
        guard let maxMegabytes else {
            try await ffmpeg(alternatives: alternatives(nil, 128), duration: info.duration, progress: progress)
            return
        }
        guard info.duration > 0 else { throw KumquatError.noResult(String(localized: "Couldn't read the length of “\(input.lastPathComponent)”.")) }
        let limit = maxMegabytes * 1024 * 1024
        // 5% headroom for the container; low budgets take a smaller audio share.
        var totalKbps = maxMegabytes * 8 * 1024 * 0.95 / info.duration
        let audioKbps = totalKbps < 600 ? 64 : 128
        for _ in 0..<3 {
            let videoKbps = Int(totalKbps) - (info.audio != nil ? audioKbps : 0)
            guard videoKbps >= 100 else {
                throw KumquatError.noResult(String(localized: "\(maxMegabytes.formatted()) MB is too small for “\(input.lastPathComponent)”."))
            }
            try await ffmpeg(alternatives: alternatives(videoKbps, audioKbps), duration: info.duration, progress: progress)
            let size = Double((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size <= limit { return }
            totalKbps *= limit / size * 0.95
        }
        throw KumquatError.noResult(String(localized: "Couldn't fit “\(input.lastPathComponent)” in \(maxMegabytes.formatted()) MB."))
    }

    /// A small H.264 copy for previewing formats AVFoundation can't play (MKV, WebM, AVI, WMV, GIF).
    public static func makePreviewProxy(_ input: URL, output: URL, progress: Progress? = nil) async throws {
        let info = try await probe(input)
        guard info.video != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no video track.")) }
        let alternatives = [["-c:v", "h264_videotoolbox", "-q:v", "45", "-allow_sw", "1"],
                            ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "28"]].map { codec -> [String] in
            var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
            args += codec + ["-vf", "scale=-2:'min(480,ih)',\(evenDimensions)", "-pix_fmt", "yuv420p"]
            if info.audio != nil { args += ["-c:a", "aac_at", "-b:a", "96k"] }
            return args + ["-movflags", "+faststart", output.path]
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
    }

    /// Lossless sources compress losslessly to FLAC; FLAC to AAC; lossy ones to a lower bitrate.
    public static func compressedFormat(_ source: FileFormat) -> FileFormat {
        switch source {
        case .wav, .aiff: .flac
        case .flac, .amr: .m4a
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mts, .ts, .mpg, .vob, .threeGP, .flv, .ogv: .mp4
        default: source
        }
    }

    /// Equal parts by duration, cut losslessly at keyframes.
    public static func split(_ input: URL, from source: FileFormat, parts: Int, into directory: URL, baseName: String, progress: Progress? = nil) async throws -> [URL] {
        guard parts >= 2, parts <= 100 else { throw KumquatError.noResult(String(localized: "Choose between 2 and 100 parts.")) }
        let info = try await probe(input)
        guard info.duration > 0 else { throw KumquatError.cannotDecode(input.lastPathComponent) }
        let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(baseName) parts")
        let pattern = folder.appendingPathComponent("\(baseName) part %d.\(source.fileExtension)").path
        let length = info.duration / Double(parts)
        let segment = ["-f", "segment", "-segment_time", String(length + 0.01), "-reset_timestamps", "1", "-segment_start_number", "1", pattern]
        func produced() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        // Fast path: lossless cut at keyframes.
        try await ffmpeg(["-i", input.path, "-map", "0", "-c", "copy"] + segment, duration: info.duration, progress: nil)
        if try produced().count >= parts || info.video == nil { return try produced() }
        // Too few keyframes for equal parts: re-encode with a keyframe at every cut.
        for file in try produced() { try FileManager.default.removeItem(at: file) }
        let alternatives = encoders(for: source).map { encoder -> [String] in
            var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?"] + encoder.video
            args += ["-force_key_frames", "expr:gte(t,n_forced*\(length))", "-pix_fmt", "yuv420p"]
            if info.audio != nil { args += encoder.audio }
            return args + segment
        }
        try await ffmpeg(alternatives: alternatives, duration: info.duration, progress: progress)
        return try produced()
    }

    /// Joins clips in order. Identical streams are concatenated without re-encoding;
    /// otherwise every clip is normalised (size, frame rate, audio) and re-encoded.
    public static func merge(_ inputs: [URL], as format: FileFormat, output: URL, progress: Progress?) async throws {
        let format = container(format, output: output)
        var infos: [Info] = []
        for url in inputs { infos.append(try await probe(url)) }
        let total = infos.reduce(0) { $0 + $1.duration }
        let first = infos[0]
        let identical = infos.allSatisfy { $0.video == first.video && $0.audio == first.audio && $0.width == first.width && $0.height == first.height }
        if identical {
            let list = ImageEngine.temporaryURL("txt")
            defer { try? FileManager.default.removeItem(at: list) }
            try inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            do {
                try await ffmpeg(["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy"] + containerFlags(format) + [output.path],
                                 duration: total, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to the re-encoding path.
            }
        }
        if format.category == .audio {
            let inputArgs = inputs.flatMap { ["-i", $0.path] }
            let graph = inputs.indices.map { "[\($0):a:0]" }.joined() + "concat=n=\(inputs.count):v=0:a=1[a]"
            let alternatives = audioEncoders(for: format, bits: first.audioBits).map { inputArgs + ["-filter_complex", graph, "-map", "[a]"] + $0 + [output.path] }
            try await ffmpeg(alternatives: alternatives, duration: total, progress: progress)
            return
        }
        let width = (first.width / 2) * 2, height = (first.height / 2) * 2
        guard width > 0, height > 0 else { throw KumquatError.cannotDecode(inputs[0].lastPathComponent) }
        let withAudio = infos.contains { $0.audio != nil }
        var inputArgs: [String] = []
        var graph = ""
        var silentIndex = inputs.count
        for url in inputs { inputArgs += ["-i", url.path] }
        for (index, info) in infos.enumerated() {
            graph += "[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)];"
            if withAudio {
                if info.audio != nil {
                    graph += "[\(index):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(index)];"
                } else {
                    inputArgs += ["-f", "lavfi", "-t", String(max(info.duration, 0.1)), "-i", "anullsrc=r=48000:cl=stereo"]
                    graph += "[\(silentIndex):a]anull[a\(index)];"
                    silentIndex += 1
                }
            }
        }
        graph += infos.indices.map { "[v\($0)]" + (withAudio ? "[a\($0)]" : "") }.joined()
        graph += "concat=n=\(inputs.count):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : "")
        let audioMap: [String] = withAudio ? ["-map", "[a]"] : []
        let alternatives = encoders(for: format).map { encoder -> [String] in
            var args: [String] = inputArgs
            args += ["-filter_complex", graph, "-map", "[v]"]
            args += audioMap
            if withAudio { args += encoder.audio }
            args += encoder.video
            args += containerFlags(format)
            args.append(output.path)
            return args
        }
        try await ffmpeg(alternatives: alternatives, duration: total, progress: progress)
    }

    public static func mute(_ input: URL, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        try await ffmpeg(["-i", input.path, "-map", "0:v", "-c", "copy", "-an"] + containerFlags(FileFormat.detect(output) ?? .mp4) + [output.path],
                         duration: info.duration, progress: progress)
    }

    /// Audio format that can hold the source's audio track without re-encoding.
    public static func extractedAudioFormat(_ input: URL) async throws -> FileFormat {
        switch try await probe(input).audio {
        case "mp3"?: .mp3
        case "opus"?: .opus
        case "flac"?: .flac
        case nil: throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track."))
        default: .m4a
        }
    }

    public static func extractAudio(_ input: URL, output: URL, progress: Progress?) async throws {
        let info = try await probe(input)
        let target = FileFormat.detect(output) ?? .m4a
        try await audio(input, info: info, to: target, output: output, filters: nil, progress: progress)
    }

    public static func changeSpeed(_ input: URL, from source: FileFormat, factor: Double, output: URL, progress: Progress?) async throws {
        guard factor >= 0.25, factor <= 16 else { throw KumquatError.noResult(String(localized: "Speed must be between 0.25× and 16×.")) }
        var info = try await probe(input)
        info.duration /= factor
        try await reencode(input, info: info, as: source, output: output, videoFilter: "setpts=PTS/\(factor)",
                           audioFilter: tempoChain(factor), progress: progress)
    }

    /// atempo steps of at most 2× each way (what every FFmpeg version accepts).
    static func tempoChain(_ factor: Double) -> String {
        var tempo: [String] = []
        var remaining = factor
        while remaining > 2 { tempo.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { tempo.append("atempo=0.5"); remaining /= 0.5 }
        tempo.append("atempo=\(remaining)")
        return tempo.joined(separator: ",")
    }

    public static func resize(_ input: URL, from source: FileFormat, height: Int, output: URL, progress: Progress?) async throws {
        guard height >= 16, height <= 8640 else { throw KumquatError.noResult(String(localized: "Height must be between 16 and 8640 px.")) }
        let info = try await probe(input)
        try await reencode(input, info: info, as: source, output: output, videoFilter: "scale=-2:\(height)", audioFilter: nil, progress: progress)
    }

    public static func extractFrames(_ input: URL, fps: Double, into directory: URL, baseName: String, progress: Progress?) async throws -> [URL] {
        guard fps > 0, fps <= 60 else { throw KumquatError.noResult(String(localized: "Frames per second must be between 0.01 and 60.")) }
        let info = try await probe(input)
        let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(baseName) frames")
        try await ffmpeg(["-i", input.path, "-vf", "fps=\(fps)", "-q:v", "2", folder.appendingPathComponent("frame %04d.jpg").path],
                         duration: info.duration, progress: progress)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    /// `start`/`end` in seconds; `end == nil` runs to the end of the clip.
    public static func makeGIF(_ input: URL, start: Double = 0, end: Double? = nil, fps: Int = 15, width: Int = 480,
                               output: URL, progress: Progress?) async throws {
        guard (1...50).contains(fps) else { throw KumquatError.noResult(String(localized: "Frame rate must be between 1 and 50 fps.")) }
        guard (16...3840).contains(width) else { throw KumquatError.noResult(String(localized: "Width must be between 16 and 3840 px.")) }
        if let end, end <= start { throw KumquatError.noResult(String(localized: "End must come after start.")) }
        let info = try await probe(input)
        try await gif(input, info: info, output: output, width: width, fps: fps, start: start, length: end.map { $0 - start }, progress: progress)
    }

    /// `lufs`: integrated loudness target (−14 streaming, −16 podcasts, −23 broadcast).
    public static func normalize(_ input: URL, from source: FileFormat, lufs: Double = -16, output: URL, progress: Progress?) async throws {
        guard (-36 ... -6).contains(lufs) else { throw KumquatError.noResult(String(localized: "Loudness must be between −36 and −6 LUFS.")) }
        let info = try await probe(input)
        try await audio(input, info: info, to: source, output: output, filters: "loudnorm=I=\(lufs):TP=-1.5:LRA=11", progress: progress)
    }

    public static func adjustVolume(_ input: URL, from source: FileFormat, decibels: Double, output: URL, progress: Progress?) async throws {
        guard abs(decibels) <= 40 else { throw KumquatError.noResult(String(localized: "Gain must be between -40 and +40 dB.")) }
        let info = try await probe(input)
        try await audio(input, info: info, to: source, output: output, filters: "volume=\(decibels)dB", progress: progress)
    }
}
