import Foundation

/// The three wheels, opened by tapping a modifier while dragging.
public enum WheelKind: String, Sendable, CaseIterable, Identifiable {
    case convert, tools, actions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .convert: String(localized: "Convert")
        case .tools: String(localized: "Edit")
        case .actions: String(localized: "Send")
        }
    }
}

public enum ToolKind: String, Sendable, CaseIterable, Identifiable {
    case compress, crop, trim, split, merge, resize, rotate, flip
    case removeBackground, stripMetadata, recognizeText, readQRCode
    case mute, extractAudio, changeSpeed, extractFrames, makeGIF, normalizeVolume, adjustVolume
    case extractPages, password, watermark, shiftTiming, extract, archive, encryptArchive
    // Images
    case scanDocument, blurFaces, frame, enhance, filter, palette, iconSet, autoTag
    // Video & audio
    case vertical, addSubtitles, extractSubtitles, contactSheet, poster, replaceAudio, reverse, fade, stabilize
    case removeSilence, denoise, tags, waveform, channels
    // PDF
    case reorderPages, sign, redact, pageNumbers, flatten, nUp, extractImages, grayscale
    // Text
    case wordCount, findReplace, clean, translate, summarize, extractNotes
    // Spreadsheets & subtitles
    case csvExcel, dedupe, columnStats, transpose, changeFPS
    // Archives, folders, any file
    case splitVolumes, verify, lock, sortFolder, findDuplicates, listFiles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compress: String(localized: "Compress")
        case .crop: String(localized: "Crop")
        case .trim: String(localized: "Trim")
        case .split: String(localized: "Split")
        case .merge: String(localized: "Merge")
        case .resize: String(localized: "Resize")
        case .rotate: String(localized: "Rotate")
        case .flip: String(localized: "Flip")
        case .removeBackground: String(localized: "Remove BG")
        case .stripMetadata: String(localized: "Strip Metadata")
        case .recognizeText: String(localized: "OCR")
        case .readQRCode: String(localized: "Read QR")
        case .mute: String(localized: "Mute")
        case .extractAudio: String(localized: "Extract Audio")
        case .changeSpeed: String(localized: "Speed")
        case .extractFrames: String(localized: "Frames")
        case .makeGIF: String(localized: "Make GIF")
        case .normalizeVolume: String(localized: "Normalize")
        case .adjustVolume: String(localized: "Volume")
        case .extractPages: String(localized: "Extract Pages")
        case .password: String(localized: "Password")
        case .watermark: String(localized: "Watermark")
        case .shiftTiming: String(localized: "Shift Timing")
        case .extract: String(localized: "Extract")
        case .archive: String(localized: "Zip")
        case .encryptArchive: String(localized: "Encrypt")
        case .scanDocument: String(localized: "Scan")
        case .blurFaces: String(localized: "Blur Faces")
        case .frame: String(localized: "Frame")
        case .enhance: String(localized: "Enhance")
        case .filter: String(localized: "Filters")
        case .palette: String(localized: "Palette")
        case .iconSet: String(localized: "Icon Set")
        case .autoTag: String(localized: "Auto Tag")
        case .vertical: String(localized: "Vertical")
        case .addSubtitles: String(localized: "Subtitles")
        case .extractSubtitles: String(localized: "Get Subtitles")
        case .contactSheet: String(localized: "Contact Sheet")
        case .poster: String(localized: "Poster")
        case .replaceAudio: String(localized: "Soundtrack")
        case .reverse: String(localized: "Reverse")
        case .fade: String(localized: "Fade")
        case .stabilize: String(localized: "Stabilize")
        case .removeSilence: String(localized: "Cut Silence")
        case .denoise: String(localized: "Denoise")
        case .tags: String(localized: "Tags")
        case .waveform: String(localized: "Waveform")
        case .channels: String(localized: "Channels")
        case .reorderPages: String(localized: "Pages")
        case .sign: String(localized: "Sign")
        case .redact: String(localized: "Redact")
        case .pageNumbers: String(localized: "Page Numbers")
        case .flatten: String(localized: "Flatten")
        case .nUp: String(localized: "2-Up")
        case .extractImages: String(localized: "Get Images")
        case .grayscale: String(localized: "Grayscale")
        case .wordCount: String(localized: "Word Count")
        case .findReplace: String(localized: "Replace")
        case .clean: String(localized: "Clean")
        case .translate: String(localized: "Translate")
        case .summarize: String(localized: "Summarize")
        case .extractNotes: String(localized: "Notes & Media")
        case .csvExcel: String(localized: "Excel CSV")
        case .dedupe: String(localized: "Dedupe")
        case .columnStats: String(localized: "Column Stats")
        case .transpose: String(localized: "Transpose")
        case .changeFPS: String(localized: "Frame Rate")
        case .splitVolumes: String(localized: "Volumes")
        case .verify: String(localized: "Verify")
        case .lock: String(localized: "Lock")
        case .sortFolder: String(localized: "Sort")
        case .findDuplicates: String(localized: "Duplicates")
        case .listFiles: String(localized: "File List")
        }
    }

    public var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .crop: "crop"
        case .trim: "scissors"
        case .split: "square.split.2x1"
        case .merge: "square.stack.3d.up"
        case .resize: "arrow.up.left.and.down.right.magnifyingglass"
        case .rotate: "rotate.right"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .removeBackground: "person.crop.rectangle"
        case .stripMetadata: "eye.slash"
        case .recognizeText: "text.viewfinder"
        case .readQRCode: "qrcode.viewfinder"
        case .mute: "speaker.slash"
        case .extractAudio: "waveform"
        case .changeSpeed: "gauge.with.dots.needle.67percent"
        case .extractFrames: "film.stack"
        case .makeGIF: "photo.stack"
        case .normalizeVolume: "waveform.badge.magnifyingglass"
        case .adjustVolume: "speaker.wave.3"
        case .extractPages: "doc.on.doc"
        case .password: "lock"
        case .watermark: "signature"
        case .shiftTiming: "clock.arrow.2.circlepath"
        case .extract: "shippingbox.and.arrow.backward"
        case .archive: "archivebox"
        case .encryptArchive: "lock.rectangle.stack"
        case .scanDocument: "doc.viewfinder"
        case .blurFaces: "face.dashed"
        case .frame: "rectangle.inset.filled"
        case .enhance: "wand.and.stars"
        case .filter: "camera.filters"
        case .palette: "paintpalette"
        case .iconSet: "app.badge"
        case .autoTag: "tag"
        case .vertical: "rectangle.portrait"
        case .addSubtitles: "captions.bubble"
        case .extractSubtitles: "text.bubble"
        case .contactSheet: "square.grid.3x3"
        case .poster: "photo.on.rectangle"
        case .replaceAudio: "music.note"
        case .reverse: "backward"
        case .fade: "circle.lefthalf.filled"
        case .stabilize: "camera.metering.center.weighted"
        case .removeSilence: "waveform.path.badge.minus"
        case .denoise: "wand.and.rays"
        case .tags: "music.note.list"
        case .waveform: "waveform.path.ecg"
        case .channels: "hifispeaker.2"
        case .reorderPages: "rectangle.grid.2x2"
        case .sign: "pencil.and.scribble"
        case .redact: "highlighter"
        case .pageNumbers: "number"
        case .flatten: "square.3.layers.3d.down.right"
        case .nUp: "rectangle.split.2x1"
        case .extractImages: "photo.on.rectangle.angled"
        case .grayscale: "drop.halffull"
        case .wordCount: "textformat.123"
        case .findReplace: "magnifyingglass"
        case .clean: "sparkles"
        case .translate: "translate"
        case .summarize: "text.append"
        case .extractNotes: "note.text"
        case .csvExcel: "tablecells.badge.ellipsis"
        case .dedupe: "line.3.horizontal.decrease"
        case .columnStats: "chart.bar.doc.horizontal"
        case .transpose: "arrow.triangle.swap"
        case .changeFPS: "film"
        case .splitVolumes: "square.split.1x2"
        case .verify: "checkmark.seal"
        case .lock: "lock.shield"
        case .sortFolder: "folder.badge.gearshape"
        case .findDuplicates: "doc.on.doc.fill"
        case .listFiles: "list.bullet.rectangle"
        }
    }

    /// Tools that run once over every dropped file (a merge, or a video plus its subtitles, music or cover).
    public var combinesInputs: Bool { [.merge, .addSubtitles, .replaceAudio, .tags].contains(self) }
}

