import Foundation

/// The optional programs Kumquat can install, in the order the setup window and Settings ▸ Engines list
/// them. The raw value is the engine pack's name for it, which is also its Homebrew name.
public enum Engine: String, CaseIterable, Identifiable, Sendable {
    case ffmpeg, webp, jpegXL = "jpeg-xl", potrace, sevenZip = "sevenzip", woff2, pandoc, fonttools, calibre

    /// How the setup window groups them, and which ones it ticks to begin with.
    public enum Group: CaseIterable, Sendable {
        /// Small, and used by everyday formats: ticked.
        case recommended
        /// For less common document and font formats.
        case documents
        /// Hundreds of megabytes.
        case large
    }

    public var id: String { rawValue }

    public var group: Group {
        switch self {
        case .ffmpeg, .webp, .jpegXL, .potrace, .sevenZip, .woff2: .recommended
        case .pandoc, .fonttools: .documents
        case .calibre: .large
        }
    }

    /// What it adds to Kumquat.
    public var title: String {
        switch self {
        case .ffmpeg: String(localized: "Audio & video")
        case .webp: String(localized: "WebP output")
        case .jpegXL: String(localized: "JPEG XL output")
        case .potrace: String(localized: "Pictures to SVG")
        case .sevenZip: String(localized: "7-Zip archives")
        case .woff2: String(localized: "WOFF2 web fonts")
        case .pandoc: String(localized: "LaTeX, reST, AsciiDoc, Org")
        case .fonttools: String(localized: "TrueType ↔ OpenType outlines")
        case .calibre: String(localized: "Kindle e-books")
        }
    }

    /// What it lets Kumquat do, in a line.
    public var purpose: String {
        switch self {
        case .ffmpeg: String(localized: "Convert, trim and compress video and audio, and make GIFs")
        case .webp: String(localized: "Save pictures and animations as WebP")
        case .jpegXL: String(localized: "Save pictures as JPEG XL")
        case .potrace: String(localized: "Trace pictures into SVG drawings")
        case .sevenZip: String(localized: "Make and open 7z archives")
        case .woff2: String(localized: "Turn fonts into WOFF2 web fonts and back")
        case .pandoc: String(localized: "Convert LaTeX, reST, AsciiDoc and Org documents")
        case .fonttools: String(localized: "Switch fonts between TrueType and OpenType outlines")
        case .calibre: String(localized: "Convert MOBI and AZW3 e-books")
        }
    }

    public var package: Homebrew.Package { self == .calibre ? .cask(rawValue) : .formula(rawValue) }

    /// Where it was found, or nil while it's missing.
    public var location: URL? {
        switch self {
        case .ffmpeg: Engines.ffmpeg
        case .webp: Engines.cwebp
        case .jpegXL: Engines.cjxl
        case .potrace: Engines.potrace
        case .sevenZip: Engines.sevenZip
        case .woff2: Engines.woff2Compress
        case .pandoc: Engines.pandoc
        case .fonttools: Engines.fonttools
        case .calibre: Engines.ebookConvert
        }
    }

    /// The engine pack's download for this Mac, if it has one.
    public var asset: EnginePack.Asset? { EnginePack.asset(for: rawValue) }

    /// Whether Install can do anything for it on this Mac: from the pack, or with Homebrew.
    public var canInstall: Bool { asset != nil || Homebrew.brew != nil }

    /// Found in the pack's folder, but unpacked from an older pack than the one this app installs from.
    /// A Homebrew copy found first is the one Kumquat runs, so updating the pack's would change nothing.
    public var needsUpdate: Bool {
        guard let location, EnginePack.contains(location), asset != nil else { return false }
        return EnginePack.installedRelease(rawValue) != EnginePack.release
    }
}
