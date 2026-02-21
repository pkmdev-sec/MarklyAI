import AppKit

@MainActor
enum BrowserTabService {
    struct BrowserTab {
        let url: String
        let title: String
    }

    static func getOpenTabs(browserBundleId: String) -> [BrowserTab] {
        // Determine which AppleScript to use based on browser
        let script: String

        if browserBundleId.lowercased().contains("safari") {
            script = """
            tell application "Safari"
                set tabList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of tabList to {URL of t, name of t}
                    end repeat
                end repeat
                return tabList
            end tell
            """
        } else {
            // Chrome, Brave, Edge, Arc, BrowserOS — all Chromium-based
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleId).first?.localizedName ?? "Google Chrome"
            script = """
            tell application "\(appName)"
                set tabList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of tabList to {URL of t, title of t}
                    end repeat
                end repeat
                return tabList
            end tell
            """
        }

        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        guard error == nil else { return [] }

        var tabs: [BrowserTab] = []
        let count = result.numberOfItems
        // Result is a list of {url, title} pairs
        var i = 1
        while i <= count {
            if let urlDesc = result.atIndex(i),
               let titleDesc = result.atIndex(i + 1) {
                let url = urlDesc.stringValue ?? ""
                let title = titleDesc.stringValue ?? url
                if !url.isEmpty && url.hasPrefix("http") {
                    tabs.append(BrowserTab(url: url, title: title))
                }
            }
            i += 2
        }

        return tabs
    }
}
