import Foundation

public enum FormatCategory: String, Sendable, CaseIterable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, data, font, model

    public var title: String {
        switch self {
        case .image: String(localized: "Image")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .pdf: String(localized: "PDF")
        case .document: String(localized: "Document")
        case .slides: String(localized: "Slides")
        case .spreadsheet: String(localized: "Spreadsheet")
        case .subtitle: String(localized: "Subtitles")
        case .archive: String(localized: "Archive")
        case .data: String(localized: "Data")
        case .font: String(localized: "Font")
        case .model: String(localized: "3D Model")
        }
    }

    /// Name of the folder Sort puts this kind of file in.
    public var folderName: String {
        switch self {
        case .image: String(localized: "Images")
        case .video: String(localized: "Videos")
        case .audio: String(localized: "Audio")
        case .pdf: String(localized: "PDFs")
        case .document: String(localized: "Documents")
        case .slides: String(localized: "Presentations")
        case .spreadsheet: String(localized: "Spreadsheets")
        case .subtitle: String(localized: "Subtitles")
        case .archive: String(localized: "Archives")
        case .data: String(localized: "Data")
        case .font: String(localized: "Fonts")
        case .model: String(localized: "3D Models")
        }
    }
}

public enum FileFormat: String, Sendable, CaseIterable, Identifiable {
    case jpg, png, webp, heic, tiff, avif, bmp, svg, ico, icns, jxl, jp2, psd, tga, exr
    case dng, cr2, cr3, nef, arw, raf, orf, rw2
    case mp4, mov, mkv, webm, avi, wmv, gif, mts, ts, mpg, vob, threeGP = "3gp", flv, ogv
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma, m4b, caf, ac3, m4r, amr
    case pdf
    case docx, doc, odt, pages, md, txt, epub, rtf, rtfd, textClipping, html, tex, rst, adoc, org, mobi, azw3, fb2
    case pptx, ppt, key
    case xlsx, xls, ods, csv, tsv, numbers
    case srt, vtt, ass, sbv, ttml, lrc
    case zip, tar, gzip, xz, bz2, sevenZip = "7z", dmg, rar
    case json, yaml, xml, plist, toml, sqlite, vcf, ics
    case ttf, otf, woff, woff2
    case obj, stl, ply, usdz, usda, usdc

    public var id: String { rawValue }

    public var category: FormatCategory {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .svg, .ico, .icns, .jxl, .jp2, .psd, .tga, .exr,
             .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2: .image
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mts, .ts, .mpg, .vob, .threeGP, .flv, .ogv: .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma, .m4b, .caf, .ac3, .m4r, .amr: .audio
        case .pdf: .pdf
        case .docx, .doc, .odt, .pages, .md, .txt, .epub, .rtf, .rtfd, .textClipping, .html, .tex, .rst, .adoc, .org, .mobi, .azw3, .fb2: .document
        case .pptx, .ppt, .key: .slides
        case .xlsx, .xls, .ods, .csv, .tsv, .numbers: .spreadsheet
        case .srt, .vtt, .ass, .sbv, .ttml, .lrc: .subtitle
        case .zip, .tar, .gzip, .xz, .bz2, .sevenZip, .dmg, .rar: .archive
        case .json, .yaml, .xml, .plist, .toml, .sqlite, .vcf, .ics: .data
        case .ttf, .otf, .woff, .woff2: .font
        case .obj, .stl, .ply, .usdz, .usda, .usdc: .model
        }
    }

    /// Camera raw files, decoded by the system's RAW engine.
    public var isCameraRaw: Bool { [.dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2].contains(self) }

    public var displayName: String {
        switch self {
        case .webp: "WebP"
        case .webm: "WebM"
        case .opus: "Opus"
        case .pages: "Pages"
        case .md: "Markdown"
        case .textClipping: String(localized: "Clipping")
        case .key: "Keynote"
        case .numbers: "Numbers"
        case .gzip: "GZIP"
        case .jxl: "JPEG XL"
        case .jp2: "JPEG 2000"
        case .m4r: String(localized: "Ringtone")
        case .tex: "LaTeX"
        case .rst: "reST"
        case .adoc: "AsciiDoc"
        case .org: "Org"
        case .bz2: "BZIP2"
        case .plist: "Plist"
        case .sqlite: "SQLite"
        case .vcf: "vCard"
        case .ics: "iCal"
        case .usda: "USD"
        case .usdc: "USDC"
        default: rawValue.uppercased()
        }
    }

    public var fileExtension: String {
        switch self {
        case .gzip: "tar.gz"
        case .xz: "tar.xz"
        case .bz2: "tar.bz2"
        case .textClipping: "textClipping"
        default: rawValue
        }
    }

    private static let extensions: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in FileFormat.allCases { map[format.rawValue] = format }
        let aliases: [String: FileFormat] = [
            "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg, "heif": .heic, "tif": .tiff, "j2k": .jp2, "jpf": .jp2, "jpx": .jp2,
            "m4v": .mp4, "qt": .mov, "m2ts": .mts, "mpeg": .mpg, "m2v": .mpg, "3g2": .threeGP,
            "aac": .m4a, "oga": .ogg, "aif": .aiff, "aifc": .aiff,
            "docm": .docx, "dotx": .docx, "dot": .doc, "markdown": .md, "mdown": .md, "text": .txt,
            "textclipping": .textClipping, "htm": .html, "xhtml": .html, "latex": .tex, "asciidoc": .adoc, "azw": .azw3,
            "ppsx": .pptx, "potx": .pptx, "pps": .ppt, "xlsm": .xlsx, "tab": .tsv,
            "ssa": .ass, "dfxp": .ttml,
            "tgz": .gzip, "gz": .gzip, "txz": .xz, "tbz": .bz2, "tbz2": .bz2,
            "yml": .yaml, "sqlite3": .sqlite, "vcard": .vcf, "ical": .ics, "ifb": .ics,
            "usd": .usdc,
        ]
        map.merge(aliases) { current, _ in current }
        map["gzip"] = nil
        map["threeGP"] = nil
        map["sevenZip"] = nil
        return map
    }()

    /// Format from the file name; `nil` for folders and unknown files.
    public static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .gzip }
        if name.hasSuffix(".tar.xz") { return .xz }
        if name.hasSuffix(".tar.bz2") { return .bz2 }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        // .ts is also TypeScript: only an MPEG transport stream starts with the 0x47 sync byte.
        if ext == "ts" { return isTransportStream(url) ? .ts : nil }
        return extensions[ext]
    }

    static func isTransportStream(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 189), bytes.count == 189 else { return false }
        return bytes[bytes.startIndex] == 0x47 && bytes[bytes.startIndex + 188] == 0x47
    }

    /// Formats the system can only read (the matrix never offers them as targets).
    public var isInputOnly: Bool {
        [.rtfd, .textClipping, .ppt, .xls, .numbers, .rar, .psd, .tga, .exr, .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2,
         .mts, .ts, .mpg, .vob, .threeGP, .flv, .ogv, .amr, .fb2, .usdc].contains(self)
    }
}
