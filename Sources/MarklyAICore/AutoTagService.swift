import NaturalLanguage

@MainActor
final class AutoTagService {
    static let shared = AutoTagService()

    private let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])

    private init() {}

    /// Generate tags for a link based on URL and title
    func generateTags(url: String, title: String) -> [String] {
        var tags: Set<String> = []

        // Domain-based tags
        if let parsed = URL(string: url), let host = parsed.host?.lowercased() {
            // Remove www and TLD
            let parts = host.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let domain = parts.count > 2 ? parts[parts.count - 2] : parts[0]
                tags.insert(domain)
            }

            // Known domain categories
            let domainTags: [String: [String]] = [
                "github.com": ["dev", "code"],
                "stackoverflow.com": ["dev", "q&a"],
                "medium.com": ["article", "blog"],
                "youtube.com": ["video"],
                "twitter.com": ["social"],
                "x.com": ["social"],
                "reddit.com": ["community"],
                "docs.": ["docs"],
                "developer.apple.com": ["apple", "dev"],
                "arxiv.org": ["research", "paper"],
                "news.ycombinator.com": ["hn", "tech"],
            ]

            for (pattern, patternTags) in domainTags {
                if host.contains(pattern) {
                    for tag in patternTags { tags.insert(tag) }
                }
            }

            // Path-based hints
            let path = parsed.path.lowercased()
            if path.contains("tutorial") { tags.insert("tutorial") }
            if path.contains("docs") || path.contains("documentation") { tags.insert("docs") }
            if path.contains("blog") { tags.insert("blog") }
            if path.contains("api") { tags.insert("api") }
        }

        // NLP-based tags from title
        tagger.string = title
        let range = title.startIndex..<title.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass) { tag, tokenRange in
            if let tag = tag, (tag == .noun || tag == .verb) {
                let word = String(title[tokenRange]).lowercased()
                if word.count >= 3 && word.count <= 20 {
                    tags.insert(word)
                }
            }
            return true
        }

        return Array(tags.prefix(5)).sorted()
    }
}
