import Foundation

struct Cue: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// SRT · VTT · ASS/SSA · SBV · TTML/DFXP · LRC to each other (and TXT), plus timing tools. Pure Swift.
/// Cue text travels with SRT-style inline tags (<i>, <b>, <u>) whatever the format it came from.
public enum SubtitleEngine {
    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws {
        try render(try readCues(input, format: source), as: target).write(to: output, atomically: true, encoding: .utf8)
    }

    public static func shift(_ input: URL, from source: FileFormat, seconds: Double, output: URL) throws {
        let cues = try readCues(input, format: source).map {
            Cue(start: max(0, $0.start + seconds), end: max(0, $0.end + seconds), text: $0.text)
        }
        try render(cues, as: source).write(to: output, atomically: true, encoding: .utf8)
    }

    public static func merge(_ inputs: [URL], as format: FileFormat, output: URL) throws {
        let cues = try inputs.flatMap { try readCues($0, format: FileFormat.detect($0) ?? format) }.sorted { $0.start < $1.start }
        try render(cues, as: format).write(to: output, atomically: true, encoding: .utf8)
    }

    /// The cues of a subtitle file; throws when there are none.
    static func readCues(_ url: URL, format: FileFormat) throws -> [Cue] {
        let cues = parse(try DocumentEngine.readText(url), format: format)
        guard !cues.isEmpty else { throw KumquatError.noResult(String(localized: "No subtitles found in “\(url.lastPathComponent)”.")) }
        return cues
    }

    // MARK: - Parsing

    /// Cues of `text` in whatever format it looks like (SRT/VTT unless it's clearly another one).
    static func parse(_ text: String) -> [Cue] {
        parse(text, format: sniff(text))
    }

