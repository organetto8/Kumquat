import Compression
import Foundation

/// ZIP · TAR · GZIP · XZ · BZIP2 · 7Z · DMG (+ RAR in). The system's bsdtar (libarchive) reads and writes the
/// tar family and ZIP; repacking between those streams entries straight from one archive into the other
/// (`@archive`), with no temp extraction. 7-Zip, when installed, does 7z (and the RAR 5 archives libarchive
/// can't read); hdiutil does disk images. Anything that can't stream is unpacked into a private folder
/// (or mounted, for a disk image) and packed again.
public enum ArchiveEngine {
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    static let bzip2 = URL(fileURLWithPath: "/usr/bin/bzip2")
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Finder and volume bookkeeping that never travels from one archive to another.
    static let systemNames: Set<String> = [
        ".DS_Store", "__MACOSX", ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100",
        ".HFS+ Private Directory Data\r", ".journal", ".journal_info_block",
    ]

    static func formatArguments(_ target: FileFormat) -> [String] {
        switch target {
        case .zip: ["--format", "zip"]
        case .gzip: ["-z"]
        case .xz: ["-J"]
        case .bz2: ["-j"]
        case .sevenZip: ["--format", "7zip"]
        default: []
        }
    }

    /// Pairs bsdtar repacks in one pass. 7z goes through 7-Zip whenever it's installed (better
    /// compression, every codec); disk images always need hdiutil.
    static func canStream(_ source: FileFormat, _ target: FileFormat) -> Bool {
        guard source != .dmg, target != .dmg else { return false }
        return Engines.sevenZip == nil || (source != .sevenZip && target != .sevenZip)
    }

