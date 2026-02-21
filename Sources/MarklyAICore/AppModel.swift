import Foundation
import os

@MainActor
final class AppModel {
    private let store: DataStore
    private(set) var state: AppState
    var onChange: (() -> Void)?
    private let logger = Logger(subsystem: "com.marklyai.app", category: "model")
    let undoManager = UndoManager()

    init(store: DataStore = DataStore()) {
        self.store = store
        self.state = store.load()
        self.undoManager.levelsOfUndo = 10

        if !state.isSettingsSelected {
            if let savedId = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId),
               let uuid = UUID(uuidString: savedId),
               state.workspaces.contains(where: { $0.id == uuid }) {
                state.selectedWorkspaceId = uuid
            }
            if state.selectedWorkspaceId == nil {
                state.selectedWorkspaceId = state.workspaces.first?.id
            }
        }
    }

    var workspaces: [Workspace] {
        state.workspaces
    }

    var currentWorkspace: Workspace {
        if let selected = state.selectedWorkspaceId,
           let workspace = state.workspaces.first(where: { $0.id == selected }) {
            return workspace
        }
        if let first = state.workspaces.first {
            return first
        }
        let fallback = Workspace(id: UUID(), name: "Inbox", colorId: .defaultColor(), items: [], pinnedLinks: [])
        state.workspaces = [fallback]
        state.selectedWorkspaceId = fallback.id
        persist()
        return fallback
    }

    func selectWorkspace(id: UUID) {
        guard state.workspaces.contains(where: { $0.id == id }) else { return }
        state.selectedWorkspaceId = id
        state.isSettingsSelected = false
        UserDefaults.standard.set(id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
    }

    func selectSettings() {
        state.isSettingsSelected = true
        state.selectedWorkspaceId = nil
        persist()
    }

    @discardableResult
    func createWorkspace(name: String, colorId: WorkspaceColorId) -> UUID {
        let workspace = Workspace(id: UUID(), name: name, colorId: colorId, items: [])
        state.workspaces.append(workspace)
        state.selectedWorkspaceId = workspace.id
        UserDefaults.standard.set(workspace.id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
        return workspace.id
    }

    func renameWorkspace(id: UUID, newName: String) {
        registerUndo(actionName: "Rename Workspace")
        updateWorkspace(id: id) { workspace in
            workspace.name = newName
        }
    }

    func updateWorkspaceColor(id: UUID, colorId: WorkspaceColorId) {
        updateWorkspace(id: id) { workspace in
            workspace.colorId = colorId
        }
    }

    func deleteWorkspace(id: UUID) {
        guard state.workspaces.count > 1 else { return }
        registerUndo(actionName: "Delete Workspace")
        state.workspaces.removeAll { $0.id == id }
        if state.selectedWorkspaceId == id {
            state.selectedWorkspaceId = state.workspaces.first?.id
            if let newId = state.selectedWorkspaceId {
                UserDefaults.standard.set(newId.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            }
        }
        persist()
    }

    func moveWorkspace(id: UUID, direction: WorkspaceMoveDirection) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }

        let newIndex: Int
        switch direction {
        case .left:
            guard currentIndex > 0 else { return }
            newIndex = currentIndex - 1
        case .right:
            guard currentIndex < state.workspaces.count - 1 else { return }
            newIndex = currentIndex + 1
        }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: newIndex)
        persist()
    }

    func reorderWorkspace(id: UUID, toIndex: Int) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard toIndex >= 0 && toIndex < state.workspaces.count else { return }
        guard currentIndex != toIndex else { return }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: toIndex)
        persist()
    }

    @discardableResult
    func addFolder(name: String, parentId: UUID?, isExpanded: Bool = true) -> UUID {
        registerUndo(actionName: "Add Folder")
        let folder = Folder(id: UUID(), name: name, children: [], isExpanded: isExpanded)
        let node = Node.folder(folder)
        insertNode(node, parentId: parentId)
        return folder.id
    }

    @discardableResult
    func addLink(urlString: String, title: String, parentId: UUID?) -> UUID {
        registerUndo(actionName: "Add Link")
        let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil, createdAt: Date(), lastOpened: nil, tags: [])
        let node = Node.link(link)
        insertNode(node, parentId: parentId)
        logger.debug("Added link \(title, privacy: .public) -> \(urlString, privacy: .public)")
        return link.id
    }

    func renameNode(id: UUID, newName: String) {
        registerUndo(actionName: "Rename")
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.name = newName
                node = .folder(folder)
            case .link(var link):
                link.title = newName
                node = .link(link)
            }
        }
    }

    func deleteNode(id: UUID) {
        registerUndo(actionName: "Delete")
        updateWorkspace(id: currentWorkspace.id) { workspace in
            _ = removeNode(id: id, nodes: &workspace.items)
        }
    }

    func moveNode(id: UUID, toParentId: UUID?, index: Int) {
        guard let location = findNodeLocation(id: id, nodes: currentWorkspace.items) else { return }
        if let toParentId, isDescendant(nodeId: toParentId, in: id) { return }

        registerUndo(actionName: "Move")
        updateWorkspace(id: currentWorkspace.id) { workspace in
            guard let removedNode = removeNode(id: id, nodes: &workspace.items) else { return }

            var targetIndex = max(0, index)
            if location.parentId == toParentId, location.index < targetIndex {
                targetIndex -= 1
            }

            insertNode(removedNode, parentId: toParentId, index: targetIndex, nodes: &workspace.items)
        }
    }

    func moveNodeToWorkspace(id: UUID, workspaceId: UUID) {
        guard workspaceId != currentWorkspace.id else { return }
        var removedNode: Node?
        updateWorkspace(id: currentWorkspace.id) { workspace in
            removedNode = removeNode(id: id, nodes: &workspace.items)
        }
        guard let node = removedNode else { return }

        updateWorkspace(id: workspaceId) { workspace in
            workspace.items.append(node)
        }
    }

    func setFolderExpanded(id: UUID, isExpanded: Bool) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.isExpanded = isExpanded
                node = .folder(folder)
            case .link:
                break
            }
        }
    }

    func updateLinkFaviconPath(id: UUID, path: String?, notify: Bool = true) {
        if let node = nodeById(id), case .link(let link) = node, link.faviconPath == path {
            return
        }
        updateNode(id: id, notify: notify) { node in
            switch node {
            case .link(var link):
                link.faviconPath = path
                node = .link(link)
            case .folder:
                break
            }
        }
    }

    func updateLinkUrl(id: UUID, newUrl: String) {
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.url = newUrl
                link.faviconPath = nil
                node = .link(link)
            case .folder:
                break
            }
        }
    }

    func updateLinkTitleIfDefault(id: UUID, newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let node = nodeById(id), case .link(let link) = node else { return false }
        let defaultTitle = URL(string: link.url)?.host ?? link.url
        guard link.title == defaultTitle else { return false }
        guard link.title != trimmed else { return false }

        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.title = trimmed
                node = .link(link)
            case .folder:
                break
            }
        }
        logger.debug("Updated title for \(link.url, privacy: .public) -> \(trimmed, privacy: .public)")
        return true
    }

    func updateLinkTags(id: UUID, tags: [String]) {
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.tags = tags
                node = .link(link)
            case .folder:
                break
            }
        }
    }

    // MARK: - Link Activity Tracking

    func markLinkOpened(id: UUID) {
        updateNode(id: id, notify: false) { node in
            if case .link(var link) = node {
                link.lastOpened = Date()
                node = .link(link)
            }
        }
    }

    // MARK: - Duplicate Detection

    func findDuplicateLink(url: String) -> (workspaceName: String, linkTitle: String)? {
        let normalizedUrl = normalizeUrl(url)
        for workspace in state.workspaces {
            if let match = findLinkInNodes(normalizedUrl: normalizedUrl, nodes: workspace.items) {
                return (workspace.name, match.title)
            }
        }
        return nil
    }

    private func normalizeUrl(_ url: String) -> String {
        var normalized = url.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("[DUP CHECK] Original URL: \(url)")
        
        // Normalize protocol: http → https
        if normalized.hasPrefix("http://") {
            normalized = "https://" + normalized.dropFirst("http://".count)
        }
        
        // Remove trailing slash
        if normalized.hasSuffix("/") { normalized.removeLast() }
        
        // Remove www. prefix (after protocol)
        if let range = normalized.range(of: "://www.") {
            normalized.replaceSubrange(range, with: "://")
        }
        
        // Remove fragment
        if let hashIndex = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<hashIndex])
        }
        
        // Remove trailing slash again (in case fragment removal exposed one)
        if normalized.hasSuffix("/") { normalized.removeLast() }
        
        print("[DUP CHECK] Normalized URL: \(normalized)")
        return normalized
    }

    private func findLinkInNodes(normalizedUrl: String, nodes: [Node]) -> Link? {
        for node in nodes {
            switch node {
            case .link(let link):
                if normalizeUrl(link.url) == normalizedUrl { return link }
            case .folder(let folder):
                if let found = findLinkInNodes(normalizedUrl: normalizedUrl, nodes: folder.children) { return found }
            }
        }
        return nil
    }

    // MARK: - Reading List

    func readingListWorkspace() -> Workspace {
        if let existing = state.workspaces.first(where: { $0.isReadingList }) {
            return existing
        }
        // Create reading list workspace
        var workspace = Workspace(id: UUID(), name: "Reading List", colorId: .ocean, items: [])
        workspace.isReadingList = true
        state.workspaces.append(workspace)
        persist()
        return workspace
    }

    func addToReadingList(urlString: String, title: String) -> UUID {
        let ws = readingListWorkspace()
        let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil, createdAt: Date(), lastOpened: nil, tags: [])
        updateWorkspace(id: ws.id) { workspace in
            workspace.items.insert(.link(link), at: 0)
        }
        return link.id
    }

    // MARK: - Pinned Links

    var canPinMore: Bool {
        currentWorkspace.pinnedLinks.count < Workspace.maxPinnedLinks
    }

    func pinnedLinkById(_ id: UUID) -> Link? {
        currentWorkspace.pinnedLinks.first(where: { $0.id == id })
    }

    func pinLink(id: UUID) {
        guard canPinMore else { return }
        guard let node = nodeById(id), case .link(let link) = node else { return }
        guard !currentWorkspace.pinnedLinks.contains(where: { $0.id == id }) else { return }

        updateWorkspace(id: currentWorkspace.id) { workspace in
            _ = removeNode(id: id, nodes: &workspace.items)
            workspace.pinnedLinks.append(link)
        }
    }

    func unpinLink(id: UUID) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            guard let index = workspace.pinnedLinks.firstIndex(where: { $0.id == id }) else { return }
            let link = workspace.pinnedLinks.remove(at: index)
            workspace.items.append(.link(link))
        }
    }

    func updatePinnedLinkFaviconPath(id: UUID, path: String?) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            guard let index = workspace.pinnedLinks.firstIndex(where: { $0.id == id }) else { return }
            workspace.pinnedLinks[index].faviconPath = path
        }
    }

    func location(of nodeId: UUID) -> NodeLocation? {
        findNodeLocation(id: nodeId, nodes: currentWorkspace.items)
    }

    func nodeById(_ id: UUID) -> Node? {
        nodeById(id, nodes: currentWorkspace.items)
    }

    func findNode(id: UUID, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if case .folder(let folder) = node,
               let found = findNode(id: id, in: folder.children) {
                return found
            }
        }
        return nil
    }

    func moveNodesToWorkspace(nodeIds: [UUID], toWorkspaceId: UUID) {
        guard toWorkspaceId != currentWorkspace.id else { return }
        guard !nodeIds.isEmpty else { return }

        var nodesToMove: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in nodeIds {
                if let removed = removeNode(id: nodeId, nodes: &workspace.items) {
                    nodesToMove.append(removed)
                }
            }
        }

        updateWorkspace(id: toWorkspaceId) { workspace in
            workspace.items.append(contentsOf: nodesToMove)
        }
    }

    @discardableResult
    func groupNodesInNewFolder(nodeIds: [UUID], folderName: String) -> UUID? {
        guard !nodeIds.isEmpty else { return nil }

        var nodesToGroup: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in nodeIds {
                if let removed = removeNode(id: nodeId, nodes: &workspace.items) {
                    nodesToGroup.append(removed)
                }
            }
        }

        guard !nodesToGroup.isEmpty else { return nil }

        let folder = Folder(id: UUID(), name: folderName, children: nodesToGroup, isExpanded: true)

        updateWorkspace(id: currentWorkspace.id) { workspace in
            workspace.items.append(.folder(folder))
        }

        return folder.id
    }

    private func insertNode(_ node: Node, parentId: UUID?) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            insertNode(node, parentId: parentId, index: nil, nodes: &workspace.items)
        }
    }

    private func updateWorkspace(id: UUID, notify: Bool = true, _ mutate: (inout Workspace) -> Void) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.workspaces[index])
        persist(notify: notify)
    }

    private func updateNode(id: UUID, notify: Bool = true, _ mutate: (inout Node) -> Void) {
        updateWorkspace(id: currentWorkspace.id, notify: notify) { workspace in
            _ = updateNode(id: id, nodes: &workspace.items, mutate)
        }
    }

    private func persist(notify: Bool = true) {
        store.saveAsync(state)
        if notify {
            onChange?()
        }
        // Schedule Spotlight re-index (debounced)
        SpotlightIndexService.shared.scheduleReindex(workspaces: state.workspaces)
    }

    /// Flushes any pending saves and performs an immediate synchronous save.
    /// Call this before app termination to ensure all changes are written to disk.
    func flushPendingSave() {
        store.flush(state)
    }

    /// Registers an undo action by capturing the current state snapshot.
    /// Call this BEFORE mutating state to enable undo/redo.
    private func registerUndo(actionName: String) {
        let beforeState = state
        undoManager.registerUndo(withTarget: self) { target in
            let afterState = target.state  // Capture post-mutation state for redo
            target.state = beforeState
            target.persist()
            // Register redo with the state we just undid from
            target.undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.state = afterState
                redoTarget.persist()
            }
            target.undoManager.setActionName(actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func insertNode(_ node: Node, parentId: UUID?, index: Int?, nodes: inout [Node]) {
        if let parentId {
            for i in nodes.indices {
                switch nodes[i] {
                case .folder(var folder):
                    if folder.id == parentId {
                        if let index {
                            let idx = max(0, min(index, folder.children.count))
                            folder.children.insert(node, at: idx)
                        } else {
                            folder.children.append(node)
                        }
                        nodes[i] = .folder(folder)
                        return
                    }
                    insertNode(node, parentId: parentId, index: index, nodes: &folder.children)
                    nodes[i] = .folder(folder)
                case .link:
                    continue
                }
            }
        } else {
            if let index {
                let idx = max(0, min(index, nodes.count))
                nodes.insert(node, at: idx)
            } else {
                nodes.append(node)
            }
        }
    }

    private func updateNode(id: UUID, nodes: inout [Node], _ mutate: (inout Node) -> Void) -> Bool {
        for index in nodes.indices {
            switch nodes[index] {
            case .link(let link):
                if link.id == id {
                    var node = nodes[index]
                    mutate(&node)
                    nodes[index] = node
                    return true
                }
            case .folder(var folder):
                if folder.id == id {
                    var node = nodes[index]
                    mutate(&node)
                    nodes[index] = node
                    return true
                }
                if updateNode(id: id, nodes: &folder.children, mutate) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    private func removeNode(id: UUID, nodes: inout [Node]) -> Node? {
        for index in nodes.indices {
            switch nodes[index] {
            case .link(let link):
                if link.id == id {
                    return nodes.remove(at: index)
                }
            case .folder(var folder):
                if folder.id == id {
                    return nodes.remove(at: index)
                }
                if let removed = removeNode(id: id, nodes: &folder.children) {
                    nodes[index] = .folder(folder)
                    return removed
                }
            }
        }
        return nil
    }

    private func findNodeLocation(id: UUID, nodes: [Node], parentId: UUID? = nil) -> NodeLocation? {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .link(let link):
                if link.id == id {
                    return NodeLocation(parentId: parentId, index: index)
                }
            case .folder(let folder):
                if folder.id == id {
                    return NodeLocation(parentId: parentId, index: index)
                }
                if let location = findNodeLocation(id: id, nodes: folder.children, parentId: folder.id) {
                    return location
                }
            }
        }
        return nil
    }

    private func isDescendant(nodeId: UUID, in potentialAncestorId: UUID) -> Bool {
        guard let ancestor = nodeById(potentialAncestorId, nodes: currentWorkspace.items) else { return false }
        return containsNode(nodeId, within: ancestor)
    }

    private func nodeById(_ id: UUID, nodes: [Node]) -> Node? {
        for node in nodes {
            switch node {
            case .link(let link):
                if link.id == id { return node }
            case .folder(let folder):
                if folder.id == id { return node }
                if let found = nodeById(id, nodes: folder.children) {
                    return found
                }
            }
        }
        return nil
    }

    private func containsNode(_ id: UUID, within node: Node) -> Bool {
        switch node {
        case .link(let link):
            return link.id == id
        case .folder(let folder):
            if folder.id == id { return true }
            return folder.children.contains(where: { containsNode(id, within: $0) })
        }
    }

    // MARK: - AI Organization

    /// Execute an AI organization decision — creates workspace/folder as needed, then adds the link
    /// - Parameters:
    ///   - url: The URL of the link to add
    ///   - title: The title of the link
    ///   - decision: The AI's organization decision
    /// - Returns: The UUID of the created link
    @discardableResult
    func executeAIOrganization(url: String, title: String, decision: AIOrganizationService.OrganizationDecision) -> UUID {
        var targetWorkspaceId = decision.workspaceId ?? state.selectedWorkspaceId ?? state.workspaces.first?.id
        var targetFolderId = decision.folderId

        switch decision.action {
        case .createWorkspace:
            if let name = decision.newWorkspaceName {
                let workspace = createWorkspace(name: name, colorId: .randomColor())
                targetWorkspaceId = workspace
                // If also creating a folder in the new workspace
                if let folderName = decision.newFolderName {
                    // Switch to new workspace first
                    selectWorkspace(id: workspace)
                    targetFolderId = addFolder(name: folderName, parentId: nil)
                }
            }

        case .createFolder:
            if let folderName = decision.newFolderName, let wsId = targetWorkspaceId {
                // Ensure we're in the right workspace
                if wsId != state.selectedWorkspaceId {
                    selectWorkspace(id: wsId)
                }
                targetFolderId = addFolder(name: folderName, parentId: decision.folderId)
            }

        case .place:
            // Just place in existing location
            if let wsId = targetWorkspaceId, wsId != state.selectedWorkspaceId {
                selectWorkspace(id: wsId)
            }
        }

        // Add the link
        let linkId = addLink(urlString: url, title: title, parentId: targetFolderId)
        return linkId
    }
}