public enum ActionKind: String, Sendable, CaseIterable, Identifiable {
    case airDrop, basket, copy, move, copyPath, terminal
    case share, quickLook, openWith, copyContents, rename, trash, copyTo, duplicate, newFolder, tag
    case mail, wifiShare, print, wallpaper, addToLibrary, alias, checksum, base64, markdownLink, shortcut, script

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .airDrop: String(localized: "AirDrop")
        case .basket: String(localized: "Basket")
        case .copy: String(localized: "Copy")
        case .move: String(localized: "Move")
        case .copyPath: String(localized: "Copy Path")
        case .terminal: String(localized: "Terminal")
        case .share: String(localized: "Share")
        case .quickLook: String(localized: "Quick Look")
        case .openWith: String(localized: "Open With")
        case .copyContents: String(localized: "Copy Contents")
        case .rename: String(localized: "Rename")
        case .trash: String(localized: "Trash")
        case .copyTo: String(localized: "Copy To")
        case .duplicate: String(localized: "Duplicate")
        case .newFolder: String(localized: "New Folder")
        case .tag: String(localized: "Tag")
        case .mail: String(localized: "Mail")
        case .wifiShare: String(localized: "Wi-Fi Share")
        case .print: String(localized: "Print")
        case .wallpaper: String(localized: "Wallpaper")
        case .addToLibrary: String(localized: "Add to Library")
        case .alias: String(localized: "Alias")
        case .checksum: String(localized: "Checksum")
        case .base64: String(localized: "Base64")
        case .markdownLink: String(localized: "Markdown Link")
        case .shortcut: String(localized: "Shortcut")
        case .script: String(localized: "Script")
        }
    }

    public var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .basket: "basket"
        case .copy: "doc.on.clipboard"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        case .share: "square.and.arrow.up"
        case .quickLook: "eye"
        case .openWith: "arrow.up.forward.app"
        case .copyContents: "doc.richtext"
        case .rename: "pencil"
        case .trash: "trash"
        case .copyTo: "folder.badge.plus"
        case .duplicate: "plus.square.on.square"
        case .newFolder: "folder.badge.questionmark"
        case .tag: "tag.circle"
        case .mail: "envelope"
        case .wifiShare: "qrcode"
        case .print: "printer"
        case .wallpaper: "photo.artframe"
        case .addToLibrary: "photo.on.rectangle.angled"
        case .alias: "arrowshape.turn.up.right"
        case .checksum: "number.square"
        case .base64: "chevron.left.forwardslash.chevron.right"
        case .markdownLink: "link.badge.plus"
        case .shortcut: "square.stack.3d.forward.dottedline"
        case .script: "applescript"
        }
    }
}

