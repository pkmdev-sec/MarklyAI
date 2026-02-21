//
//  ConciseSidebarView.swift
//  MarklyAI
//
//  A thin vertical sidebar showing workspace color circles.
//  Used when there isn't enough screen space for the full sidebar.
//

import AppKit

@MainActor
final class ConciseSidebarView: NSView {
    private let stackView = NSStackView()
    private let circleSize: CGFloat = 28
    private let spacing: CGFloat = 8

    var workspaces: [Workspace] = [] {
        didSet { rebuildCircles() }
    }

    var selectedWorkspaceId: UUID? {
        didSet { rebuildCircles() }
    }

    var onWorkspaceHover: ((UUID, NSRect) -> Void)?
    var onWorkspaceClick: ((UUID) -> Void)?
    var onHoverExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.spacing = spacing
        stackView.alignment = .centerX

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 40), // Below titlebar
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.widthAnchor.constraint(equalToConstant: circleSize),
        ])
    }

    private func rebuildCircles() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for workspace in workspaces {
            let circle = WorkspaceCircle(
                workspaceId: workspace.id,
                color: workspace.colorId.color,
                isSelected: workspace.id == selectedWorkspaceId,
                size: circleSize
            )
            circle.onHover = { [weak self] id in
                guard let self, let circleView = self.stackView.arrangedSubviews.first(where: { ($0 as? WorkspaceCircle)?.workspaceId == id }) else { return }
                let screenRect = circleView.convert(circleView.bounds, to: nil)
                let windowRect = self.window?.convertToScreen(screenRect) ?? .zero
                self.onWorkspaceHover?(id, windowRect)
            }
            circle.onClick = { [weak self] id in
                self?.onWorkspaceClick?(id)
            }
            circle.onHoverExit = { [weak self] in
                self?.onHoverExit?()
            }
            stackView.addArrangedSubview(circle)
        }
    }
}

private final class WorkspaceCircle: NSView {
    let workspaceId: UUID
    private let colorView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var onHover: ((UUID) -> Void)?
    var onClick: ((UUID) -> Void)?
    var onHoverExit: (() -> Void)?

    init(workspaceId: UUID, color: NSColor, isSelected: Bool, size: CGFloat) {
        self.workspaceId = workspaceId
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        colorView.translatesAutoresizingMaskIntoConstraints = false
        colorView.wantsLayer = true
        colorView.layer?.cornerRadius = size / 2
        colorView.layer?.backgroundColor = color.cgColor

        if isSelected {
            colorView.layer?.borderWidth = 2
            colorView.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        }

        addSubview(colorView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            colorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            colorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorView.widthAnchor.constraint(equalToConstant: size),
            colorView.heightAnchor.constraint(equalToConstant: size),
        ])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            colorView.animator().layer?.transform = CATransform3DMakeScale(1.15, 1.15, 1)
        }
        onHover?(workspaceId)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            colorView.animator().layer?.transform = CATransform3DIdentity
        }
        onHoverExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(workspaceId)
    }
}
