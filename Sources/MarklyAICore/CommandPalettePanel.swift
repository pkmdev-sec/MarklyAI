import AppKit
import NaturalLanguage

@MainActor
final class CommandPalettePanel: NSPanel, NSTextFieldDelegate {

    struct SearchResult {
        enum Kind {
            case link(Link, workspaceName: String)
            case workspace(Workspace)
        }
        let kind: Kind
        var title: String {
            switch kind {
            case .link(let link, _): return link.title
            case .workspace(let ws): return ws.name
            }
        }
        var subtitle: String {
            switch kind {
            case .link(let link, let wsName): return "\(link.url) — \(wsName)"
            case .workspace(let ws): return "\(ws.items.count) items"
            }
        }
        var icon: NSImage? {
            switch kind {
            case .link: return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            case .workspace: return NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
            }
        }
    }

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let resultsStackView = NSStackView()
    private var results: [SearchResult] = []
    private var selectedIndex = 0
    private var resultViews: [NSView] = []
    private var separator: NSBox?

    var onOpenLink: ((Link) -> Void)?
    var onSwitchWorkspace: ((UUID) -> Void)?
    private var allWorkspaces: [Workspace] = []
    private lazy var embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 60),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .floating
        isOpaque = false
        backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 0.95)
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true

        setupUI()
    }

    private func setupUI() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = ThemeConstants.CornerRadius.large
        container.layer?.masksToBounds = true
        self.contentView = container

        // Search icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor.secondaryLabelColor

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search links and workspaces..."
        searchField.font = ThemeConstants.Fonts.systemFont(size: 16, weight: .regular)
        searchField.textColor = NSColor.labelColor
        searchField.backgroundColor = .clear
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.delegate = self

        // Scroll view for results
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.isHidden = true

        // Results stack
        resultsStackView.translatesAutoresizingMaskIntoConstraints = false
        resultsStackView.orientation = .vertical
        resultsStackView.spacing = 0
        resultsStackView.alignment = .leading

        scrollView.documentView = resultsStackView

        // Separator
        let separatorView = NSBox()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.boxType = .separator
        separatorView.isHidden = true
        separator = separatorView

        container.addSubview(iconView)
        container.addSubview(searchField)
        container.addSubview(separatorView)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ThemeConstants.Spacing.extraLarge),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            iconView.widthAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium + 2),
            iconView.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium + 2),

            searchField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: ThemeConstants.Spacing.regular),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ThemeConstants.Spacing.extraLarge),
            searchField.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ThemeConstants.Spacing.extraLarge),
            separatorView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ThemeConstants.Spacing.extraLarge),
            separatorView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: ThemeConstants.Spacing.large),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: ThemeConstants.Spacing.tiny),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -ThemeConstants.Spacing.medium),

            resultsStackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            resultsStackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            resultsStackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
        ])
    }

    func show(workspaces: [Workspace]) {
        self.allWorkspaces = workspaces
        searchField.stringValue = ""
        results = []
        selectedIndex = 0
        updateResults()

        // Size: just search field initially
        setContentSize(NSSize(width: 500, height: 56))
        center()
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }

    func dismiss() {
        searchField.stringValue = ""
        orderOut(nil)
    }

    // MARK: - Search Logic

    private func scoreMatch(query: String, text: String) -> Double {
        let queryLower = query.lowercased()
        let textLower = text.lowercased()

        // Exact substring match gets highest score
        if textLower.contains(queryLower) { return 1.0 }

        // Semantic similarity using NLEmbedding
        if let embedding = embedding {
            let distance = embedding.distance(between: queryLower, and: textLower)
            // NLEmbedding distance is 0-2 (0 = identical, 2 = unrelated)
            // Convert to 0-1 score (1 = best match)
            let score = max(0, 1.0 - distance / 2.0)
            if score > 0.3 { return score * 0.8 } // Cap semantic matches below exact
        }

        // Word-level partial matching
        let queryWords = queryLower.split(separator: " ")
        let textWords = textLower.split(separator: " ")
        let matchCount = queryWords.filter { qw in textWords.contains(where: { $0.hasPrefix(String(qw)) }) }.count
        if matchCount > 0 { return Double(matchCount) / Double(queryWords.count) * 0.6 }

        return 0
    }

    private func performSearch(_ query: String) {
        results = []
        let query = query.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            updateResults()
            return
        }

        var scored: [(result: SearchResult, score: Double)] = []

        // Search workspaces
        for workspace in allWorkspaces {
            let wsScore = scoreMatch(query: query, text: workspace.name)
            if wsScore > 0.2 {
                scored.append((SearchResult(kind: .workspace(workspace)), wsScore))
            }

            // Search links in workspace
            searchNodesScored(workspace.items, query: query, workspaceName: workspace.name, scored: &scored)
        }

        // Sort by score descending, take top 10
        scored.sort { $0.score > $1.score }
        results = scored.prefix(10).map { $0.result }
        selectedIndex = 0
        updateResults()
    }

    private func searchNodesScored(_ nodes: [Node], query: String, workspaceName: String, scored: inout [(result: SearchResult, score: Double)]) {
        for node in nodes {
            switch node {
            case .link(let link):
                let titleScore = scoreMatch(query: query, text: link.title)
                let urlScore = scoreMatch(query: query, text: link.url) * 0.7
                let bestScore = max(titleScore, urlScore)
                if bestScore > 0.2 {
                    scored.append((SearchResult(kind: .link(link, workspaceName: workspaceName)), bestScore))
                }
            case .folder(let folder):
                searchNodesScored(folder.children, query: query, workspaceName: workspaceName, scored: &scored)
            }
        }
    }

    private func updateResults() {
        // Clear old result views
        resultsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultViews.removeAll()

        let hasResults = !results.isEmpty
        scrollView.isHidden = !hasResults
        separator?.isHidden = !hasResults

        if hasResults {
            for (index, result) in results.enumerated() {
                let row = createResultRow(result, isSelected: index == selectedIndex)
                resultsStackView.addArrangedSubview(row)
                resultViews.append(row)

                row.widthAnchor.constraint(equalTo: resultsStackView.widthAnchor).isActive = true
            }

            // Resize panel to show results (max 8 rows)
            let rowHeight: CGFloat = 40
            let resultHeight = min(CGFloat(results.count), 8) * rowHeight
            setContentSize(NSSize(width: 500, height: 56 + ThemeConstants.Spacing.large + resultHeight))
        } else {
            setContentSize(NSSize(width: 500, height: 56))
        }
    }

    private func createResultRow(_ result: SearchResult, isSelected: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(ThemeConstants.Opacity.extraSubtle).cgColor : NSColor.clear.cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = result.icon
        icon.contentTintColor = NSColor.secondaryLabelColor

        let title = NSTextField(labelWithString: result.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = ThemeConstants.Fonts.systemFont(size: 13, weight: .medium)
        title.textColor = NSColor.labelColor
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: result.subtitle)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = ThemeConstants.Fonts.systemFont(size: 11, weight: .regular)
        subtitle.textColor = NSColor.tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(subtitle)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),

            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ThemeConstants.Spacing.extraLarge),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium),
            icon.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ThemeConstants.Spacing.regular),
            title.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -ThemeConstants.Spacing.extraLarge),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: ThemeConstants.Spacing.tiny),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -ThemeConstants.Spacing.extraLarge),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])

        return row
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        performSearch(searchField.stringValue)
    }

    // Handle special keys (arrow up/down, enter, escape)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveUp(_:)) {
            selectedIndex = max(0, selectedIndex - 1)
            updateResults()
            return true
        } else if commandSelector == #selector(moveDown(_:)) {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
            updateResults()
            return true
        } else if commandSelector == #selector(insertNewline(_:)) {
            activateSelected()
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    private func activateSelected() {
        guard selectedIndex < results.count else { return }
        let result = results[selectedIndex]

        switch result.kind {
        case .link(let link, _):
            onOpenLink?(link)
        case .workspace(let workspace):
            onSwitchWorkspace?(workspace.id)
        }

        dismiss()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
