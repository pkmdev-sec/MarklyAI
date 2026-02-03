import AppKit

final class NodeCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = NSColor.white.withAlphaComponent(0.92)
        titleField.lineBreakMode = .byTruncatingTail

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        deleteButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.setButtonType(.momentaryChange)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -8),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),
            deleteButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func configure(title: String, icon: NSImage?, showDelete: Bool, onDelete: (() -> Void)?) {
        titleField.stringValue = title
        iconView.image = icon
        if let icon {
            iconView.contentTintColor = icon.isTemplate ? NSColor.white.withAlphaComponent(0.9) : nil
        }
        deleteButton.isHidden = !showDelete
        self.onDelete = onDelete
    }

    @objc private func handleDelete() {
        onDelete?()
    }
}
