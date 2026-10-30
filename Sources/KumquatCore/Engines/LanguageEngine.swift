import AppKit
import Foundation
import NaturalLanguage
import PDFKit
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Text understanding on the Mac: word counts, translation (Translation framework) and summaries (Foundation Models).
/// Everything runs on device; the frameworks are only touched behind `#available(macOS 26)`.
public enum LanguageEngine {
    /// "1 234 words · 7 890 characters · 6 min read" for documents and PDFs.
    public static func wordCount(_ input: URL, from source: FileFormat) async throws -> String {
        let text = try await plainText(input, from: source)
        let words = try await runBlocking { countWords(text) }
        guard words > 0 else { throw KumquatError.noResult(String(localized: "No text found in “\(input.lastPathComponent)”.")) }
        let characters = text.filter { !$0.isNewline }.count
        let minutes = max(1, Int((Double(words) / 230).rounded(.up)))
        return String(localized: "\(words.formatted()) words · \(characters.formatted()) characters · \(minutes) min read")
    }

    static func countWords(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// The readable text of a document or PDF, without markup.
    static func plainText(_ input: URL, from source: FileFormat) async throws -> String {
        switch source {
        case .pdf:
            let text = try await runBlocking { () -> String in
                guard let document = PDFDocument(url: input) else { throw KumquatError.cannotOpen(input.lastPathComponent) }
                return document.string ?? ""
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            // Scans have no text layer: read them.
            return try await TextExtractor.pdfPages(input).joined(separator: "\n\n")
        case .txt:
            return try DocumentEngine.readText(input)
        case let markup where Catalog.markupFormats.contains(markup) && Engines.pandoc == nil:
            // Without pandoc the source itself is the closest thing to its text.
            return try DocumentEngine.readText(input)
        case .md:
            return PlainTextWriter.write(MarkdownReader.parse(try DocumentEngine.readText(input)))
        case .srt, .vtt, .ass, .sbv, .ttml, .lrc:
            return try SubtitleEngine.readCues(input, format: source).map { SubtitleEngine.plain($0.text) }.joined(separator: "\n")
        default:
            return try await DocumentEngine.attributed(input, format: source).value.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
    }

    /// Subtitles, TXT, Markdown and HTML keep their format; other documents and PDFs become DOCX.
    public static func translationOutputFormat(for source: FileFormat) -> FileFormat {
        [.srt, .vtt, .ass, .sbv, .ttml, .lrc, .txt, .md, .html].contains(source) ? source : .docx
    }

    // MARK: - Translate

    /// Translates into `language` (BCP-47 code), detecting the source language.
    public static func translate(_ input: URL, from source: FileFormat, into language: String, output: URL) async throws {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            try await Translator.translate(input, from: source, into: language, output: output)
            return
        }
        #endif
        throw KumquatError.noResult(translationUnavailableReason ?? String(localized: "Needs macOS 26"))
    }

    /// Why Translate can't run on this Mac, or `nil`.
    public static var translationUnavailableReason: String? {
        #if canImport(Translation)
        if #available(macOS 26.0, *) { return nil }
        #endif
        return String(localized: "Needs macOS 26")
    }

    /// The language most of `text` is written in.
    static func dominantLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        return recognizer.dominantLanguage
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    // MARK: - Summarize

    /// Markdown summary. `length`: "short", "medium", "long".
    public static func summarize(_ input: URL, from source: FileFormat, length: String, output: URL) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), summaryUnavailableReason == nil {
            let text = try await plainText(input, from: source)
            guard countWords(text) > 0 else { throw KumquatError.noResult(String(localized: "No text found in “\(input.lastPathComponent)”.")) }
            let summary = try await Summarizer.summarize(text, length: length)
            let name = input.deletingPathExtension().lastPathComponent
            let title = String(localized: "Summary of “\(name)”")
            try "# \(title)\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n".write(to: output, atomically: true, encoding: .utf8)
            return
        }
        #endif
        throw KumquatError.noResult(summaryUnavailableReason ?? String(localized: "Needs macOS 26"))
    }

