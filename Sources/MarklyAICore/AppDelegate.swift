import AppKit
@preconcurrency import Sparkle
import CoreSpotlight

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WindowAttachmentServiceDelegate, GlobalHotkeyServiceDelegate {
    public override init() {
        super.init()
    }
    private var window: NSWindow?
    private var mainViewController: MainViewController?
    private var alwaysOnTopMenuItem: NSMenuItem?
    private var updaterController: SPUStandardUpdaterController!
    private var quickCapturePanel: QuickCapturePanel?
    private var commandPalette: CommandPalettePanel?

    // Attachment state
    private var isAttachmentMode: Bool = false
    private var lastManualFrame: NSRect?

    // Shortcut toggle state
    private var isUserHidden: Bool = false

    // Public accessor for App Intents
    var mainViewControllerForIntents: MainViewController? {
        mainViewController
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )

        setupMenus()

        let model = AppModel()
        let mainViewController = MainViewController(model: model)
        mainViewController.updater = updaterController.updater
        self.mainViewController = mainViewController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MarklyAI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 280, height: 420)
        window.maxSize = NSSize(width: 520, height: 10000) // Unlimited height for attachment mode
        let windowAutosaveName = "MarklyAIMainWindow"
        window.setFrameAutosaveName(windowAutosaveName)
        let restoredSize = applySavedWindowSize(to: window)
        let restoredFrame = restoredSize ? false : window.setFrameUsingName(windowAutosaveName)
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = mainViewController
        if !restoredSize && !restoredFrame {
            window.center()
        }
        ensureWindowVisible(window)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        self.window = window
        applyAlwaysOnTopFromDefaults()
        setupAttachmentService()
        setupGlobalHotkey()
        observeBrowserChanges()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let window {
            saveWindowSize(window)
        }
        // Flush any pending async saves to ensure data is written before quit
        mainViewController?.model.flushPendingSave()
    }

    public func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == CSSearchableItemActionType,
           let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let uuid = UUID(uuidString: identifier) {
            // Find and open the link
            if let mvc = mainViewController {
                for workspace in mvc.model.workspaces {
                    if let link = findLink(id: uuid, in: workspace.items) {
                        BrowserManager.open(url: URL(string: link.url)!)
                        return true
                    }
                }
            }
        }
        return false
    }

    private func findLink(id: UUID, in nodes: [Node]) -> Link? {
        for node in nodes {
            switch node {
            case .link(let link):
                if link.id == id { return link }
            case .folder(let folder):
                if let found = findLink(id: id, in: folder.children) { return found }
            }
        }
        return nil
    }

    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        saveWindowSize(window)
    }

    private func ensureWindowVisible(_ window: NSWindow) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        if screenFrame.intersects(window.frame) { return }

        let origin = NSPoint(
            x: screenFrame.midX - window.frame.width / 2,
            y: screenFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func applySavedWindowSize(to window: NSWindow) -> Bool {
        guard let sizeString = UserDefaults.standard.string(forKey: UserDefaultsKeys.mainWindowSize) else {
            return false
        }
        let savedSize = NSSizeFromString(sizeString)
        guard savedSize.width > 0, savedSize.height > 0 else { return false }

        let clampedWidth = min(max(savedSize.width, window.minSize.width), window.maxSize.width)
        let clampedHeight = min(max(savedSize.height, window.minSize.height), window.maxSize.height)
        var frame = window.frame
        frame.size = NSSize(width: clampedWidth, height: clampedHeight)
        window.setFrame(frame, display: false)
        return true
    }

    private func saveWindowSize(_ window: NSWindow) {
        let sizeString = NSStringFromSize(window.frame.size)
        UserDefaults.standard.set(sizeString, forKey: UserDefaultsKeys.mainWindowSize)
    }

    private func setupMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MarklyAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace), keyEquivalent: "n")
        let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(newFolder), keyEquivalent: "N")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFolderItem)
        let quickCaptureItem = NSMenuItem(title: "Quick Capture…", action: #selector(showQuickCapture), keyEquivalent: "s")
        quickCaptureItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(quickCaptureItem)
        fileMenu.addItem(NSMenuItem.separator())
        let openAllItem = NSMenuItem(title: "Open All Links in Browser", action: #selector(openAllLinksFromMenu), keyEquivalent: "o")
        openAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openAllItem)
        fileMenu.addItem(NSMenuItem.separator())
        let saveTabsItem = NSMenuItem(title: "Save All Browser Tabs…", action: #selector(saveAllBrowserTabs), keyEquivalent: "t")
        saveTabsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveTabsItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(performFindAction), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Command Palette…", action: #selector(showCommandPalette), keyEquivalent: "k")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu
        let showWindowItem = NSMenuItem(title: "Show MarklyAI", action: #selector(showMainWindow), keyEquivalent: "")
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)
        let alwaysOnTopItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        alwaysOnTopItem.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(alwaysOnTopItem)
        alwaysOnTopMenuItem = alwaysOnTopItem
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        // Add workspace switching shortcuts (Cmd+1-9)
        windowMenu.addItem(NSMenuItem.separator())
        for i in 1...9 {
            let item = NSMenuItem(title: "Workspace \(i)", action: #selector(switchToWorkspace(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i
            windowMenu.addItem(item)
        }

        NSApplication.shared.mainMenu = mainMenu
    }

    private func applyAlwaysOnTopFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func showMainWindow() {
        guard let window else { return }
        isUserHidden = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAlwaysOnTop() {
        let enabled = !(UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled))

        // Reset user-hidden state when toggling always on top
        if enabled {
            isUserHidden = false
        }

        // If enabling always on top, disable attachment first
        if enabled && isAttachmentMode {
            // Save current frame before disabling attachment
            if let window = window {
                lastManualFrame = window.frame
            }

            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
            updateWindowConstraints()
        }

        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal
    }

    @objc private func openPreferences() {
        // Select the settings tab in the main window instead of opening a separate preferences window
        guard let mainVC = mainViewController else { return }
        mainVC.model.selectSettings()
        showMainWindow()
    }

    @objc private func newWorkspace() {
        mainViewController?.promptCreateWorkspace()
    }

    @objc private func newFolder() {
        mainViewController?.createFolderAndBeginRename(parentId: nil)
    }

    @objc private func performFindAction() {
        mainViewController?.focusSearchField()
    }

    @objc private func showCommandPalette() {
        guard let mvc = mainViewController else { return }

        if commandPalette == nil {
            commandPalette = CommandPalettePanel()
            commandPalette?.onOpenLink = { link in
                guard let url = URL(string: link.url) else { return }
                BrowserManager.open(url: url)
            }
            commandPalette?.onSwitchWorkspace = { [weak self] workspaceId in
                self?.mainViewController?.model.selectWorkspace(id: workspaceId)
            }
        }

        commandPalette?.show(workspaces: mvc.model.workspaces)
    }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        let index = sender.tag - 1  // Convert to 0-based index
        guard let mainVC = mainViewController else { return }
        let workspaces = mainVC.model.workspaces

        // Bounds check
        guard index >= 0 && index < workspaces.count else { return }

        let workspace = workspaces[index]
        mainVC.model.selectWorkspace(id: workspace.id)

        // Show window if it was hidden
        showMainWindow()
    }

    @objc private func openAllLinksFromMenu() {
        mainViewController?.openAllLinksInWorkspace()
    }

    @objc private func showQuickCapture() {
        guard let mvc = mainViewController else { return }

        if quickCapturePanel == nil {
            quickCapturePanel = QuickCapturePanel()
        }

        quickCapturePanel?.show(
            workspaces: mvc.model.workspaces,
            currentWorkspaceId: mvc.model.state.selectedWorkspaceId
        ) { [weak self] urlString, workspaceId in
            guard let self, let mvc = self.mainViewController else { return }

            // Check for duplicate
            if let duplicate = mvc.model.findDuplicateLink(url: urlString) {
                let alert = NSAlert()
                alert.messageText = "Duplicate Link"
                alert.informativeText = "This link already exists as \"\(duplicate.linkTitle)\" in \(duplicate.workspaceName)."
                alert.addButton(withTitle: "Add Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            // Check if user explicitly chose a workspace (different from current)
            let userChoseWorkspace = (workspaceId != nil && workspaceId != mvc.model.state.selectedWorkspaceId)

            // If a specific workspace was selected, switch to it first
            if let workspaceId, workspaceId != mvc.model.state.selectedWorkspaceId {
                mvc.model.selectWorkspace(id: workspaceId)
            }

            // Add the link
            if let url = URL(string: urlString), urlString.lowercased().hasPrefix("http") {
                let initialTitle = url.host ?? urlString
                let linkId = mvc.model.addLink(urlString: url.absoluteString, title: initialTitle, parentId: nil)

                // Auto-generate tags
                let tags = AutoTagService.shared.generateTags(url: url.absoluteString, title: initialTitle)
                mvc.model.updateLinkTags(id: linkId, tags: tags)

                // Fetch real title in background
                LinkTitleService.shared.fetchTitle(for: url, linkId: linkId) { title in
                    guard let title else { return }
                    if mvc.model.updateLinkTitleIfDefault(id: linkId, newTitle: title) {
                        // Regenerate tags with the real title
                        let updatedTags = AutoTagService.shared.generateTags(url: url.absoluteString, title: title)
                        mvc.model.updateLinkTags(id: linkId, tags: updatedTags)
                    }
                }

                // AI organize (if enabled and user didn't explicitly choose a workspace)
                if AIOrganizationService.shared.isAvailable && !userChoseWorkspace {
                    Task {
                        // Wait briefly for title to be fetched
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                        // Get the updated title from the model
                        let currentTitle: String
                        if let node = mvc.model.findNode(id: linkId, in: mvc.model.currentWorkspace.items),
                           case .link(let link) = node {
                            currentTitle = link.title
                        } else {
                            currentTitle = initialTitle
                        }

                        guard let decision = await AIOrganizationService.shared.organize(
                            url: url.absoluteString,
                            title: currentTitle,
                            workspaces: mvc.model.workspaces,
                            excludeLinkId: linkId
                        ) else { return }

                        // Execute the decision
                        mvc.model.deleteNode(id: linkId)
                        let newLinkId = mvc.model.executeAIOrganization(url: url.absoluteString, title: currentTitle, decision: decision)

                        // Fetch title for newly placed link
                        LinkTitleService.shared.fetchTitle(for: url, linkId: newLinkId) { title in
                            guard let title else { return }
                            _ = mvc.model.updateLinkTitleIfDefault(id: newLinkId, newTitle: title)
                        }
                    }
                }
            }
        }
    }

    @objc private func saveAllBrowserTabs() {
        guard let mvc = mainViewController else { return }
        let bundleId = BrowserManager.resolveDefaultBrowserBundleId() ?? ""
        let tabs = BrowserTabService.getOpenTabs(browserBundleId: bundleId)

        guard !tabs.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Tabs Found"
            alert.informativeText = "Could not read tabs from the browser. Make sure the browser is running."
            alert.runModal()
            return
        }

        // Confirm
        let alert = NSAlert()
        alert.messageText = "Save \(tabs.count) Browser Tabs?"
        alert.informativeText = "This will create a new folder with all open tabs in the current workspace."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Create a folder with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        let folderName = "Tabs — \(formatter.string(from: Date()))"
        let folderId = mvc.model.addFolder(name: folderName, parentId: nil)

        // Add each tab as a link
        for tab in tabs {
            mvc.model.addLink(urlString: tab.url, title: tab.title, parentId: folderId)
        }
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        GlobalHotkeyService.shared.delegate = self

        if let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.toggleSidebarShortcut) {
            // Key exists: decode saved shortcut, or treat as explicitly cleared
            if let saved = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
                GlobalHotkeyService.shared.register(shortcut: saved)
            }
        } else {
            // No data = first launch, use default
            GlobalHotkeyService.shared.register(shortcut: .defaultToggleSidebar)
        }
    }

    func hotkeyServiceDidTrigger(_ service: GlobalHotkeyService) {
        // Silently ignore when Always on Top is enabled
        let alwaysOnTopEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        guard !alwaysOnTopEnabled else { return }

        guard let window = window else { return }

        if window.isVisible && !isUserHidden {
            // Hide window
            isUserHidden = true
            window.orderOut(nil)
        } else {
            // Show window
            isUserHidden = false
            if isAttachmentMode {
                WindowAttachmentService.shared.forceUpdate()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Window Attachment

    private func setupAttachmentService() {
        WindowAttachmentService.shared.delegate = self

        // Check for mutual exclusion with always on top
        let alwaysOnTopEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        if alwaysOnTopEnabled {
            // Don't enable attachment if always on top is enabled
            return
        }

        let attachmentEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
        guard attachmentEnabled else { return }

        // Load preferences
        let positionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right"
        let position: SidebarPosition = positionString == "left" ? .left : .right

        // Save current frame before entering attachment mode
        if let window = window {
            lastManualFrame = window.frame
        }

        isAttachmentMode = true
        updateWindowConstraints()

        // Enable without specific browser — attaches to any frontmost browser
        WindowAttachmentService.shared.enable(position: position)
    }

    private func updateWindowConstraints() {
        guard let window = window else { return }

        if isAttachmentMode {
            // In attachment mode: allow unlimited height, disable manual movement
            window.minSize = NSSize(width: 280, height: 100)
            window.maxSize = NSSize(width: 520, height: 10000)
            window.isMovable = false
            window.isMovableByWindowBackground = false
        } else {
            // Manual mode: restore original constraints, enable movement
            window.minSize = NSSize(width: 280, height: 420)
            window.maxSize = NSSize(width: 520, height: 10000)
            window.isMovable = true
            window.isMovableByWindowBackground = true

            // Restore last manual frame if available
            if let lastFrame = lastManualFrame {
                window.setFrame(lastFrame, display: true, animate: false)
            }
        }
    }

    private func observeBrowserChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserChanged),
            name: .defaultBrowserChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAlwaysOnTopSettingChanged),
            name: .alwaysOnTopSettingChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAttachmentSettingChanged),
            name: .attachmentSettingChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarPositionChanged),
            name: .sidebarPositionChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleSidebarShortcutChanged),
            name: .toggleSidebarShortcutChanged,
            object: nil
        )
    }

    @objc private func handleBrowserChanged(_ notification: Notification) {
        // With adaptive multi-browser attachment, browser changes don't require action
        // The service automatically attaches to whichever browser is frontmost
        // This handler can be left for compatibility but doesn't need to restart the service
    }

    @objc private func handleAlwaysOnTopSettingChanged(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }

        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal

        // Reset user-hidden state when Always on Top changes
        if enabled {
            isUserHidden = false
        }

        // If enabling and attachment is active, disable attachment
        if enabled && isAttachmentMode {
            if let window = window {
                lastManualFrame = window.frame
            }
            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            updateWindowConstraints()
        }
    }

    @objc private func handleAttachmentSettingChanged(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }

        if enabled {
            // Enable attachment
            let positionString = notification.userInfo?["position"] as? String ?? "right"
            let position: SidebarPosition = positionString == "left" ? .left : .right

            if let window = window {
                lastManualFrame = window.frame
            }

            isAttachmentMode = true
            updateWindowConstraints()
            WindowAttachmentService.shared.enable(position: position)
        } else {
            // Disable attachment
            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            isUserHidden = false
            updateWindowConstraints()

            // Show window in case it was hidden
            window?.orderFront(nil)
        }
    }

    @objc private func handleSidebarPositionChanged(_ notification: Notification) {
        guard isAttachmentMode,
              let positionString = notification.userInfo?["position"] as? String else {
            return
        }

        let position: SidebarPosition = positionString == "left" ? .left : .right

        // Re-enable with new position
        WindowAttachmentService.shared.disable()
        WindowAttachmentService.shared.enable(position: position)
    }

    @objc private func handleToggleSidebarShortcutChanged() {
        if let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.toggleSidebarShortcut),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            GlobalHotkeyService.shared.register(shortcut: shortcut)
        } else {
            GlobalHotkeyService.shared.unregister()
        }
    }

    // MARK: - WindowAttachmentServiceDelegate

    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool) {
        guard let window = window else { return }

        // Capture visibility state once to avoid TOCTOU race during rapid activation
        let wasHidden = !window.isVisible
        if wasHidden {
            // Clear user-hidden state when browser becomes active and wants to show the window
            // This ensures that after hiding via global hotkey, the sidebar reappears when switching back to browser
            isUserHidden = false
            window.setFrame(frame, display: true, animate: false)
            window.orderFront(nil)
            return
        }

        // Skip if frame hasn't changed and window is already visible
        if window.frame == frame { return }

        // Apply frame with smooth animation
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            })
        } else {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService) {
        window?.orderOut(nil)
    }

    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService) {
        guard !isUserHidden else { return }
        window?.orderFront(nil)
    }
}
