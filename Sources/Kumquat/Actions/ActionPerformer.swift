import AppKit
import CryptoKit
import ImageIO
import KumquatCore
import PDFKit
import Photos
import Quartz
import UniformTypeIdentifiers

/// The ⌃ wheel's actions: share, move and open files, copy what's in them, run automations. Never metered.
final class ActionPerformer: NSObject {
    private let basket: Basket
    private let jobs: JobCenter
    private let prompt: ParameterPrompt
    private let wifi = WiFiShare()
    /// Opens Settings on the Actions tab (favourite folders, scripts).
    var showSettings: () -> Void = {}
    /// What Quick Look shows; the app delegate hands it to the panel.
    private(set) var previewItems: [URL] = []
    private var shareAnchor: NSPanel?

    init(basket: Basket, jobs: JobCenter, prompt: ParameterPrompt) {
        self.basket = basket
        self.jobs = jobs
        self.prompt = prompt
    }

    func perform(_ action: ActionKind, files: [URL]) {
        guard !files.isEmpty else { return }
        let subject = Self.subject(files)
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                jobs.notice(String(localized: "AirDrop isn't available"), failed: true)
                return
            }
            NSApp.activate()
            service.perform(withItems: files)
        case .basket:
            basket.add(files)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(files as [NSURL])
            jobs.notice(String(localized: "Copied \(subject)"), detail: String(localized: "Paste in Finder or any app"))
        case .copyPath:
            copyText(files.map(\.path).joined(separator: "\n"),
                     title: files.count == 1 ? String(localized: "Copied path") : String(localized: "Copied paths"),
                     detail: files.count == 1 ? files[0].path : String(localized: "\(files.count) paths"))
        case .move:
            chooseFolder(for: files, moving: true)
        case .terminal:
            openTerminal(at: files)
        case .share:
            showSharePicker(files)
        case .quickLook:
            quickLook(files)
        case .openWith:
            openWith(files)
        case .copyContents:
            copyContents(files, subject: subject)
        case .rename:
            askRename(files)
        case .trash:
            trash(files, subject: subject)
        case .copyTo:
            chooseFolder(for: files, moving: false)
        case .duplicate:
            duplicate(files)
        case .newFolder:
            newFolder(with: files, subject: subject)
        case .tag:
            tagMenu(files)
        case .mail:
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else {
                jobs.notice(String(localized: "Mail isn't set up"), detail: String(localized: "Add an account in the Mail app first"), failed: true)
                return
            }
            NSApp.activate()
            service.perform(withItems: files)
        case .wifiShare:
            wifi.share(files) { [weak self] message in self?.jobs.notice(String(localized: "Can't share over Wi-Fi"), detail: message, failed: true) }
        case .print:
            print(files)
        case .wallpaper:
            setWallpaper(files)
        case .addToLibrary:
            addToLibrary(files)
        case .alias:
            makeAliases(files)
        case .checksum:
            checksum(files)
        case .base64:
            base64(files)
        case .markdownLink:
            let links = files.map { "[\($0.lastPathComponent)](\($0.absoluteString))" }.joined(separator: "\n")
            copyText(links, title: String(localized: "Copied Markdown link"), detail: subject)
        case .shortcut:
            shortcutMenu(files)
        case .script:
            scriptMenu(files)
        }
    }

    static func subject(_ files: [URL]) -> String {
        files.count == 1 ? "“\(files[0].lastPathComponent)”" : String(localized: "\(files.count) items")
    }

    private func copyText(_ text: String, title: String, detail: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        jobs.notice(title, detail: detail)
    }

    // MARK: - Menus (the sub-rings of Copy To, Tag, Open With, Shortcut, Script)

    /// Closure-backed menu item; the menu runs synchronously, so `items` keeps the handlers alive.
    private final class MenuHandler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    private struct MenuEntry {
        var title: String
        var image: NSImage?
        var state: NSControl.StateValue = .off
        var action: (() -> Void)?
        static let separator = MenuEntry(title: "-")
        static func header(_ title: String) -> MenuEntry { MenuEntry(title: title) }
    }

    private func popUp(_ entries: [MenuEntry]) {
        let menu = NSMenu()
        var handlers: [MenuHandler] = []
        for entry in entries {
            if entry.title == "-" {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.image = entry.image
            item.state = entry.state
            if let action = entry.action {
                let handler = MenuHandler(action)
                handlers.append(handler)
                item.target = handler
                item.action = #selector(MenuHandler.run)
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = handlers
    }

    private static func icon(_ url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Copy To / Move

    private func chooseFolder(for files: [URL], moving: Bool) {
        let favourites = Prefs.favoriteFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        let recents = Prefs.recentFolders.filter { recent in FileManager.default.fileExists(atPath: recent.path) && !favourites.contains(recent) }
        guard !favourites.isEmpty || !recents.isEmpty else {
            pickFolder(for: files, moving: moving)
            return
        }
        var entries: [MenuEntry] = [.header(moving ? String(localized: "Move to") : String(localized: "Copy to"))]
        for folder in favourites {
            entries.append(MenuEntry(title: folder.lastPathComponent, image: Self.icon(folder)) { [weak self] in self?.transfer(files, to: folder, moving: moving) })
        }
        if !recents.isEmpty {
            entries += [.separator, .header(String(localized: "Recent"))]
            for folder in recents {
                entries.append(MenuEntry(title: folder.lastPathComponent, image: Self.icon(folder)) { [weak self] in self?.transfer(files, to: folder, moving: moving) })
            }
        }
        entries += [.separator,
                    MenuEntry(title: String(localized: "Choose Folder…")) { [weak self] in self?.pickFolder(for: files, moving: moving) },
                    MenuEntry(title: String(localized: "Edit Favorites…")) { [weak self] in self?.showSettings() }]
        popUp(entries)
    }

    private func pickFolder(for files: [URL], moving: Bool) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = moving ? String(localized: "Move Here") : String(localized: "Copy Here")
        panel.message = moving ? String(localized: "Move \(Self.subject(files)) to…") : String(localized: "Copy \(Self.subject(files)) to…")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        transfer(files, to: folder, moving: moving)
    }

    private func transfer(_ files: [URL], to folder: URL, moving: Bool) {
        Prefs.rememberFolder(folder)
        var done: [URL] = []
        var failure: String?
        for file in files {
            let target = OutputNaming.unique(in: folder, name: file.lastPathComponent)
            do {
                if moving { try FileManager.default.moveItem(at: file, to: target) } else { try FileManager.default.copyItem(at: file, to: target) }
                done.append(target)
            } catch {
                failure = error.localizedDescription
            }
        }
        let doneSubject = Self.subject(done)
        let title = switch (moving, done.isEmpty) {
        case (true, false): String(localized: "Moved \(doneSubject)")
        case (false, false): String(localized: "Copied \(doneSubject)")
        case (true, true): String(localized: "Couldn't move \(Self.subject(files))")
        case (false, true): String(localized: "Couldn't copy \(Self.subject(files))")
        }
        jobs.notice(title, detail: failure ?? String(localized: "to \(folder.lastPathComponent)"), outputs: done, failed: done.isEmpty)
    }

    // MARK: - Open

    private func openTerminal(at files: [URL]) {
        var folders: [URL] = []
        for file in files {
            let folder = Catalog.isFolder(file) ? file : file.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Prefs.terminalApp)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let terminal else { return }
        NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func openWith(_ files: [URL]) {
        let first = files[0]
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: first)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred { apps = [preferred] + apps.filter { $0 != preferred } }
        var seen = Set<String>()
        apps = apps.filter { seen.insert(FileManager.default.displayName(atPath: $0.path)).inserted }
        guard !apps.isEmpty else {
            jobs.notice(String(localized: "No app opens \(Self.subject([first]))"), failed: true)
            return
        }
        var entries: [MenuEntry] = [.header(String(localized: "Open \(Self.subject(files)) with"))]
        for (index, app) in apps.prefix(24).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            entries.append(MenuEntry(title: index == 0 && preferred != nil ? String(localized: "\(name) (default)") : name, image: Self.icon(app)) {
                NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            })
            if index == 0, preferred != nil { entries.append(.separator) }
        }
        popUp(entries)
    }

    private func quickLook(_ files: [URL]) {
        previewItems = files
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    /// The system share sheet needs a view to point at: a tiny clear panel under the pointer.
    private func showSharePicker(_ files: [URL]) {
        shareAnchor?.close()
        let point = NSEvent.mouseLocation
        let anchor = NSPanel(contentRect: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.level = .popUpMenu
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        shareAnchor = anchor
        NSApp.activate()
        guard let view = anchor.contentView else { return }
        let picker = NSSharingServicePicker(items: files)
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func print(_ files: [URL]) {
        Task {
            do {
                let pdf = try await Self.printablePDF(files)
                guard let document = PDFDocument(url: pdf.url) else { throw KumquatError.cannotOpen(pdf.url.lastPathComponent) }
                NSApp.activate()
                guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
                    throw KumquatError.cannotOpen(pdf.url.lastPathComponent)
                }
                operation.jobTitle = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Kumquat"
                operation.run()
                if pdf.temporary { try? FileManager.default.removeItem(at: pdf.url) }
            } catch {
                jobs.notice(String(localized: "Can't print \(Self.subject(files))"), detail: error.localizedDescription, failed: true)
            }
        }
    }

    /// One PDF holding every printable file: PDFs as they are, pictures one per page, documents and sheets laid out.
    private static func printablePDF(_ files: [URL]) async throws -> (url: URL, temporary: Bool) {
        if files.count == 1, FileFormat.detect(files[0]) == .pdf { return (files[0], false) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kumquat Print \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var parts: [URL] = []
        for (index, file) in files.enumerated() {
            guard let format = FileFormat.detect(file) else { continue }
            let part = folder.appendingPathComponent("\(index).pdf")
            switch format.category {
            case .pdf: parts.append(file); continue
            case .image: try PDFEngine.imagesToPDF([file], output: part)
            case .document: try await DocumentEngine.convert(file, from: format, to: .pdf, output: part)
            case .spreadsheet: try await SheetEngine.convert(file, from: format, to: .pdf, output: part)
            default: continue
            }
            parts.append(part)
        }
        guard !parts.isEmpty else { throw KumquatError.noResult(String(localized: "Nothing here can be printed.")) }
        if parts.count == 1 { return (parts[0], parts[0].path.hasPrefix(folder.path)) }
        let merged = folder.appendingPathComponent("print.pdf")
        try PDFEngine.merge(parts, output: merged)
        return (merged, true)
    }

    private func setWallpaper(_ files: [URL]) {
        guard let image = files.first(where: { FileFormat.detect($0)?.category == .image }) else { return }
        do {
            for screen in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:]) }
            jobs.notice(String(localized: "Wallpaper set"), detail: image.lastPathComponent)
        } catch {
            jobs.notice(String(localized: "Can't set the wallpaper"), detail: error.localizedDescription, failed: true)
        }
    }

    private func addToLibrary(_ files: [URL]) {
        let media = files.filter { [.image, .video].contains(FileFormat.detect($0)?.category) }
        let audio = files.filter { FileFormat.detect($0)?.category == .audio }
        if !audio.isEmpty, let music = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(audio, withApplicationAt: music, configuration: configuration)
            jobs.notice(String(localized: "Added to Music"), detail: Self.subject(audio))
        }
        guard !media.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.jobs.notice(String(localized: "Kumquat can't add to Photos"),
                                     detail: String(localized: "Allow it in System Settings ▸ Privacy & Security ▸ Photos"), failed: true)
                    return
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for file in media {
                            if FileFormat.detect(file)?.category == .video {
                                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
                            } else {
                                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: file)
                            }
                        }
                    }
                    self.jobs.notice(String(localized: "Added to Photos"), detail: Self.subject(media))
                } catch {
                    self.jobs.notice(String(localized: "Couldn't add to Photos"), detail: error.localizedDescription, failed: true)
                }
            }
        }
    }

    // MARK: - Organise

    private func trash(_ files: [URL], subject: String) {
        NSWorkspace.shared.recycle(files) { [weak self] trashed, error in
            Task { @MainActor in
                if let error, trashed.isEmpty {
                    self?.jobs.notice(String(localized: "Couldn't move \(subject) to the Trash"), detail: error.localizedDescription, failed: true)
                } else {
                    self?.jobs.notice(String(localized: "Moved \(subject) to the Trash"), detail: String(localized: "Put Back from the Trash to undo"))
                }
            }
        }
    }

    private func duplicate(_ files: [URL]) {
        var copies: [URL] = []
        var failure: String?
        for file in files {
            let ext = file.pathExtension
            let stem = file.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty || Catalog.isFolder(file) ? String(localized: "\(file.lastPathComponent) copy") : String(localized: "\(stem) copy") + ".\(ext)"
            let target = OutputNaming.unique(in: file.deletingLastPathComponent(), name: name)
            do {
                try FileManager.default.copyItem(at: file, to: target)
                copies.append(target)
            } catch {
                failure = error.localizedDescription
            }
        }
        jobs.notice(copies.isEmpty ? String(localized: "Couldn't duplicate") : String(localized: "Duplicated \(Self.subject(files))"),
                    detail: failure ?? "", outputs: copies, failed: copies.isEmpty)
    }

    private func newFolder(with files: [URL], subject: String) {
        let parent = files[0].deletingLastPathComponent()
        let folder = OutputNaming.unique(in: parent, name: String(localized: "New Folder With Items"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for file in files { try FileManager.default.moveItem(at: file, to: OutputNaming.unique(in: folder, name: file.lastPathComponent)) }
            jobs.notice(String(localized: "Put \(subject) in a new folder"), detail: folder.lastPathComponent, outputs: [folder])
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            jobs.notice(String(localized: "Couldn't make the folder"), detail: error.localizedDescription, failed: true)
        }
    }

    private func makeAliases(_ files: [URL]) {
        var aliases: [URL] = []
        var failure: String?
        for file in files {
            let target = OutputNaming.unique(in: file.deletingLastPathComponent(), name: String(localized: "\(file.lastPathComponent) alias"))
            do {
                let data = try file.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: target)
                aliases.append(target)
            } catch {
                failure = error.localizedDescription
            }
        }
        jobs.notice(aliases.isEmpty ? String(localized: "Couldn't make an alias") : String(localized: "Made \(aliases.count) aliases"),
                    detail: failure ?? "", outputs: aliases, failed: aliases.isEmpty)
    }

    private func tagMenu(_ files: [URL]) {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        let current = files.map { Set((try? $0.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []) }
        var entries: [MenuEntry] = [.header(String(localized: "Tag \(Self.subject(files))"))]
        for index in labels.indices.dropFirst() where index < colors.count {
            let name = labels[index]
            let everyFile = current.allSatisfy { $0.contains(name) }
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                colors[index].setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            entries.append(MenuEntry(title: name, image: dot, state: everyFile ? .on : .off) { [weak self] in
                self?.setTag(name, on: !everyFile, files: files)
            })
        }
        popUp(entries)
    }

    private func setTag(_ name: String, on: Bool, files: [URL]) {
        for file in files {
            var tags = (try? file.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            tags.removeAll { $0 == name }
            if on { tags.append(name) }
            try? (file as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        jobs.notice(on ? String(localized: "Tagged \(Self.subject(files)) “\(name)”") : String(localized: "Removed “\(name)”"), outputs: files)
    }

    // MARK: Rename

    private func askRename(_ files: [URL]) {
        let parameters = [
            ToolParameter("pattern", "New name", default: files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "{name} {n}",
                          hint: "{name} {n} {date} {taken} — e.g. Holiday {n} → Holiday 01.jpg"),
            ToolParameter("start", "First number", default: "1", kind: .number),
        ]
        let values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.defaultValue) })
        prompt.ask(title: ActionKind.rename.title, subtitle: Self.subject(files), parameters: parameters, values: values, preview: nil,
                   at: NSEvent.mouseLocation) { [weak self] values in
            self?.rename(files, pattern: values["pattern"] ?? "{name}", start: Int(values["start"] ?? "") ?? 1)
        }
    }

    private func rename(_ files: [URL], pattern: String, start: Int) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let digits = max(2, String(start + files.count - 1).count)
        let days = DateFormatter()
        days.dateFormat = "yyyy-MM-dd"
        var renamed: [URL] = []
        var failure: String?
        for (index, file) in files.enumerated() {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let number = String(format: "%0\(digits)d", start + index)
            var name = trimmed
                .replacingOccurrences(of: "{name}", with: file.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: number)
                .replacingOccurrences(of: "{date}", with: days.string(from: created))
                .replacingOccurrences(of: "{taken}", with: days.string(from: Self.captureDate(file) ?? created))
            // Several files under one fixed name would collide: number them.
            if files.count > 1, !trimmed.contains("{n}"), !trimmed.contains("{name}") { name += " \(number)" }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let ext = Catalog.isFolder(file) ? "" : file.pathExtension
            let fullName = ext.isEmpty ? name : "\(name).\(ext)"
            guard fullName != file.lastPathComponent else { renamed.append(file); continue }
            let target = OutputNaming.unique(in: file.deletingLastPathComponent(), name: fullName)
            do {
                try FileManager.default.moveItem(at: file, to: target)
                renamed.append(target)
            } catch {
                failure = error.localizedDescription
            }
        }
        jobs.notice(renamed.isEmpty ? String(localized: "Couldn't rename") : String(localized: "Renamed \(Self.subject(renamed))"),
                    detail: failure ?? "", outputs: renamed, failed: renamed.isEmpty)
    }

    /// When a photo was taken, from its EXIF.
    private static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    // MARK: - Copy what's inside

    private func copyContents(_ files: [URL], subject: String) {
        let images = files.compactMap { FileFormat.detect($0)?.category == .image ? NSImage(contentsOf: $0) : nil }
        if !images.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(images)
            jobs.notice(images.count == 1 ? String(localized: "Copied the picture") : String(localized: "Copied \(images.count) pictures"),
                        detail: String(localized: "Paste it into a chat, a mail or a document"))
            return
        }
        Task {
            var texts: [String] = []
            for file in files {
                guard let text = try? await Self.text(of: file), !text.isEmpty else { continue }
                texts.append(text)
            }
            guard !texts.isEmpty else {
                jobs.notice(String(localized: "No text in \(subject)"), failed: true)
                return
            }
            let text = texts.joined(separator: "\n\n")
            copyText(text, title: String(localized: "Copied the text of \(subject)"),
                     detail: String(localized: "\(text.split(whereSeparator: \.isNewline).count) lines"))
        }
    }

    private static func text(of url: URL) async throws -> String {
        switch FileFormat.detect(url)?.category {
        case .pdf?: return PDFDocument(url: url)?.string ?? ""
        case .document?: return try await runBlocking { try DocumentEngine.readText(url) }
        default: return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func checksum(_ files: [URL]) {
        let regular = files.filter { !Catalog.isFolder($0) }
        guard !regular.isEmpty else { return }
        Task {
            do {
                let lines = try await runBlocking { try regular.map { "\(try Self.sha256($0))  \($0.lastPathComponent)" } }
                let text = regular.count == 1 ? String(lines[0].prefix(64)) : lines.joined(separator: "\n")
                copyText(text, title: String(localized: "Copied SHA-256"), detail: regular.count == 1 ? text : String(localized: "\(regular.count) files"))
            } catch {
                jobs.notice(String(localized: "Couldn't read \(Self.subject(regular))"), detail: error.localizedDescription, failed: true)
            }
        }
    }

    /// Streams the file in 4 MB chunks, so a large video never sits in memory whole.
    nonisolated private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func base64(_ files: [URL]) {
        let file = files[0]
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 10 << 20, !Catalog.isFolder(file), let data = try? Data(contentsOf: file) else {
            jobs.notice(String(localized: "Too big for Base64"), detail: String(localized: "Up to 10 MB"), failed: true)
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        copyText("data:\(mime);base64,\(data.base64EncodedString())", title: String(localized: "Copied as Base64"),
                 detail: String(localized: "\(file.lastPathComponent) as a data URI"))
    }

    // MARK: - Automations

    private func shortcutMenu(_ files: [URL]) {
        Task {
            let names = await Self.shortcutNames()
            guard !names.isEmpty else {
                jobs.notice(String(localized: "No shortcuts yet"), detail: String(localized: "Make one in the Shortcuts app"), failed: true)
                return
            }
            var entries: [MenuEntry] = [.header(String(localized: "Run a shortcut on \(Self.subject(files))"))]
            for name in names.prefix(40) {
                entries.append(MenuEntry(title: name) { [weak self] in self?.runShortcut(name, files: files) })
            }
            popUp(entries)
        }
    }

    nonisolated private static func shortcutNames() async -> [String] {
        let result = try? await ExternalTool.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), ["list"], timeout: 20)
        return String(decoding: result?.stdout ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func runShortcut(_ name: String, files: [URL]) {
        Task {
            do {
                try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/shortcuts"), ["run", name] + files.flatMap { ["--input-path", $0.path] }, timeout: 600)
                jobs.notice(String(localized: "Ran “\(name)”"), detail: Self.subject(files))
            } catch {
                jobs.notice(String(localized: "“\(name)” failed"), detail: error.localizedDescription, failed: true)
            }
        }
    }

    private func scriptMenu(_ files: [URL]) {
        let scripts = Prefs.scripts
        var entries: [MenuEntry] = [.header(String(localized: "Run a script on \(Self.subject(files))"))]
        for script in scripts {
            entries.append(MenuEntry(title: script.name) { [weak self] in self?.runScript(script, files: files) })
        }
        if scripts.isEmpty { entries.append(.header(String(localized: "No scripts yet"))) }
        entries += [.separator, MenuEntry(title: String(localized: "Edit Scripts…")) { [weak self] in self?.showSettings() }]
        popUp(entries)
    }

    /// The command runs in a login zsh; the files arrive as "$@" (and $KUMQUAT_FILES, one per line).
    private func runScript(_ script: Prefs.Script, files: [URL]) {
        Task {
            do {
                let list = "KUMQUAT_FILES=" + files.map(\.path).joined(separator: "\n")
                let result = try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/env"),
                                                          [list, "/bin/zsh", "-lc", script.command, "kumquat"] + files.map(\.path), timeout: 600)
                let output = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                jobs.notice(String(localized: "Ran “\(script.name)”"), detail: output.isEmpty ? Self.subject(files) : output,
                            outputs: files.filter { FileManager.default.fileExists(atPath: $0.path) })
            } catch {
                jobs.notice(String(localized: "“\(script.name)” failed"), detail: error.localizedDescription, failed: true)
            }
        }
    }
}

extension ActionPerformer: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            shareAnchor?.close()
            shareAnchor = nil
        }
    }
}

extension ActionPerformer: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewItems[index] as NSURL }
    }
}
