import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Speech
import Testing
@testable import KumquatCore

/// Clips, tones and probes for the media tools, all synthesised with FFmpeg's lavfi sources.
enum MediaFixtures {
    static func ffmpeg(_ arguments: [String]) async throws {
        try await ExternalTool.check(Engines.ffmpeg!, ["-hide_banner", "-loglevel", "error", "-y"] + arguments)
    }

    /// Test pattern with a tone; `picture` replaces the pattern (e.g. "color=c=black").
    static func clip(_ dir: URL, name: String = "clip.mp4", size: String = "320x240", seconds: Double = 2, rate: Int = 25,
                     picture: String? = nil, audio: Bool = true, codecs: [String]? = nil) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let source = picture.map { "\($0):s=\(size):r=\(rate):d=\(seconds)" } ?? "testsrc=size=\(size):rate=\(rate):duration=\(seconds)"
        var args = ["-f", "lavfi", "-i", source]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        args += codecs ?? (["-c:v", "libx264", "-pix_fmt", "yuv420p"] + (audio ? ["-c:a", "aac"] : []))
        try await ffmpeg(args + ["-shortest", url.path])
        return url
    }

    /// Sine tone, `silence` seconds of silence in the middle.
    static func tone(_ dir: URL, name: String = "tone.wav", seconds: Double = 2, silence: Double = 0, codecs: [String] = []) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        if silence > 0 {
            try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds / 2)", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=\(silence)",
                              "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds / 2)", "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1"] + codecs + [url.path])
        } else {
            try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-ac", "2"] + codecs + [url.path])
        }
        return url
    }

    /// AMR-NB has no encoder in most FFmpeg builds: 2 s of 12.2 kbps frames with random payloads decode as noise.
    static func amr(_ dir: URL) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        var data = Data("#!AMR\n".utf8)
        for _ in 0..<100 {
            data.append(0x3C)
            data.append(contentsOf: (0..<31).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
        let url = dir.appendingPathComponent("memo.amr")
        try data.write(to: url)
        return url
    }

    static func image(_ dir: URL, name: String = "cover.png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Fixtures.write(Fixtures.makeImage(width: 600, height: 600), to: url, type: name.hasSuffix(".png") ? .png : .jpeg)
        return url
    }

    static func srt(_ dir: URL, name: String, _ cues: [(Double, Double, String)]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try SubtitleEngine.render(cues.map { Cue(start: $0.0, end: $0.1, text: $0.2) }, as: .srt).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ffprobe's JSON (streams and format).
    static func probe(_ url: URL) async throws -> [String: Any] {
        let result = try await ExternalTool.check(Engines.ffprobe!, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        return try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] ?? [:]
    }

    static func streams(_ url: URL) async throws -> [[String: Any]] {
        try await probe(url)["streams"] as? [[String: Any]] ?? []
    }

    static func tags(_ url: URL) async throws -> [String: String] {
        let format = try await probe(url)["format"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (key, value) in format["tags"] as? [String: Any] ?? [:] { tags[key.lowercased()] = value as? String }
        // Ogg keeps the comments on the stream.
        for stream in try await streams(url) {
            for (key, value) in stream["tags"] as? [String: Any] ?? [:] { tags[key.lowercased()] = tags[key.lowercased()] ?? value as? String }
        }
        return tags
    }

    static func hasCover(_ url: URL) async throws -> Bool {
        try await streams(url).contains { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }
    }

    /// RGB of one pixel of the frame at `time`, `x`/`y` as fractions of the frame.
    static func pixel(_ url: URL, at time: Double, x: Double, y: Double) async throws -> (r: Int, g: Int, b: Int) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("kq-pixel-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await ffmpeg(["-ss", String(time), "-i", url.path, "-frames:v", "1", "-vf", "crop=2:2:trunc(iw*\(x)):trunc(ih*\(y))",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path])
        let bytes = [UInt8](try Data(contentsOf: raw))
        guard bytes.count >= 3 else { return (0, 0, 0) }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    static func brightness(_ pixel: (r: Int, g: Int, b: Int)) -> Int { (pixel.r + pixel.g + pixel.b) / 3 }

    static func fileSize(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}

@Suite(.enabled(if: Engines.ffmpeg != nil)) struct MediaConversionTests {
    @Test func legacyVideoConvertsEverywhere() async throws {
        let dir = try Fixtures.tempDirectory()
        let mts = try await MediaFixtures.clip(dir, name: "camera.mts", codecs: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "ac3", "-f", "mpegts"])
        let mpg = try await MediaFixtures.clip(dir, name: "tape.mpg", codecs: ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg"])
        let vob = try await MediaFixtures.clip(dir, name: "VTS_01_1.vob", codecs: ["-c:v", "mpeg2video", "-c:a", "ac3", "-f", "vob"])
        let threeGP = try await MediaFixtures.clip(dir, name: "phone.3gp", size: "352x288", codecs: ["-c:v", "h263", "-c:a", "aac", "-ac", "1", "-ar", "8000"])
        let flv = try await MediaFixtures.clip(dir, name: "old.flv", codecs: ["-c:v", "flv", "-c:a", "libmp3lame", "-ar", "44100"])
        let ogv = try await MediaFixtures.clip(dir, name: "free.ogv", codecs: ["-c:v", "libvpx", "-b:v", "300k", "-c:a", "libopus"])
        for input in [mts, mpg, vob, threeGP, flv, ogv] {
            let mp4 = try #require(try await run(.convert(.mp4), [input]).outputs.first)
            let info = try await MediaEngine.probe(mp4)
            #expect(info.video == "h264", "\(input.lastPathComponent)")
            #expect(info.audio != nil, "\(input.lastPathComponent)")
            #expect(abs(info.duration - 2) < 0.3, "\(input.lastPathComponent)")
            let m4a = try #require(try await run(.convert(.m4a), [input]).outputs.first)
            #expect(try await MediaEngine.probe(m4a).audio == "aac", "\(input.lastPathComponent)")
        }
        // H.264 in a transport stream is copied, not re-encoded.
        let copied = try await MediaEngine.probe(try #require(try await run(.convert(.mkv), [mts]).outputs.first))
        #expect(copied.video == "h264")
        for (input, target) in [(mpg, FileFormat.webm), (threeGP, .mov), (flv, .gif), (vob, .wav), (ogv, .flac), (mts, .mp3)] {
            let output = try #require(try await run(.convert(target), [input]).outputs.first, "\(input.lastPathComponent) → \(target)")
            #expect(output.pathExtension == target.fileExtension)
            let info = try await MediaEngine.probe(output)
            #expect(target.category == .audio ? info.audio != nil : info.video != nil)
        }
        // Tools on read-only formats write MP4.
        let trimmed = try #require(try await run(.tool(.trim), [mts], ["start": "0.5", "end": "1.5"]).outputs.first)
        #expect(trimmed.pathExtension == "mp4")
        #expect(abs(try await MediaEngine.probe(trimmed).duration - 1) < 0.2)
    }

    @Test func amrConvertsAndTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let amr = try MediaFixtures.amr(dir)
        for target in [FileFormat.mp3, .m4a, .wav, .m4r, .caf] {
            let output = try #require(try await run(.convert(target), [amr]).outputs.first)
            let info = try await MediaEngine.probe(output)
            #expect(info.audio != nil)
            #expect(abs(info.duration - 2) < 0.2)
        }
        let louder = try #require(try await run(.tool(.adjustVolume), [amr], ["db": "3"]).outputs.first)
        #expect(louder.pathExtension == "m4a")
        #expect(try await MediaEngine.probe(louder).audio == "aac")
    }

    @Test func videoToAudioTargets() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir)
        let m4a = try #require(try await run(.convert(.m4a), [clip]).outputs.first)
        #expect(try await MediaEngine.probe(m4a).audio == "aac")
        let wav = try #require(try await run(.convert(.wav), [clip]).outputs.first)
        #expect(try await MediaEngine.probe(wav).audio?.hasPrefix("pcm_") == true)
        let flac = try #require(try await run(.convert(.flac), [clip]).outputs.first)
        #expect(try await MediaEngine.probe(flac).audio == "flac")
    }

    @Test(.enabled(if: Engines.img2webp != nil)) func animatedWebP() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir, size: "960x540", seconds: 1.5, rate: 30)
        let webp = try #require(try await run(.convert(.webp), [clip]).outputs.first)
        let data = try Data(contentsOf: webp)
        #expect(data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8))
        let source = try #require(CGImageSourceCreateWithURL(webp as CFURL, nil))
        // ≤15 fps for 1.5 s, ≤640 px wide.
        #expect((15...24).contains(CGImageSourceGetCount(source)))
        #expect(ImageProbe.orientedPixelSize(webp).width == 640)
        let gif = try #require(try await run(.convert(.gif), [clip]).outputs.first)
        let fromGIF = try #require(try await run(.convert(.webp), [gif]).outputs.first)
        #expect(CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(fromGIF as CFURL, nil))) > 5)
    }

    @Test func newAudioTargets() async throws {
        let dir = try Fixtures.tempDirectory()
        let wav = try await MediaFixtures.tone(dir, seconds: 3)
        let caf = try await MediaEngine.probe(try #require(try await run(.convert(.caf), [wav]).outputs.first))
        #expect(caf.audio == "alac")
        let mp3 = try #require(try await run(.convert(.mp3), [wav]).outputs.first)
        #expect(try await MediaEngine.probe(try #require(try await run(.convert(.caf), [mp3]).outputs.first)).audio == "aac")
        let ac3 = try await MediaEngine.probe(try #require(try await run(.convert(.ac3), [wav]).outputs.first))
        #expect(ac3.audio == "ac3")
        let m4a = try #require(try await run(.convert(.m4a), [wav]).outputs.first)
        // AAC goes into an audiobook untouched.
        let m4b = try #require(try await run(.convert(.m4b), [m4a]).outputs.first)
        #expect(m4b.pathExtension == "m4b")
        #expect(try await MediaEngine.probe(m4b).audio == "aac")
        #expect(abs(MediaFixtures.fileSize(m4b) - MediaFixtures.fileSize(m4a)) < 4096)

        let song = try await MediaFixtures.tone(dir, name: "song.flac", seconds: 50)
        let ringtone = try #require(try await run(.convert(.m4r), [song]).outputs.first)
        #expect(ringtone.pathExtension == "m4r")
        let ring = try await MediaEngine.probe(ringtone)
        #expect(ring.audio == "aac")
        #expect(abs(ring.duration - 40) < 0.3)
        let format = try await MediaFixtures.probe(ringtone)["format"] as? [String: Any]
        #expect((format?["format_name"] as? String)?.contains("mp4") == true)
    }

    @Test func audiogram() async throws {
        let dir = try Fixtures.tempDirectory()
        let wav = try await MediaFixtures.tone(dir, seconds: 2)
        let plain = try await MediaEngine.probe(try #require(try await run(.convert(.mp4), [wav]).outputs.first))
        #expect(plain.video == "h264" && plain.width == 1280 && plain.height == 720)
        #expect(plain.audio == "aac")
        #expect(abs(plain.duration - 2) < 0.3)

        // With cover art, the cover shows above the waveform.
        let cover = try MediaFixtures.image(dir, name: "art.jpg")
        let mp3 = dir.appendingPathComponent("song.mp3")
        try await MediaFixtures.ffmpeg(["-i", wav.path, "-i", cover.path, "-map", "0:a", "-map", "1:0", "-c:a", "libmp3lame", "-c:v", "copy",
                                        "-disposition:v:0", "attached_pic", "-id3v2_version", "3", mp3.path])
        let covered = try #require(try await run(.convert(.mp4), [mp3]).outputs.first)
        let info = try await MediaEngine.probe(covered)
        #expect(info.video == "h264" && info.width == 1280)
        // Orange-ish cover pixels in the middle of the top half (the fixture is orange with a green disc).
        let corner = try await MediaFixtures.pixel(covered, at: 1, x: 0.36, y: 0.12)
        #expect(corner.r > 150 && corner.b < 120)
    }

    @Test func compressForSharing() async throws {
        let dir = try Fixtures.tempDirectory()
        let wide = try await MediaFixtures.clip(dir, name: "wide.mov", size: "1920x1080", seconds: 2, rate: 60)
        let whatsapp = try #require(try await run(.tool(.compress), [wide], ["preset": "whatsapp"]).outputs.first)
        #expect(whatsapp.pathExtension == "mp4")
        let info = try await MediaEngine.probe(whatsapp)
        #expect(info.video == "h264")
        #expect(info.height == 720 && info.width == 1280)
        #expect(info.fps <= 30.5)
        #expect(Double(MediaFixtures.fileSize(whatsapp)) <= 16 * 1024 * 1024)

        let tall = try await MediaFixtures.clip(dir, name: "tall.mp4", size: "1080x1920", seconds: 2)
        let portrait = try await MediaEngine.probe(try #require(try await run(.tool(.compress), [tall], ["preset": "discord"]).outputs.first))
        #expect(portrait.width == 720 && portrait.height == 1280)

        // A tight budget is met even when the encoder overshoots.
        let tight = try #require(try await run(.tool(.compress), [wide], ["preset": "email", "maxMB": "0.3"]).outputs.first)
        #expect(MediaFixtures.fileSize(tight) <= 315_000)
    }
}

@Suite(.enabled(if: Engines.ffmpeg != nil)) struct VideoExtrasTests {
    @Test func vertical() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir)
        for background in ["blur", "black", "white"] {
            let output = try #require(try await run(.tool(.vertical), [clip], ["background": background]).outputs.first)
            let info = try await MediaEngine.probe(output)
            #expect(info.width == 320 && info.height == 568, "\(background)")
            #expect(info.audio != nil)
        }
        let white = try #require(try await run(.tool(.vertical), [clip], ["background": "white"]).outputs.first)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(white, at: 0.5, x: 0.5, y: 0.05)) > 230)
        let gif = try #require(try await run(.convert(.gif), [clip]).outputs.first)
        let verticalGIF = try await MediaEngine.probe(try #require(try await run(.tool(.vertical), [gif]).outputs.first))
        #expect(verticalGIF.video == "gif")
    }

    @Test func burnedSubtitles() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir, name: "night.mp4", size: "640x360", picture: "color=c=black")
        let srt = try MediaFixtures.srt(dir, name: "night.srt", [(0.6, 1.4, "HELLO WORLD")])
        let burned = try #require(try await run(.tool(.addSubtitles), [clip, srt]).outputs.first)
        #expect(burned.lastPathComponent == "night (subtitled).mp4")
        // Text sits centred near the bottom, only while the cue is on.
        func brightest(at time: Double) async throws -> Int {
            var best = 0
            for x in stride(from: 0.3, through: 0.7, by: 0.02) {
                for y in [0.84, 0.86, 0.88, 0.9] { best = max(best, MediaFixtures.brightness(try await MediaFixtures.pixel(burned, at: time, x: x, y: y))) }
            }
            return best
        }
        #expect(try await brightest(at: 1.0) > 200)
        #expect(try await brightest(at: 0.2) < 40)
        #expect(try await brightest(at: 1.8) < 40)
        #expect(try await MediaEngine.probe(burned).audio == "aac")

        // Hundreds of cues stay one overlay.
        let lines: [(Double, Double, String)] = (0..<300).map { index -> (Double, Double, String) in
            let start = Double(index) * 0.1
            return (start, start + 0.08, "Line \(index)")
        }
        let long = try await MediaFixtures.clip(dir, name: "long.mp4", seconds: 30, rate: 10)
        let busy = try MediaFixtures.srt(dir, name: "long.srt", lines)
        let many = try #require(try await run(.tool(.addSubtitles), [long, busy]).outputs.first)
        #expect(abs(try await MediaEngine.probe(many).duration - 30) < 0.5)
    }

    @Test func subtitleTracksRoundTrip() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir, name: "film.mp4")
        let srt = try MediaFixtures.srt(dir, name: "film.srt", [(0.2, 0.9, "Questa è una frase in italiano."), (1.0, 1.8, "E questa è la seconda.")])
        let mp4 = try #require(try await run(.tool(.addSubtitles), [clip, srt], ["mode": "track"]).outputs.first)
        let streams = try await MediaFixtures.streams(mp4)
        let subtitle = try #require(streams.first { $0["codec_type"] as? String == "subtitle" })
        #expect(subtitle["codec_name"] as? String == "mov_text")
        #expect((subtitle["tags"] as? [String: Any])?["language"] as? String == "ita")
        // The picture is copied, not re-encoded.
        #expect(MediaFixtures.fileSize(mp4) < MediaFixtures.fileSize(clip) + 20_000)

        let mkvClip = try #require(try await run(.convert(.mkv), [clip]).outputs.first)
        let mkv = try #require(try await run(.tool(.addSubtitles), [mkvClip, srt], ["mode": "track"]).outputs.first)
        #expect(mkv.pathExtension == "mkv")
        #expect(try await MediaFixtures.streams(mkv).contains { $0["codec_name"] as? String == "subrip" })

        let extracted = try await run(.tool(.extractSubtitles), [mp4]).outputs
        let file = try #require(extracted.first)
        #expect(extracted.count == 1)
        #expect(file.pathExtension == "srt")
        #expect(file.lastPathComponent.hasPrefix("film (subtitled) ("))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("seconda"))

        let none = await Executor.run(JobRequest(operation: .tool(.extractSubtitles), inputs: [clip], destination: { _ in dir })) { _ in }
        #expect(none.failures.first?.message == "“film.mp4” has no subtitles.")
    }

    @Test func posterAndContactSheet() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir)
        let jpg = try #require(try await run(.tool(.poster), [clip], ["at": "1"]).outputs.first)
        #expect(jpg.lastPathComponent == "clip (poster).jpg")
        #expect(ImageProbe.orientedPixelSize(jpg) == CGSize(width: 320, height: 240))
        let covered = try #require(try await run(.tool(.poster), [clip], ["output": "cover"]).outputs.first)
        #expect(covered.pathExtension == "mp4")
        #expect(try await MediaFixtures.hasCover(covered))
        #expect(try await MediaEngine.probe(covered).video == "h264")
        let mkv = try #require(try await run(.convert(.mkv), [clip]).outputs.first)
        let fromMKV = try #require(try await run(.tool(.poster), [mkv], ["output": "cover"]).outputs.first)
        #expect(fromMKV.pathExtension == "mp4")
        #expect(try await MediaFixtures.hasCover(fromMKV))

        let sheet = try #require(try await run(.tool(.contactSheet), [clip], ["count": "6", "columns": "3"]).outputs.first)
        #expect(sheet.lastPathComponent == "clip (contact sheet).jpg")
        let size = ImageProbe.orientedPixelSize(sheet)
        #expect(size.width > 1800 && size.width <= 1920)
        // Two rows of 4:3 tiles plus the header.
        #expect(size.height > 2 * size.width / 3 * 0.75 * 0.9)
    }

    @Test func soundTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir, name: "video.mp4")
        let music = try await MediaFixtures.tone(dir, name: "music.m4a", seconds: 6, codecs: ["-c:a", "aac"])
        let replaced = try #require(try await run(.tool(.replaceAudio), [clip, music]).outputs.first)
        #expect(replaced.lastPathComponent == "video (new audio).mp4")
        let info = try await MediaEngine.probe(replaced)
        #expect(abs(info.duration - 2) < 0.2)
        #expect(info.video == "h264" && info.audio == "aac")
        let mixed = try #require(try await run(.tool(.replaceAudio), [clip, music], ["mode": "mix", "db": "-6"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(mixed).duration - 2) < 0.2)

        let silent = try await MediaFixtures.clip(dir, name: "silent.mp4", audio: false)
        let scored = try await MediaEngine.probe(try #require(try await run(.tool(.replaceAudio), [silent, music], ["mode": "mix"]).outputs.first))
        #expect(scored.audio == "aac")

        let denoised = try await MediaEngine.probe(try #require(try await run(.tool(.denoise), [clip], ["strength": "strong"]).outputs.first))
        #expect(denoised.video == "h264" && denoised.audio == "aac")
        let noVideoSound = await Executor.run(JobRequest(operation: .tool(.denoise), inputs: [silent], destination: { _ in dir })) { _ in }
        #expect(noVideoSound.failures.first?.message == "“silent.mp4” has no audio track.")
    }

    @Test func reverseAndBoomerang() async throws {
        let dir = try Fixtures.tempDirectory()
        // Black fading to white: brightness tells the direction.
        let ramp = dir.appendingPathComponent("ramp.mp4")
        try await MediaFixtures.ffmpeg(["-f", "lavfi", "-i", "color=c=white:s=160x120:r=25:d=3", "-f", "lavfi", "-i", "sine=d=3",
                                        "-vf", "fade=t=in:st=0:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", ramp.path])
        let reversed = try #require(try await run(.tool(.reverse), [ramp]).outputs.first)
        #expect(reversed.lastPathComponent == "ramp (reversed).mp4")
        #expect(abs(try await MediaEngine.probe(reversed).duration - 3) < 0.2)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(reversed, at: 0.1, x: 0.5, y: 0.5)) > 180)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(reversed, at: 2.8, x: 0.5, y: 0.5)) < 60)

        let boomerang = try #require(try await run(.tool(.reverse), [ramp], ["mode": "boomerang"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(boomerang).duration - 6) < 0.3)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(boomerang, at: 3, x: 0.5, y: 0.5)) > 180)

        // Long clips are reversed in pieces: a tiny memory budget forces 1 s pieces here.
        var info = try await MediaEngine.probe(ramp)
        info.fps = 25
        let pieces = dir.appendingPathComponent("pieces.mov")
        let pixels = Double(info.displayWidth * info.displayHeight)
        try await MediaEngine.reversedCopy(ramp, info: info, output: pieces, progress: nil, memoryBudget: pixels * 2 * 25)
        #expect(abs(try await MediaEngine.probe(pieces).duration - 3) < 0.2)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(pieces, at: 0.1, x: 0.5, y: 0.5)) > 180)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(pieces, at: 1.5, x: 0.5, y: 0.5)) < 180)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(pieces, at: 2.8, x: 0.5, y: 0.5)) < 60)
    }

    @Test func pictureTools() async throws {
        let dir = try Fixtures.tempDirectory()
        let clip = try await MediaFixtures.clip(dir)
        let faded = try #require(try await run(.tool(.fade), [clip], ["seconds": "1", "where": "in"]).outputs.first)
        #expect(MediaFixtures.brightness(try await MediaFixtures.pixel(faded, at: 0, x: 0.3, y: 0.3)) < 30)
        #expect(abs(try await MediaEngine.probe(faded).duration - 2) < 0.2)

        let original = try await MediaFixtures.pixel(clip, at: 0.5, x: 0.05, y: 0.3)
        let flipped = try #require(try await run(.tool(.flip), [clip]).outputs.first)
        // Columns 16–17 come back as 303–302.
        let mirrored = try await MediaFixtures.pixel(flipped, at: 0.5, x: 0.94375, y: 0.3)
        #expect(abs(original.r - mirrored.r) < 40 && abs(original.g - mirrored.g) < 40 && abs(original.b - mirrored.b) < 40)

        let stabilized = try await MediaEngine.probe(try #require(try await run(.tool(.stabilize), [clip]).outputs.first))
        #expect(stabilized.width == 320 && abs(stabilized.duration - 2) < 0.2)

        let black = try await MediaFixtures.clip(dir, name: "black.mp4", picture: "color=c=black")
        let marked = try #require(try await run(.tool(.watermark), [black], ["text": "KUMQUAT", "opacity": "80", "angle": "horizontal"]).outputs.first)
        var best = 0
        for x in stride(from: 0.2, through: 0.8, by: 0.03) { best = max(best, MediaFixtures.brightness(try await MediaFixtures.pixel(marked, at: 1, x: x, y: 0.5))) }
        #expect(best > 150)
        let gif = try #require(try await run(.convert(.gif), [black]).outputs.first)
        #expect(try await MediaEngine.probe(try #require(try await run(.tool(.watermark), [gif], ["text": "GIF"]).outputs.first)).video == "gif")
    }
}

@Suite(.enabled(if: Engines.ffmpeg != nil)) struct AudioExtrasTests {
    @Test func silenceSpeedAndChannels() async throws {
        let dir = try Fixtures.tempDirectory()
        let gap = try await MediaFixtures.tone(dir, name: "talk.wav", seconds: 2, silence: 3)
        let tight = try #require(try await run(.tool(.removeSilence), [gap], ["pause": "0.5"]).outputs.first)
        #expect(tight.lastPathComponent == "talk (no silences).wav")
        #expect(abs(try await MediaEngine.probe(tight).duration - 2.5) < 0.15)

        let tone = try await MediaFixtures.tone(dir, seconds: 2)
        let higher = try #require(try await run(.tool(.changeSpeed), [tone], ["factor": "1", "semitones": "12"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(higher).duration - 2) < 0.1)
        let faster = try #require(try await run(.tool(.changeSpeed), [tone], ["factor": "2", "semitones": "-3"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(faster).duration - 1) < 0.1)

        let mono = try await MediaEngine.probe(try #require(try await run(.tool(.channels), [tone], ["channels": "mono", "rate": "48000"]).outputs.first))
        #expect(mono.channels == 1 && mono.sampleRate == 48000)
        let fade = try #require(try await run(.tool(.fade), [tone], ["seconds": "0.5"]).outputs.first)
        #expect(abs(try await MediaEngine.probe(fade).duration - 2) < 0.1)
        let clean = try #require(try await run(.tool(.denoise), [tone], ["strength": "light"]).outputs.first)
        #expect(clean.pathExtension == "wav")
    }

    @Test func tagsAndCovers() async throws {
        let dir = try Fixtures.tempDirectory()
        let wav = try await MediaFixtures.tone(dir, seconds: 1)
        let cover = try MediaFixtures.image(dir)
        for target in [FileFormat.mp3, .m4a, .flac, .ogg, .aiff] {
            let song = try #require(try await run(.convert(target), [wav]).outputs.first)
            let renamed = dir.appendingPathComponent("song-\(target.rawValue).\(target.fileExtension)")
            try FileManager.default.moveItem(at: song, to: renamed)
            let tagged = try #require(try await run(.tool(.tags), [renamed, cover], ["title": "Kumquat Song", "artist": "Citrus"]).outputs.first)
            #expect(tagged.lastPathComponent == "song-\(target.rawValue) (tagged).\(target.fileExtension)")
            let tags = try await MediaFixtures.tags(tagged)
            #expect(tags["title"] == "Kumquat Song", "\(target)")
            #expect(tags["artist"] == "Citrus", "\(target)")
            #expect(try await MediaFixtures.hasCover(tagged), "\(target)")
            // The sound is copied, not re-encoded.
            #expect(try await MediaEngine.probe(tagged).audio == (try await MediaEngine.probe(renamed).audio), "\(target)")
        }
        // Only text for WAV; tags already there stay.
        let first = try #require(try await run(.tool(.tags), [wav], ["album": "Orchard"]).outputs.first)
        let second = try #require(try await run(.tool(.tags), [first], ["title": "Second"]).outputs.first)
        let tags = try await MediaFixtures.tags(second)
        #expect(tags["album"] == "Orchard" && tags["title"] == "Second")
    }

    @Test func waveform() async throws {
        let dir = try Fixtures.tempDirectory()
        let tone = try await MediaFixtures.tone(dir, seconds: 2)
        let png = try #require(try await run(.tool(.waveform), [tone], ["color": "white"]).outputs.first)
        #expect(png.lastPathComponent == "tone (waveform).png")
        let image = try #require(ImageProbe.source(png).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 1920 && image.height == 480)
        #expect(![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo))
        // Transparent outside the wave.
        let corner = try await MediaFixtures.pixel(png, at: 0, x: 0, y: 0)
        #expect(corner == (0, 0, 0))
    }
}

@Suite struct SpeechEngineTests {
    @Test func cuesFollowSentencesAndLimits() {
        typealias Word = SpeechEngine.Word
        var words: [Word] = []
        var time = 0.0
        for word in "Hello world. This is a rather long sentence that keeps going and going well past the length of a single subtitle line or two.".split(separator: " ") {
            words.append(Word(start: time, end: time + 0.3, text: " " + word))
            time += 0.35
        }
        let cues = SpeechEngine.cues(from: words)
        #expect(cues.first?.text == "Hello world.")
        #expect(cues.count >= 3)
        for cue in cues {
            #expect(cue.text.count <= 85)
            #expect(cue.end - cue.start <= 7.01)
            #expect(cue.text.split(separator: "\n").allSatisfy { $0.count <= 50 })
        }
        #expect(cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ").hasSuffix("line or two."))
        #expect(SpeechEngine.plainText(words).hasPrefix("Hello world. This is"))
    }

    @Test func pdfTextBecomesParagraphs() {
        let parts = SpeechEngine.paragraphs("First line of a para-\ngraph that wraps\nhere.\n\nSecond one.\n\n  \n", hardWrapped: true)
        #expect(parts == ["First line of a paragraph that wraps here.", "Second one."])
        let long = String(repeating: "This is a sentence. ", count: 120)
        #expect(SpeechEngine.paragraphs(long, hardWrapped: false).allSatisfy { $0.count <= 1000 })
    }

    @Test func readsTextAloud() async throws {
        let dir = try Fixtures.tempDirectory()
        let txt = dir.appendingPathComponent("note.txt")
        try "Hello world. Kumquat reads this short note aloud.\n\nThis is the second paragraph.".write(to: txt, atomically: true, encoding: .utf8)
        let m4a = try #require(try await run(.convert(.m4a), [txt]).outputs.first)
        #expect(m4a.lastPathComponent == "note.m4a")
        let duration = try await AVURLAsset(url: m4a).load(.duration).seconds
        #expect(duration > 0.5)
    }

    /// Needs the recogniser to run without asking: macOS 26 with the English model installed, or
    /// Speech Recognition already allowed for this process.
    static func canTranscribe() async -> Bool {
        if #available(macOS 26.0, *) {
            guard SpeechTranscriber.isAvailable else { return false }
            return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == "en-US" }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    @Test func transcribesSpeech() async throws {
        guard await Self.canTranscribe() else { return }
        let dir = try Fixtures.tempDirectory()
        let txt = dir.appendingPathComponent("speech.txt")
        try "Hello world. The weather is lovely today.".write(to: txt, atomically: true, encoding: .utf8)
        let m4a = try #require(try await run(.convert(.m4a), [txt]).outputs.first)
        let srt = dir.appendingPathComponent("speech.srt")
        try await SpeechEngine.transcribe(m4a, from: .m4a, to: .srt, locale: Locale(identifier: "en-US"), output: srt, progress: nil)
        let text = try String(contentsOf: srt, encoding: .utf8)
        #expect(text.contains("-->"))
        #expect(text.lowercased().contains("weather"))
        let plain = dir.appendingPathComponent("speech.txt.out")
        try await SpeechEngine.transcribe(m4a, from: .m4a, to: .txt, locale: Locale(identifier: "en-US"), output: plain, progress: nil)
        #expect(try String(contentsOf: plain, encoding: .utf8).lowercased().contains("hello"))
    }
}

/// Drives Keynote through Apple Events: the first run asks for Automation permission (and Keynote may
/// show its welcome window), which would stall an unattended run. Opt in with KUMQUAT_KEYNOTE_TESTS=1.
@Suite(.enabled(if: Engines.App.keynote.isInstalled && ProcessInfo.processInfo.environment["KUMQUAT_KEYNOTE_TESTS"] == "1"), .serialized)
struct SlidesExtrasTests {
    static func deck(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("deck.pptx")
        let pictures = try (0..<2).map { index -> PPTXWriter.Picture in
            let jpg = dir.appendingPathComponent("slide\(index).jpg")
            try Fixtures.write(Fixtures.makeTextImage("Slide \(index + 1)", size: CGSize(width: 1280, height: 720)), to: jpg, type: .jpeg)
            return PPTXWriter.Picture(jpeg: try Data(contentsOf: jpg), size: CGSize(width: 1280, height: 720))
        }
        try PPTXWriter.write(pictures, to: url)
        return url
    }

    @Test func keynoteExports() async throws {
        let dir = try Fixtures.tempDirectory()
        let pptx = try Self.deck(dir)
        let key = try #require(try await run(.convert(.key), [pptx]).outputs.first)
        #expect(key.lastPathComponent == "deck.key")
        #expect(FileManager.default.fileExists(atPath: key.path))

        let web = try #require(try await run(.convert(.html), [pptx]).outputs.first)
        #expect(web.lastPathComponent == "deck (web)")
        #expect(FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path))

        guard Engines.ffmpeg != nil else { return }
        let movie = try #require(try await run(.convert(.mp4), [pptx]).outputs.first)
        let info = try await MediaEngine.probe(movie)
        #expect(info.video != nil && info.duration > 1)
        let gif = try #require(try await run(.convert(.gif), [key]).outputs.first)
        #expect(try await MediaEngine.probe(gif).video == "gif")
    }
}
