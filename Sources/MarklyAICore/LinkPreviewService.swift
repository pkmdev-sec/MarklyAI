import AppKit

@MainActor
final class LinkPreviewService {
    static let shared = LinkPreviewService()
    private var cache: [String: String] = [:] // url -> description
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    func fetchDescription(for url: String, completion: @escaping (String?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }

        guard let parsed = URL(string: url) else { completion(nil); return }

        Task {
            do {
                let (data, _) = try await session.data(from: parsed)
                guard let html = String(data: data, encoding: .utf8) else {
                    completion(nil)
                    return
                }

                // Extract og:description or meta description
                let description = extractDescription(from: html)
                if let desc = description {
                    cache[url] = desc
                }
                completion(description)
            } catch {
                completion(nil)
            }
        }
    }

    private func extractDescription(from html: String) -> String? {
        // Try og:description first
        if let ogMatch = html.range(of: "og:description.*?content=\"([^\"]+)\"", options: .regularExpression) {
            let content = html[ogMatch]
            if let contentRange = content.range(of: "content=\"([^\"]+)\"", options: .regularExpression) {
                var desc = String(content[contentRange])
                desc = desc.replacingOccurrences(of: "content=\"", with: "")
                desc = desc.replacingOccurrences(of: "\"", with: "")
                return String(desc.prefix(200))
            }
        }

        // Try meta description
        if let metaMatch = html.range(of: "name=\"description\".*?content=\"([^\"]+)\"", options: .regularExpression) {
            let content = html[metaMatch]
            if let contentRange = content.range(of: "content=\"([^\"]+)\"", options: .regularExpression) {
                var desc = String(content[contentRange])
                desc = desc.replacingOccurrences(of: "content=\"", with: "")
                desc = desc.replacingOccurrences(of: "\"", with: "")
                return String(desc.prefix(200))
            }
        }

        return nil
    }
}
