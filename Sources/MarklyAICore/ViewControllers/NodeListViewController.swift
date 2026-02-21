//
//  NodeListViewController.swift
//  MarklyAI
//

import AppKit

/// Manages the node list collection view, including drag-drop and context menus
@MainActor
final class NodeListViewController: NSViewController {

    // MARK: - Properties

    fileprivate let collectionView = ContextMenuCollectionView()
    let scrollView = NSScrollView()
    private let topShadowView = NSView()
    private let bottomShadowView = NSView()
    private let dropIndicator = DropIndicatorView()
    private let listMetrics = ListMetrics()
    private let contextMenu = NSMenu()

    private var visibleRows: [NodeListRow] = []
    private var contextIndexPath: IndexPath?
    private var isDraggingItems = false
    private var pendingInsertedIds: Set<UUID> = []
    private let rowAnimationDuration: TimeInterval = 0.16
    private let rowAnimationOffset: CGFloat = 10

    // Multi-selection support
    fileprivate var selectedNodeIds: Set<UUID> = []
    fileprivate var isBulkContextMenu = false

    // Inline rename support
    private weak var inlineRenameItem: NodeCollectionViewItem?
    var inlineRenameNodeId: UUID?
    private var pendingInlineRenameId: UUID?
    private var suppressNextSelection = false

    // Pending favicon updates for off-screen cells (applied in willDisplay)
    private var pendingFaviconUpdates: [UUID: String] = [:]

    // Cached gradient layers for scroll shadows
    private var topGradientLayer: CAGradientLayer?
    private var bottomGradientLayer: CAGradientLayer?
    private var lastShadowColor: WorkspaceColorId?

    // Callbacks
    var onNodeSelected: ((UUID) -> Void)?
    var onFolderToggled: ((UUID, Bool) -> Void)?
    var onNodeMoved: ((UUID, UUID?, Int) -> Void)?
    var onNodeDeleted: ((UUID) -> Void)?
    var onNodeRenamed: ((UUID, String) -> Void)?
    var onNodeMovedToWorkspace: ((UUID, UUID) -> Void)?
    var onBulkNodesMovedToWorkspace: (([UUID], UUID) -> Void)?
    var onBulkNodesGrouped: (([UUID], String) -> UUID?)?
    var onBulkNodesCopied: (([UUID]) -> Void)?
    var onBulkNodesDeleted: (([UUID]) -> Void)?
    var onNewFolderRequested: ((UUID?) -> Void)?
    var onLinkUrlEdited: ((UUID, String) -> Void)?
    var onPinLink: ((UUID) -> Void)?
    var canPinLink: (() -> Bool)?
    var onOpenAllInFolder: ((UUID) -> Void)?

    // Data provider closure
    var nodeProvider: (() -> [Node])?
    var workspacesProvider: (() -> [Workspace])?
    var currentWorkspaceIdProvider: (() -> UUID?)?
    var findNodeById: ((UUID) -> Node?)?
    var findNodeLocation: ((UUID) -> NodeLocation?)?
    var findNodeInNodes: ((UUID, [Node]) -> Node?)?

    // State
    var isSearchActive: Bool = false
    var workspaceColor: WorkspaceColorId = .defaultColor() {
        didSet {
            updateShadows()
        }
    }