    /// Why Summarize can't run on this Mac, or `nil`.
    public static var summaryUnavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in System Settings")
            case .unavailable(.deviceNotEligible):
                return String(localized: "This Mac doesn't support Apple Intelligence")
            case .unavailable(.modelNotReady):
                return String(localized: "Apple Intelligence is still downloading")
            case .unavailable:
                return String(localized: "Apple Intelligence isn't available")
            }
        }
        #endif
        return String(localized: "Needs macOS 26")
    }

    /// Paragraph-aligned pieces of at most `limit` characters (longer paragraphs are cut at sentences).
    static func chunks(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func add(_ piece: String) {
            if !current.isEmpty, current.count + piece.count + 2 > limit {
                out.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n\n" + piece
        }
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for paragraph in paragraphs {
            if paragraph.count <= limit {
                add(paragraph)
                continue
            }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var sentence = ""
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let next = String(paragraph[range])
                if sentence.count + next.count > limit, !sentence.isEmpty {
                    add(sentence)
                    sentence = ""
                }
                sentence += next.count > limit ? String(next.prefix(limit)) : next
                return true
            }
            if !sentence.isEmpty { add(sentence) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - Translation

#if canImport(Translation)
@available(macOS 26.0, *)
private enum Translator {
    static func translate(_ input: URL, from source: FileFormat, into language: String, output: URL) async throws {
        let name = input.lastPathComponent
        switch source {
        case .srt, .vtt, .ass, .sbv, .ttml, .lrc:
            // Cue by cue, keeping every timing.
            let cues = try SubtitleEngine.readCues(input, format: source)
            let texts = cues.map { SubtitleEngine.plain($0.text) }
            let translated = try await translate(texts, into: language, name: name)
            let result = zip(cues, translated).map { Cue(start: $0.start, end: $0.end, text: $1) }
            try SubtitleEngine.render(result, as: source).write(to: output, atomically: true, encoding: .utf8)
        case .txt:
            // Paragraph by paragraph; blank lines stay where they were.
            let text = try DocumentEngine.readText(input).replacingOccurrences(of: "\r\n", with: "\n")
            let paragraphs = text.components(separatedBy: "\n\n")
            let translated = try await translate(paragraphs, into: language, name: name)
            try translated.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
        case .md:
            let document = try await translate(MarkdownReader.parse(try DocumentEngine.readText(input)), into: language, name: name)
            try MarkdownWriter.write(document).write(to: output, atomically: true, encoding: .utf8)
        case .html:
            let document = try await translate(try await DocumentEngine.model(input, format: .html), into: language, name: name)
            try HTMLWriter.page(document, fallbackTitle: DocumentEngine.baseName(input)).write(to: output, atomically: true, encoding: .utf8)
        default:
            let model = source == .pdf ? try await PDFEngine.model(input) : try await DocumentEngine.model(input, format: source)
            let document = try await translate(model, into: language, name: name)
            let text = SendableText(value: AttributedBridge.attributed(document))
            try await runBlocking { try DocumentEngine.write(text.value, type: .officeOpenXML, to: output) }
        }
    }

    /// Every text block translated as one piece (inline styling inside a block is not kept); code stays.
    static func translate(_ document: RichDocument, into language: String, name: String) async throws -> RichDocument {
        var texts: [String] = []
        for block in document.blocks {
            switch block {
            case .heading(_, let inlines), .paragraph(let inlines), .listItem(_, let inlines), .quote(let inlines): texts.append(inlines.plainText)
            default: texts.append("")
            }
        }
        let translated = try await translate(texts, into: language, name: name)
        var out = document
        out.blocks = zip(document.blocks, translated).map { block, text in
            switch block {
            case .heading(let level, _): .heading(level, [Inline(text: text)])
            case .paragraph: .paragraph([Inline(text: text)])
            case .listItem(let ordered, _): .listItem(ordered: ordered, [Inline(text: text)])
            case .quote: .quote([Inline(text: text)])
            default: block
            }
        }
        return out
    }

    /// Translates each string (blank ones pass through), batching the requests.
    static func translate(_ texts: [String], into language: String, name: String) async throws -> [String] {
        let sample = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        guard !sample.isEmpty else { throw KumquatError.noResult(String(localized: "No text found in “\(name)”.")) }
        guard let detected = LanguageEngine.dominantLanguage(sample) else {
            throw KumquatError.noResult(String(localized: "Couldn't tell which language “\(name)” is in."))
        }
        let sourceLanguage = Locale.Language(identifier: detected.rawValue)
        let targetLanguage = Locale.Language(identifier: language)
        let sourceName = LanguageEngine.languageName(detected.rawValue), targetName = LanguageEngine.languageName(language)
        if sourceLanguage.languageCode == targetLanguage.languageCode {
            throw KumquatError.noResult(String(localized: "“\(name)” is already in \(targetName)."))
        }
        switch await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) {
        case .installed:
            break
        case .supported:
            throw KumquatError.noResult(String(localized: "Download \(sourceName) and \(targetName) in System Settings ▸ General ▸ Language & Region ▸ Translation Languages, then try again."))
        case .unsupported:
            throw KumquatError.noResult(String(localized: "Translating from \(sourceName) to \(targetName) isn't supported."))
        @unknown default:
            throw KumquatError.noResult(String(localized: "Translating from \(sourceName) to \(targetName) isn't supported."))
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        var out = texts
        let pending = texts.indices.filter { !texts[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for start in stride(from: 0, to: pending.count, by: 40) {
            try Task.checkCancellation()
            let batch = pending[start..<min(start + 40, pending.count)]
            let requests = batch.map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init) { out[index] = response.targetText }
            }
        }
        return out
    }
}
#endif

// MARK: - Summaries

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum Summarizer {
    /// The on-device model's context is about 4 000 tokens: pieces this long leave room for the reply.
    static let chunkLimit = 6_000

    static func summarize(_ text: String, length: String) async throws -> String {
        let pieces = LanguageEngine.chunks(text, limit: chunkLimit)
        if pieces.count == 1 { return try await final(pieces[0], length: length, partial: false) }
        // Map: notes for each piece. Reduce: notes about notes until they fit, then the summary.
        var notes = try await notesFor(pieces)
        for _ in 0..<3 where notes.count > chunkLimit {
            notes = try await notesFor(LanguageEngine.chunks(notes, limit: chunkLimit))
        }
        return try await final(String(notes.prefix(chunkLimit)), length: length, partial: true)
    }

    static func notesFor(_ pieces: [String]) async throws -> String {
        var notes: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            notes.append(try await respond(
                "List the key facts, names, numbers and conclusions of this part of a document as short bullet points, in the document's language.",
                piece))
        }
        return notes.joined(separator: "\n\n")
    }

    static func final(_ text: String, length: String, partial: Bool) async throws -> String {
        let shape = switch length {
        case "long": "a detailed summary in Markdown with a few \"##\" sections covering every main point"
        case "medium": "a Markdown summary: one short paragraph, then 5 to 8 bullet points"
        default: "a Markdown summary of 3 to 5 bullet points"
        }
        let what = partial ? "These are notes taken from a long document. Write" : "Write"
        return try await respond("\(what) \(shape), in the same language as the text. Reply with the summary only.", text)
    }

    /// One fresh session per request, so earlier pieces don't fill the context window.
    static func respond(_ task: String, _ text: String) async throws -> String {
        let session = LanguageModelSession(instructions: "You summarize documents faithfully. Never invent facts. Never add a preamble.")
        do {
            return try await session.respond(to: "\(task)\n\n---\n\(text)").content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // Too long for this language's tokens: halve and try again.
                let halves = LanguageEngine.chunks(text, limit: max(500, text.count / 2))
                guard halves.count > 1 else { throw KumquatError.noResult(String(localized: "This document is too long to summarize.")) }
                var parts: [String] = []
                for half in halves { parts.append(try await respond(task, half)) }
                return parts.joined(separator: "\n\n")
            case .guardrailViolation:
                throw KumquatError.noResult(String(localized: "Apple Intelligence declined to summarize this document."))
            case .unsupportedLanguageOrLocale:
                throw KumquatError.noResult(String(localized: "Apple Intelligence can't summarize text in this language yet."))
            default:
                throw KumquatError.processFailed(error.localizedDescription)
            }
        }
    }
}
#endif
