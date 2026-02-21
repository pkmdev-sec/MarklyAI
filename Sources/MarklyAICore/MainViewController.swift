import AppKit
@preconcurrency import Sparkle

@MainActor
final class MainViewController: NSViewController {
    let model: AppModel

    // Coordinators and child view controllers
    private let searchCoordinator = SearchCoordinator()
    private let nodeListViewController = NodeListViewController()
    private let settingsViewController = SettingsContentViewController()

    // UI Components
    private let workspaceSwitcher = WorkspaceSwitcherView(style: .defaultStyle)
    private let searchField = SearchBarView(style: .defaultSearch)
    private let pinnedTabsView = PinnedTabsView()
    private let pasteButton = IconTitleButton(
        title: "Add links from clipboard",
        symbolName: "plus",
        style: .pasteAction
    )
    private var clipboardBanner: ClipboardSaveBanner?

    // Concise sidebar mode
    enum SidebarMode { case full, concise }
    private var sidebarMode: SidebarMode = .full
    private let conciseSidebarView = ConciseSidebarView()
    private var workspaceOverlayPanel: WorkspaceOverlayPanel?
    private let emptyStateView: NSStackView = {
        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = NSColor.secondaryLabelColor
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40)
        ])

        // Title
        let titleLabel = NSTextField(labelWithString: "No links yet")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.textColor = NSColor.labelColor
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Paste URLs or press + to get started")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)

        // Stack
        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.isHidden = true

        return stack
    }()

    // Sparkle updater (passed from AppDelegate)
    var updater: SPUUpdater? {
        didSet { settingsViewController.updater = updater }
    }

    // State
    private var isReloadScheduled = false
    private var hasLoaded = false
    private var lastWorkspaceId: UUID?
    private var pendingWorkspaceRenameId: UUID?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var undoManager: UndoManager? {
        model.undoManager
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.wantsLayer = true
        effectView.material = .hudWindow  // Dark translucent material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChildViewControllers()
        setupUI()
        setupSearchCoordinator()
        setupNodeListCallbacks()
        bindModel()
        setupClipboardMonitoring()
        reloadData()

        // Listen for favicon updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdate),
            name: .init("UpdateLinkFavicon"),
            object: nil
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Concise mode is triggered by WindowAttachmentService frame calculation,
        // not by viewDidLayout. This prevents false triggers during settings view.
    }

    // MARK: - Setup

    private func setupChildViewControllers() {
        addChild(nodeListViewController)
        addChild(settingsViewController)
    }

    private func setupUI() {
        // Workspace switcher
        workspaceSwitcher.translatesAutoresizingMaskIntoConstraints = false
        workspaceSwitcher.onWorkspaceSelected = { [weak self] workspaceId in
            self?.model.selectWorkspace(id: workspaceId)
        }
        workspaceSwitcher.onWorkspaceRightClick = { [weak self] workspaceId, point in
            self?.showWorkspaceContextMenu(for: workspaceId, at: point)
        }
        workspaceSwitcher.onAddWorkspace = { [weak self] in
            self?.promptCreateWorkspace()
        }
        workspaceSwitcher.onWorkspaceRename = { [weak self] workspaceId, newName in
            self?.model.renameWorkspace(id: workspaceId, newName: newName)
        }
        workspaceSwitcher.onSettingsSelected = { [weak self] in
            self?.model.selectSettings()
        }

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search in workspace"
        searchField.onTextChange = { [weak self] text in
            self?.nodeListViewController.clearSelections()
            self?.searchCoordinator.updateQuery(text)
        }

        // Pinned tabs
        pinnedTabsView.onLinkClicked = { [weak self] linkId in
            guard let self, let link = self.model.pinnedLinkById(linkId) else { return }
            self.openLink(link)
        }
        pinnedTabsView.onLinkRightClicked = { [weak self] linkId, event in
            self?.showPinnedTabContextMenu(for: linkId, at: event)
        }

        // Paste button
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.target = self
        pasteButton.action = #selector(pasteLink)
        pasteButton.toolTip = "Add links from clipboard"

        // Node list view
        nodeListViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Settings view
        settingsViewController.appModel = model
        settingsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        settingsViewController.view.isHidden = true

        // Layout
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(workspaceSwitcher)

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(pasteButton)

        let stack = NSStackView(views: [topBar, searchField, pinnedTabsView, nodeListViewController.view, bottomBar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .centerX

        view.addSubview(stack)
        view.addSubview(settingsViewController.view)
        view.addSubview(emptyStateView)

        // Setup concise sidebar view (hidden initially)
        conciseSidebarView.translatesAutoresizingMaskIntoConstraints = false
        conciseSidebarView.isHidden = true
        view.addSubview(conciseSidebarView)
        NSLayoutConstraint.activate([
            conciseSidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conciseSidebarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conciseSidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            conciseSidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Wire up concise sidebar callbacks
        conciseSidebarView.onWorkspaceHover = { [weak self] workspaceId, screenRect in
            guard let self, let workspace = self.model.workspaces.first(where: { $0.id == workspaceId }) else { return }
            if self.workspaceOverlayPanel == nil {
                self.workspaceOverlayPanel = WorkspaceOverlayPanel()
                self.workspaceOverlayPanel?.onLinkClicked = { [weak self] link in
                    guard let url = URL(string: link.url) else { return }
                    BrowserManager.open(url: url)
                }
            }
            self.workspaceOverlayPanel?.cancelHide()
            self.workspaceOverlayPanel?.show(workspace: workspace, anchorRect: screenRect)
        }

        conciseSidebarView.onWorkspaceClick = { [weak self] workspaceId in
            self?.model.selectWorkspace(id: workspaceId)
        }

        conciseSidebarView.onHoverExit = { [weak self] in
            self?.workspaceOverlayPanel?.scheduleHide()
        }

        NSLayoutConstraint.activate([
            workspaceSwitcher.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            workspaceSwitcher.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            workspaceSwitcher.topAnchor.constraint(equalTo: topBar.topAnchor),
            workspaceSwitcher.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),

            pasteButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            pasteButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            pasteButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: LayoutConstants.windowPadding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -LayoutConstants.windowPadding),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: LayoutConstants.windowPadding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -LayoutConstants.windowPadding),

            topBar.heightAnchor.constraint(equalToConstant: 30),
            bottomBar.heightAnchor.constraint(equalToConstant: pasteButton.style.height)
        ])

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 2),
            searchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -2),
            pinnedTabsView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 2),
            pinnedTabsView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -2),
        ])

        // Settings view constraints
        NSLayoutConstraint.activate([
            settingsViewController.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            settingsViewController.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            settingsViewController.view.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            settingsViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -LayoutConstants.windowPadding)
        ])

        // Empty state label constraints
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupSearchCoordinator() {
        searchCoordinator.onQueryChanged = { [weak self] _ in
            self?.reloadData()
        }
    }

    private func setupNodeListCallbacks() {
        nodeListViewController.nodeProvider = { [weak self] in
            guard let self else { return [] }
            return self.searchCoordinator.filter(nodes: self.model.currentWorkspace.items)
        }

        nodeListViewController.workspacesProvider = { [weak self] in
            self?.model.workspaces ?? []
        }

        nodeListViewController.currentWorkspaceIdProvider = { [weak self] in
            self?.model.currentWorkspace.id
        }

        nodeListViewController.findNodeById = { [weak self] id in
            self?.model.nodeById(id)
        }

        nodeListViewController.findNodeLocation = { [weak self] id in
            self?.model.location(of: id)
        }

        nodeListViewController.findNodeInNodes = { [weak self] id, nodes in
            self?.model.findNode(id: id, in: nodes)
        }

        nodeListViewController.onNodeSelected = { [weak self] nodeId in
            guard let self, let node = self.model.nodeById(nodeId) else { return }
            if case .link(let link) = node {
                self.openLink(link)
            }
        }

        nodeListViewController.onFolderToggled = { [weak self] folderId, _ in
            guard let self else { return }
            if self.searchCoordinator.isSearchActive { return }
            if let node = self.model.nodeById(folderId), case .folder(let folder) = node {
                self.model.setFolderExpanded(id: folder.id, isExpanded: !folder.isExpanded)
            }
        }

        nodeListViewController.onNodeMoved = { [weak self] nodeId, targetParentId, targetIndex in
            self?.model.moveNode(id: nodeId, toParentId: targetParentId, index: targetIndex)
        }

        nodeListViewController.onNodeDeleted = { [weak self] nodeId in
            self?.model.deleteNode(id: nodeId)
        }

        nodeListViewController.onNodeRenamed = { [weak self] nodeId, newName in
            self?.model.renameNode(id: nodeId, newName: newName)
        }

        nodeListViewController.onNodeMovedToWorkspace = { [weak self] nodeId, workspaceId in
            self?.model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesMovedToWorkspace = { [weak self] nodeIds, workspaceId in
            self?.model.moveNodesToWorkspace(nodeIds: nodeIds, toWorkspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesGrouped = { [weak self] nodeIds, folderName in
            self?.model.groupNodesInNewFolder(nodeIds: nodeIds, folderName: folderName)
        }

        nodeListViewController.onBulkNodesCopied = { [weak self] nodeIds in
            self?.handleBulkCopyLinks(nodeIds)
        }

        nodeListViewController.onBulkNodesDeleted = { [weak self] nodeIds in
            guard let self else { return }
            for nodeId in nodeIds {
                self.model.deleteNode(id: nodeId)
            }
        }

        nodeListViewController.onNewFolderRequested = { [weak self] parentId in
            self?.createFolderAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onLinkUrlEdited = { [weak self] nodeId, newUrl in
            self?.model.updateLinkUrl(id: nodeId, newUrl: newUrl)
        }

        nodeListViewController.onPinLink = { [weak self] nodeId in
            self?.model.pinLink(id: nodeId)
        }

        nodeListViewController.canPinLink = { [weak self] in
            self?.model.canPinMore ?? false
        }

        nodeListViewController.onOpenAllInFolder = { [weak self] folderId in
            guard let self else { return }
            if let folder = self.model.findNode(id: folderId, in: self.model.currentWorkspace.items),
               case .folder(let f) = folder {
                let links = self.collectAllLinks(from: f.children)
                guard !links.isEmpty else { return }

                // Show confirmation for large link counts
                if links.count > 10 {
                    let alert = NSAlert()
                    alert.messageText = "Open \(links.count) Links?"
                    alert.informativeText = "This will open \(min(links.count, 30)) links as new browser tabs."
                    alert.addButton(withTitle: "Open All")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .informational
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }

                for (index, link) in links.prefix(30).enumerated() {
                    guard let url = URL(string: link.url) else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                        BrowserManager.open(url: url)
                    }
                }
            }
        }
    }

    private func bindModel() {
        model.onChange = { [weak self] in
            guard let self else { return }
            if self.isReloadScheduled { return }
            self.isReloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReloadScheduled = false
                self.reloadData()
            }
        }
    }

    // MARK: - Data Reload

    private func countNodes(in nodes: [Node]) -> Int {
        var count = 0
        for node in nodes {
            count += 1
            if case .folder(let folder) = node {
                count += countNodes(in: folder.children)
            }
        }
        return count
    }

    private func reloadData() {
        // Cancel any in-progress inline rename if node is deleted
        if let renameId = nodeListViewController.inlineRenameNodeId,
           model.nodeById(renameId) == nil {
            nodeListViewController.cancelInlineRename()
        }

        reloadWorkspaceMenu()

        // Notify settings view that workspaces may have changed
        settingsViewController.notifyWorkspacesChanged()

        // Clear selections when workspace changes
        let currentWorkspaceId = model.currentWorkspace.id
        if hasLoaded && currentWorkspaceId != lastWorkspaceId {
            nodeListViewController.clearSelections()
            lastWorkspaceId = currentWorkspaceId
        }

        // Check if settings is selected
        if model.state.isSettingsSelected {
            nodeListViewController.clearSelections()
            showSettingsContent()
        } else {
            showWorkspaceContent()
            applyWorkspaceStyling()
            pinnedTabsView.update(pinnedLinks: model.currentWorkspace.pinnedLinks)
            let filteredNodes = searchCoordinator.filter(nodes: model.currentWorkspace.items)
            let forceExpand = searchCoordinator.isSearchActive
            nodeListViewController.isSearchActive = searchCoordinator.isSearchActive
            nodeListViewController.reloadData(with: filteredNodes, forceExpand: forceExpand)

            // Update search result count
            if searchCoordinator.isSearchActive {
                let count = countNodes(in: filteredNodes)
                searchField.resultCount = count
            } else {
                searchField.resultCount = nil
            }

            // Show/hide empty state
            let hasItems = !model.currentWorkspace.items.isEmpty
            emptyStateView.isHidden = hasItems
        }
        hasLoaded = true
    }

    private func reloadWorkspaceMenu() {
        let workspaces = model.workspaces

        workspaceSwitcher.workspaces = workspaces.map { workspace in
            WorkspaceSwitcherView.WorkspaceItem(
                id: workspace.id,
                name: workspace.name,
                colorId: workspace.colorId
            )
        }

        workspaceSwitcher.isSettingsSelected = model.state.isSettingsSelected

        if model.state.isSettingsSelected {
            workspaceSwitcher.selectedWorkspaceId = nil
            workspaceSwitcher.workspaceColor = .settingsBackground
        } else {
            let selectedId = model.currentWorkspace.id
            workspaceSwitcher.selectedWorkspaceId = selectedId
            workspaceSwitcher.workspaceColor = model.currentWorkspace.colorId
        }

        handlePendingWorkspaceRename()
    }

    private func applyWorkspaceStyling() {
        // Workspace color is only shown on tab borders
        nodeListViewController.workspaceColor = model.currentWorkspace.colorId
    }

    private func showSettingsContent() {
        // Always show workspace switcher
        workspaceSwitcher.isHidden = false
        conciseSidebarView.isHidden = true

        // Hide workspace content
        searchField.isHidden = true
        pinnedTabsView.isHidden = true
        pasteButton.isHidden = true
        nodeListViewController.view.isHidden = true
        emptyStateView.isHidden = true

        // Show settings content
        settingsViewController.view.isHidden = false
    }

    private func showWorkspaceContent() {
        // Always show workspace switcher
        workspaceSwitcher.isHidden = false
        conciseSidebarView.isHidden = true

        // Show workspace content
        searchField.isHidden = false
        pinnedTabsView.isHidden = model.currentWorkspace.pinnedLinks.isEmpty
        pasteButton.isHidden = false
        nodeListViewController.view.isHidden = false

        // Hide settings content
        settingsViewController.view.isHidden = true
    }

    // MARK: - Workspace Management

    private func showWorkspaceContextMenu(for workspaceId: UUID, at point: NSPoint) {
        // Temporarily select the workspace for context menu actions
        let previousWorkspaceId = model.currentWorkspace.id
        if previousWorkspaceId != workspaceId {
            model.selectWorkspace(id: workspaceId)
        }

        let menu = NSMenu()
        let canDelete = model.workspaces.count > 1
        guard let workspaceIndex = model.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let canMoveLeft = workspaceIndex > 0
        let canMoveRight = workspaceIndex < model.workspaces.count - 1

        let openAllItem = NSMenuItem(title: "Open All in Browser", action: #selector(openAllLinksInWorkspace), keyEquivalent: "")
        openAllItem.target = self
        openAllItem.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open All")
        menu.addItem(openAllItem)
        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(title: "Rename Workspace…", action: #selector(renameWorkspaceFromMenu), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")
        menu.addItem(renameItem)

        let colorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Change Color")
        let colorSubmenu = NSMenu()
        for colorId in WorkspaceColorId.allCases {
            let colorMenuItem = NSMenuItem(title: colorId.name, action: #selector(changeColorTo(_:)), keyEquivalent: "")
            colorMenuItem.target = self
            colorMenuItem.representedObject = colorId
            colorMenuItem.image = createColorPreviewImage(color: colorId.color)
            if colorId == model.currentWorkspace.colorId {
                colorMenuItem.state = .on
            }
            colorSubmenu.addItem(colorMenuItem)
        }
        colorItem.submenu = colorSubmenu
        menu.addItem(colorItem)

        if canMoveLeft || canMoveRight {
            menu.addItem(NSMenuItem.separator())

            if canMoveLeft {
                let moveLeftItem = NSMenuItem(title: "Move Left", action: #selector(moveWorkspaceLeft), keyEquivalent: "")
                moveLeftItem.target = self
                moveLeftItem.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: "Move Left")
                menu.addItem(moveLeftItem)
            }

            if canMoveRight {
                let moveRightItem = NSMenuItem(title: "Move Right", action: #selector(moveWorkspaceRight), keyEquivalent: "")
                moveRightItem.target = self
                moveRightItem.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Move Right")
                menu.addItem(moveRightItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "Delete Workspace…", action: #selector(deleteWorkspaceFromMenu), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = canDelete
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        menu.addItem(deleteItem)

        if view.window != nil {
            let pointInView = view.convert(point, from: nil)
            menu.popUp(positioning: nil, at: pointInView, in: view)
        }
    }

    @objc private func renameWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        workspaceSwitcher.beginInlineRename(workspaceId: workspace.id)
    }

    @objc private func changeColorTo(_ sender: NSMenuItem) {
        guard let colorId = sender.representedObject as? WorkspaceColorId else { return }
        let workspace = model.currentWorkspace
        model.updateWorkspaceColor(id: workspace.id, colorId: colorId)
    }

    private func createColorPreviewImage(color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        // Add subtle border
        let borderColor = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.078, alpha: 0.20)
        borderColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        image.unlockFocus()
        return image
    }

    @objc private func deleteWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        let alert = NSAlert()
        alert.messageText = "Delete Workspace"
        alert.informativeText = "This will delete the workspace and everything inside it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteWorkspace(id: workspace.id)
        }
    }

    @objc private func moveWorkspaceLeft() {
        let workspace = model.currentWorkspace
        model.moveWorkspace(id: workspace.id, direction: .left)
    }

    @objc private func moveWorkspaceRight() {
        let workspace = model.currentWorkspace
        model.moveWorkspace(id: workspace.id, direction: .right)
    }

    func promptCreateWorkspace() {
        let workspaceId = model.createWorkspace(name: "Untitled Workspace", colorId: .randomColor())
        scheduleWorkspaceInlineRename(for: workspaceId)
    }

    private func scheduleWorkspaceInlineRename(for workspaceId: UUID) {
        pendingWorkspaceRenameId = workspaceId
    }

    private func handlePendingWorkspaceRename() {
        guard let workspaceId = pendingWorkspaceRenameId else { return }
        pendingWorkspaceRenameId = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workspaceSwitcher.beginInlineRename(workspaceId: workspaceId)
        }
    }

    // MARK: - Node Management

    func createFolderAndBeginRename(parentId: UUID?) {
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addFolder(name: "Untitled", parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    func focusSearchField() {
        // Make sure we're showing workspace content, not settings
        if model.state.isSettingsSelected { return }
        searchField.focus()
    }

    @objc func paste(_ sender: Any?) {
        pasteLink()
    }

    @objc private func pasteLink() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        let urls = extractUrls(from: pasted)
        guard !urls.isEmpty else { return }
        
        print("[PASTE] Extracted \(urls.count) URLs")
        
        for url in urls {
            print("[PASTE] Processing URL: \(url.absoluteString)")
            
            // Check for duplicate
            if let duplicate = model.findDuplicateLink(url: url.absoluteString) {
                print("[PASTE] Duplicate found: \(duplicate.linkTitle) in \(duplicate.workspaceName)")
                let alert = NSAlert()
                alert.messageText = "Duplicate Link"
                alert.informativeText = "This link already exists as \"\(duplicate.linkTitle)\" in \(duplicate.workspaceName)."
                alert.addButton(withTitle: "Add Anyway")
                alert.addButton(withTitle: "Skip")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    print("[PASTE] User skipped duplicate")
                    continue
                }
                print("[PASTE] User chose to add anyway")
            }

            print("[PASTE] Adding link to workspace")
            let title = titleForUrl(url)
            let linkId = model.addLink(urlString: url.absoluteString, title: title, parentId: nil)
            print("[PASTE] Link added with ID: \(linkId)")
            
            fetchTitleForNewLink(id: linkId, url: url)

            // Auto-generate tags
            let tags = AutoTagService.shared.generateTags(url: url.absoluteString, title: title)
            model.updateLinkTags(id: linkId, tags: tags)

            // AI organization (async, non-blocking)
            if AIOrganizationService.shared.isAvailable {
                print("[PASTE] AI organize is available, scheduling organization")
                organizeWithAI(linkId: linkId, url: url.absoluteString, title: title)
            } else {
                print("[PASTE] AI organize not available")
            }
        }
    }

    private func openLink(_ link: Link) {
        guard let url = URL(string: link.url) else { return }
        model.markLinkOpened(id: link.id)
        BrowserManager.open(url: url)
    }

    // MARK: - AI Organization

    private func organizeWithAI(linkId: UUID, url: String, title: String) {
        print("[AI ORG] Starting organize for link: \(linkId), url: \(url)")
        Task {
            // Wait briefly for title to be fetched
            print("[AI ORG] Waiting 2 seconds for title fetch")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            // Get the updated title from the model
            let currentTitle: String
            if let node = model.findNode(id: linkId, in: model.currentWorkspace.items),
               case .link(let link) = node {
                currentTitle = link.title
                print("[AI ORG] Found link in workspace, using title: \(currentTitle)")
            } else {
                currentTitle = title
                print("[AI ORG] Link not found in current workspace, using original title: \(currentTitle)")
            }

            print("[AI ORG] Calling AI service to get organization decision")
            guard let decision = await AIOrganizationService.shared.organize(
                url: url,
                title: currentTitle,
                workspaces: model.workspaces,
                excludeLinkId: linkId
            ) else {
                print("[AI ORG] AI service returned nil, aborting")
                return
            }

            print("[AI ORG] AI decision: action=\(decision.action), reasoning=\(decision.reasoning)")
            print("[AI ORG] wsId=\(decision.workspaceId?.uuidString ?? "nil"), folderId=\(decision.folderId?.uuidString ?? "nil"), newWs=\(decision.newWorkspaceName ?? "nil"), newFolder=\(decision.newFolderName ?? "nil")")

            // Execute the AI's decision — move the link to the right place
            let sourceWorkspaceId = model.currentWorkspace.id
            var targetWorkspaceId = decision.workspaceId ?? sourceWorkspaceId

            switch decision.action {
            case .createWorkspace:
                if let name = decision.newWorkspaceName {
                    print("[AI ORG] Creating workspace: \(name)")
                    let newWsId = model.createWorkspace(name: name, colorId: .randomColor())
                    targetWorkspaceId = newWsId
                    // createWorkspace auto-selects new workspace — switch back to source
                    // so moveNodeToWorkspace can find the link
                    model.selectWorkspace(id: sourceWorkspaceId)
                    print("[AI ORG] Switched back to source workspace for move")
                }

            case .createFolder:
                if let folderName = decision.newFolderName {
                    let wsId = decision.workspaceId ?? sourceWorkspaceId
                    print("[AI ORG] Creating folder: \(folderName) in workspace \(wsId)")
                    targetWorkspaceId = wsId
                    model.selectWorkspace(id: wsId)
                    let folderId = model.addFolder(name: folderName, parentId: decision.folderId)
                    // Switch back to source to move the link
                    model.selectWorkspace(id: sourceWorkspaceId)
                    model.moveNodeToWorkspace(id: linkId, workspaceId: wsId)
                    model.selectWorkspace(id: wsId)
                    model.moveNode(id: linkId, toParentId: folderId, index: 0)
                    model.selectWorkspace(id: sourceWorkspaceId)
                    print("[AI ORG] Link moved to folder \(folderName)")
                    await showAIOrganizationResult(decision.reasoning)
                    return
                }

            case .place:
                print("[AI ORG] Placing in existing workspace")
            }

            // Move link to target workspace (if different from source)
            if targetWorkspaceId != sourceWorkspaceId {
                print("[AI ORG] Moving link from \(sourceWorkspaceId) to \(targetWorkspaceId)")
                // Ensure we're on the source workspace so moveNodeToWorkspace finds the link
                model.selectWorkspace(id: sourceWorkspaceId)
                model.moveNodeToWorkspace(id: linkId, workspaceId: targetWorkspaceId)

                // If there's a target folder, move into it
                if let folderId = decision.folderId {
                    model.selectWorkspace(id: targetWorkspaceId)
                    model.moveNode(id: linkId, toParentId: folderId, index: 0)
                    model.selectWorkspace(id: sourceWorkspaceId)
                }
                print("[AI ORG] Move complete")
            } else if let folderId = decision.folderId {
                model.moveNode(id: linkId, toParentId: folderId, index: 0)
            }

            print("[AI ORG] Organization complete")
            await showAIOrganizationResult(decision.reasoning)
        }
    }

    private func showAIOrganizationResult(_ reasoning: String) async {
        // Run on main thread
        await MainActor.run {
            // Show a brief notification at the bottom of the window
            let label = NSTextField(labelWithString: "AI: \(reasoning)")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor.labelColor
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            label.layer?.cornerRadius = 6
            label.lineBreakMode = .byTruncatingTail

            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -50),
                label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
                label.heightAnchor.constraint(equalToConstant: 24)
            ])

            // Fade in then out after 3 seconds
            label.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                label.animator().alphaValue = 1
            }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.3
                        label.animator().alphaValue = 0
                    }) {
                        label.removeFromSuperview()
                    }
                }
            }
        }
    }

    // MARK: - URL Utilities

    private func normalizedUrl(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        if lower.hasPrefix("localhost") {
            return URL(string: "http://\(trimmed)")
        }

        return nil
    }

    private func extractUrls(from text: String) -> [URL] {
        let pattern = #"(?i)\b(?:https?://[^\s<>"',;]+|localhost(?::\d+)?(?:/[^\s<>"',;]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var urls: [URL] = []

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let stringRange = Range(matchRange, in: text) else { return }
            let candidate = stripTrailingPunctuation(from: String(text[stringRange]))
            if let url = normalizedUrl(from: candidate) {
                urls.append(url)
            }
        }

        return urls
    }

    private func stripTrailingPunctuation(from value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, ".,;:)]}?!".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func titleForUrl(_ url: URL) -> String {
        if let host = url.host {
            return host
        }
        return url.absoluteString
    }

    private func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { [weak self] title in
            guard let self, let title else { return }
            _ = self.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }

    @objc private func handleFaviconUpdate(_ notification: Notification) {
        guard let linkId = notification.userInfo?["linkId"] as? UUID,
              let path = notification.userInfo?["path"] as? String else { return }
        if model.pinnedLinkById(linkId) != nil {
            model.updatePinnedLinkFaviconPath(id: linkId, path: path)
        } else {
            // Update model silently (notify: false) to avoid full reloadData().
            // Safe because we update the specific cell's icon directly below,
            // and pinned links are handled separately above.
            model.updateLinkFaviconPath(id: linkId, path: path, notify: false)
            nodeListViewController.updateFavicon(for: linkId, path: path)
        }
    }

    // MARK: - Pinned Tabs

    private func showPinnedTabContextMenu(for linkId: UUID, at event: NSEvent) {
        let menu = NSMenu()
        let unpinItem = NSMenuItem(title: "Unpin", action: #selector(unpinTab(_:)), keyEquivalent: "")
        unpinItem.target = self
        unpinItem.representedObject = linkId
        unpinItem.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: "Unpin")
        menu.addItem(unpinItem)
        NSMenu.popUpContextMenu(menu, with: event, for: pinnedTabsView)
    }

    @objc private func unpinTab(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID else { return }
        model.unpinLink(id: linkId)
    }

    // MARK: - Bulk Operations

    private func handleBulkCopyLinks(_ nodeIds: [UUID]) {
        let nodes = nodeIds.compactMap { id in
            model.findNode(id: id, in: model.currentWorkspace.items)
        }
        let urls = nodes.compactMap { node -> String? in
            if case .link(let link) = node {
                return link.url
            }
            return nil
        }

        guard !urls.isEmpty else { return }

        let joined = urls.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    // MARK: - Open All in Browser

    @objc func openAllLinksInWorkspace() {
        let links = collectAllLinks(from: model.currentWorkspace.items)
        guard !links.isEmpty else { return }

        // Show confirmation for large link counts
        if links.count > 10 {
            let alert = NSAlert()
            alert.messageText = "Open \(links.count) Links?"
            alert.informativeText = "This will open \(min(links.count, 30)) links as new browser tabs."
            alert.addButton(withTitle: "Open All")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Open with slight delay between each to avoid browser overload (cap at 30)
        for (index, link) in links.prefix(30).enumerated() {
            guard let url = URL(string: link.url) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                BrowserManager.open(url: url)
            }
        }
    }

    private func collectAllLinks(from nodes: [Node]) -> [Link] {
        var links: [Link] = []
        for node in nodes {
            switch node {
            case .link(let link):
                links.append(link)
            case .folder(let folder):
                links.append(contentsOf: collectAllLinks(from: folder.children))
            }
        }
        return links
    }

    // MARK: - Clipboard Monitoring

    private func setupClipboardMonitoring() {
        ClipboardMonitorService.shared.onURLDetected = { [weak self] url in
            self?.showClipboardBanner(for: url)
        }
        ClipboardMonitorService.shared.start()
    }

    private func showClipboardBanner(for url: URL) {
        // Hide any existing banner
        hideClipboardBanner()

        // Create new banner
        let banner = ClipboardSaveBanner(url: url)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.onSave = { [weak self] in
            guard let self else { return }
            let linkId = self.model.addLink(urlString: url.absoluteString, title: url.host ?? url.absoluteString, parentId: nil)
            self.fetchTitleForNewLink(id: linkId, url: url)
            self.hideClipboardBanner()

            // AI organize
            if AIOrganizationService.shared.isAvailable {
                self.organizeWithAI(linkId: linkId, url: url.absoluteString, title: url.host ?? url.absoluteString)
            }
        }
        banner.onDismiss = { [weak self] in
            self?.hideClipboardBanner()
        }

        view.addSubview(banner)

        // Position at the bottom, just above the "Add links from clipboard" button
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: LayoutConstants.windowPadding),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -LayoutConstants.windowPadding),
            banner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(LayoutConstants.windowPadding + 40)),
            banner.heightAnchor.constraint(equalToConstant: 32)
        ])

        clipboardBanner = banner

        // Animate in
        banner.layer?.opacity = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            banner.animator().layer?.opacity = 1
        })

        // Auto-hide after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.hideClipboardBanner()
        }
    }

    private func hideClipboardBanner() {
        guard let banner = clipboardBanner else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            banner.animator().layer?.opacity = 0
        }, completionHandler: {
            banner.removeFromSuperview()
        })

        clipboardBanner = nil
    }

    // MARK: - Sidebar Mode Management

    func setSidebarMode(_ mode: SidebarMode) {
        guard mode != sidebarMode else { return }
        sidebarMode = mode

        switch mode {
        case .full:
            // Hide concise UI
            conciseSidebarView.isHidden = true
            workspaceOverlayPanel?.dismiss()

            // Show full UI based on current state
            if model.state.isSettingsSelected {
                showSettingsContent()
            } else {
                showWorkspaceContent()
            }

        case .concise:
            // Hide full UI
            workspaceSwitcher.isHidden = true
            searchField.isHidden = true
            nodeListViewController.view.isHidden = true
            pasteButton.isHidden = true
            settingsViewController.view.isHidden = true
            pinnedTabsView.isHidden = true
            emptyStateView.isHidden = true

            // Show concise UI
            conciseSidebarView.isHidden = false
            conciseSidebarView.workspaces = model.workspaces
            conciseSidebarView.selectedWorkspaceId = model.state.selectedWorkspaceId
        }
    }
}

// MARK: - Clipboard Save Banner

private final class ClipboardSaveBanner: NSView {
    private let url: URL
    var onSave: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let dismissButton = NSButton(title: "×", target: nil, action: nil)

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 6

        // Label
        label.stringValue = "Save: \(url.host ?? url.absoluteString)"
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        // Save button
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        // Dismiss button
        dismissButton.isBordered = false
        dismissButton.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        dismissButton.contentTintColor = NSColor.secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(saveButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 20),

            saveButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -8)
        ])
    }

    @objc private func handleSave() {
        onSave?()
    }

    @objc private func handleDismiss() {
        onDismiss?()
    }
}

// MARK: - Vibrancy Blocking View
