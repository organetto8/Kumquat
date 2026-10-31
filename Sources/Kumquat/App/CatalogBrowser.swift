import KumquatCore
import SwiftUI

/// All Actions as a page of the menu bar panel: Convert, Edit and Send by kind of file, down to each format,
/// tool and action, or found by typing. It takes the panel's place at the panel's size, so the panel never jumps.
struct CatalogBrowser: View {
    let choose: (CatalogMenu.Choice) -> Void
    /// Back to the panel's first page.
    let close: () -> Void

    @State private var path: [Page] = []
    @State private var query = ""
    @FocusState private var searching: Bool

    enum Page: Hashable {
        case wheel(WheelKind)
        case convert(FormatCategory)
        case source(FileFormat)
        case tools(FormatCategory?)
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider().padding(.horizontal, 12)
            ScrollView {
                content
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new page starts at the top.
            .id(isSearching ? nil : path)
            Divider().padding(.horizontal, 12)
            Text("Runs on the files selected in Finder, or asks for them")
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .task { searching = true }
    }

    // MARK: - Bar

    private var bar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Back")
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all actions", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    private var title: String {
        switch path.last {
        case nil: String(localized: "All Actions")
        case .wheel(let kind)?: kind.title
        case .convert(let category)?: "\(WheelKind.convert.title) · \(category.folderName)"
        case .source(let format)?: String(localized: "Convert \(format.displayName) to")
        case .tools(let category)?: "\(WheelKind.tools.title) · \(category?.folderName ?? String(localized: "Folders"))"
        }
    }

    private func back() {
        if isSearching {
            query = ""
        } else if path.isEmpty {
            close()
        } else {
            path.removeLast()
        }
    }

    // MARK: - Pages

    @ViewBuilder private var content: some View {
        if isSearching {
            results
        } else {
            switch path.last {
            case nil: wheels
            case .wheel(let kind)?: wheel(kind)
            case .convert(let category)?: sources(in: category)
            case .source(let format)?: targets(of: format)
            case .tools(let category)?: tools(for: category)
            }
        }
    }

