import AppKit
import Foundation

extension Notification.Name {
    static let defaultBrowserChanged = Notification.Name("defaultBrowserChanged")
    static let alwaysOnTopSettingChanged = Notification.Name("alwaysOnTopSettingChanged")
    static let attachmentSettingChanged = Notification.Name("attachmentSettingChanged")
    static let sidebarPositionChanged = Notification.Name("sidebarPositionChanged")
    static let toggleSidebarShortcutChanged = Notification.Name("toggleSidebarShortcutChanged")
}

enum UserDefaultsKeys {
    static let defaultBrowserBundleId = "defaultBrowserBundleId"
    static let alwaysOnTopEnabled = "alwaysOnTopEnabled"
    static let lastSelectedWorkspaceId = "lastSelectedWorkspaceId"
    static let mainWindowSize = "mainWindowSize"
    static let sidebarAttachmentEnabled = "sidebarAttachmentEnabled"
    static let sidebarPosition = "sidebarPosition"
    static let lastArcImportDate = "lastArcImportDate"
    static let arcImportCount = "arcImportCount"
    static let toggleSidebarShortcut = "toggleSidebarShortcut"
}

let nodePasteboardType = NSPasteboard.PasteboardType("com.marklyai.node")
let workspacePasteboardType = NSPasteboard.PasteboardType("com.marklyai.workspace")

struct LayoutConstants {
    static let windowPadding: CGFloat = 8
}

struct ListMetrics {
    let rowHeight: CGFloat = 40
    let verticalGap: CGFloat = 4
    let leftPadding: CGFloat = 8
    let iconSize: CGFloat = 20
    let indentWidth: CGFloat = 16
    let rowCornerRadius: CGFloat = 12
    let iconCornerRadius: CGFloat = 4
    let linkTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    let folderTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    let titleColor: NSColor = NSColor.labelColor.withAlphaComponent(0.8)
    let hoverBackgroundColor: NSColor = NSColor.labelColor.withAlphaComponent(0.06)
    let selectedBackgroundColor: NSColor = NSColor.labelColor.withAlphaComponent(0.12)
    let deleteTintColor: NSColor = NSColor.secondaryLabelColor
    let iconTintColor: NSColor = NSColor.labelColor.withAlphaComponent(0.7)
}
