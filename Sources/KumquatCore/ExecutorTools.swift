import Foundation

/// Dispatch for the tools added after the first 26: one case per (tool, category).
extension Executor {
    static func runNewTool(_ tool: ToolKind, inputs: [URL], source: FileFormat, category: FormatCategory, parameters: [String: String],
                           directory: URL, base: String, progress: @escaping MediaEngine.Progress) async throws -> Produced {
        let url = inputs[0]
        let ext = source.fileExtension
        let image = ImageEngine.toolOutputFormat(for: source, tool: tool).fileExtension
        let sheet = SheetEngine.toolOutputFormat(for: source).fileExtension

        switch (tool, category) {
        // Images
        case (.merge, .image):
            let layout = parameters["layout"] ?? "pdf"
            let images = inputs.filter { FileFormat.detect($0)?.category == .image }
            let outputExt = switch layout { case "gif": "gif"; case "pdf": "pdf"; default: "png" }
            return Produced(urls: try await producing(directory, "Merged", outputExt) { try await ImageEngine.merge(images, layout: layout, output: $0) })
        case (.scanDocument, .image):
            return Produced(urls: try await producing(directory, "\(base) (scanned)", image) {
                try await ImageEngine.scanDocument(url, from: source, look: parameters["look"] ?? "color", output: $0)
            })
        case (.blurFaces, .image):
            let area = parameters["mode"] == "area" ? region(parameters) : nil
            if parameters["mode"] == "area", area == nil { throw KumquatError.noResult(String(localized: "Draw the area to blur.")) }
            return Produced(urls: try await producing(directory, "\(base) (blurred)", image) {
                try await ImageEngine.blurFaces(url, from: source, region: area, style: parameters["style"] ?? "pixelate", output: $0)
            })
        case (.frame, .image):
            let padding = try number(parameters, "padding", default: 8)
            let radius = try number(parameters, "radius", default: 2)
            return Produced(urls: try await producing(directory, "\(base) (framed)", "png") {
                try await ImageEngine.frame(url, background: parameters["background"] ?? "sunset", padding: padding / 100, radius: radius / 100,
                                            shadow: parameters["shadow"] != "no", output: $0)
            })
        case (.enhance, .image):
            return Produced(urls: try await producing(directory, "\(base) (enhanced)", image) { try await ImageEngine.enhance(url, from: source, output: $0) })
        case (.filter, .image):
            let style = parameters["style"] ?? "noir"
            return Produced(urls: try await producing(directory, "\(base) (\(style))", image) { try await ImageEngine.filter(url, from: source, style: style, output: $0) })
        case (.palette, .image):
            let count = Int(try number(parameters, "count", default: 5))
            var colors: [String] = []
            let urls = try await producing(directory, "\(base) (palette)", "png") { colors = try await ImageEngine.palette(url, count: count, output: $0) }
            return Produced(urls: urls, text: colors.joined(separator: " "))
        case (.iconSet, .image):
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) icons")
            do {
                return Produced(urls: try await ImageEngine.iconSet(url, kind: parameters["kind"] ?? "all", into: folder))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case (.autoTag, .image):
            let tags = try await ImageEngine.autoTag(url)
            return Produced(urls: [], note: tags.joined(separator: ", "))
        case (.watermark, .image):
            let (text, opacity, diagonal) = try watermark(parameters)
            return Produced(urls: try await producing(directory, "\(base) (watermarked)", image) {
                try await ImageEngine.watermark(url, from: source, text: text, opacity: opacity, diagonal: diagonal, output: $0)
            })

        // Video
        case (.vertical, .video):
            return Produced(urls: try await producing(directory, "\(base) (vertical)", ext) {
                try await MediaEngine.vertical(url, from: source, background: parameters["background"] ?? "blur", output: $0, progress: progress)
            })
        case (.addSubtitles, .video):
            let subtitles = inputs.filter { FileFormat.detect($0)?.category == .subtitle }
            let burn = parameters["mode"] != "track"
            var outputs: [URL] = []
            for video in inputs where FileFormat.detect(video)?.category == .video {
                let videoFormat = FileFormat.detect(video) ?? .mp4
                let match = subtitles.first { OutputNaming.baseName($0).hasPrefix(OutputNaming.baseName(video)) } ?? subtitles[0]
                let target: FileFormat = burn ? (videoFormat.isInputOnly ? .mp4 : videoFormat) : (videoFormat == .mkv ? .mkv : .mp4)
                outputs += try await producing(directory, "\(OutputNaming.baseName(video)) (subtitled)", target.fileExtension) {
                    try await MediaEngine.addSubtitles(video, from: videoFormat, subtitles: match, burn: burn, output: $0, progress: progress)
                }
            }
            return Produced(urls: outputs)
        case (.extractSubtitles, .video):
            return Produced(urls: try await MediaEngine.extractSubtitles(url, into: directory, baseName: base, progress: progress))
        case (.poster, .video):
            let at = MediaEngine.parseTime(parameters["at"] ?? "")
            let embed = parameters["output"] == "cover"
            let target: FileFormat = embed ? (source == .mov ? .mov : .mp4) : .jpg
            return Produced(urls: try await producing(directory, "\(base) (\(embed ? String(localized: "with cover") : String(localized: "poster")))", target.fileExtension) {
                try await MediaEngine.poster(url, from: source, at: at, embed: embed, output: $0, progress: progress)
            })
        case (.contactSheet, .video):
            let count = Int(try number(parameters, "count", default: 16))
            let columns = Int(try number(parameters, "columns", default: 4))
            return Produced(urls: try await producing(directory, "\(base) (contact sheet)", "jpg") {
                try await MediaEngine.contactSheet(url, count: count, columns: columns, output: $0, progress: progress)
            })
        case (.replaceAudio, .video):
            guard let audio = inputs.first(where: { FileFormat.detect($0)?.category == .audio }) else {
                throw KumquatError.noResult(String(localized: "Drop the video together with the audio to use."))
            }
            let mix = parameters["mode"] == "mix"
            let db = try number(parameters, "db", default: -12)
            var outputs: [URL] = []
            for video in inputs where FileFormat.detect(video)?.category == .video {
                let videoFormat = FileFormat.detect(video) ?? .mp4
                let target: FileFormat = videoFormat.isInputOnly ? .mp4 : videoFormat
                outputs += try await producing(directory, "\(OutputNaming.baseName(video)) (new audio)", target.fileExtension) {
                    try await MediaEngine.replaceAudio(video, from: videoFormat, audio: audio, mix: mix, musicDecibels: db, output: $0, progress: progress)
                }
            }
            return Produced(urls: outputs)
        case (.reverse, .video):
            let boomerang = parameters["mode"] == "boomerang"
            return Produced(urls: try await producing(directory, "\(base) (\(boomerang ? "boomerang" : String(localized: "reversed")))", mediaExt(source)) {
                try await MediaEngine.reverse(url, from: source, boomerang: boomerang, output: $0, progress: progress)
            })
        case (.fade, .video), (.fade, .audio):
            let seconds = try number(parameters, "seconds", default: 1)
            let side = parameters["where"] ?? "both"
            return Produced(urls: try await producing(directory, "\(base) (faded)", mediaExt(source)) {
                try await MediaEngine.fade(url, from: source, seconds: seconds, fadeIn: side != "out", fadeOut: side != "in", output: $0, progress: progress)
            })
        case (.stabilize, .video):
            return Produced(urls: try await producing(directory, "\(base) (stabilized)", mediaExt(source)) {
                try await MediaEngine.stabilize(url, from: source, output: $0, progress: progress)
            })
        case (.flip, .video):
            let vertical = parameters["axis"] == "vertical"
            return Produced(urls: try await producing(directory, "\(base) (flipped)", mediaExt(source)) {
                try await MediaEngine.flip(url, from: source, vertical: vertical, output: $0, progress: progress)
            })
        case (.watermark, .video):
            let (text, opacity, diagonal) = try watermark(parameters)
            return Produced(urls: try await producing(directory, "\(base) (watermarked)", mediaExt(source)) {
                try await MediaEngine.watermark(url, from: source, text: text, opacity: opacity, diagonal: diagonal, output: $0, progress: progress)
            })
        case (.denoise, .video), (.denoise, .audio):
            return Produced(urls: try await producing(directory, "\(base) (denoised)", mediaExt(source)) {
                try await MediaEngine.denoise(url, from: source, strength: parameters["strength"] ?? "medium", output: $0, progress: progress)
            })

        // Audio
        case (.removeSilence, .audio):
            let threshold = try number(parameters, "threshold", default: -40)
            let pause = try number(parameters, "pause", default: 0.7)
            return Produced(urls: try await producing(directory, "\(base) (no silences)", mediaExt(source)) {
                try await MediaEngine.removeSilence(url, from: source, thresholdDB: threshold, pause: pause, output: $0, progress: progress)
            })
        case (.tags, .audio):
            let cover = inputs.first { FileFormat.detect($0)?.category == .image }
            let title = nonEmpty(parameters, "title"), artist = nonEmpty(parameters, "artist"), album = nonEmpty(parameters, "album")
            var outputs: [URL] = []
            for audio in inputs where FileFormat.detect(audio)?.category == .audio {
                let audioFormat = FileFormat.detect(audio) ?? .mp3
                outputs += try await producing(directory, "\(OutputNaming.baseName(audio)) (tagged)", mediaExt(audioFormat)) {
                    try await MediaEngine.tags(audio, from: audioFormat, title: title, artist: artist, album: album,
                                               cover: cover, output: $0, progress: progress)
                }
            }
            return Produced(urls: outputs)
        case (.waveform, .audio):
            return Produced(urls: try await producing(directory, "\(base) (waveform)", "png") {
                try await MediaEngine.waveform(url, color: parameters["color"] ?? "orange", output: $0, progress: progress)
            })
        case (.channels, .audio):
            return Produced(urls: try await producing(directory, "\(base) (\(parameters["channels"] ?? "mono"))", mediaExt(source)) {
                try await MediaEngine.channels(url, from: source, channels: parameters["channels"] ?? "mono", rate: parameters["rate"] ?? "keep",
                                               output: $0, progress: progress)
            })

        // PDF
        case (.reorderPages, .pdf):
            let order = parameters["order"] ?? ""
            guard !order.isEmpty else { throw KumquatError.noResult(String(localized: "Arrange the pages first.")) }
            return Produced(urls: try await producing(directory, "\(base) (rearranged)", "pdf") { output in
                try await runBlocking { try PDFEngine.reorder(url, order: order, output: output) }
            })
        case (.sign, .pdf):
            guard let signature = parameters["signature"].flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0) }),
                  FileManager.default.fileExists(atPath: signature.path) else {
                throw KumquatError.noResult(String(localized: "Draw or import your signature first."))
            }
            let page = parameters["page"] ?? "last"
            let area = region(parameters)
            return Produced(urls: try await producing(directory, "\(base) (signed)", "pdf") { output in
                try await runBlocking { try PDFEngine.sign(url, signature: signature, page: page, region: area, output: output) }
            })
        case (.redact, .pdf):
            let terms = (parameters["find"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let patterns = parameters["also"] ?? "none"
            guard !terms.isEmpty || patterns != "none" else { throw KumquatError.noResult(String(localized: "Enter what to hide.")) }
            return Produced(urls: try await producing(directory, "\(base) (redacted)", "pdf") { output in
                try await runBlocking { try PDFEngine.redact(url, terms: terms, patterns: patterns, output: output) }
            })
        case (.pageNumbers, .pdf):
            let start = Int(try number(parameters, "start", default: 1))
            let position = parameters["position"] ?? "bottomCenter"
            let skipFirst = parameters["skipFirst"] == "yes"
            return Produced(urls: try await producing(directory, "\(base) (numbered)", "pdf") { output in
                try await runBlocking { try PDFEngine.pageNumbers(url, position: position, start: start, skipFirst: skipFirst, output: output) }
            })
        case (.flatten, .pdf):
            return Produced(urls: try await producing(directory, "\(base) (flattened)", "pdf") { output in try await runBlocking { try PDFEngine.flatten(url, output: output) } })
        case (.nUp, .pdf):
            let layout = parameters["layout"] ?? "2"
            return Produced(urls: try await producing(directory, "\(base) (\(layout == "booklet" ? String(localized: "booklet") : "\(layout)-up"))", "pdf") { output in
                try await runBlocking { try PDFEngine.nUp(url, layout: layout, output: output) }
            })
        case (.extractImages, .pdf):
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) images")
            do {
                return Produced(urls: try await runBlocking { try PDFEngine.extractImages(url, into: folder, baseName: base) })
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case (.grayscale, .pdf):
            return Produced(urls: try await producing(directory, "\(base) (grayscale)", "pdf") { output in try await runBlocking { try PDFEngine.grayscale(url, output: output) } })
        case (.stripMetadata, .pdf):
            let title = nonEmpty(parameters, "title"), author = nonEmpty(parameters, "author")
            return Produced(urls: try await producing(directory, "\(base) (clean)", "pdf") { output in
                try await runBlocking { try PDFEngine.setMetadata(url, title: title, author: author, output: output) }
            })

        // Text: documents, PDFs and subtitles
        case (.wordCount, .document), (.wordCount, .pdf):
            return Produced(urls: [], note: try await LanguageEngine.wordCount(url, from: source))
        case (.translate, .document), (.translate, .pdf), (.translate, .subtitle):
            let language = parameters["language"] ?? Catalog.defaultTranslationLanguage
            let format = LanguageEngine.translationOutputFormat(for: source)
            return Produced(urls: try await producing(directory, "\(base) (\(language))", format.fileExtension) {
                try await LanguageEngine.translate(url, from: source, into: language, output: $0)
            })
        case (.summarize, .document), (.summarize, .pdf):
            return Produced(urls: try await producing(directory, "\(base) (summary)", "md") {
                try await LanguageEngine.summarize(url, from: source, length: parameters["length"] ?? "short", output: $0)
            })
        case (.split, .document):
            let level = Int(try number(parameters, "level", default: 1))
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) chapters")
            do {
                return Produced(urls: try await DocumentEngine.split(url, from: source, level: level, into: folder, baseName: base))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case (.findReplace, .document):
            let find = parameters["find"] ?? ""
            guard !find.isEmpty else { throw KumquatError.noResult(String(localized: "Enter the text to find.")) }
            var count = 0
            let urls = try await producing(directory, "\(base) (replaced)", ext) { output in
                count = try await DocumentEngine.findReplace(url, from: source, find: find, replace: parameters["replace"] ?? "",
                                                             regex: parameters["regex"] == "regex", output: output)
            }
            return Produced(urls: urls, note: String(localized: "\(count) replacements"))
        case (.clean, .document):
            return Produced(urls: try await producing(directory, "\(base) (clean)", ext) { try await DocumentEngine.clean(url, from: source, output: $0) })
        case (.compress, .document), (.compress, .slides), (.compress, .spreadsheet):
            let quality = try number(parameters, "quality", default: 70) / 100
            return Produced(urls: try await producing(directory, "\(base) (compressed)", ext) { try await DocumentEngine.compressOffice(url, quality: quality, output: $0) })
        case (.extractNotes, .slides):
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) notes and media")
            do {
                return Produced(urls: try await DocumentEngine.extractNotes(url, into: folder, baseName: base))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }

        // Spreadsheets
        case (.csvExcel, .spreadsheet):
            return Produced(urls: try await producing(directory, "\(base) (Excel)", "csv") { try await SheetEngine.excelCSV(url, from: source, output: $0) })
        case (.dedupe, .spreadsheet):
            var removed = 0
            let urls = try await producing(directory, "\(base) (deduped)", sheet) { output in
                removed = try await SheetEngine.dedupe(url, from: source, column: parameters["column"] ?? "", output: output)
            }
            return Produced(urls: urls, note: String(localized: "\(removed) duplicate rows removed"))
        case (.columnStats, .spreadsheet):
            return Produced(urls: try await producing(directory, "\(base) (summary)", "md") { try await SheetEngine.columnStats(url, from: source, output: $0) })
        case (.transpose, .spreadsheet):
            return Produced(urls: try await producing(directory, "\(base) (transposed)", sheet) { try await SheetEngine.transpose(url, from: source, output: $0) })

        // Subtitles
        case (.changeFPS, .subtitle):
            let from = try number(parameters, "from", default: 23.976)
            let to = try number(parameters, "to", default: 25)
            guard from != to else { throw KumquatError.noResult(String(localized: "Pick two different frame rates.")) }
            return Produced(urls: try await producing(directory, "\(base) (\(to.formatted()) fps)", ext) { output in
                try SubtitleEngine.changeFrameRate(url, from: source, fps: from, to: to, output: output)
            })
        case (.clean, .subtitle):
            return Produced(urls: try await producing(directory, "\(base) (clean)", ext) { output in try SubtitleEngine.clean(url, from: source, output: output) })

        // Archives
        case (.splitVolumes, .archive):
            let megabytes = Int(try number(parameters, "size", default: 25))
            let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(base) parts")
            do {
                return Produced(urls: try await ArchiveEngine.splitVolumes(url, megabytes: megabytes, into: folder, baseName: base))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        case (.verify, .archive):
            return Produced(urls: [], note: try await ArchiveEngine.verify(url, from: source))

        default:
            throw KumquatError.unsupported(String(localized: "\(tool.title) for \(category.title.lowercased()) files"))
        }
    }

    /// Folder tools work inside the folder itself; the result is the folder, ready to reveal.
    static func runFolderTool(_ tool: ToolKind, folder: URL, parameters: [String: String]) async throws -> Produced {
        guard Catalog.isFolder(folder) else { throw KumquatError.noResult(String(localized: "“\(folder.lastPathComponent)” isn't a folder.")) }
        switch tool {
        case .sortFolder:
            let moved = try await FolderEngine.sort(folder, by: parameters["by"] ?? "type")
            return Produced(urls: [folder], note: String(localized: "\(moved) files sorted"))
        case .findDuplicates:
            let result = try await FolderEngine.findDuplicates(folder)
            guard let duplicates = result.folder else {
                throw KumquatError.noResult(String(localized: "No duplicates in “\(folder.lastPathComponent)”."))
            }
            return Produced(urls: [duplicates], note: String(localized: "\(result.count) duplicates moved"))
        case .flatten:
            let moved = try await FolderEngine.flatten(folder)
            return Produced(urls: [folder], note: String(localized: "\(moved) files moved up"))
        case .listFiles:
            return Produced(urls: try await producing(folder.deletingLastPathComponent(), "\(folder.lastPathComponent) (files)", "csv") {
                try await FolderEngine.listFiles(folder, output: $0)
            })
        default:
            throw KumquatError.unsupported(tool.title)
        }
    }

    static func nonEmpty(_ parameters: [String: String], _ key: String) -> String? {
        let text = parameters[key]?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? nil : text
    }

    static func watermark(_ parameters: [String: String]) throws -> (String, Double, Bool) {
        let text = parameters["text"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { throw KumquatError.noResult(String(localized: "Enter the watermark text.")) }
        return (text, try number(parameters, "opacity", default: 28) / 100, parameters["angle"] != "horizontal")
    }

    /// Container a media tool writes: the source's own, or MP4 / M4A for formats Kumquat only reads.
    static func mediaExt(_ source: FileFormat) -> String {
        guard source.isInputOnly else { return source.fileExtension }
        return source.category == .audio ? FileFormat.m4a.fileExtension : FileFormat.mp4.fileExtension
    }
}