    // MARK: - Initialization

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let view = NSView()
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupScrollView()
        setupNotifications()
        setupKeyboardNavigation()
    }

    // MARK: - Setup

    private func setupCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.autoresizingMask = [.width, .height]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.wantsLayer = true
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = ListFlowLayout(metrics: listMetrics)
        collectionView.register(NodeCollectionViewItem.self, forItemWithIdentifier: NodeCollectionViewItem.identifier)
        collectionView.registerForDraggedTypes([nodePasteboardType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        collectionView.onContextRequest = { [weak self] indexPath in
            self?.contextIndexPath = indexPath
        }
        collectionView.onDragExit = { [weak self] in
            self?.hideDropIndicator()
        }
        collectionView.onBackgroundClick = { [weak self] in
            self?.clearSelections()
        }
        collectionView.parentViewController = self

        dropIndicator.isHidden = true
        collectionView.addSubview(dropIndicator)

        contextMenu.delegate = self
        collectionView.menu = contextMenu
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        collectionView.frame = scrollView.bounds
        scrollView.contentView.postsBoundsChangedNotifications = true

        view.addSubview(scrollView)

        // Setup shadow views
        topShadowView.translatesAutoresizingMaskIntoConstraints = false
        topShadowView.wantsLayer = true
        bottomShadowView.translatesAutoresizingMaskIntoConstraints = false
        bottomShadowView.wantsLayer = true

        view.addSubview(topShadowView)
        view.addSubview(bottomShadowView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topShadowView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topShadowView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topShadowView.topAnchor.constraint(equalTo: view.topAnchor),
            topShadowView.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.scrollShadowHeight),

            bottomShadowView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomShadowView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomShadowView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomShadowView.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.scrollShadowHeight)
        ])

        updateShadows()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupKeyboardNavigation() {
        collectionView.onKeyNavigation = { [weak self] action in
            guard let self else { return }
            self.handleKeyNavigation(action)
        }
    }

    // MARK: - Public Methods

    /// Reloads the collection view with new visible rows
    func reloadData(with nodes: [Node], forceExpand: Bool, animated: Bool = true) {
        pendingFaviconUpdates.removeAll()
        let newRows = buildVisibleRows(nodes: nodes, depth: 0, forceExpand: forceExpand)

        if !animated {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        applyVisibleRows(newRows)
        handlePendingInlineRename()
    }

    /// Clears all selections
    func clearSelections() {
        guard !selectedNodeIds.isEmpty else { return }
        selectedNodeIds.removeAll()
        reloadVisibleSelection()
    }

    /// Schedules inline rename for a node
    func scheduleInlineRename(for nodeId: UUID) {
        pendingInlineRenameId = nodeId
    }

    /// Cancels any in-progress inline rename
    func cancelInlineRename() {
        if let item = inlineRenameItem {
            item.cancelInlineRename()
        } else {
            clearInlineRenameState()
        }
    }

    /// Updates the favicon for a specific link without triggering a full reload.
    /// If the cell is off-screen, queues the update for when the cell becomes visible.
    func updateFavicon(for linkId: UUID, path: String) {
        guard let index = visibleRows.firstIndex(where: { $0.id == linkId }) else { return }

        let indexPath = IndexPath(item: index, section: 0)
        if let item = collectionView.item(at: indexPath) as? NodeCollectionViewItem,
           let currentRow = row(at: indexPath),
           currentRow.id == linkId,  // Validate ID match to prevent stale IndexPath race
           let image = NSImage(contentsOfFile: path) {
            item.updateIcon(image)
            pendingFaviconUpdates.removeValue(forKey: linkId)
        } else {
            // Cell is off-screen — queue for when it becomes visible
            pendingFaviconUpdates[linkId] = path
        }
    }

    // MARK: - Private Methods

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Reset entire gradient cache so layers are recreated when view reappears
        lastShadowColor = nil
        topGradientLayer = nil
        bottomGradientLayer = nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateShadows()
    }

    @objc private func handleScrollBoundsChanged() {
        updateShadows()
        for item in collectionView.visibleItems() {
            (item as? NodeCollectionViewItem)?.refreshHoverState()
        }
    }

    private func updateShadows() {
        let clipView = scrollView.contentView
        let visibleRect = clipView.documentVisibleRect
        let contentHeight = collectionView.bounds.height

        let canScrollUp = visibleRect.origin.y > 0
        let canScrollDown = visibleRect.origin.y + visibleRect.height < contentHeight

        // Use black for shadows (works on any background)
        let baseColor = NSColor.black
        let shadowOpacity: CGFloat = 1.0
        let colorChanged = lastShadowColor != workspaceColor

        // Top shadow
        if canScrollUp {
            if topGradientLayer == nil {
                // Create gradient layer on first use
                let layer = CAGradientLayer()
                layer.startPoint = CGPoint(x: 0.5, y: 0)
                layer.endPoint = CGPoint(x: 0.5, y: 1)
                topShadowView.layer?.addSublayer(layer)
                topGradientLayer = layer
            }

            // Update frame on every call (handles window resizing)
            topGradientLayer?.frame = topShadowView.bounds

            // Only update colors when workspace color changes
            if colorChanged {
                topGradientLayer?.colors = [
                    baseColor.withAlphaComponent(0.0).cgColor,
                    baseColor.withAlphaComponent(shadowOpacity).cgColor
                ]
            }

            topShadowView.isHidden = false
        } else {
            topShadowView.isHidden = true
        }

        // Bottom shadow
        if canScrollDown {
            if bottomGradientLayer == nil {
                // Create gradient layer on first use
                let layer = CAGradientLayer()
                layer.startPoint = CGPoint(x: 0.5, y: 0)
                layer.endPoint = CGPoint(x: 0.5, y: 1)
                bottomShadowView.layer?.addSublayer(layer)
                bottomGradientLayer = layer
            }

            // Update frame on every call (handles window resizing)
            bottomGradientLayer?.frame = bottomShadowView.bounds

            // Only update colors when workspace color changes
            if colorChanged {
                bottomGradientLayer?.colors = [
                    baseColor.withAlphaComponent(shadowOpacity).cgColor,
                    baseColor.withAlphaComponent(0.0).cgColor
                ]
            }

            bottomShadowView.isHidden = false
        } else {
            bottomShadowView.isHidden = true
        }

        // Track last color to detect changes
        if colorChanged {
            lastShadowColor = workspaceColor
        }
    }

    fileprivate func row(at indexPath: IndexPath) -> NodeListRow? {
        guard indexPath.item >= 0, indexPath.item < visibleRows.count else { return nil }
        return visibleRows[indexPath.item]
    }

    private func buildVisibleRows(nodes: [Node], depth: Int, forceExpand: Bool) -> [NodeListRow] {
        var rows: [NodeListRow] = []
        for node in nodes {
            rows.append(NodeListRow(node: node, depth: depth))
            if case .folder(let folder) = node, folder.isExpanded || forceExpand {
                rows.append(contentsOf: buildVisibleRows(nodes: folder.children, depth: depth + 1, forceExpand: forceExpand))
            }
        }
        return rows
    }

    private func applyVisibleRows(_ newRows: [NodeListRow]) {
        if isSearchActive {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        let oldRows = visibleRows
        let oldIds = oldRows.map { $0.id }
        let newIds = newRows.map { $0.id }
        let oldSet = Set(oldIds)
        let newSet = Set(newIds)

        if oldSet == newSet {
            // Find cells that actually need updating
            guard oldRows.count == newRows.count else {
                visibleRows = newRows
                collectionView.reloadData()
                return
            }

            var changedIndexPaths: Set<IndexPath> = []
            for i in 0..<newRows.count {
                let oldRow = oldRows[i]
                let newRow = newRows[i]

                // Compare node IDs and depth
                if oldRow.id != newRow.id || oldRow.depth != newRow.depth {
                    changedIndexPaths.insert(IndexPath(item: i, section: 0))
                    continue
                }

                // Compare display-relevant properties based on node type
                switch (oldRow.node, newRow.node) {
                case (.folder(let oldFolder), .folder(let newFolder)):
                    if oldFolder.name != newFolder.name || oldFolder.isExpanded != newFolder.isExpanded {
                        changedIndexPaths.insert(IndexPath(item: i, section: 0))
                    }
                case (.link(let oldLink), .link(let newLink)):
                    if oldLink.title != newLink.title || oldLink.faviconPath != newLink.faviconPath {
                        changedIndexPaths.insert(IndexPath(item: i, section: 0))
                    }
                default:
                    // Node type changed (folder <-> link), needs reload
                    changedIndexPaths.insert(IndexPath(item: i, section: 0))
                }
            }

            visibleRows = newRows

            if changedIndexPaths.isEmpty {
                return  // Nothing actually changed - skip reload entirely
            }

            collectionView.reloadItems(at: changedIndexPaths)
            return
        }

        var deletedIndexPaths: [IndexPath] = []
        for (index, row) in oldRows.enumerated() where !newSet.contains(row.id) {
            deletedIndexPaths.append(IndexPath(item: index, section: 0))
        }

        var insertedIndexPaths: [IndexPath] = []
        for (index, row) in newRows.enumerated() where !oldSet.contains(row.id) {
            insertedIndexPaths.append(IndexPath(item: index, section: 0))
        }

        let deletionSnapshots = makeDeletionSnapshots(for: deletedIndexPaths)

        performListUpdates(
            newRows: newRows,
            insertedIndexPaths: insertedIndexPaths,
            deletedIndexPaths: deletedIndexPaths
        )
        animateDeletionSnapshots(deletionSnapshots)
    }

    private func performListUpdates(newRows: [NodeListRow],
                                    insertedIndexPaths: [IndexPath],
                                    deletedIndexPaths: [IndexPath]) {
        pendingInsertedIds = Set(insertedIndexPaths.compactMap { indexPath in
            guard indexPath.item < newRows.count else { return nil }
            return newRows[indexPath.item].id
        })
        visibleRows = newRows
        collectionView.performBatchUpdates({
            if !deletedIndexPaths.isEmpty {
                collectionView.deleteItems(at: Set(deletedIndexPaths))
            }
            if !insertedIndexPaths.isEmpty {
                collectionView.insertItems(at: Set(insertedIndexPaths))
            }
        }, completionHandler: nil)
    }

    private func makeDeletionSnapshots(for indexPaths: [IndexPath]) -> [NSImageView] {
        var snapshots: [NSImageView] = []
        for indexPath in indexPaths {
            guard let item = collectionView.item(at: indexPath) else { continue }
            let view = item.view
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            let frame = view.convert(view.bounds, to: collectionView)
            let imageView = NSImageView(frame: frame)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            collectionView.addSubview(imageView)
            view.alphaValue = 0
            snapshots.append(imageView)
        }
        return snapshots
    }

    private func animateDeletionSnapshots(_ snapshots: [NSImageView]) {
        guard !snapshots.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = rowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            for snapshot in snapshots {
                let finalOrigin = NSPoint(x: snapshot.frame.origin.x, y: snapshot.frame.origin.y - rowAnimationOffset)
                snapshot.animator().setFrameOrigin(finalOrigin)
                snapshot.animator().alphaValue = 0
            }
        } completionHandler: {
            DispatchQueue.main.async {
                for snapshot in snapshots {
                    snapshot.removeFromSuperview()
                }
            }
        }
    }

    private func animateInsert(item: NSCollectionViewItem) {
        let view = item.view
        view.wantsLayer = true
        let finalOrigin = view.frame.origin
        view.alphaValue = 0
        view.frame.origin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - rowAnimationOffset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = rowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            view.animator().setFrameOrigin(finalOrigin)
            view.animator().alphaValue = 1
        }
    }

    private func handlePendingInlineRename() {
        guard let nodeId = pendingInlineRenameId else { return }
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        pendingInlineRenameId = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
            if self.collectionView.item(at: indexPath) is NodeCollectionViewItem {
                self.beginInlineRename(nodeId: nodeId, indexPath: indexPath)
            } else {
                self.pendingInlineRenameId = nodeId
            }
        }
    }

    private func beginInlineRename(nodeId: UUID, indexPath: IndexPath) {
        cancelInlineRename()
        guard findNodeById?(nodeId) != nil,
              let item = collectionView.item(at: indexPath) as? NodeCollectionViewItem else {
            clearInlineRenameState()
            return
        }

        inlineRenameNodeId = nodeId
        inlineRenameItem = item
        item.beginInlineRename(onCommit: { [weak self] newName in
            self?.commitInlineRename(newName)
        }, onCancel: { [weak self] in
            self?.handleInlineRenameCancelled()
        })
    }

    private func commitInlineRename(_ newName: String) {
        guard let nodeId = inlineRenameNodeId else {
            clearInlineRenameState()
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handleInlineRenameCancelled()
            return
        }
        onNodeRenamed?(nodeId, trimmed)
        clearInlineRenameState()
    }

    private func handleInlineRenameCancelled() {
        suppressNextSelection = true
        clearInlineRenameState()
    }

    private func clearInlineRenameState() {
        inlineRenameItem = nil
        inlineRenameNodeId = nil
    }

    private func toggleSelection(for nodeId: UUID) {
        if selectedNodeIds.contains(nodeId) {
            selectedNodeIds.remove(nodeId)
        } else {
            selectedNodeIds.insert(nodeId)
        }
        reloadVisibleSelection()
    }

    private func reloadVisibleSelection() {
        for (index, _) in visibleRows.enumerated() {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.reloadItems(at: [indexPath])
        }
    }

    // MARK: - Drop Indicator

    private func showDropIndicator(at indexPath: IndexPath, operation: NSCollectionView.DropOperation) {
        switch operation {
        case .on:
            guard let frame = frameForItem(at: indexPath) else {
                hideDropIndicator()
                return
            }
            dropIndicator.showHighlight(in: frame.insetBy(dx: 2, dy: 2))
        case .before:
            guard let frame = insertionLineFrame(for: indexPath) else {
                hideDropIndicator()
                return
            }
            dropIndicator.showLine(in: frame)
        default:
            hideDropIndicator()
        }
    }

    private func hideDropIndicator() {
        dropIndicator.hide()
    }

    private func frameForItem(at indexPath: IndexPath) -> NSRect? {
        collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }

    private func insertionLineFrame(for indexPath: IndexPath) -> NSRect? {
        let lineHeight: CGFloat = 2
        var depth = 0
        var y: CGFloat = listMetrics.verticalGap / 2

        if indexPath.item < visibleRows.count,
           let frame = frameForItem(at: indexPath) {
            depth = visibleRows[indexPath.item].depth
            y = frame.minY - listMetrics.verticalGap / 2
        } else if let lastIndex = visibleRows.indices.last,
                  let frame = frameForItem(at: IndexPath(item: lastIndex, section: 0)) {
            depth = 0
            y = frame.maxY + listMetrics.verticalGap / 2
        }

        let x = listMetrics.leftPadding + CGFloat(depth) * listMetrics.indentWidth
        let width = max(8, collectionView.bounds.width - x - listMetrics.leftPadding)
        return NSRect(x: x, y: y - lineHeight / 2, width: width, height: lineHeight)
    }

    private func shouldDropOnItem(at indexPath: IndexPath, draggingInfo: NSDraggingInfo) -> Bool {
        let location = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
            return true
        }
        let upper = frame.minY + frame.height * 0.25
        let lower = frame.maxY - frame.height * 0.25
        return location.y >= upper && location.y <= lower
    }

    // MARK: - Keyboard Navigation

    private func handleKeyNavigation(_ action: KeyNavigationAction) {
        switch action {
        case .moveUp:
            moveSelectionUp()
        case .moveDown:
            moveSelectionDown()
        case .expandOrMoveRight:
            expandOrMoveRight()
        case .collapseOrMoveLeft:
            collapseOrMoveLeft()
        case .activate:
            activateSelectedItem()
        case .delete:
            deleteSelectedItems()
        }
    }

    private func moveSelectionUp() {
        guard visibleRows.count > 0 else { return }

        let currentSelection = collectionView.selectionIndexPaths.first?.item ?? 0
        let newSelection = max(0, currentSelection - 1)

        if newSelection != currentSelection {
            selectItem(at: newSelection)
        }
    }

    private func moveSelectionDown() {
        guard visibleRows.count > 0 else { return }

        let currentSelection = collectionView.selectionIndexPaths.first?.item ?? -1
        let newSelection = min(visibleRows.count - 1, currentSelection + 1)

        if newSelection != currentSelection || currentSelection == -1 {
            selectItem(at: newSelection)
        }
    }

    private func selectItem(at index: Int) {
        guard index >= 0 && index < visibleRows.count else { return }

        let indexPath = IndexPath(item: index, section: 0)

        // Deselect previous selection
        let previousSelection = collectionView.selectionIndexPaths
        collectionView.deselectItems(at: previousSelection)

        // Select new item
        collectionView.selectItems(at: [indexPath], scrollPosition: .centeredVertically)

        // Update visual selection state if needed
        if !selectedNodeIds.isEmpty {
            clearSelections()
        }
    }

    private func expandOrMoveRight() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex < visibleRows.count else { return }

        let row = visibleRows[selectedIndex]

        if case .folder(let folder) = row.node {
            if !folder.isExpanded {
                // Expand collapsed folder
                onFolderToggled?(folder.id, true)
            }
        }
    }

    private func collapseOrMoveLeft() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex < visibleRows.count else { return }

        let row = visibleRows[selectedIndex]

        if case .folder(let folder) = row.node, folder.isExpanded {
            // Collapse expanded folder
            onFolderToggled?(folder.id, false)
        } else if row.depth > 0, let location = findNodeLocation?(row.id) {
            // Move to parent folder
            if let parentId = location.parentId,
               let parentIndex = visibleRows.firstIndex(where: { $0.id == parentId }) {
                selectItem(at: parentIndex)
            }
        }
    }

    private func activateSelectedItem() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex < visibleRows.count else { return }

        let row = visibleRows[selectedIndex]

        switch row.node {
        case .folder(let folder):
            // Toggle folder expand/collapse
            onFolderToggled?(folder.id, !folder.isExpanded)
        case .link(let link):
            // Open link
            onNodeSelected?(link.id)
        }
    }

    private func deleteSelectedItems() {
        // If there are multi-selected items, delete all of them
        if selectedNodeIds.count > 0 {
            let nodes = selectedNodeIds.compactMap { id in
                findNodeInNodes?(id, nodeProvider?() ?? [])
            }
            let hasFolders = nodes.contains { if case .folder = $0 { return true }; return false }

            if hasFolders {
                let count = selectedNodeIds.count
                confirmFolderDeletion(title: "Delete \(count) Item\(count > 1 ? "s" : "")") {
                    self.onBulkNodesDeleted?(Array(self.selectedNodeIds))
                    self.clearSelections()
                }
            } else {
                onBulkNodesDeleted?(Array(selectedNodeIds))
                clearSelections()
            }
            return
        }

        // Otherwise delete the currently selected single item
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex < visibleRows.count else { return }

        let row = visibleRows[selectedIndex]

        if case .folder = row.node {
            confirmFolderDeletion(title: "Delete Folder") {
                self.onNodeDeleted?(row.id)
            }
        } else {
            onNodeDeleted?(row.id)
        }
    }

    private func confirmFolderDeletion(title: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "This will also delete any items inside folders. This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension NodeListViewController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleRows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NodeCollectionViewItem.identifier, for: indexPath)
        guard let nodeItem = item as? NodeCollectionViewItem else { return item }
        guard let row = row(at: indexPath) else { return item }

        let isSelected = selectedNodeIds.contains(row.node.id)

        switch row.node {
        case .folder(let folder):
            let icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            icon?.isTemplate = true
            nodeItem.configure(
                title: folder.name,
                icon: icon,
                titleFont: listMetrics.folderTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: false,
                onDelete: nil,
                isSelected: isSelected,
                childCount: folder.children.count
            )
        case .link(let link):
            let globeIconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let placeholder = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(globeIconConfig)
            placeholder?.isTemplate = true
            var iconToUse = placeholder
            var shouldFetch = true
            if let path = link.faviconPath,
               FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                image.isTemplate = false
                iconToUse = image
                shouldFetch = false
            }

            nodeItem.configure(
                title: link.title,
                icon: iconToUse,
                titleFont: listMetrics.linkTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: true,
                onDelete: { [weak self] in
                    self?.onNodeDeleted?(link.id)
                    self?.clearSelections()
                },
                isSelected: isSelected,
                linkUrl: link.url
            )

            if shouldFetch, let url = URL(string: link.url) {
                FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { _, path in
                    guard let path else { return }
                    // Notify parent to update favicon path
                    NotificationCenter.default.post(
                        name: .init("UpdateLinkFavicon"),
                        object: nil,
                        userInfo: ["linkId": link.id, "path": path]
                    )
                }
            }
        }

        return nodeItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let row = row(at: indexPath) else { return }
        if pendingInsertedIds.remove(row.id) != nil {
            animateInsert(item: item)
        } else {
            item.view.alphaValue = 1
        }

        // Apply any pending favicon updates for this cell
        if let path = pendingFaviconUpdates.removeValue(forKey: row.id),
           let nodeItem = item as? NodeCollectionViewItem,
           let image = NSImage(contentsOfFile: path) {
            nodeItem.updateIcon(image)
        }
    }
}

