import Foundation

/// More Keynote exports: Keynote documents, movies, GIFs and web pages.
extension SlidesEngine {
    public static func toKeynote(_ input: URL, output: URL) async throws {
        try FileManager.default.removeItem(at: output)
        try await KeynoteScript.run(input, output: output, verb: "save theDoc in outFile")
    }

    /// QuickTime export from Keynote, written as MP4.
    /// Keynote plays the deck as self-playing (its own timings and transitions) at 1080p.
    public static func toMovie(_ input: URL, output: URL, progress: MediaEngine.Progress?) async throws {
        let folder = try KeynoteScript.stagingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("slides.m4v")
        try await KeynoteScript.run(input, output: movie, verb: "export theDoc to outFile as QuickTime movie with properties {movie format: format1080p}",
                                    timeout: 1800)
        progress?(0.8)
        guard Engines.ffmpeg != nil else {
            // Keynote writes H.264/AAC in an MPEG-4 file already: only the name changes.
            _ = try FileManager.default.replaceItemAt(output, withItemAt: movie)
            progress?(1)
            return
        }
        let info = try await MediaEngine.probe(movie)
        try await MediaEngine.video(movie, info: info, to: .mp4, output: output, progress: MediaEngine.scaled(progress, 0.8, 1))
    }

    /// Movie export turned into an animated GIF (FFmpeg).
    public static func toGIF(_ input: URL, output: URL, progress: MediaEngine.Progress?) async throws {
        let movie = ImageEngine.temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        FileManager.default.createFile(atPath: movie.path, contents: nil)
        try await toMovie(input, output: movie, progress: MediaEngine.scaled(progress, 0, 0.7))
        let info = try await MediaEngine.probe(movie)
        // Slides hold still most of the time: 10 fps is plenty.
        try await MediaEngine.gif(movie, info: info, output: output, width: 640, fps: 10, progress: MediaEngine.scaled(progress, 0.7, 1))
    }

    /// Keynote's HTML export: a folder "<baseName> (web)" with index.html. Returns the folder.
    public static func toHTML(_ input: URL, into directory: URL, baseName: String) async throws -> URL {
        let folder = try OutputNaming.reserveDirectory(in: directory, base: "\(baseName) (web)")
        do {
            let staging = try KeynoteScript.stagingFolder()
            defer { try? FileManager.default.removeItem(at: staging) }
            let export = staging.appendingPathComponent("web", isDirectory: true)
            try await KeynoteScript.run(input, output: export, verb: "export theDoc to outFile as HTML")
            // Keynote writes the folder itself (index.html plus assets); its contents move into ours.
            guard let index = FileManager.default.enumerator(at: export, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "index.html" }) else {
                throw KumquatError.processFailed(String(localized: "Keynote didn't produce a web page."))
            }
            let root = index.deletingLastPathComponent()
            for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try FileManager.default.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

/// Keynote scripting for the exports IWork doesn't cover (save as Keynote, movie, HTML), one
/// document at a time like IWork.
enum KeynoteScript {
    private static var gate: AsyncGate { IWork.gate }

    static func run(_ input: URL, output: URL, verb: String, timeout: TimeInterval = 300) async throws {
        let app = Engines.App.keynote
        guard app.isInstalled else { throw KumquatError.toolMissing(app.rawValue) }
        let script = [
            "on run argv",
            "set inFile to POSIX file (item 1 of argv)",
            "set outFile to POSIX file (item 2 of argv)",
            "set wasRunning to application \"Keynote\" is running",
            "tell application \"Keynote\"",
            "set theDoc to open inFile",
            // Movie exports of long decks outlast the default two-minute Apple Event timeout.
            "with timeout of \(Int(timeout)) seconds",
            verb,
            "end timeout",
            "close theDoc saving no",
            "if not wasRunning then quit",
            "end tell",
            "end run",
        ]
        let arguments = script.flatMap { ["-e", $0] } + [input.path, output.path]
        _ = try await gate.withLock {
            try await ExternalTool.check(Engines.osascript, arguments, timeout: timeout)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw KumquatError.processFailed(String(localized: "Keynote didn't produce \(output.lastPathComponent)."))
        }
    }

    /// Empty private folder for Keynote to write into.
    static func stagingFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-keynote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
