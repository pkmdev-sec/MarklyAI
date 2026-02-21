import AppIntents
import AppKit

// MARK: - Add Link Intent

struct AddLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Link to MarklyAI"
    static let description: IntentDescription = "Saves a URL to a MarklyAI workspace"

    @Parameter(title: "URL")
    var url: String

    @Parameter(title: "Workspace Name", default: nil)
    var workspaceName: String?

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let mvc = appDelegate.mainViewControllerForIntents else { return }

            // Find workspace by name or use current
            if let name = workspaceName,
               let workspace = mvc.model.workspaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                mvc.model.selectWorkspace(id: workspace.id)
            }

            if let parsed = URL(string: url) {
                let title = parsed.host ?? url
                let linkId = mvc.model.addLink(urlString: parsed.absoluteString, title: title, parentId: nil)

                // Auto-generate tags
                let tags = AutoTagService.shared.generateTags(url: parsed.absoluteString, title: title)
                mvc.model.updateLinkTags(id: linkId, tags: tags)
            }
        }
        return .result()
    }
}

// MARK: - Open Workspace Intent

struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open MarklyAI Workspace"
    static let description: IntentDescription = "Switches to a workspace and optionally opens all links"

    @Parameter(title: "Workspace Name")
    var workspaceName: String

    @Parameter(title: "Open Links in Browser", default: false)
    var openInBrowser: Bool

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let mvc = appDelegate.mainViewControllerForIntents else { return }

            if let workspace = mvc.model.workspaces.first(where: { $0.name.lowercased() == workspaceName.lowercased() }) {
                mvc.model.selectWorkspace(id: workspace.id)

                if openInBrowser {
                    mvc.openAllLinksInWorkspace()
                }
            }
        }
        return .result()
    }
}

// MARK: - Search Bookmarks Intent

struct SearchBookmarksIntent: AppIntent {
    static let title: LocalizedStringResource = "Search MarklyAI Bookmarks"
    static let description: IntentDescription = "Searches across all workspaces for matching bookmarks"

    @Parameter(title: "Query")
    var query: String

    func perform() async throws -> some ReturnsValue<String> {
        let results = await MainActor.run { () -> [String] in
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let mvc = appDelegate.mainViewControllerForIntents else { return [] }

            let query = query.lowercased()
            var matches: [String] = []

            for workspace in mvc.model.workspaces {
                searchNodes(workspace.items, query: query, results: &matches)
            }

            return Array(matches.prefix(10))
        }

        return .result(value: results.joined(separator: "\n"))
    }

    private func searchNodes(_ nodes: [Node], query: String, results: inout [String]) {
        for node in nodes {
            switch node {
            case .link(let link):
                if link.title.lowercased().contains(query) || link.url.lowercased().contains(query) {
                    results.append("\(link.title): \(link.url)")
                }
            case .folder(let folder):
                searchNodes(folder.children, query: query, results: &results)
            }
        }
    }
}

// MARK: - App Shortcuts Provider

struct MarklyAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddLinkIntent(),
            phrases: ["Save link in \(.applicationName)", "Add bookmark to \(.applicationName)"],
            shortTitle: "Add Link",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: OpenWorkspaceIntent(),
            phrases: ["Open \(.applicationName) workspace"],
            shortTitle: "Open Workspace",
            systemImageName: "square.stack"
        )
    }
}
