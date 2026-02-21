import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexService {
    static let shared = SpotlightIndexService()

    private let searchableIndex = CSSearchableIndex.default()
    private var reindexTimer: Timer?

    private init() {}

    /// Schedule a re-index after a brief delay (debounced)
    func scheduleReindex(workspaces: [Workspace]) {
        reindexTimer?.invalidate()
        reindexTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.reindexAll(workspaces: workspaces)
            }
        }
    }

    /// Re-indexes all bookmarks from all workspaces
    func reindexAll(workspaces: [Workspace]) {
        // Build items on main actor before passing to background
        var items: [CSSearchableItem] = []
        for workspace in workspaces {
            collectItems(from: workspace.items, workspaceName: workspace.name, items: &items)
        }
        guard !items.isEmpty else { return }

        // Delete existing index then add new items
        searchableIndex.deleteAllSearchableItems { [weak self] _ in
            self?.searchableIndex.indexSearchableItems(items) { error in
                if let error {
                    print("SpotlightIndexService: Failed to index - \(error)")
                }
            }
        }
    }

    /// Index a single link
    func indexLink(_ link: Link, workspaceName: String) {
        let item = createSearchableItem(link: link, workspaceName: workspaceName)
        searchableIndex.indexSearchableItems([item])
    }

    /// Remove a link from index
    func removeLink(id: UUID) {
        searchableIndex.deleteSearchableItems(withIdentifiers: [id.uuidString])
    }

    private func collectItems(from nodes: [Node], workspaceName: String, items: inout [CSSearchableItem]) {
        for node in nodes {
            switch node {
            case .link(let link):
                items.append(createSearchableItem(link: link, workspaceName: workspaceName))
            case .folder(let folder):
                collectItems(from: folder.children, workspaceName: workspaceName, items: &items)
            }
        }
    }

    private func createSearchableItem(link: Link, workspaceName: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = link.title
        attributes.contentDescription = "MarklyAI bookmark in \(workspaceName)"
        attributes.url = URL(string: link.url)
        attributes.keywords = [workspaceName, link.url, link.title]

        return CSSearchableItem(
            uniqueIdentifier: link.id.uuidString,
            domainIdentifier: "com.marklyai.bookmarks",
            attributeSet: attributes
        )
    }
}
