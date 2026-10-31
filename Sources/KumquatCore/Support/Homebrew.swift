import Foundation

/// Install in Settings ▸ Engines when Kumquat's engine pack has nothing for this Mac. Homebrew does
/// the downloading; Kumquat only starts it.
public enum Homebrew {
    /// The formula or cask that provides an engine.
    public struct Package: Hashable, Sendable {
        public let name: String
        public let isCask: Bool

        public static func formula(_ name: String) -> Package { Package(name: name, isCask: false) }
        public static func cask(_ name: String) -> Package { Package(name: name, isCask: true) }

        var arguments: [String] { ["install"] + (isCask ? ["--cask"] : []) + [name] }

        /// The same install, typed in Terminal.
        public var command: String { (["brew"] + arguments).joined(separator: " ") }
    }

    public static var brew: URL? { ExternalTool.locate("brew") }

    /// Runs `brew install`; `onStep` gets each "==>" heading brew prints ("Pouring ffmpeg…").
    /// Lookups are reset afterwards, so a new engine is found straight away.
    public static func install(_ package: Package, onStep: (@Sendable (String) -> Void)? = nil) async throws {
        guard let tool = brew else { throw KumquatError.toolMissing("Homebrew") }
        defer { ExternalTool.resetCache() }
        try await ExternalTool.check(tool, package.arguments, onStdoutLine: { line in
            if line.hasPrefix("==> ") { onStep?(String(line.dropFirst(4))) }
        })
    }
}