    private var wheels: some View {
        VStack(spacing: 2) {
            ForEach(WheelKind.allCases) { kind in
                Button { path.append(.wheel(kind)) } label: {
                    BrowseRow(symbol: kind.symbol, title: kind.title, detail: CatalogMenu.count(for: kind), accent: true,
                              key: Prefs.modifier(for: kind).symbol, drills: true)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    @ViewBuilder private func wheel(_ kind: WheelKind) -> some View {
        switch kind {
        case .convert:
            VStack(spacing: 2) {
                ForEach(FormatCategory.allCases.filter { !Catalog.convertSources(in: $0).isEmpty }, id: \.self) { category in
                    drill(to: .convert(category), symbol: category.symbol, title: category.folderName,
                          detail: Self.preview(Catalog.convertSources(in: category).map(\.displayName)))
                }
            }
        case .tools:
            VStack(spacing: 2) {
                ForEach(CatalogMenu.toolKinds, id: \.self) { category in
                    drill(to: .tools(category), symbol: category?.symbol ?? "folder", title: category?.folderName ?? String(localized: "Folders"),
                          detail: Self.preview(Catalog.specificTools(for: category).map(\.title)))
                }
                section(String(localized: "Any File or Folder"))
                ForEach(Catalog.anyFile) { tool in
                    toolRow(tool, in: nil, inputs: .anything)
                }
            }
        case .actions:
            let groups = Catalog.actionGroups
            VStack(spacing: 2) {
                ForEach(groups.indices, id: \.self) { index in
                    section(groups[index].title)
                    ForEach(groups[index].actions) { action in
                        leaf(CatalogMenu.Choice(operation: .action(action), inputs: .anything), symbol: action.symbol, title: action.title,
                             detail: CatalogMenu.notes(for: action).joined(separator: " · "), unavailable: nil)
                    }
                }
            }
        }
    }

    private func sources(in category: FormatCategory) -> some View {
        VStack(spacing: 2) {
            ForEach(Catalog.convertSources(in: category), id: \.self) { format in
                drill(to: .source(format), symbol: Catalog.symbol(for: format), title: format.displayName,
                      detail: "→ " + Self.preview(Catalog.convertTargets(for: format).map(\.displayName)))
            }
        }
    }

    /// What a format can become, as tiles like the panel's wheels; what's missing is said underneath.
    private func targets(of format: FileFormat) -> some View {
        let targets = Catalog.convertTargets(for: format)
        let reasons = targets.map { Engines.missingRequirement(for: .convert($0), input: format) }
        let notes = Array(Set(reasons.compactMap { $0 })).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(targets.indices, id: \.self) { index in
                    FormatTile(format: targets[index], unavailable: reasons[index]) {
                        choose(CatalogMenu.Choice(operation: .convert(targets[index]), inputs: .format(format)))
                    }
                }
            }
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(4)
    }

    private func tools(for category: FormatCategory?) -> some View {
        VStack(spacing: 2) {
            ForEach(Catalog.specificTools(for: category)) { tool in
                toolRow(tool, in: category, inputs: category.map(InputKind.category) ?? .folder)
            }
        }
    }

    private var results: some View {
        let hits = Self.search(query)
        return LazyVStack(spacing: 2) {
            if hits.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(hits) { hit in
                leaf(hit.choice, symbol: hit.symbol, title: hit.title, detail: hit.detail,
                     unavailable: Engines.missingRequirement(for: hit.choice.operation, input: hit.input))
            }
        }
    }

    // MARK: - Rows

    private func drill(to page: Page, symbol: String, title: String, detail: String?) -> some View {
        Button { path.append(page) } label: {
            BrowseRow(symbol: symbol, title: title, detail: detail, drills: true)
        }
        .buttonStyle(RowButtonStyle())
    }

    private func toolRow(_ tool: ToolKind, in category: FormatCategory?, inputs: InputKind) -> some View {
        leaf(CatalogMenu.Choice(operation: .tool(tool), inputs: inputs), symbol: tool.symbol, title: tool.title,
             detail: CatalogMenu.notes(for: tool, in: category).joined(separator: " · "),
             unavailable: CatalogMenu.missing(tool, in: category))
    }

    private func leaf(_ choice: CatalogMenu.Choice, symbol: String, title: String, detail: String?, unavailable: String?) -> some View {
        Button { choose(choice) } label: {
            BrowseRow(symbol: symbol, title: title, detail: detail, unavailable: unavailable)
        }
        .buttonStyle(RowButtonStyle())
        .disabled(unavailable != nil)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// "JPG, PNG, WebP, HEIC, TIFF…"
    private static func preview(_ names: [String]) -> String {
        names.prefix(5).joined(separator: ", ") + (names.count > 5 ? "…" : "")
    }

    // MARK: - Search

    private struct Hit: Identifiable {
        let id: String
        let choice: CatalogMenu.Choice
        let symbol: String
        let title: String
        let detail: String
        /// The file kind availability is judged on.
        let input: FileFormat?
        let words: String
    }

    /// Every entry, built once: tools and actions first, since the conversions are many.
    private static let index: [Hit] = {
        var hits: [Hit] = []
        for category in CatalogMenu.toolKinds {
            let place = "\(WheelKind.tools.title) · \(category?.folderName ?? String(localized: "Folders"))"
            for tool in Catalog.specificTools(for: category) {
                let detail = ([place] + CatalogMenu.notes(for: tool, in: category)).joined(separator: " · ")
                hits.append(Hit(id: "tool.\(tool.rawValue).\(category?.rawValue ?? "folder")",
                                choice: CatalogMenu.Choice(operation: .tool(tool), inputs: category.map(InputKind.category) ?? .folder),
                                symbol: tool.symbol, title: tool.title, detail: detail, input: CatalogMenu.sample(of: category),
                                words: "\(tool.title) \(tool.rawValue) \(detail)"))
            }
        }
        for tool in Catalog.anyFile {
            let detail = ([WheelKind.tools.title] + CatalogMenu.notes(for: tool, in: nil)).joined(separator: " · ")
            hits.append(Hit(id: "tool.\(tool.rawValue).any", choice: CatalogMenu.Choice(operation: .tool(tool), inputs: .anything),
                            symbol: tool.symbol, title: tool.title, detail: detail, input: nil,
                            words: "\(tool.title) \(tool.rawValue) \(detail)"))
        }
        for action in ActionKind.allCases {
            let detail = ([WheelKind.actions.title] + CatalogMenu.notes(for: action)).joined(separator: " · ")
            hits.append(Hit(id: "action.\(action.rawValue)", choice: CatalogMenu.Choice(operation: .action(action), inputs: .anything),
                            symbol: action.symbol, title: action.title, detail: detail, input: nil,
                            words: "\(action.title) \(action.rawValue) \(detail)"))
        }
        for category in FormatCategory.allCases {
            for source in Catalog.convertSources(in: category) {
                for target in Catalog.convertTargets(for: source) {
                    let detail = "\(WheelKind.convert.title) · \(category.folderName)"
                    hits.append(Hit(id: "convert.\(source.rawValue).\(target.rawValue)",
                                    choice: CatalogMenu.Choice(operation: .convert(target), inputs: .format(source)),
                                    symbol: Catalog.symbol(for: target), title: "\(source.displayName) → \(target.displayName)",
                                    detail: detail, input: source,
                                    words: "\(source.displayName) \(source.rawValue) \(target.displayName) \(target.rawValue) \(detail)"))
                }
            }
        }
        return hits
    }()

    /// Entries holding every word typed, in any case or accent.
    private static func search(_ query: String) -> [Hit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(index.lazy.filter { hit in terms.allSatisfy { hit.words.localizedStandardContains($0) } }.prefix(80))
    }
}

/// A row of the browser, drawn like the panel's own rows.
private struct BrowseRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    /// The orange of the wheel tiles, for Convert, Edit and Send.
    var accent = false
    var key: String? = nil
    var drills = false
    /// Why it can't run on this Mac yet; shown in place of the detail.
    var unavailable: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent ? Color.orange : Color.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(accent ? Color.orange.opacity(0.15) : Color.primary.opacity(0.07)))
                .opacity(unavailable == nil ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(unavailable == nil ? Color.primary : Color.secondary)
                if let note = unavailable ?? detail {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let key { KeyCap(text: key) }
            if drills {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A format to convert to, drawn like the panel's wheel tiles.
private struct FormatTile: View {
    let format: FileFormat
    let unavailable: String?
    let action: () -> Void
    @State private var hovering = false

    private var lit: Bool { hovering && unavailable == nil }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: Catalog.symbol(for: format))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lit ? Color.white : Color.orange)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(lit ? Color.orange : Color.orange.opacity(0.15)))
                Text(format.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(lit ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(unavailable == nil ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: lit)
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .onHover { hovering = $0 }
        .help(unavailable ?? String(localized: "Convert to \(format.displayName)"))
    }
}
