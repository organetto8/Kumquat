import CryptoKit
import Foundation

/// Tools for folders (and Lock, for anything): encrypted disk images, sorting, duplicates, flattening, file lists.
/// Nothing here deletes a file: sorting, flattening and de-duplicating only move files within the folder.
public enum FolderEngine {
    /// AES-256 encrypted, compressed disk image holding `items`; opens on any Mac with the password.
    /// The items are cloned (instant on APFS) into a staging folder on the image's volume; a single
    /// plain folder is imaged directly. The password reaches hdiutil on stdin, never in its arguments.
    public static func lock(_ items: [URL], password: String, output: URL) async throws {
        guard !password.isEmpty else { throw KumquatError.noResult(String(localized: "Enter a password.")) }
        let volumeName = output.deletingPathExtension().lastPathComponent
        if items.count == 1, isPlainFolder(items[0]) {
            try await DiskImage.create(from: items[0], volumeName: volumeName, password: password, output: output)
            return
        }
        let staging = try stagingFolder(near: output)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await runBlocking {
            for item in items {
                try clone(item, to: OutputNaming.unique(in: staging, name: item.lastPathComponent))
            }
        }
        try await DiskImage.create(from: staging, volumeName: volumeName, password: password, output: output)
    }

    /// Moves the folder's top-level files into subfolders by kind ("Images", "Videos", … "Other") or by month
    /// of creation ("2026-10"). Folders, packages and hidden files stay where they are. Returns how many moved.
    public static func sort(_ folder: URL, by: String) async throws -> Int {
        try await runBlocking {
            let fm = FileManager.default
            let month = DateFormatter()
            month.locale = Locale(identifier: "en_US_POSIX")
            month.dateFormat = "yyyy-MM"
            var moved = 0
            for file in try topLevelFiles(folder) {
                let group: String
                if by == "month" {
                    let created = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    group = month.string(from: created?.creationDate ?? created?.contentModificationDate ?? Date())
                } else {
                    group = FileFormat.detect(file)?.category.folderName ?? String(localized: "Other")
                }
                let destination = try subfolder(group, in: folder)
                try fm.moveItem(at: file, to: OutputNaming.unique(in: destination, name: file.lastPathComponent))
                moved += 1
            }
            return moved
        }
    }

    /// Moves files whose content repeats one already seen into "<folder>/Duplicates" (nothing is deleted).
    /// Candidates are grouped by size first, so only same-size files are hashed (SHA-256, streamed).
    /// The oldest copy of each set stays. Returns that folder (or `nil` when there were none) and how many moved.
    public static func findDuplicates(_ folder: URL) async throws -> (folder: URL?, count: Int) {
        let name = String(localized: "Duplicates")
        return try await runCancellable { flag -> (folder: URL?, count: Int) in
            let duplicatesFolder = folder.appendingPathComponent(name, isDirectory: true)
            let files = try allFiles(in: folder, excluding: duplicatesFolder)
            var bySize: [Int: [URL]] = [:]
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 { bySize[size, default: []].append(file) }  // empty files are all "equal": leave them
            }
            var repeats: [URL] = []
            for group in bySize.values where group.count > 1 {
                var byHash: [SHA256.Digest: [URL]] = [:]
                for file in group {
                    try flag.check()
                    byHash[try sha256(file), default: []].append(file)
                }
                for copies in byHash.values where copies.count > 1 {
                    repeats += copies.sorted(by: olderFirst).dropFirst()
                }
            }
            guard !repeats.isEmpty else { return (nil, 0) }
            let destination = try subfolder(name, in: folder)
            for file in repeats.sorted(by: { $0.path < $1.path }) {
                try FileManager.default.moveItem(at: file, to: OutputNaming.unique(in: destination, name: file.lastPathComponent))
            }
            return (destination, repeats.count)
        }
    }

    /// Moves every file in subfolders up into the folder itself (numbering clashes), removing the emptied subfolders. Returns how many moved.
    public static func flatten(_ folder: URL) async throws -> Int {
        try await runBlocking {
            let fm = FileManager.default
            let nested = try allFiles(in: folder, excluding: nil).filter { $0.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path }
            for file in nested {
                try fm.moveItem(at: file, to: OutputNaming.unique(in: folder, name: file.lastPathComponent))
            }
            // Deepest first, so a parent is only looked at once its children are gone. Folders still
            // holding something (hidden files) stay.
            let subfolders = directories(in: folder).sorted { $0.pathComponents.count > $1.pathComponents.count }
            for subfolder in subfolders {
                let left = (try? fm.contentsOfDirectory(atPath: subfolder.path)) ?? ["?"]
                if left.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: subfolder) }
            }
            return nested.count
        }
    }

    /// CSV of every file inside: path, name, kind, size in bytes, created, modified.
    public static func listFiles(_ folder: URL, output: URL) async throws {
        try await runBlocking {
            let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let base = folder.standardizedFileURL.path
            var rows = [["path", "name", "kind", "size", "created", "modified"]]
            for file in try allFiles(in: folder, excluding: nil).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                let values = try? file.resourceValues(forKeys: keys)
                let full = file.standardizedFileURL.path
                let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : file.lastPathComponent
                let size = isPackage(file) ? packageSize(file) : Int64(values?.fileSize ?? 0)
                let created = values?.creationDate.map { stamp.string(from: $0) } ?? ""
                let modified = values?.contentModificationDate.map { stamp.string(from: $0) } ?? ""
                rows.append([relative, file.lastPathComponent, values?.localizedTypeDescription ?? "", String(size), created, modified])
            }
            try CSV.write(rows, delimiter: ",").write(to: output, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Helpers

extension FolderEngine {
    /// APFS clone when possible (instant, no extra space; whole folder trees too), plain copy otherwise.
    static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// A fresh temp folder on the same volume as `url`, so clones stay instant; the caller removes it.
    static func stagingFolder(near url: URL) throws -> URL {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true) {
            return folder
        }
        return try ArchiveEngine.privateFolder()
    }

    static func isPackage(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true }

    static func isPlainFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !isPackage(url)
    }

    /// Visible top-level items that aren't folders (packages, like an .app or .rtfd, count as folders).
    static func topLevelFiles(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Visible files at any depth; a package counts as one file. `excluding` skips a subfolder.
    static func allFiles(in folder: URL, excluding: URL?) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw KumquatError.cannotOpen(folder.lastPathComponent)
        }
        let skipped = excluding?.standardizedFileURL.path
        var files: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                if url.standardizedFileURL.path == skipped { walker.skipDescendants() }
                continue
            }
            files.append(url)
        }
        return files
    }

    /// Every real subfolder (not packages), hidden ones included.
    static func directories(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        var folders: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true { folders.append(url) }
        }
        return folders
    }

    /// `name` inside `folder`, created when missing; a file already using the name gets a numbered folder instead.
    static func subfolder(_ name: String, in folder: URL) throws -> URL {
        let candidate = folder.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? candidate : try OutputNaming.reserveDirectory(in: folder, base: name)
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    static func packageSize(_ package: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Created earlier first; same date: shorter path (closer to the top), then by name.
    static func olderFirst(_ a: URL, _ b: URL) -> Bool {
        let first = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
        let second = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
        if first != second { return first < second }
        if a.pathComponents.count != b.pathComponents.count { return a.pathComponents.count < b.pathComponents.count }
        return a.path < b.path
    }

    /// SHA-256 of a file's content, read in 1 MB chunks.
    static func sha256(_ url: URL) throws -> SHA256.Digest {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }
}
