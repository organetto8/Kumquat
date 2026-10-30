import Foundation

public struct WheelItem: Sendable, Hashable, Identifiable {
    public let operation: Operation
    public let title: String
    public let symbol: String
    /// Why the item can't run on this Mac (missing engine), or `nil` when ready.
    public let unavailableReason: String?

    public var id: Operation { operation }
    public var isAvailable: Bool { unavailableReason == nil }

    public init(operation: Operation, title: String, symbol: String, unavailableReason: String?) {
        self.operation = operation
        self.title = title
        self.symbol = symbol
        self.unavailableReason = unavailableReason
    }
}

public struct Wheel: Sendable {
    public let kind: WheelKind
    public let items: [WheelItem]
    /// "photo.jpg", "3 images", "2 items".
    public let subject: String
    public let category: FormatCategory?
}

/// Single source of truth for what each wheel offers. The UI is generated from it, so a
/// new converter or tool shows up in the wheel as soon as it is listed here.
public enum Catalog {
    static let rasters: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp]
    /// Most used first: the wheel shows the first page right away.
    static let imageTargets: [FileFormat] = rasters + [.pdf, .gif, .jxl, .ico, .icns, .jp2, .svg]
    static let videos: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    static let videoExtras: [FileFormat] = [.gif, .mp3, .srt, .m4a, .webp, .wav, .flac, .vtt, .txt]
    static let audios: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let audioExtras: [FileFormat] = [.srt, .m4r, .m4b, .mp4, .caf, .ac3, .txt, .vtt]
    static let pdfTargets: [FileFormat] = [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md, .html, .rtf, .odt, .tiff, .heic, .webp, .csv, .m4a]
    static let documentTargets: [FileFormat] = [.docx, .pages, .md, .txt, .epub, .html, .pdf, .rtf, .odt, .doc, .m4a]
    static let markupFormats: [FileFormat] = [.tex, .rst, .adoc, .org]
    static let ebooks: [FileFormat] = [.mobi, .azw3, .fb2]
    static let ebookTargets: [FileFormat] = [.epub, .pdf, .docx, .txt, .html, .rtf, .mobi, .azw3]
    static let ebookSources: Set<FileFormat> = [.epub, .docx, .md, .html, .txt]
    static let sheetTargets: [FileFormat] = [.xlsx, .ods, .csv, .tsv, .pdf, .json, .md, .html, .sqlite]
    static let subtitles: [FileFormat] = [.srt, .vtt, .ass, .sbv, .ttml, .lrc]
    static let archives: [FileFormat] = [.zip, .tar, .gzip, .xz, .bz2, .sevenZip, .dmg]
    static let structured: [FileFormat] = [.json, .yaml, .xml, .plist, .toml]
    static let fonts: [FileFormat] = [.ttf, .otf, .woff, .woff2]
    static let models: [FileFormat] = [.obj, .stl, .ply, .usdz, .usda]
    /// Office Open XML packages, whose embedded pictures Compress can shrink.
    public static let officeFormats: Set<FileFormat> = [.docx, .pptx, .xlsx]

    public static func convertTargets(for format: FileFormat) -> [FileFormat] {
        let targets: [FileFormat] = switch format.category {
        case .image: format == .svg ? imageTargets.filter { $0 != .svg } : imageTargets
        case .video: format == .gif ? videos + [.webp] : videos + videoExtras
        case .audio: audios + audioExtras
        case .pdf: pdfTargets
        case .document:
            ebooks.contains(format) ? ebookTargets
                : documentTargets + markupFormats + (ebookSources.contains(format) ? [.mobi, .azw3] : [])
        case .slides: format == .key ? [.pdf, .jpg, .png, .pptx, .mp4, .gif, .html] : [.pdf, .jpg, .png, .pptx, .key, .mp4, .gif, .html]
        case .spreadsheet: sheetTargets + ([.csv, .xlsx].contains(format) ? [.vcf, .ics] : [])
        case .subtitle: subtitles + [.txt]
        case .archive: archives
        case .data:
            switch format {
            case .json: structured + [.xlsx, .csv, .tsv]
            case .yaml, .xml, .plist, .toml: structured
            case .sqlite: [.csv, .xlsx, .json]
            default: [.csv, .xlsx]
            }
        case .font: fonts
        case .model: models
        }
        return targets.filter { $0 != format && !$0.isInputOnly }
    }

    /// Every input → output pair the Convert wheel can produce.
    public static var conversionCount: Int {
        FileFormat.allCases.reduce(0) { $0 + convertTargets(for: $1).count }
    }

    /// Tools every file and folder gets, at the end of each wheel.
    static let anyFile: [ToolKind] = [.lock, .archive]

    public static func tools(for category: FormatCategory?) -> [ToolKind] {
        let specific: [ToolKind] = switch category {
        case .image?: [.compress, .crop, .resize, .rotate, .flip, .removeBackground, .stripMetadata, .recognizeText, .readQRCode,
                       .merge, .scanDocument, .blurFaces, .frame, .enhance, .filter, .palette, .iconSet, .watermark, .autoTag]
        case .video?: [.trim, .crop, .rotate, .compress, .split, .merge, .mute, .extractAudio, .changeSpeed, .resize, .extractFrames, .makeGIF,
                       .vertical, .addSubtitles, .extractSubtitles, .poster, .contactSheet, .replaceAudio, .reverse, .fade, .stabilize,
                       .flip, .watermark, .denoise]
        case .audio?: [.trim, .split, .merge, .compress, .normalizeVolume, .adjustVolume,
                       .removeSilence, .denoise, .changeSpeed, .fade, .tags, .waveform, .channels]
        case .pdf?: [.merge, .split, .compress, .crop, .extractPages, .rotate, .password, .watermark, .recognizeText,
                     .reorderPages, .sign, .redact, .pageNumbers, .flatten, .nUp, .extractImages, .grayscale, .stripMetadata,
                     .summarize, .translate, .wordCount]
        case .document?: [.merge, .split, .wordCount, .findReplace, .clean, .translate, .summarize, .compress]
        case .slides?: [.compress, .extractNotes]
        case .spreadsheet?: [.merge, .split, .csvExcel, .dedupe, .columnStats, .transpose, .compress]
        case .subtitle?: [.shiftTiming, .merge, .changeFPS, .clean, .translate]
        case .archive?: [.extract, .encryptArchive, .splitVolumes, .verify]
        case .data?, .font?, .model?: []
        case nil: [.sortFolder, .findDuplicates, .flatten, .listFiles]
        }
        return specific + anyFile
    }

    /// Formats a tool is limited to inside its category; `nil` means all of them.
    public static func formats(for tool: ToolKind, category: FormatCategory?) -> Set<FileFormat>? {
        switch (tool, category) {
        case (.compress, .document?), (.compress, .slides?), (.compress, .spreadsheet?): officeFormats
        case (.extractNotes, _): [.pptx]
        case (.split, .document?): [.md, .docx, .txt, .html, .odt, .rtf]
        case (.findReplace, _): [.txt, .md, .html, .docx, .rtf, .tex, .rst, .adoc, .org]
        case (.clean, .document?): [.txt, .md, .html, .tex, .rst, .adoc, .org]
        case (.wordCount, .document?), (.translate, .document?), (.summarize, .document?): [.docx, .doc, .odt, .pages, .md, .txt, .epub, .rtf, .rtfd, .html, .tex, .rst, .adoc, .org]
        case (.splitVolumes, _): [.zip]
        case (.verify, _): [.zip, .tar, .gzip, .xz, .bz2, .sevenZip, .dmg, .rar]
        case (.encryptArchive, _): [.zip, .tar, .gzip, .xz, .bz2, .sevenZip, .rar]
        default: nil
        }
    }

    /// Tools that only make sense on a folder.
    public static let folderTools: Set<ToolKind> = [.sortFolder, .findDuplicates, .flatten, .listFiles]

    /// Files that ride along with a combining tool without being its subject.
    public static func companions(for tool: ToolKind) -> Set<FormatCategory> {
        switch tool {
        case .addSubtitles: [.subtitle]
        case .replaceAudio: [.audio]
        case .tags: [.image]
        default: []
        }
    }

    public static let actions: [ActionKind] = ActionKind.allCases

    /// Actions for a selection; a few only make sense for some kinds of file.
    public static func actions(for category: FormatCategory?) -> [ActionKind] {
        actions.filter { action in
            switch action {
            case .wallpaper: category == .image
            case .addToLibrary: [.image, .video, .audio].contains(category)
            case .copyContents: [.image, .pdf, .document, .subtitle, .data, .spreadsheet].contains(category)
            case .print: [.image, .pdf, .document, .spreadsheet].contains(category)
            default: true
            }
        }
    }

    /// The languages Translate offers, in their own name order.
    static let translationLanguages = ["en", "it", "es", "fr", "de", "pt", "nl", "pl", "tr", "ru", "uk", "ja", "ko", "zh", "ar", "hi"]

    static var translationOptions: [ToolParameter.Option] {
        translationLanguages.map { code in
            .init(code, Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code)
        }
    }

    static var defaultTranslationLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return translationLanguages.contains(code) ? code : "en"
    }

    /// Values asked before running; empty means the tool runs immediately (zero-click).
    public static func parameters(for tool: ToolKind, category: FormatCategory?) -> [ToolParameter] {
        switch (tool, category) {
        case (.trim, .video?):
            [ToolParameter("start", "Start", default: "0:00", kind: .time, hint: "m:ss or seconds"),
             ToolParameter("end", "End", default: "", kind: .time, hint: "empty = until the end")]
        case (.crop, .video?):
            [ToolParameter("aspect", "Shape", default: "auto", kind: .choice(cropShapes), hint: "Auto removes black bars"),
             ToolParameter("region", "Area", default: "", kind: .region)]
        case (.crop, .image?):
            [ToolParameter("aspect", "Shape", default: "auto", kind: .choice(cropShapes), hint: "Auto trims plain borders"),
             ToolParameter("region", "Area", default: "", kind: .region)]
        case (.crop, .pdf?):
            [ToolParameter("aspect", "Shape", default: "auto", kind: .choice([
                .init("auto", String(localized: "Auto")), .init("free", String(localized: "Free")),
             ]), hint: "Auto trims white margins; the area drawn on the first page applies to every page"),
             ToolParameter("region", "Area", default: "", kind: .region)]
        case (.compress, .video?):
            [ToolParameter("preset", "Ready for", default: "custom", kind: .choice([
                .init("custom", String(localized: "Any")), .init("whatsapp", "WhatsApp"), .init("instagram", "Instagram"),
                .init("discord", "Discord"), .init("email", String(localized: "Email")),
             ]), hint: "A destination sets size, resolution and codec for you"),
             ToolParameter("quality", "Quality", default: "balanced", kind: .choice(qualityLevels)),
             ToolParameter("maxMB", "Size limit (MB)", default: "", kind: .number, hint: "empty = no limit, e.g. 25 for Discord")]
        case (.compress, .audio?):
            [ToolParameter("bitrate", "Bitrate", default: "auto", kind: .choice([
                .init("auto", String(localized: "Auto")), .init("64", "64k"), .init("96", "96k"), .init("128", "128k"), .init("192", "192k"), .init("256", "256k"),
             ]), hint: "WAV and AIFF become lossless FLAC instead")]
        case (.compress, .image?):
            [ToolParameter("quality", "Quality", default: "60", kind: .slider(range: 10...95, step: 5, unit: "%", presets: [40, 60, 80]),
                           hint: "PNG and BMP stay lossless")]
        case (.compress, .document?), (.compress, .slides?), (.compress, .spreadsheet?):
            [ToolParameter("quality", "Picture quality", default: "70", kind: .slider(range: 30...95, step: 5, unit: "%", presets: [50, 70, 85]),
                           hint: "Only the pictures inside change; text and layout stay the same")]
        case (.split, .video?), (.split, .audio?):
            [ToolParameter("parts", "Equal parts", default: "2", kind: .slider(range: 2...20, step: 1, unit: String(localized: "parts")))]
        case (.split, .spreadsheet?):
            [ToolParameter("by", "Split by", default: "sheet", kind: .choice([
                .init("sheet", String(localized: "Sheet")), .init("column", String(localized: "Column value")),
             ])),
             ToolParameter("column", "Column", default: "", hint: "name or letter, for “Column value”; empty = first column")]
        case (.split, .document?):
            [ToolParameter("level", "One file per", default: "1", kind: .choice([
                .init("1", String(localized: "Heading 1")), .init("2", String(localized: "Heading 2")),
             ]))]
        case (.merge, .image?):
            [ToolParameter("layout", "Result", default: "pdf", kind: .choice([
                .init("pdf", "PDF"), .init("vertical", String(localized: "Strip")), .init("grid", String(localized: "Grid")), .init("gif", "GIF"),
             ]))]
        case (.resize, .image?):
            [ToolParameter("percent", "Scale", default: "50", kind: .slider(range: 5...200, step: 5, unit: "%", presets: [25, 50, 75]))]
        case (.resize, .video?):
            [ToolParameter("height", "Height", default: "720", kind: .choice([
                .init("2160", "4K"), .init("1440", "1440p"), .init("1080", "1080p"), .init("720", "720p"),
                .init("480", "480p"), .init("360", "360p"),
             ]))]
        case (.rotate, .image?):
            [ToolParameter("angle", "Rotate", default: "90", kind: .choice([.init("0", "0°")] + quarterTurns)),
             ToolParameter("tilt", "Straighten", default: "0", kind: .slider(range: -45...45, step: 0.5, unit: "°", presets: [-5, 0, 5]),
                           hint: "Any tilt crops the corners away", perFile: true)]
        case (.rotate, .pdf?), (.rotate, .video?):
            [ToolParameter("angle", "Rotate", default: "90", kind: .choice(quarterTurns))]
        case (.flip, .image?), (.flip, .video?):
            [ToolParameter("axis", "Flip", default: "horizontal", kind: .choice([
                .init("horizontal", String(localized: "⇆ Horizontal")), .init("vertical", String(localized: "⇅ Vertical")),
             ]))]
        case (.stripMetadata, .image?):
            [ToolParameter("what", "Remove", default: "all", kind: .choice([
                .init("all", String(localized: "Everything")), .init("location", String(localized: "Location only")),
             ]), hint: "Location only keeps the date and the camera")]
        case (.stripMetadata, .pdf?):
            [ToolParameter("title", "Title", default: "", hint: "empty = removed"),
             ToolParameter("author", "Author", default: "", hint: "empty = removed")]
        case (.changeSpeed, .audio?):
            [ToolParameter("factor", "Speed", default: "1.25", kind: .slider(range: 0.25...4, step: 0.05, unit: "×", presets: [0.75, 1, 1.25, 1.5, 2])),
             ToolParameter("semitones", "Pitch", default: "0", kind: .slider(range: -12...12, step: 1, unit: String(localized: "semitones"), presets: [-2, 0, 2]),
                           hint: "0 keeps the original pitch")]
        case (.changeSpeed, _):
            [ToolParameter("factor", "Speed", default: "2", kind: .slider(range: 0.25...4, step: 0.05, unit: "×", presets: [0.5, 1.5, 2, 3]))]
        case (.makeGIF, _):
            [ToolParameter("start", "Start", default: "0:00", kind: .time, hint: "m:ss or seconds"),
             ToolParameter("end", "End", default: "", kind: .time, hint: "empty = until the end"),
             ToolParameter("fps", "Frame rate", default: "15", kind: .slider(range: 5...30, step: 1, unit: "fps", presets: [10, 15, 24])),
             ToolParameter("width", "Width", default: "480", kind: .choice([
                .init("320", "320"), .init("480", "480"), .init("640", "640"), .init("800", "800"),
             ]), hint: "pixels; smaller files load faster")]
        case (.extractFrames, _):
            [ToolParameter("fps", "Frames per second", default: "1", kind: .slider(range: 0.1...10, step: 0.1, unit: "fps", presets: [0.5, 1, 5]))]
        case (.normalizeVolume, _):
            [ToolParameter("lufs", "Target loudness", default: "-16", kind: .choice([
                .init("-14", String(localized: "Music −14")), .init("-16", String(localized: "Podcast −16")), .init("-23", String(localized: "Broadcast −23")),
             ]), hint: "LUFS: streaming services use −14")]
        case (.adjustVolume, _):
            [ToolParameter("db", "Gain", default: "6", kind: .slider(range: -20...20, step: 1, unit: "dB", presets: [-6, 3, 6, 10]))]
        case (.extractPages, _):
            [ToolParameter("pages", "Pages", default: "1", hint: "e.g. 1-3, 5, 8-")]
        case (.password, _):
            [ToolParameter("password", "Password", default: "", kind: .secure, hint: "encrypts, or unlocks a protected PDF")]
        case (.watermark, _):
            [ToolParameter("text", "Text", default: String(localized: "CONFIDENTIAL")),
             ToolParameter("opacity", "Opacity", default: "30", kind: .slider(range: 5...80, step: 5, unit: "%")),
             ToolParameter("angle", "Direction", default: "diagonal", kind: .choice([
                .init("diagonal", String(localized: "Diagonal")), .init("horizontal", String(localized: "Horizontal")),
             ]))]
        case (.shiftTiming, _):
            [ToolParameter("seconds", "Shift (s)", default: "+1.0", hint: "negative = earlier")]
        case (.encryptArchive, _), (.lock, _):
            [ToolParameter("password", "Password", default: "", kind: .secure)]

        // Images
        case (.scanDocument, _):
            [ToolParameter("look", "Look", default: "color", kind: .choice([
                .init("color", String(localized: "Color")), .init("gray", String(localized: "Gray")), .init("bw", String(localized: "Black & white")),
             ]))]
        case (.blurFaces, _):
            [ToolParameter("mode", "Blur", default: "faces", kind: .choice([
                .init("faces", String(localized: "Faces")), .init("area", String(localized: "Drawn area")),
             ]), hint: "Faces are found automatically; draw an area to blur anything else"),
             ToolParameter("style", "Style", default: "pixelate", kind: .choice([
                .init("pixelate", String(localized: "Pixelate")), .init("blur", String(localized: "Blur")), .init("black", String(localized: "Black box")),
             ])),
             ToolParameter("region", "Area", default: "", kind: .region)]
        case (.frame, _):
            [ToolParameter("background", "Background", default: "sunset", kind: .choice(frameBackgrounds)),
             ToolParameter("padding", "Margin", default: "8", kind: .slider(range: 0...30, step: 1, unit: "%", presets: [4, 8, 12])),
             ToolParameter("radius", "Corners", default: "2", kind: .slider(range: 0...10, step: 0.5, unit: "%", presets: [0, 2, 4])),
             ToolParameter("shadow", "Shadow", default: "yes", kind: .choice(yesNo))]
        case (.filter, _):
            [ToolParameter("style", "Filter", default: "noir", kind: .choice([
                .init("noir", "Noir"), .init("mono", "Mono"), .init("sepia", String(localized: "Sepia")), .init("vivid", String(localized: "Vivid")),
                .init("fade", String(localized: "Faded")), .init("instant", String(localized: "Retro")),
             ]))]
        case (.palette, _):
            [ToolParameter("count", "Colors", default: "5", kind: .slider(range: 3...10, step: 1, unit: String(localized: "colors"), presets: [3, 5, 8]))]
        case (.iconSet, _):
            [ToolParameter("kind", "Icons for", default: "all", kind: .choice([
                .init("all", String(localized: "Everything")), .init("mac", "macOS"), .init("web", String(localized: "Web")),
             ]), hint: "macOS: .icns + .iconset · Web: favicon.ico, apple-touch-icon, PWA")]

        // Video & audio
        case (.vertical, _):
            [ToolParameter("background", "Background", default: "blur", kind: .choice([
                .init("blur", String(localized: "Blurred")), .init("black", String(localized: "Black")), .init("white", String(localized: "White")),
             ]))]
        case (.addSubtitles, _):
            [ToolParameter("mode", "Subtitles", default: "burn", kind: .choice([
                .init("burn", String(localized: "In the picture")), .init("track", String(localized: "Switchable track")),
             ]), hint: "Drop the video together with its .srt or .vtt")]
        case (.poster, _):
            [ToolParameter("at", "Still frame", default: "", kind: .time, hint: "m:ss; empty = a frame at 10%", perFile: true),
             ToolParameter("output", "Use it as", default: "image", kind: .choice([
                .init("image", String(localized: "JPG image")), .init("cover", String(localized: "Video cover")),
             ]))]
        case (.contactSheet, _):
            [ToolParameter("count", "Frames", default: "16", kind: .slider(range: 4...64, step: 1, unit: String(localized: "frames"), presets: [9, 16, 25])),
             ToolParameter("columns", "Columns", default: "4", kind: .slider(range: 2...8, step: 1, unit: String(localized: "columns")))]
        case (.replaceAudio, _):
            [ToolParameter("mode", "Audio", default: "replace", kind: .choice([
                .init("replace", String(localized: "Replace")), .init("mix", String(localized: "Mix under")),
             ]), hint: "Drop the video together with the music"),
             ToolParameter("db", "Music volume", default: "-12", kind: .slider(range: -30...0, step: 1, unit: "dB", presets: [-18, -12, -6]),
                           hint: "for “Mix under”")]
        case (.reverse, _):
            [ToolParameter("mode", "Play", default: "reverse", kind: .choice([
                .init("reverse", String(localized: "Backwards")), .init("boomerang", "Boomerang"),
             ]))]
        case (.fade, _):
            [ToolParameter("seconds", "Length", default: "1", kind: .slider(range: 0.5...5, step: 0.5, unit: "s", presets: [0.5, 1, 2])),
             ToolParameter("where", "Fade", default: "both", kind: .choice([
                .init("both", String(localized: "In & out")), .init("in", String(localized: "In")), .init("out", String(localized: "Out")),
             ]))]
        case (.denoise, _):
            [ToolParameter("strength", "Strength", default: "medium", kind: .choice([
                .init("light", String(localized: "Light")), .init("medium", String(localized: "Medium")), .init("strong", String(localized: "Strong")),
             ]))]
        case (.removeSilence, _):
            [ToolParameter("threshold", "Silence below", default: "-40", kind: .choice([
                .init("-50", "−50 dB"), .init("-40", "−40 dB"), .init("-30", "−30 dB"),
             ]), hint: "−30 dB also cuts quiet breathing"),
             ToolParameter("pause", "Longest pause kept", default: "0.7", kind: .slider(range: 0.2...3, step: 0.1, unit: "s", presets: [0.4, 0.7, 1.5]))]
        case (.tags, _):
            [ToolParameter("title", "Title", default: "", hint: "empty = unchanged", perFile: true),
             ToolParameter("artist", "Artist", default: "", hint: "empty = unchanged"),
             ToolParameter("album", "Album", default: "", hint: "empty = unchanged; drop an image too for the cover")]
        case (.waveform, _):
            [ToolParameter("color", "Color", default: "orange", kind: .choice([
                .init("orange", String(localized: "Orange")), .init("black", String(localized: "Black")), .init("white", String(localized: "White")),
             ]))]
        case (.channels, _):
            [ToolParameter("channels", "Channels", default: "mono", kind: .choice([
                .init("keep", String(localized: "Keep")), .init("mono", "Mono"), .init("stereo", "Stereo"),
             ])),
             ToolParameter("rate", "Sample rate", default: "keep", kind: .choice([
                .init("keep", String(localized: "Keep")), .init("44100", "44.1 kHz"), .init("48000", "48 kHz"),
             ]))]

        // PDF
        case (.reorderPages, _):
            [ToolParameter("order", "Pages", default: "", kind: .pages, hint: "Drag to reorder, ⌫ deletes, R turns a page")]
        case (.sign, _):
            [ToolParameter("signature", "Signature", default: "", kind: .signature),
             ToolParameter("page", "Page", default: "last", hint: "a number, or “last”"),
             ToolParameter("region", "Where", default: "", kind: .region)]
        case (.redact, _):
            [ToolParameter("find", "Hide", default: "", hint: "words or phrases, separated by commas"),
             ToolParameter("also", "Also hide", default: "none", kind: .choice([
                .init("none", String(localized: "Nothing else")), .init("email", String(localized: "Emails")),
                .init("iban", "IBAN"), .init("phone", String(localized: "Phone numbers")), .init("all", String(localized: "All of these")),
             ]))]
        case (.pageNumbers, _):
            [ToolParameter("position", "Position", default: "bottomCenter", kind: .choice([
                .init("bottomCenter", String(localized: "Bottom")), .init("bottomRight", String(localized: "Bottom right")),
                .init("topRight", String(localized: "Top right")),
             ])),
             ToolParameter("start", "First number", default: "1", kind: .number),
             ToolParameter("skipFirst", "Cover", default: "no", kind: .choice([
                .init("no", String(localized: "Numbered")), .init("yes", String(localized: "Skipped")),
             ]))]
        case (.nUp, _):
            [ToolParameter("layout", "Layout", default: "2", kind: .choice([
                .init("2", String(localized: "2 per sheet")), .init("4", String(localized: "4 per sheet")), .init("booklet", String(localized: "Booklet")),
             ]))]

        // Text
        case (.findReplace, _):
            [ToolParameter("find", "Find", default: ""),
             ToolParameter("replace", "Replace with", default: ""),
             ToolParameter("regex", "Match", default: "text", kind: .choice([
                .init("text", String(localized: "Text")), .init("regex", String(localized: "Regular expression")),
             ]))]
        case (.translate, _):
            [ToolParameter("language", "Into", default: defaultTranslationLanguage, kind: .choice(translationOptions),
                           hint: "Uses the languages downloaded in System Settings ▸ General ▸ Language & Region")]
        case (.summarize, _):
            [ToolParameter("length", "Length", default: "short", kind: .choice([
                .init("short", String(localized: "Short")), .init("medium", String(localized: "Medium")), .init("long", String(localized: "Detailed")),
             ]))]

        // Spreadsheets & subtitles
        case (.dedupe, _):
            [ToolParameter("column", "Compare", default: "", hint: "column name or letter; empty = whole row")]
        case (.changeFPS, _):
            [ToolParameter("from", "From", default: "23.976", kind: .choice(frameRates)),
             ToolParameter("to", "To", default: "25", kind: .choice(frameRates))]

        // Archives & folders
        case (.splitVolumes, _):
            [ToolParameter("size", "Part size", default: "25", kind: .choice([
                .init("10", "10 MB"), .init("25", "25 MB"), .init("100", "100 MB"), .init("700", "700 MB"),
             ]))]
        case (.sortFolder, _):
            [ToolParameter("by", "Sort into", default: "type", kind: .choice([
                .init("type", String(localized: "Kind")), .init("month", String(localized: "Month")),
             ]))]
        default:
            []
        }
    }

    static let qualityLevels: [ToolParameter.Option] = [.init("high", String(localized: "High")), .init("balanced", String(localized: "Balanced")), .init("small", String(localized: "Smallest"))]
    static let cropShapes: [ToolParameter.Option] = [
        .init("auto", String(localized: "Auto")), .init("free", String(localized: "Free")), .init("1:1", "1:1"), .init("4:3", "4:3"),
        .init("3:2", "3:2"), .init("16:9", "16:9"), .init("9:16", "9:16"), .init("4:5", "4:5"),
    ]
    static let quarterTurns: [ToolParameter.Option] = [
        .init("270", String(localized: "↺ Left")), .init("90", String(localized: "↻ Right")), .init("180", "180°"),
    ]
    static let yesNo: [ToolParameter.Option] = [.init("yes", String(localized: "Yes")), .init("no", String(localized: "No"))]
    static let frameBackgrounds: [ToolParameter.Option] = [
        .init("sunset", String(localized: "Sunset")), .init("ocean", String(localized: "Ocean")), .init("white", String(localized: "White")),
        .init("black", String(localized: "Black")), .init("clear", String(localized: "Transparent")),
    ]
    static let frameRates: [ToolParameter.Option] = ["23.976", "24", "25", "29.97", "30"].map { .init($0, "\($0) fps") }

    /// Tools with options that still run straight away with the last values; their options open on request (⌥).
    static let instantTools: Set<ToolKind> = [.compress, .flip, .makeGIF, .normalizeVolume, .merge, .scanDocument, .frame, .filter, .palette,
                                              .iconSet, .vertical, .addSubtitles, .contactSheet, .reverse, .fade, .denoise, .removeSilence,
                                              .waveform, .pageNumbers, .nUp, .summarize, .dedupe, .splitVolumes, .sortFolder]

    /// Tools that run straight away with the last options used; their options open on request (⌥).
    /// The rest show their options first.
    public static func runsInstantly(_ tool: ToolKind, category: FormatCategory?) -> Bool {
        let parameters = parameters(for: tool, category: category)
        guard !parameters.contains(where: { $0.kind == .secure }) else { return false }
        if parameters.isEmpty || instantTools.contains(tool) { return true }
        return switch (tool, category) {
        case (.stripMetadata, .image?), (.split, .spreadsheet?), (.split, .document?): true
        default: false
        }
    }

    /// Tools whose options are picked on a playable preview of the first video.
    public static func previewsVideo(_ tool: ToolKind, category: FormatCategory?) -> Bool {
        category == .video && [.trim, .crop, .rotate, .changeSpeed, .makeGIF, .poster].contains(tool)
    }

    /// Tools whose options are picked on the first image, or the first page of the first PDF.
    public static func previewsStill(_ tool: ToolKind, category: FormatCategory?) -> Bool {
        switch category {
        case .image?: [.crop, .rotate, .blurFaces].contains(tool)
        case .pdf?: [.crop, .rotate, .sign].contains(tool)
        default: false
        }
    }

    /// Tools whose options are picked on a grid of the PDF's pages.
    public static func previewsPages(_ tool: ToolKind, category: FormatCategory?) -> Bool {
        category == .pdf && tool == .reorderPages
    }

    public static func dominantCategory(of formats: [FileFormat?]) -> FormatCategory? {
        var counts: [FormatCategory: Int] = [:]
        for case let format? in formats { counts[format.category, default: 0] += 1 }
        guard let best = counts.values.max() else { return nil }
        // A video wins a tie with its subtitles or music; otherwise the first file's category does.
        if counts[.video] == best { return .video }
        return formats.compactMap { $0?.category }.first { counts[$0] == best }
    }

    public static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    public static func applies(_ operation: Operation, to url: URL) -> Bool {
        let format = FileFormat.detect(url)
        switch operation {
        case .convert(let target):
            guard let format else { return false }
            return convertTargets(for: format).contains(target)
        case .tool(let tool):
            if let category = format?.category, companions(for: tool).contains(category) { return true }
            guard tools(for: format?.category).contains(tool) else { return false }
            if let allowed = formats(for: tool, category: format?.category) {
                guard let format, allowed.contains(format) else { return false }
            }
            if format == nil, folderTools.contains(tool) { return isFolder(url) }
            return true
        case .action:
            return true
        }
    }

    public static func wheel(_ kind: WheelKind, for urls: [URL]) -> Wheel {
        let detected = urls.map(FileFormat.detect)
        let category = dominantCategory(of: detected)
        let items: [WheelItem]
        switch kind {
        case .convert:
            var inputs: [FileFormat] = []
            for case let format? in detected where format.category == category && !inputs.contains(format) { inputs.append(format) }
            var targets: [FileFormat] = []
            for target in inputs.flatMap(convertTargets(for:)) where !targets.contains(target) { targets.append(target) }
            items = targets.map { target in
                let missing = inputs.lazy.compactMap { Engines.missingRequirement(for: .convert(target), input: $0) }.first
                return WheelItem(operation: .convert(target), title: target.displayName, symbol: symbol(for: target), unavailableReason: missing)
            }
        case .tools:
            let selected = detected.compactMap { $0 }.filter { $0.category == category }
            items = tools(for: category).map { tool in
                var missing = Engines.missingRequirement(for: .tool(tool), input: selected.first)
                if missing == nil, let allowed = formats(for: tool, category: category), !selected.contains(where: allowed.contains) {
                    missing = String(localized: "Only for \(ListFormatter.localizedString(byJoining: allowed.map(\.displayName).sorted())) files")
                }
                if missing == nil, category == nil, folderTools.contains(tool), !urls.contains(where: isFolder) {
                    missing = String(localized: "Only for folders")
                }
                return WheelItem(operation: .tool(tool), title: tool.title, symbol: tool.symbol, unavailableReason: missing)
            }
        case .actions:
            items = actions(for: category).map { action in
                WheelItem(operation: .action(action), title: action.title, symbol: action.symbol, unavailableReason: Engines.missingRequirement(for: .action(action), input: nil))
            }
        }
        return Wheel(kind: kind, items: items, subject: subject(urls, category: category), category: category)
    }

    static func subject(_ urls: [URL], category: FormatCategory?) -> String {
        guard urls.count != 1 else { return urls.first?.lastPathComponent ?? "" }
        let allSame = urls.allSatisfy { FileFormat.detect($0)?.category == category }
        let count = urls.count
        guard allSame, let category else { return String(localized: "\(count) items") }
        return switch category {
        case .image: String(localized: "\(count) images")
        case .video: String(localized: "\(count) videos")
        case .audio: String(localized: "\(count) audio files")
        case .pdf: String(localized: "\(count) PDFs")
        case .document: String(localized: "\(count) documents")
        case .slides: String(localized: "\(count) presentations")
        case .spreadsheet: String(localized: "\(count) spreadsheets")
        case .subtitle: String(localized: "\(count) subtitles")
        case .archive: String(localized: "\(count) archives")
        case .data: String(localized: "\(count) data files")
        case .font: String(localized: "\(count) fonts")
        case .model: String(localized: "\(count) 3D models")
        }
    }

    public static func symbol(for format: FileFormat) -> String {
        switch format.category {
        case .image:
            if format.isCameraRaw { "camera.aperture" } else if [.ico, .icns].contains(format) { "app" } else if format == .svg { "scribble.variable" } else { "photo" }
        case .video: format == .gif ? "photo.stack" : "film"
        case .audio:
            switch format {
            case .m4r: "bell"
            case .m4b: "book.closed"
            default: "music.note"
            }
        case .pdf: "doc.richtext"
        case .document:
            switch format {
            case .md: "number"
            case .txt: "text.alignleft"
            case .epub, .mobi, .azw3, .fb2: "book"
            case .html: "chevron.left.forwardslash.chevron.right"
            case .tex: "function"
            case .rst, .adoc, .org: "doc.plaintext"
            default: "doc.text"
            }
        case .slides: "rectangle.on.rectangle.angled"
        case .spreadsheet: format == .csv || format == .tsv ? "tablecells" : "tablecells.fill"
        case .subtitle: "captions.bubble"
        case .archive: format == .dmg ? "externaldrive" : "archivebox"
        case .data:
            switch format {
            case .xml: "chevron.left.forwardslash.chevron.right"
            case .plist: "list.bullet.indent"
            case .sqlite: "cylinder"
            case .vcf: "person.crop.rectangle.stack"
            case .ics: "calendar"
            default: "curlybraces"
            }
        case .font: "textformat"
        case .model: format == .usdz ? "arkit" : "cube"
        }
    }
}