    public static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) async throws {
        if canStream(source, target) {
            do {
                try await ExternalTool.check(Engines.tar, ["-c"] + formatArguments(target) + ["-f", output.path, "@" + input.path])
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not a stream libarchive reads (a bare .gz/.xz/.bz2 file, RAR 5…): unpack, then pack.
            }
        }
        try await withContents(of: input, from: source) { folder, entries in
            try await pack(entries, in: folder, to: target, output: output)
        }
    }

    /// Packs `entries` (names inside `folder`) as `target` into `output`, replacing it.
    static func pack(_ entries: [String], in folder: URL, to target: FileFormat, output: URL) async throws {
        if target == .dmg {
            try await DiskImage.create(from: folder, volumeName: output.deletingPathExtension().lastPathComponent, output: output)
            return
        }
        if target == .sevenZip, let sevenZip = Engines.sevenZip {
            // 7-Zip would try to update the reserved (empty) file as an archive.
            try? FileManager.default.removeItem(at: output)
            // Absolute paths are stored relative to their parent, so each entry lands at the top level.
            try await SevenZip.run(sevenZip, ["a", "-t7z", "-y", "-bso0", "-bsp0", output.path] + entries.map { folder.appendingPathComponent($0).path })
            return
        }
        try await ExternalTool.check(Engines.tar, ["-c"] + formatArguments(target) + ["-f", output.path, "-C", folder.path] + entries.map(safeName))
    }

    /// A name bsdtar won't mistake for an option.
    static func safeName(_ name: String) -> String { name.hasPrefix("-") ? "./" + name : name }

    /// Runs `body` with a folder holding the archive's top-level items and their names: the mounted
    /// volume for a disk image (always detached afterwards), otherwise a private temp folder that is
    /// removed afterwards. Throws when the archive holds nothing.
    @discardableResult
    static func withContents<T>(of input: URL, from source: FileFormat, _ body: (URL, [String]) async throws -> T) async throws -> T {
        if source == .dmg {
            return try await DiskImage.withMounted(input) { volume in
                try await body(volume, try entries(in: volume, of: input))
            }
        }
        let folder = try privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await unpack(input, from: source, into: folder)
        prune(folder)
        return try await body(folder, try entries(in: folder, of: input))
    }

    static func entries(in folder: URL, of input: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !systemNames.contains($0) }.sorted()
        guard !names.isEmpty else { throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is empty.")) }
        return names
    }

    /// Drops the Finder leftovers (`__MACOSX`, `.DS_Store`) at the top of an unpacked folder.
    static func prune(_ folder: URL) {
        for name in systemNames { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    static func privateFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func emptyFolder(_ folder: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Unpacks any archive except a disk image into the existing folder `folder`.
    static func unpack(_ input: URL, from source: FileFormat, into folder: URL) async throws {
        if source == .sevenZip, let sevenZip = Engines.sevenZip {
            try await SevenZip.run(sevenZip, ["x", "-y", "-bso0", "-bsp0", "-o" + folder.path, input.path], for: input)
            return
        }
        do {
            try await ExternalTool.check(Engines.tar, ["-xf", input.path, "-C", folder.path])
        } catch is CancellationError {
            throw CancellationError()
        } catch where [FileFormat.gzip, .xz, .bz2].contains(source) {
            // A bare compressed file, not a tarball: decompress that one file.
            try emptyFolder(folder)
            _ = try await decompressFile(input, from: source, into: folder)
        } catch {
            // RAR 5 features libarchive lacks.
            guard source == .rar, let sevenZip = Engines.sevenZip else { throw error }
            try emptyFolder(folder)
            try await SevenZip.run(sevenZip, ["x", "-y", "-bso0", "-bsp0", "-o" + folder.path, input.path], for: input)
        }
    }

    /// A bare .gz / .xz / .bz2 (one compressed file, not a tarball) decompressed into `folder`.
    static func decompressFile(_ input: URL, from source: FileFormat, into folder: URL) async throws -> URL {
        let compressed: Set<String> = ["gz", "gzip", "xz", "bz2", "bzip2"]
        let stem = compressed.contains(input.pathExtension.lowercased()) ? input.deletingPathExtension().lastPathComponent : input.lastPathComponent
        let file = folder.appendingPathComponent(stem.isEmpty ? "file" : stem)
        switch source {
        case .xz:
            // No xz binary ships with macOS; the Compression framework's LZMA decoder reads .xz streams.
            try await runBlocking { try unxz(input, to: file) }
        default:
            // gzip and bzip2 decompress in place: work on a (cloned) copy named the way they expect.
            let copy = file.appendingPathExtension(source == .gzip ? "gz" : "bz2")
            try FolderEngine.clone(input, to: copy)
            try await ExternalTool.check(source == .gzip ? gzip : bzip2, source == .gzip ? ["-d", "-f", "-n", copy.path] : ["-d", "-f", copy.path])
        }
        return file
    }

    static func unxz(_ input: URL, to output: URL) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw KumquatError.cannotWrite(output.deletingLastPathComponent().lastPathComponent) }
        let reader = try FileHandle(forReadingFrom: input)
        let writer = try FileHandle(forWritingTo: output)
        defer {
            try? reader.close()
            try? writer.close()
        }
        do {
            let filter = try OutputFilter(.decompress, using: .lzma) { chunk in
                if let chunk { try writer.write(contentsOf: chunk) }
            }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try filter.write(chunk) }
            try filter.finalize()
        } catch is FilterError {
            throw KumquatError.cannotDecode(input.lastPathComponent)
        }
    }

    /// Extracts next to the archive. A single top-level item lands directly (like Archive
    /// Utility); several items go into a folder named after the archive.
    public static func extract(_ input: URL, from source: FileFormat, into directory: URL, baseName: String) async throws -> URL {
        // "photos.tar.xz" reaches here as "photos.tar".
        let baseName = baseName.lowercased().hasSuffix(".tar") && baseName.count > 4 ? String(baseName.dropLast(4)) : baseName
        let staging = directory.appendingPathComponent(".\(baseName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        if source == .dmg {
            try await DiskImage.withMounted(input) { volume in
                for name in try entries(in: volume, of: input) {
                    try await ExternalTool.check(Engines.ditto, [volume.appendingPathComponent(name).path, staging.appendingPathComponent(name).path])
                }
            }
        } else {
            try await unpack(input, from: source, into: staging)
        }
        let fm = FileManager.default
        prune(staging)
        let items = try entries(in: staging, of: input).map { staging.appendingPathComponent($0) }
        if items.count == 1 {
            let target = OutputNaming.unique(in: directory, name: items[0].lastPathComponent)
            try fm.moveItem(at: items[0], to: target)
            return target
        }
        let target = OutputNaming.unique(in: directory, name: baseName)
        try fm.moveItem(at: staging, to: target)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)  // keeps the deferred cleanup harmless
        return target
    }

    /// Finder-identical ZIP for one item (ditto keeps extended attributes); bsdtar for several.
    public static func archive(_ items: [URL], output: URL) async throws {
        if items.count == 1 {
            try await ExternalTool.check(Engines.ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].path, output.path])
            return
        }
        var arguments = ["-c", "--format", "zip", "--exclude", ".DS_Store", "-f", output.path]
        for item in items { arguments += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent] }
        try await ExternalTool.check(Engines.tar, arguments)
    }

    /// Repacks any archive as an AES-256 encrypted ZIP. (bsdtar can't combine a passphrase with
    /// `@archive` input, so entries are staged in a private temp folder, or read off the mounted image, first.)
    public static func encrypt(_ input: URL, password: String, output: URL) async throws {
        guard !password.isEmpty else { throw KumquatError.noResult(String(localized: "Enter a password.")) }
        try await withContents(of: input, from: FileFormat.detect(input) ?? .zip) { folder, entries in
            try await ExternalTool.check(Engines.tar, ["-c", "--format", "zip", "--options", "zip:encryption=aes256",
                                                       "--passphrase", password, "-f", output.path, "-C", folder.path] + entries.map(safeName))
        }
    }
}