// MARK: - NSCollectionViewDelegate

extension NodeListViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        guard !isSearchActive else {
            return false
        }

        guard selectedNodeIds.isEmpty else {
            return false
        }

        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, let row = row(at: indexPath) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDraggingItems { return }
            if self.suppressNextSelection {
                self.suppressNextSelection = false
                self.collectionView.deselectItems(at: indexPaths)
                return
            }
            if self.inlineRenameNodeId != nil {
                self.collectionView.deselectItems(at: indexPaths)
                return
            }
            if !self.collectionView.selectionIndexPaths.contains(indexPath) { return }

            // Check for Cmd key modifier for multi-selection
            if NSEvent.modifierFlags.contains(.command) {
                self.toggleSelection(for: row.node.id)
                self.collectionView.deselectItems(at: indexPaths)
                return
            }

            // Clear selections on regular click
            if !self.selectedNodeIds.isEmpty {
                self.clearSelections()
            }

            switch row.node {
            case .folder(let folder):
                self.onFolderToggled?(folder.id, !folder.isExpanded)
            case .link(let link):
                self.onNodeSelected?(link.id)
            }

            self.collectionView.deselectItems(at: indexPaths)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let row = row(at: indexPath) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(row.node.id.uuidString, forType: nodePasteboardType)
        return pasteboardItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        isDraggingItems = true
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        isDraggingItems = false
        hideDropIndicator()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if isSearchActive {
            hideDropIndicator()
            return []
        }

        let indexPath = proposedDropIndexPath.pointee as IndexPath
        if indexPath.item < visibleRows.count,
           let row = row(at: indexPath),
           case .folder = row.node,
           shouldDropOnItem(at: indexPath, draggingInfo: draggingInfo) {
            proposedDropOperation.pointee = .on
        } else {
            proposedDropOperation.pointee = .before
        }

        showDropIndicator(at: indexPath, operation: proposedDropOperation.pointee)

        return .move
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        hideDropIndicator()
        guard let idString = draggingInfo.draggingPasteboard.string(forType: nodePasteboardType),
              let nodeId = UUID(uuidString: idString),
              let nodes = nodeProvider?() else { return false }

        var targetParentId: UUID?
        var targetIndex: Int

        if indexPath.item < visibleRows.count, let row = row(at: indexPath) {
            switch row.node {
            case .folder(let folder):
                if dropOperation == .on {
                    targetParentId = folder.id
                    targetIndex = folder.children.count
                } else if let location = findNodeLocation?(folder.id) {
                    targetParentId = location.parentId
                    targetIndex = location.index
                } else {
                    targetParentId = nil
                    targetIndex = nodes.count
                }
            case .link(let link):
                if let location = findNodeLocation?(link.id) {
                    targetParentId = location.parentId
                    targetIndex = location.index
                } else {
                    targetParentId = nil
                    targetIndex = nodes.count
                }
            }
        } else {
            targetParentId = nil
            targetIndex = nodes.count
        }

        if targetIndex < 0 { targetIndex = nodes.count }
        onNodeMoved?(nodeId, targetParentId, targetIndex)
        return true
    }
}

