import AppKit

/// A toggle switch control that wraps NSSwitch with a title label.
/// Provides the same API as the previous custom implementation but uses
/// the native macOS switch control for proper vibrancy and appearance.
final class CustomToggle: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    var isOn: Bool {
        get { toggle.state == .on }
        set {
            let newState: NSControl.StateValue = newValue ? .on : .off
            if toggle.state != newState {
                toggle.state = newState
            }
        }
    }

    var isEnabled: Bool {
        get { toggle.isEnabled }
        set {
            toggle.isEnabled = newValue
            titleLabel.alphaValue = newValue ? 1.0 : 0.5
        }
    }

    var target: AnyObject? {
        get { toggle.target }
        set { toggle.target = newValue }
    }

    var action: Selector? {
        get { toggle.action }
        set { toggle.action = newValue }
    }

    var titleText: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(titleLabel.stringValue)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ThemeConstants.Fonts.bodyRegular
        titleLabel.textColor = ThemeConstants.Colors.darkGray
        titleLabel.lineBreakMode = .byTruncatingTail

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .mini

        addSubview(titleLabel)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
