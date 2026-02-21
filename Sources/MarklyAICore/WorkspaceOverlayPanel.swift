//
//  WorkspaceOverlayPanel.swift
//  MarklyAI
//
//  An overlay panel that shows workspace links/folders when hovering on a concise circle.
//

import AppKit

@MainActor
final class WorkspaceOverlayPanel: NSPanel {
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var hideTimer: Timer?

    var onLinkClicked: ((Link) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        setupUI()
    }

    private func setupUI() {
        let container = NSVisualEffectView()
        container.wantsLayer = true
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        self.contentView = container

        // Title label
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.tag = 100 // For easy access

        // Scroll view for items
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 2
        contentStack.alignment = .leading

        scrollView.documentView = contentStack

        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
        ])
    }

    func show(workspace: Workspace, anchorRect: NSRect) {
        // Set title
        if let titleLabel = contentView?.viewWithTag(100) as? NSTextField {
            titleLabel.stringValue = workspace.name
        }

        // Populate items
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        populateNodes(workspace.items, depth: 0)

        // Calculate height based on items (max 400pt)
        let itemCount = contentStack.arrangedSubviews.count
        let estimatedHeight = min(CGFloat(itemCount) * 32 + 44, 400)

        // Position to the right of anchor circle
        let panelFrame = NSRect(
            x: anchorRect.maxX + 8,
            y: anchorRect.midY - estimatedHeight / 2,
            width: 280,
            height: estimatedHeight
        )
        setFrame(panelFrame, display: true)
        orderFront(nil)
    }

    private func populateNodes(_ nodes: [Node], depth: Int) {
        for node in nodes {
            switch node {
            case .link(let link):
                let row = createLinkRow(link, depth: depth)
                contentStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

            case .folder(let folder):
                let row = createFolderRow(folder, depth: depth)
                contentStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

                // Show children inline (expanded)
                populateNodes(folder.children, depth: depth + 1)
            }
        }
    }

    private func createLinkRow(_ link: Link, depth: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.secondaryLabelColor

        let label = NSTextField(labelWithString: link.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail

        row.addSubview(icon)
        row.addSubview(label)

        let indent = CGFloat(depth) * 16 + 14
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        // Click handler
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleLinkClick(_:)))
        row.addGestureRecognizer(clickGesture)
        row.setAccessibilityLabel(link.title)

        // Store link data for click handling
        let linkData = LinkRowData(link: link)
        objc_setAssociatedObject(row, &linkDataKey, linkData, .OBJC_ASSOCIATION_RETAIN)

        return row
    }

    private func createFolderRow(_ folder: Folder, depth: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.secondaryLabelColor

        let label = NSTextField(labelWithString: folder.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail

        row.addSubview(icon)
        row.addSubview(label)

        let indent = CGFloat(depth) * 16 + 14
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    @objc private func handleLinkClick(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view,
              let linkData = objc_getAssociatedObject(row, &linkDataKey) as? LinkRowData else { return }
        onLinkClicked?(linkData.link)
    }

    func dismiss() {
        orderOut(nil)
    }

    func scheduleHide(delay: TimeInterval = 0.3) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}

nonisolated(unsafe) private var linkDataKey: UInt8 = 0

private class LinkRowData: NSObject {
    let link: Link
    init(link: Link) { self.link = link }
}