// MARK: - Added after 1.2

extension ArchiveEngine {
    /// ZIP split into numbered parts of `megabytes` ("<base>.zip", "<base>.z01", …) that unzip together.
    /// Info-ZIP copies the entries as they are (no recompression); an archive smaller than one part stays whole.
    public static func splitVolumes(_ input: URL, megabytes: Int, into directory: URL, baseName: String) async throws -> [URL] {
        let output = directory.appendingPathComponent("\(baseName).zip")
        try await ExternalTool.check(Engines.zip, ["-q", input.path, "--out", output.path, "-s", "\(max(1, megabytes))m"])
        let parts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.deletingPathExtension().lastPathComponent == baseName && $0.pathExtension.lowercased().hasPrefix("z") }
        // The .zip (the part to open) first, then .z01, .z02, …
        return parts.sorted { a, b in
            let (x, y) = (a.pathExtension.lowercased(), b.pathExtension.lowercased())
            return x == "zip" ? y != "zip" : (y == "zip" ? false : x < y)
        }
    }

    /// Tests every entry; returns "OK · 123 files · 45 MB" or throws `noResult` describing the damage.
    public static func verify(_ input: URL, from source: FileFormat) async throws -> String {
        let summary: (files: Int, bytes: Int64)
        do {
            switch source {
            case .dmg:
                summary = try await DiskImage.verify(input)
            case .sevenZip, .rar:
                if let sevenZip = Engines.sevenZip {
                    summary = try await SevenZip.test(sevenZip, input)
                } else {
                    summary = try await listing(input)
                }
            case .zip:
                // Decompresses every entry and checks its CRC; `listing` then counts.
                try await ExternalTool.check(unzip, ["-tqq", input.path])
                summary = try await listing(input)
            case .gzip, .xz, .bz2:
                summary = try await compressedSummary(input, from: source)
            default:
                summary = try await listing(input)
            }
        } catch KumquatError.processFailed(let details), KumquatError.cannotDecode(let details) {
            throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is damaged: \(details)"))
        }
        let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        return String(localized: "OK · \(summary.files) files · \(size)")
    }

    /// Regular files and their total size, from bsdtar's `ls -l`-style listing (which also walks
    /// the whole compressed stream).
    static func listing(_ input: URL) async throws -> (files: Int, bytes: Int64) {
        let result = try await ExternalTool.check(Engines.tar, ["-tvf", input.path])
        var files = 0
        var bytes: Int64 = 0
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") where line.hasPrefix("-") {
            // mode, links, owner, group, size, …
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            files += 1
            if fields.count > 4 { bytes += Int64(fields[4]) ?? 0 }
        }
        return (files, bytes)
    }

    /// A compressed tarball checked end to end (gzip/bzip2 test the whole stream's CRC), or a bare
    /// compressed file, which is decompressed into a private folder to be checked and measured.
    static func compressedSummary(_ input: URL, from source: FileFormat) async throws -> (files: Int, bytes: Int64) {
        if source != .xz { try await ExternalTool.check(source == .gzip ? gzip : bzip2, ["-t", input.path]) }
        if let summary = try? await listing(input) { return summary }
        let folder = try privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await decompressFile(input, from: source, into: folder)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (1, Int64(size))
    }
}

// MARK: - 7-Zip

