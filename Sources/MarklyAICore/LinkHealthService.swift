import AppKit

@MainActor
final class LinkHealthService {
    static let shared = LinkHealthService()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    /// Check a single link's health (returns HTTP status or nil for network error)
    func checkLink(url: String) async -> Int? {
        guard let parsed = URL(string: url) else { return nil }

        // Try HEAD first (lighter)
        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        if let (_, response) = try? await session.data(for: request),
           let httpResponse = response as? HTTPURLResponse {
            return httpResponse.statusCode
        }

        // Fallback to GET (some servers reject HEAD)
        request.httpMethod = "GET"
        if let (_, response) = try? await session.data(for: request),
           let httpResponse = response as? HTTPURLResponse {
            return httpResponse.statusCode
        }

        return nil  // Network error — treat as alive, not dead
    }

    /// Check all links in workspaces, returns IDs of dead links
    func checkAllLinks(workspaces: [Workspace]) async -> [UUID] {
        var deadLinks: [UUID] = []
        var allLinks: [(id: UUID, url: String)] = []

        for workspace in workspaces {
            collectLinks(from: workspace.items, into: &allLinks)
        }

        // Check in batches of 5 to avoid overwhelming network
        for batch in stride(from: 0, to: allLinks.count, by: 5) {
            let end = min(batch + 5, allLinks.count)
            let chunk = allLinks[batch..<end]

            await withTaskGroup(of: (UUID, Bool).self) { group in
                for link in chunk {
                    group.addTask {
                        let status = await self.checkLink(url: link.url)
                        let isDead = status == 404 || status == 410
                        return (link.id, isDead)
                    }
                }
                for await (id, isDead) in group {
                    if isDead { deadLinks.append(id) }
                }
            }
        }

        return deadLinks
    }

    private func collectLinks(from nodes: [Node], into links: inout [(id: UUID, url: String)]) {
        for node in nodes {
            switch node {
            case .link(let link): links.append((link.id, link.url))
            case .folder(let folder): collectLinks(from: folder.children, into: &links)
            }
        }
    }
}
