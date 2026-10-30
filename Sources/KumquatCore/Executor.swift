import Foundation

public struct JobRequest: Sendable {
    public var operation: Operation
    public var inputs: [URL]
    public var parameters: [String: String]
    /// Folder that receives the result for a given input.
    public var destination: @Sendable (URL) -> URL

    public init(operation: Operation, inputs: [URL], parameters: [String: String] = [:],
                destination: @escaping @Sendable (URL) -> URL = { OutputNaming.defaultDirectory(for: $0) }) {
        self.operation = operation
        self.inputs = inputs
        self.parameters = parameters
        self.destination = destination
    }
}

public struct JobOutcome: Sendable {
    public struct Failure: Sendable {
        public let file: String
        public let message: String
    }

    public var outputs: [URL] = []
    public var failures: [Failure] = []
    public var skipped = 0
    /// Text the app should put on the clipboard (OCR, QR codes).
    public var clipboardText: String?
    /// Short results to show, not copy ("3 duplicates moved", a word count).
    public var notes: [String] = []
    public var cancelled = false
}

/// Runs a Convert or Tools operation over a selection: per-file work in parallel (bounded per
/// engine), multi-file tools (merge, zip) once over everything.
public enum Executor {
    public static func run(_ request: JobRequest, progress: @escaping @Sendable (Double) -> Void) async -> JobOutcome {
        var outcome = JobOutcome()
        let inputs = request.inputs.filter { Catalog.applies(request.operation, to: $0) }
        outcome.skipped = request.inputs.count - inputs.count
        guard !inputs.isEmpty else {
            outcome.failures.append(.init(file: "", message: String(localized: "Nothing here can be \(verb(request.operation)).")))
            return outcome
        }

        if case .tool(let tool) = request.operation, tool.combinesInputs || ([.archive, .lock].contains(tool) && inputs.count > 1) {
            if let problem = combiningProblem(tool, inputs: inputs) {
                outcome.failures.append(.init(file: inputs[0].lastPathComponent, message: problem))
                return outcome
            }
            do {
                let produced = try await perform(request, inputs: inputs, progress: progress)
                outcome.outputs = produced.urls
                outcome.clipboardText = produced.text
                outcome.notes = produced.note.map { [$0] } ?? []
            } catch is CancellationError {
                outcome.cancelled = true
            } catch {
                outcome.failures.append(.init(file: inputs[0].lastPathComponent, message: error.localizedDescription))
            }
            progress(1)
            return outcome
        }

        let tracker = ProgressTracker(count: inputs.count, report: progress)
        let limit = concurrency(for: inputs)
        await withTaskGroup(of: (URL, Result<Produced, Error>).self) { group in
            var next = 0
            func schedule() {
                guard next < inputs.count else { return }
                let index = next, url = inputs[index]
                next += 1
                group.addTask {
                    do {
                        let produced = try await perform(request, inputs: [url]) { tracker.update(index, $0) }
                        tracker.update(index, 1)
                        return (url, .success(produced))
                    } catch {
                        tracker.update(index, 1)
                        return (url, .failure(error))
                    }
                }
            }
            for _ in 0..<min(limit, inputs.count) { schedule() }
            var texts: [String] = []
            while let (url, result) = await group.next() {
                switch result {
                case .success(let produced):
                    outcome.outputs += produced.urls
                    if let text = produced.text { texts.append(inputs.count > 1 ? "\(url.lastPathComponent):\n\(text)" : text) }
                    if let note = produced.note { outcome.notes.append(inputs.count > 1 ? "\(url.lastPathComponent): \(note)" : note) }
                case .failure(let error as CancellationError):
                    _ = error
                    outcome.cancelled = true
                case .failure(let error):
                    outcome.failures.append(.init(file: url.lastPathComponent, message: error.localizedDescription))
                }
                schedule()
            }
            if !texts.isEmpty { outcome.clipboardText = texts.joined(separator: "\n\n") }
        }
        return outcome
    }

    /// Why a combining tool can't run on this selection, or `nil`.
    static func combiningProblem(_ tool: ToolKind, inputs: [URL]) -> String? {
        let categories = inputs.map { FileFormat.detect($0)?.category }
        switch tool {
        case .merge where inputs.count < 2:
            return String(localized: "Drop two or more files to merge.")
        case .addSubtitles where !categories.contains(.video) || !categories.contains(.subtitle):
            return String(localized: "Drop the video together with its subtitle file.")
        case .replaceAudio where !categories.contains(.video) || !categories.contains(.audio):
            return String(localized: "Drop the video together with the audio to use.")
        case .tags where !categories.contains(.audio):
            return String(localized: "Drop one or more audio files.")
        default:
            return nil
        }
    }

