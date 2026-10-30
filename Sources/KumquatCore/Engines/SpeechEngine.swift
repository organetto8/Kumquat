import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// On-device speech: transcription (audio/video → SRT, VTT, TXT) and reading text aloud (→ M4A).
///
/// Transcription uses SpeechAnalyzer + SpeechTranscriber on macOS 26 (no permission prompt; the
/// language model is downloaded on first use) and on-device SFSpeechRecognizer on macOS 14–15,
/// which needs the user's Speech Recognition permission (NSSpeechRecognitionUsageDescription).
public enum SpeechEngine {
    /// Recognises speech in the file's language (the system language when unsure) and writes timed cues
    /// (SRT/VTT) or plain text (TXT). Throws `noResult` when nothing was recognised.
    public static func transcribe(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, progress: MediaEngine.Progress?) async throws {
        try await transcribe(input, from: source, to: target, locale: nil, output: output, progress: progress)
    }

    /// `locale`: language to listen for; `nil` picks the file's tag, the system language or English.
    static func transcribe(_ input: URL, from source: FileFormat, to target: FileFormat, locale: Locale?, output: URL, progress: MediaEngine.Progress?) async throws {
        guard [.srt, .vtt, .txt].contains(target) else { throw KumquatError.unsupported(String(localized: "Transcription → \(target.displayName)")) }
        let wav = ImageEngine.temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let audio = try await prepareAudio(input, source: source, output: wav, progress: MediaEngine.scaled(progress, 0, 0.1))
        let words = try await recognize(wav, locale: locale, languageHint: audio.language, duration: audio.duration,
                                        progress: MediaEngine.scaled(progress, 0.1, 1))
        guard words.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw KumquatError.noResult(String(localized: "No speech recognised in “\(input.lastPathComponent)”."))
        }
        let text = target == .txt ? plainText(words) : try SubtitleEngine.render(cues(from: words), as: target)
        try text.write(to: output, atomically: true, encoding: .utf8)
        progress?(1)
    }

    /// A recognised word (or punctuation run) with its time in the file.
    struct Word: Sendable, Equatable {
        var start: Double
        var end: Double
        /// As recognised, leading space included, so joining keeps each language's spacing.
        var text: String
    }

    // MARK: - Audio

    /// 16 kHz mono WAV of the first audio track: AVFoundation for the formats it reads, FFmpeg for the rest.
    static func prepareAudio(_ input: URL, source: FileFormat, output: URL, progress: MediaEngine.Progress?) async throws -> (duration: Double, language: String?) {
        if Engines.nativeMedia.contains(source) {
            do {
                return try await extractNatively(input, to: output)
            } catch is CancellationError {
                throw CancellationError()
            } catch where Engines.ffmpeg != nil {
                // Some MP4/MOV variants AVFoundation can't read: FFmpeg below.
            }
        }
        let info = try await MediaEngine.probe(input)
        guard info.audio != nil else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track.")) }
        try await MediaEngine.ffmpeg(["-i", input.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path],
                                     duration: info.duration, progress: progress)
        return (info.duration, info.audioLanguage)
    }

    static func extractNatively(_ input: URL, to output: URL) async throws -> (duration: Double, language: String?) {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” has no audio track."))
        }
        let duration = try await asset.load(.duration).seconds
        let language = try? await track.load(.languageCode)
        // Loaded above and only read from here on.
        let source = Unchecked(value: (asset, track))
        try await runCancellable { flag in
            let reader = try AVAssetReader(asset: source.value.0)
            let trackOutput = AVAssetReaderTrackOutput(track: source.value.1, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(trackOutput)
            guard reader.startReading(), let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
                throw KumquatError.cannotDecode(input.lastPathComponent)
            }
            let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            while let sample = trackOutput.copyNextSampleBuffer() {
                try flag.check()
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let samples = buffer.int16ChannelData?[0] else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2, destination: samples) == kCMBlockBufferNoErr else {
                    throw KumquatError.cannotDecode(input.lastPathComponent)
                }
                try file.write(from: buffer)
            }
            if reader.status == .failed { throw reader.error ?? KumquatError.cannotDecode(input.lastPathComponent) }
        }
        return (duration, language)
    }

    struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    // MARK: - Recognition

    static func recognize(_ wav: URL, locale: Locale?, languageHint: String?, duration: Double, progress: MediaEngine.Progress?) async throws -> [Word] {
        let candidates = [locale, languageHint.map { Locale(identifier: Locale.LanguageCode($0).identifier(.alpha2) ?? $0) }, Locale.current, Locale(identifier: "en-US")]
            .compactMap { $0 }
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            for candidate in candidates {
                if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                    return try await analyze(wav, locale: supported, duration: duration, progress: progress)
                }
            }
            throw KumquatError.noResult(String(localized: "Speech recognition isn't available for this language on this Mac."))
        }
        guard let recognizer = candidates.lazy.compactMap({ SFSpeechRecognizer(locale: $0) }).first else {
            throw KumquatError.noResult(String(localized: "Speech recognition isn't available for this language on this Mac."))
        }
        return try await legacyRecognize(wav, with: recognizer, duration: duration, progress: progress)
    }

    @available(macOS 26.0, *)
    static func analyze(_ wav: URL, locale: Locale, duration: Double, progress: MediaEngine.Progress?) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        var recognition = progress
        // The language model is a system download, shared by every app, fetched once.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let download = MediaEngine.scaled(progress, 0, 0.5)
            let poller = Task {
                while !Task.isCancelled {
                    download?(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
            recognition = MediaEngine.scaled(progress, 0.5, 1)
        }
        let report = recognition
        let file = try AVAudioFile(forReading: wav)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    if let range = run.audioTimeRange {
                        words.append(Word(start: range.start.seconds, end: range.end.seconds, text: text))
                    } else if !words.isEmpty {
                        words[words.count - 1].text += text
                    }
                }
                if duration > 0 { report?(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        try Task.checkCancellation()
        return words
    }

    /// macOS 14–15: SFSpeechRecognizer, on-device only (nothing leaves the Mac).
    static func legacyRecognize(_ wav: URL, with recognizer: SFSpeechRecognizer, duration: Double, progress: MediaEngine.Progress?) async throws -> [Word] {
        try await authorize()
        guard recognizer.supportsOnDeviceRecognition else {
            throw KumquatError.noResult(String(localized: "On-device speech recognition for this language isn't available on this Mac."))
        }
        let request = SFSpeechURLRecognitionRequest(url: wav)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        recognizer.queue = OperationQueue()
        let session = RecognitionSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        session.merge(result.bestTranscription.segments.map {
                            Word(start: $0.timestamp, end: $0.timestamp + $0.duration, text: " " + $0.substring)
                        })
                        if duration > 0, let last = session.words.last { progress?(min(1, last.end / duration)) }
                        if result.isFinal { session.finish(.success(session.words)) }
                    }
                    if let error {
                        // "No speech detected" after real words still counts as a result.
                        session.finish(session.words.isEmpty ? .failure(error) : .success(session.words))
                    }
                }
                session.task = task
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// Speech Recognition permission, asked for only when the app can explain why (Info.plist).
    static func authorize() async throws {
        let denied = KumquatError.noResult(String(localized: "Allow Kumquat in System Settings › Privacy & Security › Speech Recognition."))
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            // Asking without a usage description terminates the process.
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { throw denied }
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw denied }
        default:
            throw denied
        }
    }

    /// Collects SFSpeechRecognizer callbacks (on its own queue) and resumes the caller once.
    final class RecognitionSession: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[Word], Error>?
        private var collected: [Word] = []
        var task: SFSpeechRecognitionTask? {
            get { lock.withLock { storedTask } }
            set { lock.withLock { storedTask = newValue } }
        }
        private var storedTask: SFSpeechRecognitionTask?

        var words: [Word] { lock.withLock { collected } }

        func start(_ continuation: CheckedContinuation<[Word], Error>) { lock.withLock { self.continuation = continuation } }

        /// Results may repeat earlier segments (cumulative) or bring only new ones: keep each time once.
        func merge(_ segments: [Word]) {
            guard let first = segments.first else { return }
            lock.withLock {
                collected.removeAll { $0.start >= first.start }
                collected += segments
            }
        }

        func finish(_ result: Result<[Word], Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<[Word], Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }

        func cancel() {
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }

    // MARK: - Cues

    /// Subtitle cues of at most ~7 s and 84 characters (two lines of 42), ending at sentence ends
    /// and long pauses.
    static func cues(from words: [Word], maxDuration: Double = 7, maxCharacters: Int = 84) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = joined(current)
            if !text.isEmpty { cues.append(Cue(start: first.start, end: last.end, text: lines(text))) }
            current.removeAll()
        }
        for word in words {
            if let first = current.first, let last = current.last {
                let longer = joined(current + [word])
                if longer.count > maxCharacters || word.end - first.start > maxDuration || word.start - last.end > 1 || endsSentence(last.text) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        // Very short cues stay up a little longer, never into the next one.
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : .infinity
            cues[index].end = max(cues[index].end, min(cues[index].start + 1, next))
        }
        return cues
    }

    static func joined(_ words: [Word]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]"))
        return trimmed.last.map { ".?!…。？！".contains($0) } ?? false
    }

    /// Breaks text longer than one subtitle line at the space nearest the middle.
    static func lines(_ text: String) -> String {
        guard text.count > 42 else { return text }
        let middle = text.count / 2
        let spaces = text.indices.filter { text[$0] == " " }
        guard let split = spaces.min(by: { abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle) }) else {
            return text
        }
        return text[..<split] + "\n" + text[text.index(after: split)...]
    }

    /// Running text, a new paragraph after a sentence followed by a long pause.
    static func plainText(_ words: [Word]) -> String {
        var paragraphs: [[Word]] = [[]]
        for (index, word) in words.enumerated() {
            paragraphs[paragraphs.count - 1].append(word)
            if index + 1 < words.count, endsSentence(word.text), words[index + 1].start - word.end > 1.5 { paragraphs.append([]) }
        }
        return paragraphs.map(joined).filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Reading aloud

    /// Reads a document or PDF aloud with a system voice for its language and writes AAC (.m4a).
    public static func speak(_ input: URL, from source: FileFormat, output: URL, progress: MediaEngine.Progress?) async throws {
        let raw: String
        if source == .pdf {
            // The text layer, or OCR for scanned pages.
            raw = try await TextExtractor.pdfPages(input).joined(separator: "\n\n")
        } else {
            raw = try await DocumentEngine.attributed(input, format: source).value.string
        }
        let parts = paragraphs(raw, hardWrapped: source == .pdf)
        guard !parts.isEmpty else { throw KumquatError.noResult(String(localized: "No text to read in “\(input.lastPathComponent)”.")) }
        let voice = voice(for: parts.prefix(20).joined(separator: "\n"))
        try? FileManager.default.removeItem(at: output)
        try await synthesize(parts, voice: voice, output: output, progress: progress)
    }

    /// Paragraphs of at most ~1000 characters (longer ones split between sentences). PDF text is
    /// hard-wrapped: single line breaks inside a paragraph become spaces.
    static func paragraphs(_ text: String, hardWrapped: Bool) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n").replacingOccurrences(of: "\u{0C}", with: "\n\n")
        let blocks: [String] = hardWrapped
            ? normalized.replacingOccurrences(of: "\n[ \t]*\n", with: "\u{1E}", options: .regularExpression).components(separatedBy: "\u{1E}").map {
                $0.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ")
            }
            : normalized.components(separatedBy: "\n")
        var result: [String] = []
        for block in blocks {
            let clean = block.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            guard clean.count > 1000 else {
                result.append(clean)
                continue
            }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = clean
            var chunk = ""
            tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { range, _ in
                let sentence = String(clean[range])
                if chunk.count + sentence.count > 1000, !chunk.isEmpty {
                    result.append(chunk.trimmingCharacters(in: .whitespaces))
                    chunk = ""
                }
                chunk += sentence
                return true
            }
            if !chunk.trimmingCharacters(in: .whitespaces).isEmpty { result.append(chunk.trimmingCharacters(in: .whitespaces)) }
        }
        return result
    }

    /// The best installed voice for the text's language: higher quality first (premium, enhanced),
    /// then the one chosen in System Settings, then the user's region; novelty voices never.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        var language = recognizer.dominantLanguage?.rawValue ?? Locale.current.language.languageCode?.identifier ?? "en"
        if language == "und" { language = Locale.current.language.languageCode?.identifier ?? "en" }
        // NaturalLanguage names scripts, voices name regions.
        let code = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][language] ?? language
        let prefix = String(code.split(separator: "-").first ?? "en")
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            (voice.language == code || voice.language.hasPrefix(prefix + "-") || voice.language == prefix)
                && !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        let preferred = AVSpeechSynthesisVoice(language: code)?.identifier
        let region = Locale.current.region?.identifier
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, Int, Int, Int) {
            (voice.quality.rawValue, voice.identifier == preferred ? 1 : 0, voice.language == code ? 1 : 0,
             region.map { voice.language.hasSuffix("-\($0)") } == true ? 1 : 0, voice.identifier.contains("eloquence") ? 0 : 1)
        }
        return voices.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: code)
    }

    static func synthesize(_ paragraphs: [String], voice: AVSpeechSynthesisVoice?, output: URL, progress: MediaEngine.Progress?) async throws {
        let writer = SpeechWriter(output: output)
        let synthesizer = SynthesizerBox()
        let total = Double(paragraphs.reduce(0) { $0 + $1.count })
        var done = 0.0
        for paragraph in paragraphs {
            try Task.checkCancellation()
            let utterance = AVSpeechUtterance(string: paragraph)
            utterance.voice = voice
            try await withTaskCancellationHandler {
                try await synthesizer.write(utterance, into: writer)
            } onCancel: {
                synthesizer.stop()
            }
            // A breath between paragraphs.
            try writer.silence(seconds: 0.35)
            done += Double(paragraph.count)
            progress?(done / max(total, 1))
        }
        let frames = try writer.close()
        guard frames > 0 else { throw KumquatError.noResult(String(localized: "The system voice produced no sound.")) }
    }

    /// AVSpeechSynthesizer delivers PCM buffers on its own queue: they go straight into the AAC file.
    final class SpeechWriter: @unchecked Sendable {
        private let lock = NSLock()
        private let output: URL
        private var file: AVAudioFile?
        private var format: AVAudioFormat?
        private(set) var frames: AVAudioFramePosition = 0

        init(output: URL) { self.output = output }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            try lock.withLock {
                if file == nil {
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: buffer.format.sampleRate,
                                                   AVNumberOfChannelsKey: buffer.format.channelCount, AVEncoderBitRateKey: buffer.format.channelCount > 1 ? 128_000 : 64_000]
                    file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                    format = buffer.format
                }
                try file?.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
        }

        func silence(seconds: Double) throws {
            guard let format = lock.withLock({ format }),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * seconds)) else { return }
            buffer.frameLength = buffer.frameCapacity
            // New buffers are zero-filled: silence.
            try write(buffer)
        }

        /// Finishes the file (the AAC encoder flushes when the file is released).
        func close() throws -> AVAudioFramePosition {
            lock.withLock {
                if #available(macOS 15.0, *) { file?.close() }
                file = nil
                return frames
            }
        }
    }

    final class SynthesizerBox: @unchecked Sendable {
        private let synthesizer = AVSpeechSynthesizer()
        private let lock = NSLock()
        private var pending: CheckedContinuation<Void, Error>?

        func write(_ utterance: AVSpeechUtterance, into writer: SpeechWriter) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { pending = continuation }
                synthesizer.write(utterance) { [self] buffer in
                    // An empty buffer marks the end of the utterance.
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        finish(.success(()))
                        return
                    }
                    do {
                        try writer.write(pcm)
                    } catch {
                        synthesizer.stopSpeaking(at: .immediate)
                        finish(.failure(error))
                    }
                }
            }
        }

        func stop() {
            synthesizer.stopSpeaking(at: .immediate)
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<Void, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { pending = nil }
                return pending
            }
            continuation?.resume(with: result)
        }
    }
}
