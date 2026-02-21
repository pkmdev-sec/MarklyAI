import AppKit

@MainActor
final class QuickCapturePanel: NSPanel {
    private let urlField = NSTextField()
    private let workspacePopup = NSPopUpButton()
    private var onSave: ((String, UUID?) -> Void)?

    init() {
        // Create small floating panel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 56),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Panel configuration
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        isOpaque = false
        backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 0.95)
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true

        // Single-line design: [icon] [url field] [workspace popup]
        setupUI()
    }

    private func setupUI() {
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true
        self.contentView = contentView

        // URL icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor.secondaryLabelColor

        // URL text field
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.placeholderString = "Paste URL and press Enter..."
        urlField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        urlField.textColor = NSColor.labelColor
        urlField.backgroundColor = .clear
        urlField.isBordered = false
        urlField.focusRingType = .none
        urlField.target = self
        urlField.action = #selector(saveURL)

        // Workspace selector (compact)
        workspacePopup.translatesAutoresizingMaskIntoConstraints = false
        workspacePopup.controlSize = .small
        workspacePopup.font = NSFont.systemFont(ofSize: 11)

        contentView.addSubview(iconView)
        contentView.addSubview(urlField)
        contentView.addSubview(workspacePopup)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            urlField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            urlField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            workspacePopup.leadingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: 8),
            workspacePopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            workspacePopup.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            workspacePopup.widthAnchor.constraint(equalToConstant: 100),
        ])
    }

    func show(workspaces: [Workspace], currentWorkspaceId: UUID?, onSave: @escaping (String, UUID?) -> Void) {
        self.onSave = onSave

        // Populate workspace popup
        workspacePopup.removeAllItems()
        for workspace in workspaces {
            workspacePopup.addItem(withTitle: workspace.name)
            workspacePopup.lastItem?.representedObject = workspace.id
        }
        if let currentId = currentWorkspaceId,
           let index = workspaces.firstIndex(where: { $0.id == currentId }) {
            workspacePopup.selectItem(at: index)
        }

        // Auto-fill from clipboard if it contains a URL
        if let clipboard = NSPasteboard.general.string(forType: .string),
           let _ = URL(string: clipboard),
           clipboard.lowercased().hasPrefix("http") {
            urlField.stringValue = clipboard
            urlField.selectText(nil)
        } else {
            urlField.stringValue = ""
        }

        // Center on screen and show
        center()
        makeKeyAndOrderFront(nil)
        urlField.becomeFirstResponder()
    }

    func dismiss() {
        urlField.stringValue = ""
        orderOut(nil)
    }

    @objc private func saveURL() {
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }

        let workspaceId = workspacePopup.selectedItem?.representedObject as? UUID
        onSave?(urlString, workspaceId)
        dismiss()
    }

    // Handle Escape key
    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            dismiss()
        } else {
            super.keyDown(with: event)
        }
    }
}
