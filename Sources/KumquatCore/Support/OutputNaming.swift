import Foundation

public enum OutputNaming {
    /// Atomically reserves a Finder-style unique file name ("name.ext", "name 2.ext", …)
    /// so parallel jobs never race for the same path. The returned file exists and is empty.
    public static func reserve(in directory: URL, base: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = sanitize(base)
        var counter = 1
        while true {
            let name = counter == 1 ? clean : "\(clean) \(counter)"
            let candidate = directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            let fd = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            guard errno == EEXIST else { throw KumquatError.cannotWrite(directory.lastPathComponent) }
            counter += 1
        }
    }

    /// Creates a uniquely named folder.
    public static func reserveDirectory(in directory: URL, base: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = sanitize(base)
        var counter = 1
        while true {
            let candidate = directory.appendingPathComponent(counter == 1 ? clean : "\(clean) \(counter)", isDirectory: true)
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            guard errno == EEXIST else { throw KumquatError.cannotWrite(directory.lastPathComponent) }
            counter += 1
        }
    }

    /// First free "name", "name 2", … (keeps the extension) without creating anything.
    public static func unique(in directory: URL, name: String) -> URL {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let candidateName = counter == 1 ? name : (ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    /// File name without its extension ("archive.tar.gz" → "archive").
    public static func baseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.xz", ".tar.bz2"] where name.lowercased().hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The source folder when writable, otherwise Downloads.
    public static func defaultDirectory(for source: URL) -> URL {
        let parent = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) { return parent }
        return downloads
    }

    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private static func sanitize(_ base: String) -> String {
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "Untitled" : clean
    }
}
