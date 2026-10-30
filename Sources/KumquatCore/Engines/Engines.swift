import Foundation

/// Which engines exist on this Mac, and what each operation needs.
public enum Engines {
    public static var ffmpeg: URL? { ExternalTool.locate("ffmpeg") }
    public static var ffprobe: URL? { ExternalTool.locate("ffprobe") }
    public static var cwebp: URL? { ExternalTool.locate("cwebp") }
    public static var img2webp: URL? { ExternalTool.locate("img2webp") }
    public static var cjxl: URL? { ExternalTool.locate("cjxl") }
    public static var potrace: URL? { ExternalTool.locate("potrace") }
    public static var pandoc: URL? { ExternalTool.locate("pandoc") }
    public static var sevenZip: URL? { ExternalTool.locate("7zz") ?? ExternalTool.locate("7z") }
    public static var woff2Compress: URL? { ExternalTool.locate("woff2_compress") }
    public static var woff2Decompress: URL? { ExternalTool.locate("woff2_decompress") }
    public static var fonttools: URL? { ExternalTool.locate("fonttools") }
    public static var ebookConvert: URL? {
        ExternalTool.locate("ebook-convert") ?? ["/Applications/calibre.app", NSHomeDirectory() + "/Applications/calibre.app",
                                                 EnginePack.folder("calibre").appendingPathComponent("calibre.app").path]
            .map { URL(fileURLWithPath: $0 + "/Contents/MacOS/ebook-convert") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static var tar: URL { URL(fileURLWithPath: "/usr/bin/tar") }
    static var ditto: URL { URL(fileURLWithPath: "/usr/bin/ditto") }
    static var osascript: URL { URL(fileURLWithPath: "/usr/bin/osascript") }
    static var hdiutil: URL { URL(fileURLWithPath: "/usr/bin/hdiutil") }
    static var zip: URL { URL(fileURLWithPath: "/usr/bin/zip") }

    public enum App: String, Sendable, CaseIterable {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"

        public var isInstalled: Bool {
            ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].contains {
                FileManager.default.fileExists(atPath: "\($0)/\(rawValue).app")
            }
        }

        /// Its page in the Mac App Store, where it is free.
        public var appStoreURL: URL {
            let id = switch self {
            case .pages: 409201541
            case .keynote: 409183694
            case .numbers: 409203825
            }
            return URL(string: "macappstore://apps.apple.com/app/id\(id)")!
        }
    }

    public static let ffmpegHint = engineHint("FFmpeg")
    public static let webpHint = engineHint("cwebp")

    public static func appHint(_ app: App) -> String { String(localized: "Needs \(app.rawValue) (free on the App Store)") }

    /// Settings ▸ Engines installs every optional program with one click, Homebrew or not.
    static func engineHint(_ tool: String) -> String { String(localized: "Needs \(tool) — install it in Settings ▸ Engines") }

    /// Formats AVFoundation reads without FFmpeg (enough for transcription).
    static let nativeMedia: Set<FileFormat> = [.mp4, .mov, .m4a, .mp3, .wav, .aiff, .caf, .m4b, .m4r]

    public static func missingRequirement(for operation: Operation, input: FileFormat?) -> String? {
        switch operation {
        case .action:
            return nil
        case .tool(let tool):
            if tool == .translate, let reason = LanguageEngine.translationUnavailableReason { return reason }
            if tool == .summarize, let reason = LanguageEngine.summaryUnavailableReason { return reason }
            guard let input else { return nil }
            let category = input.category
            if (category == .video || category == .audio), !Catalog.anyFile.contains(tool), ffmpeg == nil { return ffmpegHint }
            if Catalog.markupFormats.contains(input), [.merge, .wordCount, .translate, .summarize, .split].contains(tool), pandoc == nil {
                return engineHint("pandoc")
            }
            return nil
        case .convert(let target):
            guard let input else { return nil }
            return convertRequirement(input, target)
        }
    }

    static func convertRequirement(_ input: FileFormat, _ target: FileFormat) -> String? {
        let media: Set<FormatCategory> = [.video, .audio]
        // Transcription and reading aloud run on the system's own speech engines.
        if media.contains(input.category), [.srt, .vtt, .txt].contains(target) {
            return ffmpeg == nil && !nativeMedia.contains(input) ? ffmpegHint : nil
        }
        if [.document, .pdf].contains(input.category), target == .m4a { return documentRequirement(input, .txt) }
        if input.category == .slides {
            if !App.keynote.isInstalled { return appHint(.keynote) }
            return target == .gif && ffmpeg == nil ? ffmpegHint : nil
        }
        if input.category == .image {
            switch target {
            case .webp: return cwebp == nil ? webpHint : nil
            case .jxl: return cjxl == nil ? engineHint("cjxl") : nil
            case .svg: return potrace == nil ? engineHint("potrace") : nil
            default: return nil
            }
        }
        if media.contains(input.category) || media.contains(target.category) {
            if ffmpeg == nil { return ffmpegHint }
            return target == .webp && img2webp == nil ? webpHint : nil
        }
        if input.category == .pdf, target == .webp { return cwebp == nil ? webpHint : nil }
        if input.category == .document { return documentRequirement(input, target) }
        if input.category == .font { return FontEngine.requirement(input, target) }
        if input.category == .model { return ModelEngine.canExport(target) ? nil : String(localized: "macOS can't write \(target.displayName) files") }
        if (input == .pages || target == .pages), !App.pages.isInstalled { return appHint(.pages) }
        if (input == .xls || input == .numbers), !App.numbers.isInstalled { return appHint(.numbers) }
        return nil
    }

    static func documentRequirement(_ input: FileFormat, _ target: FileFormat) -> String? {
        if Catalog.ebooks.contains(input) || Catalog.ebooks.contains(target) {
            return ebookConvert == nil ? engineHint("Calibre") : nil
        }
        if Catalog.markupFormats.contains(input) || Catalog.markupFormats.contains(target) {
            return pandoc == nil ? engineHint("pandoc") : nil
        }
        if (input == .pages || target == .pages), !App.pages.isInstalled { return appHint(.pages) }
        return nil
    }
}
