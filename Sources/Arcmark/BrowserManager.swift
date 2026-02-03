import AppKit
import CoreServices

struct BrowserInfo: Equatable {
    let bundleId: String
    let name: String
    let icon: NSImage?
}

enum BrowserManager {
    static func installedBrowsers() -> [BrowserInfo] {
        guard let handlers = LSCopyAllHandlersForURLScheme("http" as CFString)?.takeRetainedValue() as? [String] else {
            return []
        }
        return handlers.compactMap { bundleId in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            let name = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String } ?? bundleId
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return BrowserInfo(bundleId: bundleId, name: name, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultBrowserBundleId() -> String? {
        LSCopyDefaultHandlerForURLScheme("http" as CFString)?.takeRetainedValue() as String?
    }

    static func resolveDefaultBrowserBundleId() -> String? {
        if let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultBrowserBundleId) {
            return stored
        }
        return defaultBrowserBundleId()
    }

    static func open(url: URL) {
        if let bundleId = resolveDefaultBrowserBundleId() {
            NSWorkspace.shared.open([url], withAppBundleIdentifier: bundleId, options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