    static func parse(_ text: String, format: FileFormat) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch format {
        case .ass: return parseASS(normalized)
        case .sbv: return parseSBV(normalized)
        case .ttml: return parseTTML(normalized)
        case .lrc: return parseLRC(normalized)
        default: return parseTimed(normalized)
        }
    }

    static func sniff(_ text: String) -> FileFormat {
        let head = String(text.prefix(4096))
        if head.contains("[Script Info]") || head.contains("[Events]") { return .ass }
        if head.contains("http://www.w3.org/ns/ttml") || head.contains("http://www.w3.org/2006/10/ttaf1") { return .ttml }
        if head.contains("-->") { return head.hasPrefix("WEBVTT") ? .vtt : .srt }
        if head.range(of: #"(?m)^\d+:\d{2}:\d{2}\.\d{1,3},\d+:\d{2}:\d{2}\.\d{1,3}"#, options: .regularExpression) != nil { return .sbv }
        if head.range(of: #"(?m)^\[\d+:\d{2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil { return .lrc }
        return .srt
    }

    nonisolated(unsafe) private static let timing = /(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})/

    private static func seconds(_ h: Substring?, _ m: Substring, _ s: Substring, _ ms: Substring) -> Double {
        let millis = Double(ms.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return Double(h ?? "0")! * 3600 + Double(m)! * 60 + Double(s)! + millis / 1000
    }

    /// SRT and WebVTT: blocks with a "start --> end" line (VTT headers, notes and styles have none).
    static func parseTimed(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let match = lines[timingIndex].firstMatch(of: timing) else { continue }
            let start = seconds(match.output.1, match.output.2, match.output.3, match.output.4)
            let end = seconds(match.output.5, match.output.6, match.output.7, match.output.8)
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues
    }

    /// ASS/SSA: "Dialogue:" lines of [Events], fields in the order its "Format:" line gives.
    static func parseASS(_ text: String) -> [Cue] {
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        var cues: [Cue] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                format = trimmed.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard trimmed.hasPrefix("Dialogue:"), let startField = format.firstIndex(of: "start"),
                  let endField = format.firstIndex(of: "end"), let textField = format.firstIndex(of: "text") else { continue }
            let fields = trimmed.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == format.count, let start = assTime(fields[startField]), let end = assTime(fields[endField]) else { continue }
            let body = assText(fields[textField])
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "0:01:02.50" → 62.5.
    static func assTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Override blocks go, except italic/bold/underline which become tags; \N is a line break.
    static func assText(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let block = rest[rest.index(after: open)..<close]
            for (code, tag) in [("\\i1", "<i>"), ("\\i0", "</i>"), ("\\b1", "<b>"), ("\\b0", "</b>"), ("\\u1", "<u>"), ("\\u0", "</u>")] where block.contains(code) {
                out += tag
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated(unsafe) private static let sbvTiming = /^(\d+):(\d{2}):(\d{2})\.(\d{1,3}),(\d+):(\d{2}):(\d{2})\.(\d{1,3})/

    /// YouTube SBV: "0:00:01.000,0:00:02.500" then the text.
    static func parseSBV(_ text: String) -> [Cue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
            guard let first = lines.first, let match = first.trimmingCharacters(in: .whitespaces).firstMatch(of: sbvTiming) else { return nil }
            let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return Cue(start: seconds(match.output.1, match.output.2, match.output.3, match.output.4),
                       end: seconds(match.output.5, match.output.6, match.output.7, match.output.8), text: body)
        }
    }

    /// LRC lyrics: "[mm:ss.xx]line" (several stamps per line allowed); each line lasts until the next
    /// stamp, and an empty stamped line just ends the previous one.
    static func parseLRC(_ text: String) -> [Cue] {
        var stamped: [(time: Double, text: String)] = []
        var offset = 0.0
        for line in text.components(separatedBy: "\n") {
            var rest = Substring(line.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = lrcTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:") {
                    offset = (Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            // Enhanced LRC word stamps (<mm:ss.xx>) aren't shown.
            let body = rest.replacingOccurrences(of: #"<\d+:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for time in times { stamped.append((max(0, time - offset), body)) }
        }
        stamped.sort { $0.time < $1.time }
        var cues: [Cue] = []
        for (index, item) in stamped.enumerated() where !item.text.isEmpty {
            let next = stamped[(index + 1)...].first { $0.time > item.time }?.time
            cues.append(Cue(start: item.time, end: next ?? item.time + 4, text: item.text))
        }
        return cues
    }

    /// "01:02.50", "01:02:50" (centiseconds) or "01:02" → seconds.
    static func lrcTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3, parts[0].allSatisfy(\.isNumber), let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        let fraction = parts.count == 3 ? (Double("0." + parts[2]) ?? 0) : 0
        return minutes * 60 + seconds + fraction
    }

    /// TTML / DFXP: timed <p> elements; <br/> breaks lines, italic/bold/underline spans become tags.
    static func parseTTML(_ text: String) -> [Cue] {
        guard let document = try? Foundation.XMLDocument(xmlString: text, options: []), let root = document.rootElement() else { return [] }
        func attribute(_ element: Foundation.XMLElement, _ name: String) -> String? {
            element.attributes?.first { $0.localName == name }?.stringValue
        }
        let multiplier = attribute(root, "frameRateMultiplier").map { $0.split(separator: " ").compactMap { Double($0) } }
        var frameRate = Double(attribute(root, "frameRate") ?? "") ?? 30
        if let multiplier, multiplier.count == 2, multiplier[1] > 0 { frameRate *= multiplier[0] / multiplier[1] }
        let tickRate = Double(attribute(root, "tickRate") ?? "") ?? 1
        func time(_ raw: String?) -> Double? { raw.flatMap { ttmlTime($0, frameRate: frameRate, tickRate: tickRate) } }

        var cues: [Cue] = []
        func walk(_ element: Foundation.XMLElement, offset: Double) {
            let begin = time(attribute(element, "begin"))
            if element.localName == "p" {
                guard let start = begin.map({ $0 + offset }) else { return }
                let end = time(attribute(element, "end")).map { $0 + offset }
                    ?? time(attribute(element, "dur")).map { start + $0 } ?? start + 3
                let body = ttmlText(element).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
                return
            }
            for case let child as Foundation.XMLElement in element.children ?? [] { walk(child, offset: offset + (begin ?? 0)) }
        }
        walk(root, offset: 0)
        return cues.sorted { $0.start < $1.start }
    }

    static func ttmlText(_ element: Foundation.XMLElement) -> String {
        var out = ""
        for node in element.children ?? [] {
            switch node.kind {
            case .text:
                out += (node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            case .element:
                guard let child = node as? Foundation.XMLElement else { continue }
                if child.localName == "br" {
                    out += "\n"
                    continue
                }
                func style(_ name: String) -> String? { child.attributes?.first { $0.localName == name }?.stringValue }
                var piece = ttmlText(child)
                if style("textDecoration") == "underline" { piece = "<u>\(piece)</u>" }
                if style("fontWeight") == "bold" { piece = "<b>\(piece)</b>" }
                if style("fontStyle") == "italic" { piece = "<i>\(piece)</i>" }
                out += piece
            default:
                continue
            }
        }
        return out
    }

    /// Clock times ("00:00:01.500", "00:00:01:12" with frames) or offsets ("1.5s", "1500ms", "36f", "10000000t").
    static func ttmlTime(_ raw: String, frameRate: Double, tickRate: Double) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":")
        if parts.count >= 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            let frames = parts.count == 4 ? (Double(parts[3]) ?? 0) / frameRate : 0
            return h * 3600 + m * 60 + s + frames
        }
        for (unit, scale) in [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1), ("f", 1 / frameRate), ("t", 1 / tickRate)] where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).map { $0 * scale }
        }
        return Double(text)
    }

    // MARK: - Rendering

    static func render(_ cues: [Cue], as format: FileFormat) throws -> String {
        switch format {
        case .srt:
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            return "WEBVTT\n\n" + cues.map { cue in
                "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case .ass:
            return renderASS(cues)
        case .sbv:
            return cues.map { cue in
                "\(sbvStamp(cue.start)),\(sbvStamp(cue.end))\n\(plain(cue.text))"
            }.joined(separator: "\n\n") + "\n"
        case .ttml:
            return renderTTML(cues)
        case .lrc:
            return renderLRC(cues)
        case .txt:
            return cues.map { plain($0.text) }.joined(separator: "\n") + "\n"
        default:
            throw KumquatError.unsupported(String(localized: "Subtitles → \(format.displayName)"))
        }
    }

    static func stamp(_ seconds: Double, separator: String) -> String {
        let totalMillis = Int((seconds * 1000).rounded())
        let h = totalMillis / 3_600_000, m = totalMillis / 60_000 % 60, s = totalMillis / 1000 % 60, ms = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    static func sbvStamp(_ seconds: Double) -> String {
        let totalMillis = Int((seconds * 1000).rounded())
        return String(format: "%d:%02d:%02d.%03d", totalMillis / 3_600_000, totalMillis / 60_000 % 60, totalMillis / 1000 % 60, totalMillis % 1000)
    }

    /// Cue text without any markup.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// The tags cue text may carry, in order, with the plain text between them.
    enum Piece {
        case text(String)
        case open(String)
        case close(String)
        case lineBreak
    }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { out.append(.text(buffer)) }
            buffer = ""
        }
        var rest = Substring(text)
        while let c = rest.first {
            if c == "\n" {
                flush()
                out.append(.lineBreak)
                rest = rest.dropFirst()
            } else if c == "<", let close = rest.firstIndex(of: ">") {
                flush()
                let tag = rest[rest.index(after: rest.startIndex)..<close].lowercased()
                let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: " ").first.map(String.init) ?? ""
                if ["i", "b", "u"].contains(name) { out.append(tag.hasPrefix("/") ? .close(name) : .open(name)) }
                rest = rest[rest.index(after: close)...]
            } else {
                buffer.append(c)
                rest = rest.dropFirst()
            }
        }
        flush()
        return out
    }

    static func renderASS(_ cues: [Cue]) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,2,60,60,50,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for cue in cues {
            let body = pieces(cue.text).map { piece -> String in
                switch piece {
                case .text(let text): text.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
                case .open(let tag): "{\\\(tag)1}"
                case .close(let tag): "{\\\(tag)0}"
                case .lineBreak: "\\N"
                }
            }.joined()
            out += "Dialogue: 0,\(assStamp(cue.start)),\(assStamp(cue.end)),Default,,0,0,0,,\(body)\n"
        }
        return out
    }

    static func assStamp(_ seconds: Double) -> String {
        let centis = Int((seconds * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", centis / 360_000, centis / 6000 % 60, centis / 100 % 60, centis % 100)
    }

    static func renderTTML(_ cues: [Cue]) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="">
          <body>
            <div>

        """
        let styles = ["i": "tts:fontStyle=\"italic\"", "b": "tts:fontWeight=\"bold\"", "u": "tts:textDecoration=\"underline\""]
        for cue in cues {
            var body = ""
            var open: [String] = []
            for piece in pieces(cue.text) {
                switch piece {
                case .text(let text): body += xmlEscape(text)
                case .lineBreak: body += "<br/>"
                case .open(let tag):
                    open.append(tag)
                    body += "<span \(styles[tag] ?? "")>"
                case .close(let tag):
                    // Only close what is open, so the XML stays well formed.
                    guard let index = open.lastIndex(of: tag) else { continue }
                    body += String(repeating: "</span>", count: open.count - index)
                    open.removeSubrange(index...)
                }
            }
            body += String(repeating: "</span>", count: open.count)
            out += "      <p begin=\"\(stamp(cue.start, separator: "."))\" end=\"\(stamp(cue.end, separator: "."))\">\(body)</p>\n"
        }
        return out + "    </div>\n  </body>\n</tt>\n"
    }

    /// One stamped line per cue; a gap before the next cue gets an empty stamp so the line clears.
    static func renderLRC(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append("[\(lrcStamp(cue.start))]\(plain(cue.text).replacingOccurrences(of: "\n", with: " "))")
            let next = index + 1 < cues.count ? cues[index + 1].start : nil
            if next == nil || cue.end < next! - 0.05 { lines.append("[\(lrcStamp(cue.end))]") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func lrcStamp(_ seconds: Double) -> String {
        let centis = Int((seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", centis / 6000, centis / 100 % 60, centis % 100)
    }
}

// MARK: - Added after 1.2

extension SubtitleEngine {
    /// Rescales every time by `from / to` (a 23.976 fps file played at 25 fps).
    public static func changeFrameRate(_ input: URL, from source: FileFormat, fps from: Double, to: Double, output: URL) throws {
        guard from > 0, to > 0 else { throw KumquatError.noResult(String(localized: "Pick two valid frame rates.")) }
        let factor = from / to
        let cues = try readCues(input, format: source).map { Cue(start: $0.start * factor, end: $0.end * factor, text: $0.text) }
        try render(cues, as: source).write(to: output, atomically: true, encoding: .utf8)
    }

    /// Removes hearing-impaired notes ([MUSIC], (laughs)), speaker labels ("JOHN:"), HTML/ASS tags and the cues left empty.
    public static func clean(_ input: URL, from source: FileFormat, output: URL) throws {
        let cues = try readCues(input, format: source).compactMap { cue -> Cue? in
            let text = cleaned(cue.text)
            return text.isEmpty ? nil : Cue(start: cue.start, end: cue.end, text: text)
        }
        guard !cues.isEmpty else { throw KumquatError.noResult(String(localized: "Nothing would be left of “\(input.lastPathComponent)”.")) }
        try render(cues, as: source).write(to: output, atomically: true, encoding: .utf8)
    }

    static func cleaned(_ text: String) -> String {
        var text = text
        for pattern in [#"<[^>]*>"#, #"\{[^}]*\}"#, #"\[[^\]]*\]"#, #"\([^)]*\)"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.components(separatedBy: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces)
                // "JOHN:" / "- MARY SMITH:" (capitals only, so "Note: …" sentences stay).
                .replacingOccurrences(of: #"^(-\s*)?\p{Lu}[\p{Lu}\d .'’-]+:\s*"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { line in
            !line.isEmpty && !line.allSatisfy { "-–—♪♫#*. ".contains($0) }
        }.joined(separator: "\n")
    }
}
