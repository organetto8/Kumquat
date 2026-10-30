import AppKit

@main
enum KumquatMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Menu-bar utility: no Dock icon, no app switcher entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