enum SevenZip {
    /// Runs 7-Zip. It reads no password (stdin is closed), so an encrypted archive ends the
    /// run at the prompt: that is reported as such rather than as a cryptic "Break signaled".
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String], for input: URL? = nil) async throws -> ProcessResult {
        let result = try await ExternalTool.run(tool, arguments)
        guard result.status == 0 else {
            let output = result.stderr + String(decoding: result.stdout, as: UTF8.self)
            if let input, output.contains("Break signaled") || output.localizedCaseInsensitiveContains("wrong password") {
                throw KumquatError.noResult(String(localized: "“\(input.lastPathComponent)” is password-protected."))
            }
            let lines = result.stderr.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(3)
            throw KumquatError.processFailed(lines.isEmpty ? String(localized: "\(tool.lastPathComponent) failed (exit \(result.status)).") : lines.joined(separator: " "))
        }
        return result
    }

    /// `7zz t`: every entry decompressed and checked. Its summary gives "Files: N" (absent for a
    /// single file) and "Size: N".
    static func test(_ tool: URL, _ input: URL) async throws -> (files: Int, bytes: Int64) {
        let result = try await run(tool, ["t", "-bsp0", input.path], for: input)
        var files: Int?
        var bytes: Int64 = 0
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "Files" { files = Int(parts[1]) }
            if parts[0] == "Size" { bytes = Int64(parts[1]) ?? 0 }
        }
        return (files ?? (bytes > 0 ? 1 : 0), bytes)
    }
}

// MARK: - Disk images

/// hdiutil, always with `-stdinpass`: without it an encrypted image would make the system put up a
/// password dialog. Without a password, stdin is simply empty and hdiutil fails at once.
/// Calls are serialised: the disk image service turns concurrent ones down ("Resource temporarily unavailable").
enum DiskImage {
    private static let gate = SerialGate()

    @discardableResult
    static func hdiutil(_ arguments: [String], input: Data? = nil) async throws -> ProcessResult {
        await gate.enter()
        do {
            let result = try await ExternalTool.check(Engines.hdiutil, arguments, input: input)
            await gate.leave()
            return result
        } catch {
            await gate.leave()
            throw error
        }
    }

    /// Compressed (UDZO) APFS image of `folder`'s contents; AES-256 encrypted when `password` is given.
    static func create(from folder: URL, volumeName: String, password: String? = nil, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)  // hdiutil refuses to replace a file
        var arguments = ["create", "-quiet", "-fs", "APFS", "-format", "UDZO", "-srcfolder", folder.path, "-volname", volumeName]
        if password != nil { arguments += ["-encryption", "AES-256", "-stdinpass"] }
        try await hdiutil(arguments + [output.path], input: password.map { Data($0.utf8) })
    }

    static func isEncrypted(_ image: URL) async -> Bool {
        guard let result = try? await hdiutil(["isencrypted", "-plist", image.path]),
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else { return false }
        return plist["encrypted"] as? Bool ?? false
    }

    /// Mounts the image read-only and out of sight, runs `body` on the volume, and always detaches.
    static func withMounted<T>(_ image: URL, _ body: (URL) async throws -> T) async throws -> T {
        if await isEncrypted(image) {
            throw KumquatError.noResult(String(localized: "“\(image.lastPathComponent)” is password-protected."))
        }
        let root = try ArchiveEngine.privateFolder()
        let arguments = ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountrandom", root.path, "-plist", "-stdinpass", image.path]
        let result: ProcessResult
        do {
            // A volume that was just detached can still be settling: one retry covers it.
            do {
                result = try await hdiutil(arguments, input: Data())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(nanoseconds: 500_000_000)
                result = try await hdiutil(arguments, input: Data())
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        guard let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            await detach(devices.min(by: { $0.count < $1.count }), root: root)
            throw KumquatError.noResult(String(localized: "“\(image.lastPathComponent)” has no volume to read."))
        }
        let value: T
        do {
            value = try await body(URL(fileURLWithPath: mountPoint, isDirectory: true))
        } catch {
            await detach(mountPoint, root: root)
            throw error
        }
        await detach(mountPoint, root: root)
        return value
    }

    /// Detaches even when the job was cancelled (a cancelled task would kill hdiutil at once).
    static func detach(_ target: String?, root: URL) async {
        if let target {
            await Task.detached {
                if (try? await hdiutil(["detach", "-quiet", target])) == nil {
                    _ = try? await hdiutil(["detach", "-quiet", "-force", target])
                }
            }.value
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `hdiutil verify` (the image's checksum), then the files on its volume counted.
    static func verify(_ image: URL) async throws -> (files: Int, bytes: Int64) {
        if await isEncrypted(image) {
            throw KumquatError.noResult(String(localized: "“\(image.lastPathComponent)” is password-protected."))
        }
        try await hdiutil(["verify", "-quiet", "-stdinpass", image.path], input: Data())
        return try await withMounted(image) { volume in try await runBlocking { measure(volume) } }
    }

    /// Regular files under `folder` and their total size, skipping volume bookkeeping.
    static func measure(_ folder: URL) -> (files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            if ArchiveEngine.systemNames.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }
}

/// An async mutex: one holder at a time, waiters resumed in arrival order.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
