import AppKit
import MarklyAICore

@MainActor
@main
struct MarklyAIApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        autoreleasepool {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            appDelegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
    }
}
