import AppKit

final class NodeRowView: BaseView {
    private let iconView = NSImageView()
    private let editableTitle = InlineEditableTextField()
    private let deleteButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private var isSelected = false
    private var showsDeleteButton = false
    private var metrics = ListMetrics()
    private var onDelete: (() -> Void)?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        layer?.cornerRadius = metrics.rowCornerRadius
        layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = metrics.iconCornerRadius
        iconView.layer?.masksToBounds = true

        editableTitle.translatesAutoresizingMaskIntoConstraints = false

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor.tertiaryLabelColor
        countLabel.isHidden = true

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.isBordered = false
        let deleteIconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(deleteIconConfig)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.setButtonType(.momentaryChange)
        deleteButton.toolTip = "Delete"

        addSubview(iconView)
        addSubview(editableTitle)
        addSubview(countLabel)
        addSubview(deleteButton)

        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 26)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 26)

        NSLayoutConstraint.activate([
            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint!,
            iconHeightConstraint!,

            editableTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            editableTitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            editableTitle.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            countLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22)
        ])

    }

    func configure(title: String,
                   icon: NSImage?,
                   titleFont: NSFont,
                   showDelete: Bool,
                   metrics: ListMetrics,
                   onDelete: (() -> Void)?,
                   isSelected: Bool,
                   childCount: Int? = nil,
                   linkUrl: String? = nil) {
        self.metrics = metrics
        self.isSelected = isSelected
        updateVisualState()
        if editableTitle.isEditing {
            if editableTitle.text != title {
                cancelInlineRename()
                editableTitle.text = title
            }
        } else {
            editableTitle.text = title
        }
        editableTitle.font = titleFont
        editableTitle.textColor = metrics.titleColor

        iconView.image = icon
        if let icon {
            iconView.contentTintColor = icon.isTemplate ? metrics.iconTintColor : nil
        }

        layer?.cornerRadius = metrics.rowCornerRadius
        iconView.layer?.cornerRadius = metrics.iconCornerRadius
        deleteButton.contentTintColor = metrics.deleteTintColor
        iconWidthConstraint?.constant = metrics.iconSize
        iconHeightConstraint?.constant = metrics.iconSize

        showsDeleteButton = showDelete
        self.onDelete = onDelete

        // Update count label
        if let childCount = childCount {
            countLabel.stringValue = "\(childCount)"
            countLabel.isHidden = false
        } else {
            countLabel.isHidden = true
        }

        // Set up link preview tooltip for links
        if let linkUrl = linkUrl {
            // Set basic tooltip immediately
            self.toolTip = linkUrl

            // Fetch rich description asynchronously
            LinkPreviewService.shared.fetchDescription(for: linkUrl) { [weak self] description in
                guard let self, let description else { return }
                self.toolTip = "\(title)\n\(description)\n\(linkUrl)"
            }
        } else {
            self.toolTip = nil
        }

        refreshHoverState()

        // Set accessibility properties
        setAccessibilityRole(.row)
        setAccessibilityLabel(title)
        iconView.setAccessibilityRole(.image)
        iconView.setAccessibilityLabel("\(title) icon")
        deleteButton.setAccessibilityLabel("Delete \(title)")
        deleteButton.setAccessibilityRole(.button)
    }

    func setIndentation(depth: Int, metrics: ListMetrics) {
        iconLeadingConstraint?.constant = metrics.leftPadding + CGFloat(depth) * metrics.indentWidth
    }

    var isInlineRenaming: Bool {
        editableTitle.isEditing
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        editableTitle.beginInlineRename(onCommit: onCommit, onCancel: onCancel)
    }

    func cancelInlineRename() {
        editableTitle.cancelInlineRename()
    }

    func updateIcon(_ icon: NSImage?) {
        iconView.image = icon
        if let icon {
            iconView.contentTintColor = icon.isTemplate ? metrics.iconTintColor : nil
        }
    }

    @objc private func handleDelete() {
        onDelete?()
    }

    override func handleHoverStateChanged() {
        updateVisualState()
    }

    private func updateVisualState() {
        if isSelected {
            layer?.backgroundColor = metrics.selectedBackgroundColor.cgColor
            deleteButton.isHidden = true
        } else if isHovered {
            layer?.backgroundColor = metrics.hoverBackgroundColor.cgColor
            deleteButton.isHidden = !showsDeleteButton
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            deleteButton.isHidden = true
        }
    }
}