    static func verb(_ operation: Operation) -> String {
        switch operation {
        case .convert(let format): String(localized: "converted to \(format.displayName)")
        case .tool(let tool): String(localized: "processed with \(tool.title)")
        case .action(let action): String(localized: "used with \(action.title)")
        }
    }

    /// FFmpeg already uses every core per job; iWork apps handle one document at a time.
    static func concurrency(for inputs: [URL]) -> Int {
        switch Catalog.dominantCategory(of: inputs.map(FileFormat.detect)) {
        case .video?: 2
        case .audio?: 3
        case .slides?: 1
        default: workerCount
        }
    }

    struct Produced: Sendable {
        var urls: [URL]
        /// Goes on the clipboard.
        var text: String?
        /// Shown in the job's summary only.
        var note: String?

        init(urls: [URL], text: String? = nil, note: String? = nil) {
            self.urls = urls
            self.text = text
            self.note = note
        }
    }

    // MARK: - Dispatch

    static func perform(_ request: JobRequest, inputs: [URL], progress: @escaping MediaEngine.Progress) async throws -> Produced {
        let url = inputs[0]
        let directory = request.destination(url)
        let base = OutputNaming.baseName(url)
        let source = FileFormat.detect(url)

        switch request.operation {
        case .action:
            throw KumquatError.unsupported(String(localized: "Actions"))
        case .convert(let target):
            guard let source else { throw KumquatError.unsupported(url.lastPathComponent) }
            return Produced(urls: try await convert(url, from: source, to: target, directory: directory, base: base, progress: progress))
        case .tool(let tool):
            return try await runTool(tool, inputs: inputs, source: source, parameters: request.parameters, directory: directory, base: base, progress: progress)
        }
    }

