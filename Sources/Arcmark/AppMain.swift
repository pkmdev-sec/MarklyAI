import AppKit

@main
struct ArcmarkApp {
    static func main() {
        autoreleasepool {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            app.run()
        }
    }
}