// MARK: - NSMenuDelegate

extension NodeListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Check for bulk selection context menu
        if isBulkContextMenu && selectedNodeIds.count > 0 {
            populateBulkContextMenu(menu)
            return
        }

        guard let indexPath = contextIndexPath,
              let row = row(at: indexPath) else {
            let newFolder = NSMenuItem(title: "New Folder…", action: #selector(contextNewFolder), keyEquivalent: "")
            newFolder.target = self
            newFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
            menu.addItem(newFolder)
            return
        }

        let node = row.node

        switch node {
        case .folder:
            let newNested = NSMenuItem(title: "New Nested Folder…", action: #selector(contextNewNestedFolder(_:)), keyEquivalent: "")
            newNested.target = self
            newNested.representedObject = node.id
            newNested.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Nested Folder")
            menu.addItem(newNested)

            let openFolderItem = NSMenuItem(title: "Open All in Browser", action: #selector(contextOpenAllInFolder(_:)), keyEquivalent: "")
            openFolderItem.target = self
            openFolderItem.representedObject = node.id
            openFolderItem.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open All")
            menu.addItem(openFolderItem)
            menu.addItem(NSMenuItem.separator())

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")
            menu.addItem(rename)

            let moveMenu = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveMenu.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: "Move to")
            let submenu = NSMenu()
            if let workspaces = workspacesProvider?(), let currentId = currentWorkspaceIdProvider?() {
                for workspace in workspaces where workspace.id != currentId {
                    let item = NSMenuItem(title: workspace.name, action: #selector(contextMoveToWorkspace), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["nodeId": node.id, "workspaceId": workspace.id]
                    submenu.addItem(item)
                }
            }
            moveMenu.submenu = submenu
            menu.addItem(moveMenu)

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            menu.addItem(delete)
        case .link:
            let pinItem = NSMenuItem(title: "Pin this link", action: #selector(contextPinLink(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = node.id
            pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
            if let canPin = canPinLink, !canPin() {
                pinItem.isEnabled = false
                pinItem.title = "Maximum pinned tabs reached"
            }
            menu.addItem(pinItem)
            menu.addItem(NSMenuItem.separator())

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")
            menu.addItem(rename)

            let editUrl = NSMenuItem(title: "Edit URL…", action: #selector(contextEditUrl(_:)), keyEquivalent: "")
            editUrl.target = self
            editUrl.representedObject = node.id
            editUrl.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Edit URL")
            menu.addItem(editUrl)

            let moveMenu = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveMenu.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: "Move to")
            let submenu = NSMenu()
            if let workspaces = workspacesProvider?(), let currentId = currentWorkspaceIdProvider?() {
                for workspace in workspaces where workspace.id != currentId {
                    let item = NSMenuItem(title: workspace.name, action: #selector(contextMoveToWorkspace), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["nodeId": node.id, "workspaceId": workspace.id]
                    submenu.addItem(item)
                }
            }
            moveMenu.submenu = submenu
            menu.addItem(moveMenu)

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            menu.addItem(delete)
        }
    }

    @objc private func contextNewFolder() {
        onNewFolderRequested?(nil)
    }

    @objc private func contextNewNestedFolder(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNewFolderRequested?(nodeId)
    }

    @objc private func contextRename() {
        guard let indexPath = contextIndexPath,
              let row = row(at: indexPath) else { return }
        beginInlineRename(nodeId: row.id, indexPath: indexPath)
    }

    @objc private func contextEditUrl(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID,
              let node = findNodeById?(nodeId),
              case .link(let link) = node else { return }

        let alert = NSAlert()
        alert.messageText = "Edit URL"
        alert.informativeText = "Enter the new URL for this link."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = link.url
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newUrl = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newUrl.isEmpty, newUrl != link.url else { return }
            onLinkUrlEdited?(nodeId, newUrl)
        }
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodeDeleted?(nodeId)
    }

    @objc private func contextMoveToWorkspace(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: UUID],
              let nodeId = dict["nodeId"],
              let workspaceId = dict["workspaceId"] else { return }
        onNodeMovedToWorkspace?(nodeId, workspaceId)
    }

    @objc private func contextPinLink(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onPinLink?(nodeId)
    }

    @objc private func contextOpenAllInFolder(_ sender: NSMenuItem) {
        guard let folderId = sender.representedObject as? UUID else { return }
        onOpenAllInFolder?(folderId)
    }

    private func populateBulkContextMenu(_ menu: NSMenu) {
        let count = selectedNodeIds.count

        // 1. Move to Workspace submenu
        let moveItem = NSMenuItem(title: "Move to…", action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: "Move to")
        let moveSubmenu = NSMenu()
        if let workspaces = workspacesProvider?(), let currentId = currentWorkspaceIdProvider?() {
            for workspace in workspaces where workspace.id != currentId {
                let item = NSMenuItem(title: workspace.name, action: #selector(bulkMoveToWorkspace), keyEquivalent: "")
                item.target = self
                item.representedObject = workspace.id
                moveSubmenu.addItem(item)
            }
        }
        moveItem.submenu = moveSubmenu
        menu.addItem(moveItem)

        // 2. Group in New Folder
        let groupItem = NSMenuItem(title: "Group in New Folder", action: #selector(bulkGroupInFolder), keyEquivalent: "")
        groupItem.target = self
        groupItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Group in Folder")
        menu.addItem(groupItem)

        // 3. Copy Links (only if there are links)
        let nodes = selectedNodeIds.compactMap { id in
            findNodeInNodes?(id, nodeProvider?() ?? [])
        }
        let linkCount = nodes.filter { node in
            if case .link = node { return true }
            return false
        }.count

        if linkCount > 0 {
            let copyItem = NSMenuItem(title: "Copy \(linkCount) Link\(linkCount > 1 ? "s" : "")", action: #selector(bulkCopyLinks), keyEquivalent: "")
            copyItem.target = self
            copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Links")
            menu.addItem(copyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 4. Delete All
        let deleteItem = NSMenuItem(title: "Delete \(count) Item\(count > 1 ? "s" : "")…", action: #selector(bulkDelete), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        menu.addItem(deleteItem)
    }

    @objc private func bulkMoveToWorkspace(_ sender: NSMenuItem) {
        guard let workspaceId = sender.representedObject as? UUID else { return }
        let nodeIds = Array(selectedNodeIds)
        onBulkNodesMovedToWorkspace?(nodeIds, workspaceId)
        clearSelections()
    }

    @objc private func bulkGroupInFolder() {
        let nodeIds = Array(selectedNodeIds)
        guard !nodeIds.isEmpty else { return }

        if let folderId = onBulkNodesGrouped?(nodeIds, "Untitled") {
            DispatchQueue.main.async { [weak self] in
                self?.clearSelections()
            }
            scheduleInlineRename(for: folderId)
        }
    }

    @objc private func bulkCopyLinks() {
        onBulkNodesCopied?(Array(selectedNodeIds))
        clearSelections()
    }

    @objc private func bulkDelete() {
        let count = selectedNodeIds.count
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(count) Item\(count > 1 ? "s" : "")"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            onBulkNodesDeleted?(Array(selectedNodeIds))
            clearSelections()
        }
    }
}

// MARK: - Supporting Types

private struct NodeListRow {
    let node: Node
    let depth: Int

    var id: UUID {
        node.id
    }
}

enum KeyNavigationAction {
    case moveUp
    case moveDown
    case expandOrMoveRight
    case collapseOrMoveLeft
    case activate
    case delete
}

private final class DropIndicatorView: NSView {
    private let lineThickness: CGFloat = 2
    private let highlightCornerRadius: CGFloat = 8
    private let accentColor = NSColor.controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    func showLine(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = lineThickness / 2
        layer?.backgroundColor = accentColor.cgColor
        layer?.borderWidth = 0
    }

    func showHighlight(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = highlightCornerRadius
        layer?.backgroundColor = accentColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = accentColor.cgColor
        layer?.borderWidth = 2
    }

    func hide() {
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ContextMenuCollectionView: NSCollectionView {
    var onContextRequest: ((IndexPath?) -> Void)?
    var onDragExit: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onKeyNavigation: ((KeyNavigationAction) -> Void)?
    weak var parentViewController: NodeListViewController?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: location)

        // If clicking on empty space, notify the callback
        if indexPath == nil {
            onBackgroundClick?()
        }

        // Always call super to allow normal click handling
        super.mouseDown(with: event)

        // Make sure we become first responder to receive keyboard events
        window?.makeFirstResponder(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: location)

        // Check if clicked item is in selection for bulk context menu
        if let parentVC = parentViewController {
            if let indexPath = indexPath,
               let row = parentVC.row(at: indexPath),
               parentVC.selectedNodeIds.contains(row.node.id),
               parentVC.selectedNodeIds.count > 0 {
                parentVC.isBulkContextMenu = true
            } else {
                parentVC.isBulkContextMenu = false
            }
        }

        onContextRequest?(indexPath)
        return menu
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func keyDown(with event: NSEvent) {
        // Let text field editor handle keys during inline rename
        if window?.firstResponder is NSTextView {
            super.keyDown(with: event)
            return
        }

        // Key codes for navigation
        let upArrow: UInt16 = 126
        let downArrow: UInt16 = 125
        let leftArrow: UInt16 = 123
        let rightArrow: UInt16 = 124
        let returnKey: UInt16 = 36
        let deleteKey: UInt16 = 51
        let forwardDeleteKey: UInt16 = 117

        switch event.keyCode {
        case upArrow:
            onKeyNavigation?(.moveUp)
        case downArrow:
            onKeyNavigation?(.moveDown)
        case leftArrow:
            onKeyNavigation?(.collapseOrMoveLeft)
        case rightArrow:
            onKeyNavigation?(.expandOrMoveRight)
        case returnKey:
            onKeyNavigation?(.activate)
        case deleteKey, forwardDeleteKey:
            onKeyNavigation?(.delete)
        default:
            super.keyDown(with: event)
        }
    }
}
