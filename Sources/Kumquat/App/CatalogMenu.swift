import AppKit
import KumquatCore

/// "All Actions", from the menu bar panel and the right-click menu: everything the three wheels can offer,
/// browsable by kind of file.
/// Hovering shows what an entry does; ones that need something installed are dimmed, with the reason.
/// Submenus are built as they open, so the status menu itself opens at once.
struct CatalogMenu {
    /// What an entry runs; its menu item's `representedObject`.
    struct Choice {
        let operation: KumquatCore.Operation
        let inputs: InputKind
    }

    /// Receives the chosen item.
    let target: AnyObject
    let action: Selector

    /// A section header, then Convert, Edit and Send; `icons` gives them the panel's wheel symbols, for a menu
    /// of their own (the right-click menu has no icons).
    func items(icons: Bool = false) -> [NSMenuItem] {
        var items = [NSMenuItem.sectionHeader(title: String(localized: "All Actions"))]
        for kind in WheelKind.allCases {
            items.append(submenuItem(kind.title, symbol: icons ? kind.symbol : nil, subtitle: Self.count(for: kind)) { menu in
                menu.addItem(Self.note(String(localized: "Runs on the files selected in Finder, or asks for them")))
                menu.addItem(.separator())
                switch kind {
                case .convert: fillConvert(menu)
                case .tools: fillEdit(menu)
                case .actions: fillSend(menu)
                }
            })
        }
        return items
    }

    private static func count(for kind: WheelKind) -> String {
        switch kind {
        case .convert: String(localized: "\(Catalog.conversionCount) conversions")
        case .tools: String(localized: "\(ToolKind.allCases.count) tools")
        case .actions: String(localized: "\(ActionKind.allCases.count) actions")
        }
    }

    // MARK: - The three catalogues

    /// Kind of file ▸ format ▸ what it can become.
    private func fillConvert(_ menu: NSMenu) {
        for category in FormatCategory.allCases {
            let sources = Catalog.convertSources(in: category)
            guard !sources.isEmpty else { continue }
            menu.addItem(submenuItem(category.folderName, symbol: category.symbol) { menu in
                for source in sources {
                    menu.addItem(submenuItem(source.displayName, symbol: Catalog.symbol(for: source)) { menu in
                        menu.addItem(.sectionHeader(title: String(localized: "Convert \(source.displayName) to")))
                        add(Catalog.convertTargets(for: source).map { target in
                            Entry(title: target.displayName, symbol: Catalog.symbol(for: target), tip: nil,
                                  choice: Choice(operation: .convert(target), inputs: .format(source)),
                                  unavailable: Engines.missingRequirement(for: .convert(target), input: source))
                        }, to: menu)
                    })
                }
            })
        }
    }

    /// Kind of file ▸ its tools; Lock and Zip, which every file gets, once at the end.
    private func fillEdit(_ menu: NSMenu) {
        let kinds = FormatCategory.allCases.map { Optional($0) } + [nil]
        for category in kinds where !Catalog.specificTools(for: category).isEmpty {
            menu.addItem(submenuItem(category?.folderName ?? String(localized: "Folders"), symbol: category?.symbol ?? "folder") { menu in
                let sample = FileFormat.allCases.first { $0.category == category }
                add(Catalog.specificTools(for: category).map { tool in
                    let limit = Catalog.formats(for: tool, category: category).map { Catalog.onlyFor($0.map(\.displayName).sorted()) }
                    return Entry(title: tool.title, symbol: tool.symbol, tip: [tool.summary(for: category), limit].compactMap { $0 }.joined(separator: "\n"),
                                 choice: Choice(operation: .tool(tool), inputs: category.map(InputKind.category) ?? .folder),
                                 unavailable: Engines.missingRequirement(for: .tool(tool), input: sample))
                }, to: menu)
            })
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Any File or Folder")))
        add(Catalog.anyFile.map { tool in
            Entry(title: tool.title, symbol: tool.symbol, tip: tool.summary(for: nil),
                  choice: Choice(operation: .tool(tool), inputs: .anything), unavailable: nil)
        }, to: menu)
    }

    /// The actions in related groups.
    private func fillSend(_ menu: NSMenu) {
        for (index, group) in Catalog.actionGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: group.title))
            add(group.actions.map { action in
                let kinds = FormatCategory.allCases.filter { Catalog.actions(for: $0).contains(action) }
                let limit = kinds.count < FormatCategory.allCases.count ? Catalog.onlyFor(kinds.map(\.title)) : nil
                return Entry(title: action.title, symbol: action.symbol, tip: [action.summary, limit].compactMap { $0 }.joined(separator: "\n"),
                             choice: Choice(operation: .action(action), inputs: .anything), unavailable: nil)
            }, to: menu)
        }
    }

    // MARK: - Items

    private struct Entry {
        let title: String
        let symbol: String
        let tip: String?
        let choice: Choice
        /// Why this Mac can't run it yet, e.g. "Needs FFmpeg — brew install ffmpeg".
        let unavailable: String?
    }

    /// Adds the entries, dimming those this Mac can't run yet. A reason they all share shows once, at the top;
    /// otherwise each dimmed entry shows its own underneath.
    private func add(_ entries: [Entry], to menu: NSMenu) {
        let shared = Set(entries.map(\.unavailable)).count == 1 ? entries.first?.unavailable : nil
        if let shared { menu.addItem(Self.note(shared, symbol: "exclamationmark.triangle")) }
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: entry.unavailable == nil ? action : nil, keyEquivalent: "")
            item.target = target
            item.representedObject = entry.choice
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            let tip = [entry.unavailable, entry.tip].compactMap { $0 }.joined(separator: "\n")
            item.toolTip = tip.isEmpty ? nil : tip
            if #available(macOS 14.4, *), shared == nil, let reason = entry.unavailable { item.subtitle = reason }
            menu.addItem(item)
        }
    }

    /// An item whose submenu is built the first time it opens. The item keeps the submenu's filler alive,
    /// since a menu only holds its delegate weakly.
    private func submenuItem(_ title: String, symbol: String? = nil, subtitle: String? = nil, fill: @escaping (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let filler = MenuFiller(title: title, fill: fill)
        item.representedObject = filler
        item.submenu = filler.menu
        if #available(macOS 14.4, *), let subtitle { item.subtitle = subtitle }
        return item
    }

    /// A line of explanation that can't be chosen.
    private static func note(_ text: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        return item
    }
}

/// A submenu and what fills it the first time it opens. It fills its own `menu`, not the one AppKit passes
/// in, so nothing nonisolated crosses into the main actor.
private final class MenuFiller: NSObject, NSMenuDelegate {
    let menu: NSMenu
    private var fill: ((NSMenu) -> Void)?

    init(title: String, fill: @escaping (NSMenu) -> Void) {
        menu = NSMenu(title: title)
        self.fill = fill
        super.init()
        menu.delegate = self
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { fillOnce() }
    }

    private func fillOnce() {
        guard let fill else { return }
        self.fill = nil
        fill(menu)
    }
}

/// Lets an open panel offer only the files a choice suits; folders stay open for browsing.
nonisolated final class OpenPanelFilter: NSObject, NSOpenSavePanelDelegate {
    private let accepts: @Sendable (URL) -> Bool

    init(accepts: @escaping @Sendable (URL) -> Bool) {
        self.accepts = accepts
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Catalog.isFolder(url) || accepts(url)
    }
}
