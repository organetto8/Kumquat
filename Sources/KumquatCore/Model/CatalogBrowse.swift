import Foundation

/// Which files an entry of the menu bar's catalogue is for.
public enum InputKind: Hashable, Sendable {
    /// Conversions from this format.
    case format(FileFormat)
    /// Tools for this kind of file, with the files they combine with (a video's subtitles or music).
    case category(FormatCategory)
    /// Tools for folders.
    case folder
    /// Lock, Zip and the Send actions: any file or folder they suit.
    case anything
}

/// The whole catalogue arranged for browsing, as the menu bar's Convert, Edit and Send menus list it.
/// Built from the same lists as the wheels, so anything new shows up in both.
extension Catalog {
    /// Formats of a kind that convert to something: those Kumquat also writes first, read-only ones after.
    public static func convertSources(in category: FormatCategory) -> [FileFormat] {
        let formats = FileFormat.allCases.filter { $0.category == category && !convertTargets(for: $0).isEmpty }
        return formats.filter { !$0.isInputOnly } + formats.filter(\.isInputOnly)
    }

    /// The Send actions in related groups; each action appears once.
    public static var actionGroups: [(title: String, actions: [ActionKind])] {
        [(String(localized: "Share with Others"), [.airDrop, .share, .mail, .wifiShare]),
         (String(localized: "Organize"), [.basket, .copyTo, .move, .duplicate, .newFolder, .rename, .tag, .alias, .trash]),
         (String(localized: "Clipboard"), [.copy, .copyPath, .copyContents, .markdownLink, .base64, .checksum]),
         (String(localized: "Open & Use"), [.quickLook, .openWith, .terminal, .print, .wallpaper, .addToLibrary]),
         (String(localized: "Automate"), [.shortcut, .script])]
    }

    /// Whether `url` is a file the entry for `operation` listed under `kind` works on.
    public static func accepts(_ url: URL, for operation: Operation, under kind: InputKind) -> Bool {
        let format = FileFormat.detect(url)
        if case .action(let action) = operation { return actions(for: format?.category).contains(action) }
        guard applies(operation, to: url) else { return false }
        switch kind {
        case .format(let source):
            return format == source
        case .category(let category):
            guard let own = format?.category else { return false }
            if case .tool(let tool) = operation, companions(for: tool).contains(own) { return true }
            return own == category
        case .folder:
            return format == nil
        case .anything:
            return true
        }
    }

    /// The files among `urls` an entry runs on: the ones it accepts, provided one of them is of its own
    /// kind (subtitles alone are no use to Add Subtitles).
    public static func inputs(among urls: [URL], for operation: Operation, under kind: InputKind) -> [URL] {
        let accepted = urls.filter { accepts($0, for: operation, under: kind) }
        guard case .category(let category) = kind else { return accepted }
        return accepted.contains { FileFormat.detect($0)?.category == category } ? accepted : []
    }
}
