import AppKit
import KumquatCore

/// Plain-text facts for a bug report: version, system, settings that change behaviour, and which
/// optional engines are installed. No paths, names or files, so it is safe to paste in a public issue.
enum Diagnostics {
    static var report: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let engines: [(String, URL?)] = [
            ("ffmpeg", Engines.ffmpeg), ("cwebp", Engines.cwebp), ("cjxl", Engines.cjxl), ("potrace", Engines.potrace),
            ("pandoc", Engines.pandoc), ("calibre", Engines.ebookConvert), ("7-Zip", Engines.sevenZip),
            ("woff2", Engines.woff2Compress), ("fonttools", Engines.fonttools), ("Homebrew", Homebrew.brew),
        ]
        // English names, whatever language the app shows: the report is read by the maintainer.
        let names: [WheelKind: String] = [.convert: "Convert", .tools: "Edit", .actions: "Send"]
        let keys = WheelKind.allCases.map { "\(names[$0] ?? $0.rawValue) \(Prefs.modifier(for: $0).symbol)" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return """
        Kumquat \(version) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(sysctl("kern.osversion"))) · \(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string"))
        Language: \(Bundle.main.preferredLocalizations.first ?? "?") (system \(Locale.preferredLanguages.first ?? "?"))
        Wheel keys: \(keys.joined(separator: ", ")) · drag gesture \(Prefs.dragGesture ? "on" : "off")
        Input Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "not granted")
        Engines: \(engines.map { "\($0.0) \($0.1 == nil ? "–" : "✓")" }.joined(separator: ", "))
        Apps: \(Engines.App.allCases.map { "\($0.rawValue) \($0.isInstalled ? "✓" : "–")" }.joined(separator: ", "))
        """
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}