public enum Operation: Sendable, Hashable {
    case convert(FileFormat)
    case tool(ToolKind)
    case action(ActionKind)

    public var title: String {
        switch self {
        case .convert(let format): format.displayName
        case .tool(let tool): tool.title
        case .action(let action): action.title
        }
    }
}

/// A value the user confirms before a tool runs (pre-filled so Enter applies at once).
public struct ToolParameter: Sendable, Hashable, Identifiable {
    public struct Option: Sendable, Hashable {
        public let value: String
        public let label: String

        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Kind: Sendable, Hashable {
        case text, number, secure
        /// A continuous value; `presets` show as one-click chips under the slider.
        case slider(range: ClosedRange<Double>, step: Double, unit: String, presets: [Double] = [])
        case choice([Option])
        /// A position in a clip ("1:05.5"); the video preview drives it with timeline handles.
        case time
        /// The area to keep as normalised "x:y:w:h" (0…1, top-left origin), drawn on the preview.
        case region
        /// PDF page order picked on a grid of thumbnails ("3,1,2r90": 1-based, `r` = extra clockwise turn).
        case pages
        /// Path of the signature image the user drew or imported once.
        case signature
    }

    public let key: String
    public let label: String
    public let defaultValue: String
    public let kind: Kind
    public let hint: String
    /// Only makes sense for the file it was picked on (e.g. how far to straighten a photo).
    public let perFile: Bool

    public var id: String { key }

    public init(_ key: String, _ label: String.LocalizationValue, default defaultValue: String, kind: Kind = .text,
                hint: String.LocalizationValue? = nil, perFile: Bool = false) {
        self.key = key
        self.label = String(localized: label)
        self.defaultValue = defaultValue
        self.kind = kind
        self.hint = hint.map { String(localized: $0) } ?? ""
        self.perFile = perFile
    }

    /// Whether the last value is offered again next time. Secrets never are, and neither are
    /// values that only make sense for the file they were picked on.
    public var remembers: Bool {
        switch kind {
        case .secure, .time, .region, .pages: false
        default: !perFile
        }
    }

    /// Whether `value` is still valid, e.g. a remembered choice that a newer version dropped.
    public func accepts(_ value: String) -> Bool {
        switch kind {
        case .choice(let options):
            return options.contains { $0.value == value }
        case .slider(let range, _, _, _):
            guard let number = Double(value) else { return false }
            return range.contains(number)
        default:
            return true
        }
    }
}
