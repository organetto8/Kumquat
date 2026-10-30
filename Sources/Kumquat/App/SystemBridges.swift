import AppKit
import ServiceManagement

enum FinderBridge {
    static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    /// Compiled once; Apple Events need the user's one-time Automation consent.
    private static let script: NSAppleScript? = {
        let script = NSAppleScript(source: """
        tell application "Finder"
            set output to ""
            repeat with anItem in (get selection)
                set output to output & POSIX path of (anItem as alias) & linefeed
            end repeat
            return output
        end tell
        """)
        script?.compileAndReturnError(nil)
        return script
    }()

    static func selection() -> [URL] {
        var error: NSDictionary?
        guard let output = script?.executeAndReturnError(&error).stringValue else { return [] }
        return output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum AppRelaunch {
    /// Opens a fresh copy once this one has quit, so a new language or a new version is read at launch.
    static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Finder ▸ Services ▸ "Convert with Kumquat" (declared in Info.plist `NSServices`).
final class ServiceProvider: NSObject {
    var handler: ([URL]) -> Void = { _ in }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        handler(urls)
    }
}

enum StatusIcon {
    /// Original template artwork: a tilted kumquat with a leaf, drawn in code.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            var tilt = AffineTransform()
            tilt.translate(x: 8, y: 8)
            tilt.rotate(byDegrees: -20)
            tilt.translate(x: -8, y: -8)

            NSColor.black.setFill()
            let body = NSBezierPath(ovalIn: NSRect(x: 2.4, y: 1.4, width: 11.2, height: 13.2))
            body.transform(using: tilt)
            body.fill()

            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 10.4, y: 13.6))
            leaf.curve(to: NSPoint(x: 17.2, y: 16.8), controlPoint1: NSPoint(x: 11.6, y: 17.0), controlPoint2: NSPoint(x: 15.0, y: 17.8))
            leaf.curve(to: NSPoint(x: 10.4, y: 13.6), controlPoint1: NSPoint(x: 15.8, y: 13.8), controlPoint2: NSPoint(x: 12.8, y: 12.8))
            leaf.fill()

            // Punch a highlight out of the fruit for volume.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let shine = NSBezierPath(ovalIn: NSRect(x: 4.8, y: 8.6, width: 2.4, height: 3.6))
            shine.transform(using: tilt)
            shine.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
