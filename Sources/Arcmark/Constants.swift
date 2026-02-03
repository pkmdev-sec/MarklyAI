import AppKit

enum UserDefaultsKeys {
    static let defaultBrowserBundleId = "defaultBrowserBundleId"
    static let alwaysOnTopEnabled = "alwaysOnTopEnabled"
    static let lastSelectedWorkspaceId = "lastSelectedWorkspaceId"
}

let nodePasteboardType = NSPasteboard.PasteboardType("com.arcmark.node")
