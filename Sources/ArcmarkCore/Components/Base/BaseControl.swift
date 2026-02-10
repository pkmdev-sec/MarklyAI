import AppKit

/// Base class for all interactive controls with hover and pressed states
@MainActor
class BaseControl: NSControl {

    // MARK: - Hover State Management

    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var isPressed = false

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    // MARK: - Tracking Areas

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverState()
    }

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        handleHoverStateChanged()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        handleHoverStateChanged()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        handlePressedStateChanged()

        guard let window else { return }
        var keepTracking = true
        while keepTracking {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            let point = convert(nextEvent.locationInWindow, from: nil)
            let inside = bounds.contains(point)

            switch nextEvent.type {
            case .leftMouseDragged:
                let newPressed = inside
                let newHovered = inside
                if isPressed != newPressed || isHovered != newHovered {
                    isPressed = newPressed
                    isHovered = newHovered
                    handlePressedStateChanged()
                }
            case .leftMouseUp:
                isPressed = false
                handlePressedStateChanged()
                if inside {
                    performAction()
                }
                keepTracking = false
            default:
                break
            }
        }

        refreshHoverState()
    }

    /// Refresh hover state based on current mouse position
    func refreshHoverState() {
        guard let window else {
            if isHovered {
                isHovered = false
                handleHoverStateChanged()
            }
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let hovered = bounds.contains(point)
        if hovered != isHovered {
            isHovered = hovered
            handleHoverStateChanged()
        }
    }

    // MARK: - Subclass Override Points

    /// Called when hover state changes. Override to update appearance.
    func handleHoverStateChanged() {
        // Subclasses override
    }

    /// Called when pressed state changes. Override to update appearance.
    func handlePressedStateChanged() {
        // Subclasses override
    }

    /// Called when the control should perform its action (on mouseUp inside bounds)
    func performAction() {
        sendAction(action, to: target)
    }
}