    /// Reserves `output`, runs `work`, and removes the placeholder if the work fails.
    static func producing(_ directory: URL, _ base: String, _ ext: String, _ work: (URL) async throws -> Void) async throws -> [URL] {
        let output = try OutputNaming.reserve(in: directory, base: base, ext: ext)
        do {
            try await work(output)
            return [output]
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func convert(_ url: URL, from source: FileFormat, to target: FileFormat, directory: URL, base: String, progress: @escaping MediaEngine.Progress) async throws -> [URL] {
        switch source.category {
        case .image:
            return try await producing(directory, base, target.fileExtension) { try await ImageEngine.convert(url, from: source, to: target, output: $0) }
        case .video where [.srt, .vtt, .txt].contains(target), .audio where [.srt, .vtt, .txt].contains(target):
            return try await producing(directory, base, target.fileExtension) { try await SpeechEngine.transcribe(url, from: source, to: target, output: $0, progress: progress) }
        case .video, .audio:
            return try await producing(directory, base, target.fileExtension) { try await MediaEngine.convert(url, from: source, to: target, output: $0, progress: progress) }
        case .pdf where [.jpg, .png, .heic, .webp].contains(target):
            let pages = PDFEngine.pageCount(of: url)
            let folder = pages > 1 ? try OutputNaming.reserveDirectory(in: directory, base: base) : directory
            return try await PDFEngine.renderPages(of: url, format: target, into: folder, baseName: base)
        case .pdf where target == .m4a, .document where target == .m4a:
            return try await producing(directory, base, target.fileExtension) { try await SpeechEngine.speak(url, from: source, output: $0, progress: progress) }
        case .pdf:
            return try await producing(directory, base, target.fileExtension) { try await PDFEngine.convert(url, to: target, output: $0) }
        case .document:
            return try await producing(directory, base, target.fileExtension) { try await DocumentEngine.convert(url, from: source, to: target, output: $0) }
        case .slides where target == .jpg || target == .png:
            let folder = try OutputNaming.reserveDirectory(in: directory, base: base)
            do {
                return try await SlidesEngine.toImages(url, format: target, into: folder, baseName: base)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case .slides where target == .html:
            return [try await SlidesEngine.toHTML(url, into: directory, baseName: base)]
        case .slides:
            return try await producing(directory, base, target.fileExtension) { output in
                switch target {
                case .pptx: try await SlidesEngine.toPowerPoint(url, output: output)
                case .key: try await SlidesEngine.toKeynote(url, output: output)
                case .mp4: try await SlidesEngine.toMovie(url, output: output, progress: progress)
                case .gif: try await SlidesEngine.toGIF(url, output: output, progress: progress)
                default: try await SlidesEngine.toPDF(url, output: output)
                }
            }
        case .spreadsheet:
            return try await producing(directory, base, target.fileExtension) { try await SheetEngine.convert(url, from: source, to: target, output: $0) }
        case .subtitle:
            return try await producing(directory, base, target.fileExtension) { try SubtitleEngine.convert(url, from: source, to: target, output: $0) }
        case .archive:
            return try await producing(directory, base, target.fileExtension) { try await ArchiveEngine.convert(url, from: source, to: target, output: $0) }
        case .data:
            return try await producing(directory, base, target.fileExtension) { try await DataEngine.convert(url, from: source, to: target, output: $0) }
        case .font:
            return try await producing(directory, base, target.fileExtension) { try await FontEngine.convert(url, from: source, to: target, output: $0) }
        case .model:
            return try await producing(directory, base, target.fileExtension) { try await ModelEngine.convert(url, from: source, to: target, output: $0) }
        }
    }

    static func number(_ parameters: [String: String], _ key: String, default fallback: Double) throws -> Double {
        guard let raw = parameters[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: "")) else {
            throw KumquatError.noResult(String(localized: "“\(raw)” isn't a number."))
        }
        return value
    }

    /// Optional number: empty means "not set".
    static func optionalNumber(_ parameters: [String: String], _ key: String) throws -> Double? {
        guard let raw = parameters[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return try number(parameters, key, default: 0)
    }

    /// Normalised "x:y:w:h" from the crop preview, or `nil` when none was drawn.
    static func region(_ parameters: [String: String]) -> CGRect? {
        let parts = (parameters["region"] ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// "16:9" → 16/9.
    static func aspect(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    enum CropArea {
        case drawn(CGRect)
        case shape(Double)
        case auto
    }

    /// What Crop keeps: the area drawn on the preview, else the largest centred area of the picked shape, else automatic.
    static func cropArea(_ parameters: [String: String]) throws -> CropArea {
        if let region = region(parameters) { return .drawn(region) }
        let shape = parameters["aspect"] ?? "auto"
        if let aspect = aspect(shape) { return .shape(aspect) }
        if shape == "free" { throw KumquatError.noResult(String(localized: "Draw the area to keep.")) }
        return .auto
    }

    static func runTool(_ tool: ToolKind, inputs: [URL], source: FileFormat?, parameters: [String: String], directory: URL, base: String,
                        progress: @escaping MediaEngine.Progress) async throws -> Produced {
        let url = inputs[0]
        let category = source?.category

        // Tools available for any file or folder.
        if tool == .archive {
            let name = inputs.count == 1 ? url.lastPathComponent : "Archive"
            return Produced(urls: try await producing(directory, name, "zip") { output in
                try FileManager.default.removeItem(at: output)
                try await ArchiveEngine.archive(inputs, output: output)
            })
        }
        if tool == .lock {
            let password = parameters["password"] ?? ""
            guard !password.isEmpty else { throw KumquatError.noResult(String(localized: "Enter a password.")) }
            return Produced(urls: try await producing(directory, inputs.count == 1 ? base : "Locked", "dmg") { output in
                try FileManager.default.removeItem(at: output)
                try await FolderEngine.lock(inputs, password: password, output: output)
            })
        }
        if source == nil, Catalog.folderTools.contains(tool) {
            return try await runFolderTool(tool, folder: url, parameters: parameters)
        }
        guard let source, let category else { throw KumquatError.unsupported(url.lastPathComponent) }
        let ext = category == .video || category == .audio ? mediaExt(source) : source.fileExtension

        switch (tool, category) {
        // Images
        case (.compress, .image):
            let format = ImageEngine.toolOutputFormat(for: source, tool: .compress)
            let quality = try number(parameters, "quality", default: 60) / 100
            return Produced(urls: try await producing(directory, "\(base) (compressed)", format.fileExtension) {
                try await ImageEngine.compress(url, from: source, quality: quality, output: $0)
            })
        case (.crop, .image):
            let format = ImageEngine.toolOutputFormat(for: source, tool: .crop)
            let area = try cropArea(parameters)
            return Produced(urls: try await producing(directory, "\(base) (cropped)", format.fileExtension) { output in
                switch area {
                case .drawn(let region): try await ImageEngine.crop(url, from: source, region: region, output: output)
                case .shape(let aspect): try await ImageEngine.crop(url, from: source, aspect: aspect, output: output)
                case .auto: try await ImageEngine.autoCrop(url, from: source, output: output)
                }
            })
        case (.resize, .image):
            let percent = try number(parameters, "percent", default: 50)
            let format = ImageEngine.toolOutputFormat(for: source, tool: .resize)
            return Produced(urls: try await producing(directory, "\(base) (\(Int(percent))%)", format.fileExtension) {
                try await ImageEngine.resize(url, from: source, percent: percent, output: $0)
            })
        case (.rotate, .image):
            let format = ImageEngine.toolOutputFormat(for: source, tool: .rotate)
            let degrees = Int(try number(parameters, "angle", default: 90))
            let tilt = try number(parameters, "tilt", default: 0)
            return Produced(urls: try await producing(directory, "\(base) (rotated)", format.fileExtension) {
                try await ImageEngine.rotate(url, from: source, degrees: degrees, tilt: tilt, output: $0)
            })
        case (.flip, .image):
            let format = ImageEngine.toolOutputFormat(for: source, tool: .flip)
            let vertical = parameters["axis"] == "vertical"
            return Produced(urls: try await producing(directory, "\(base) (flipped)", format.fileExtension) {
                try await ImageEngine.flip(url, from: source, vertical: vertical, output: $0)
            })
        case (.removeBackground, .image):
            return Produced(urls: try await producing(directory, "\(base) (no background)", "png") { try await ImageEngine.removeBackground(url, output: $0) })
        case (.stripMetadata, .image):
            let format = ImageEngine.toolOutputFormat(for: source, tool: .stripMetadata)
            if parameters["what"] == "location" {
                return Produced(urls: try await producing(directory, "\(base) (no location)", format.fileExtension) { try await ImageEngine.stripLocation(url, from: source, output: $0) })
            }
            return Produced(urls: try await producing(directory, "\(base) (clean)", format.fileExtension) { try await ImageEngine.stripMetadata(url, from: source, output: $0) })
        case (.recognizeText, .image):
            let text = try await TextExtractor.imageText(url)
            guard !text.isEmpty else { throw KumquatError.noResult(String(localized: "No text found in “\(url.lastPathComponent)”.")) }
            return Produced(urls: [], text: text)
        case (.readQRCode, .image):
            let codes = try await TextExtractor.imageBarcodes(url)
            guard !codes.isEmpty else { throw KumquatError.noResult(String(localized: "No QR code or barcode in “\(url.lastPathComponent)”.")) }
            return Produced(urls: [], text: codes.map(\.payload).joined(separator: "\n"))

        // Video & audio
        case (.trim, _):
            return Produced(urls: try await producing(directory, "\(base) (trimmed)", ext) {
                try await MediaEngine.trim(url, from: source, start: parameters["start"] ?? "0", end: parameters["end"] ?? "", output: $0, progress: progress)
            })
        case (.crop, .video):
            let area = try cropArea(parameters)
            return Produced(urls: try await producing(directory, "\(base) (cropped)", ext) { output in
                switch area {
                case .drawn(let region): try await MediaEngine.crop(url, from: source, region: region, output: output, progress: progress)
                case .shape(let aspect): try await MediaEngine.crop(url, from: source, aspect: aspect, output: output, progress: progress)
                case .auto: try await MediaEngine.autoCrop(url, from: source, output: output, progress: progress)
                }
            })
        case (.rotate, .video):
            let degrees = Int(try number(parameters, "angle", default: 90))
            return Produced(urls: try await producing(directory, "\(base) (rotated)", ext) {
                try await MediaEngine.rotate(url, from: source, degrees: degrees, output: $0, progress: progress)
            })
        case (.compress, .video), (.compress, .audio):
            let preset = MediaEngine.SharePreset(rawValue: parameters["preset"] ?? "")
            let format = preset == nil ? MediaEngine.compressedFormat(source) : .mp4
            let quality = MediaEngine.Quality(rawValue: parameters["quality"] ?? "") ?? .balanced
            let maxMegabytes = try optionalNumber(parameters, "maxMB") ?? preset?.maxMegabytes
            let bitrate = Int(parameters["bitrate"] ?? "")
            if let maxMegabytes, maxMegabytes <= 0 { throw KumquatError.noResult(String(localized: "The size limit must be above 0 MB.")) }
            let suffix = preset.map { String(localized: "for \($0.title)") } ?? String(localized: "compressed")
            return Produced(urls: try await producing(directory, "\(base) (\(suffix))", format.fileExtension) {
                try await MediaEngine.compress(url, from: source, quality: quality, maxMegabytes: maxMegabytes, audioBitrate: bitrate,
                                               maxHeight: preset?.maxHeight, output: $0, progress: progress)
            })
        case (.split, .video), (.split, .audio):
            let parts = Int(try number(parameters, "parts", default: 2))
            return Produced(urls: try await MediaEngine.split(url, from: source, parts: parts, into: directory, baseName: base, progress: progress))
        case (.merge, .video), (.merge, .audio):
            return Produced(urls: try await producing(directory, "Merged", ext) { try await MediaEngine.merge(inputs, as: source, output: $0, progress: progress) })
        case (.mute, .video):
            return Produced(urls: try await producing(directory, "\(base) (muted)", ext) { try await MediaEngine.mute(url, output: $0, progress: progress) })
        case (.extractAudio, .video):
            let format = try await MediaEngine.extractedAudioFormat(url)
            return Produced(urls: try await producing(directory, base, format.fileExtension) { try await MediaEngine.extractAudio(url, output: $0, progress: progress) })
        case (.changeSpeed, .audio):
            let factor = try number(parameters, "factor", default: 1.25)
            let semitones = try number(parameters, "semitones", default: 0)
            return Produced(urls: try await producing(directory, "\(base) (\(factor.formatted())×)", ext) {
                try await MediaEngine.changeSpeed(url, from: source, factor: factor, semitones: semitones, output: $0, progress: progress)
            })
        case (.changeSpeed, _):
            let factor = try number(parameters, "factor", default: 2)
            return Produced(urls: try await producing(directory, "\(base) (\(factor.formatted())×)", ext) {
                try await MediaEngine.changeSpeed(url, from: source, factor: factor, output: $0, progress: progress)
            })
        case (.resize, .video):
            let height = Int(try number(parameters, "height", default: 720))
            return Produced(urls: try await producing(directory, "\(base) (\(height)p)", ext) {
                try await MediaEngine.resize(url, from: source, height: height, output: $0, progress: progress)
            })
        case (.extractFrames, _):
            let fps = try number(parameters, "fps", default: 1)
            return Produced(urls: try await MediaEngine.extractFrames(url, fps: fps, into: directory, baseName: base, progress: progress))
        case (.makeGIF, _):
            let start = MediaEngine.parseTime(parameters["start"] ?? "") ?? 0
            let end = MediaEngine.parseTime(parameters["end"] ?? "")
            let fps = Int(try number(parameters, "fps", default: 15))
            let width = Int(try number(parameters, "width", default: 480))
            return Produced(urls: try await producing(directory, base, "gif") {
                try await MediaEngine.makeGIF(url, start: start, end: end, fps: fps, width: width, output: $0, progress: progress)
            })
        case (.normalizeVolume, _):
            let lufs = try number(parameters, "lufs", default: -16)
            return Produced(urls: try await producing(directory, "\(base) (normalized)", ext) {
                try await MediaEngine.normalize(url, from: source, lufs: lufs, output: $0, progress: progress)
            })
        case (.adjustVolume, _):
            let db = try number(parameters, "db", default: 6)
            return Produced(urls: try await producing(directory, "\(base) (\(db >= 0 ? "+" : "")\(db.formatted()) dB)", ext) {
                try await MediaEngine.adjustVolume(url, from: source, decibels: db, output: $0, progress: progress)
            })

        // PDF
        case (.merge, .pdf):
            return Produced(urls: try await producing(directory, "Merged", "pdf") { output in try await runBlocking { try PDFEngine.merge(inputs, output: output) } })
        case (.split, .pdf):
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) pages")
            do {
                return Produced(urls: try await runBlocking { try PDFEngine.split(url, into: folder, baseName: base) })
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case (.compress, .pdf):
            return Produced(urls: try await producing(directory, "\(base) (compressed)", "pdf") { output in try await runBlocking { try PDFEngine.compress(url, output: output) } })
        case (.crop, .pdf):
            // The PDF shapes are Auto and Free only, so a remembered shape without an area means automatic.
            let region: CGRect? = if case .drawn(let region) = try cropArea(parameters) { region } else { nil }
            return Produced(urls: try await producing(directory, "\(base) (cropped)", "pdf") { output in
                try await runBlocking {
                    if let region { try PDFEngine.crop(url, region: region, output: output) } else { try PDFEngine.autoCrop(url, output: output) }
                }
            })
        case (.extractPages, .pdf):
            let range = parameters["pages"] ?? ""
            guard let pages = PDFEngine.parsePageRange(range, pageCount: PDFEngine.pageCount(of: url)) else {
                throw KumquatError.noResult(String(localized: "“\(range)” isn't a valid page range for this \(PDFEngine.pageCount(of: url))-page PDF."))
            }
            return Produced(urls: try await producing(directory, "\(base) (pages \(range))", "pdf") { output in
                try await runBlocking { try PDFEngine.extractPages(url, pages: pages, output: output) }
            })
        case (.rotate, .pdf):
            let degrees = Int(try number(parameters, "angle", default: 90))
            return Produced(urls: try await producing(directory, "\(base) (rotated)", "pdf") { output in
                try await runBlocking { try PDFEngine.rotate(url, degrees: degrees, output: output) }
            })
        case (.password, .pdf):
            let password = parameters["password"] ?? ""
            var unlocked = false
            let urls = try await producing(directory, "\(base) (protected)", "pdf") { output in
                unlocked = try await runBlocking { try PDFEngine.password(url, password: password, output: output) }
            }
            guard unlocked, let output = urls.first else { return Produced(urls: urls) }
            let renamed = OutputNaming.unique(in: directory, name: "\(base) (unlocked).pdf")
            try FileManager.default.moveItem(at: output, to: renamed)
            return Produced(urls: [renamed])
        case (.watermark, .pdf):
            let text = parameters["text"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !text.isEmpty else { throw KumquatError.noResult(String(localized: "Enter the watermark text.")) }
            let opacity = try number(parameters, "opacity", default: 28) / 100
            let diagonal = parameters["angle"] != "horizontal"
            return Produced(urls: try await producing(directory, "\(base) (watermarked)", "pdf") { output in
                try await runBlocking { try PDFEngine.watermark(url, text: text, opacity: opacity, diagonal: diagonal, output: output) }
            })
        case (.recognizeText, .pdf):
            return Produced(urls: try await producing(directory, "\(base) (searchable)", "pdf") { try await PDFEngine.makeSearchable(url, output: $0) })

        // Documents, sheets, subtitles
        case (.merge, .document):
            return Produced(urls: try await producing(directory, "Merged", "docx") { try await DocumentEngine.merge(inputs, output: $0) })
        case (.merge, .spreadsheet):
            return Produced(urls: try await producing(directory, "Merged", "xlsx") { try await SheetEngine.merge(inputs, output: $0) })
        case (.split, .spreadsheet):
            if parameters["by"] == "column" {
                return Produced(urls: try await SheetEngine.splitByColumn(url, from: source, column: parameters["column"] ?? "", into: directory))
            }
            return Produced(urls: try await SheetEngine.split(url, from: source, into: directory))
        case (.shiftTiming, .subtitle):
            let seconds = try number(parameters, "seconds", default: 1)
            return Produced(urls: try await producing(directory, "\(base) (shifted)", ext) { output in
                try SubtitleEngine.shift(url, from: source, seconds: seconds, output: output)
            })
        case (.merge, .subtitle):
            return Produced(urls: try await producing(directory, "Merged", ext) { output in try SubtitleEngine.merge(inputs, as: source, output: output) })

        // Archives
        case (.extract, .archive):
            return Produced(urls: [try await ArchiveEngine.extract(url, from: source, into: directory, baseName: base)])
        case (.encryptArchive, .archive):
            return Produced(urls: try await producing(directory, "\(base) (encrypted)", "zip") { output in
                try await ArchiveEngine.encrypt(url, password: parameters["password"] ?? "", output: output)
            })

        default:
            return try await runNewTool(tool, inputs: inputs, source: source, category: category, parameters: parameters,
                                        directory: directory, base: base, progress: progress)
        }
    }
}

/// Averages per-file progress into one 0…1 value, reporting at most every 1%.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private var lastReported = -1.0
    private let report: @Sendable (Double) -> Void

    init(count: Int, report: @escaping @Sendable (Double) -> Void) {
        fractions = Array(repeating: 0, count: count)
        self.report = report
    }

    func update(_ index: Int, _ fraction: Double) {
        let overall: Double? = lock.withLock {
            fractions[index] = max(fractions[index], fraction)
            let value = fractions.reduce(0, +) / Double(fractions.count)
            guard value - lastReported >= 0.01 || value >= 1 else { return nil }
            lastReported = value
            return value
        }
        if let overall { report(overall) }
    }
}
