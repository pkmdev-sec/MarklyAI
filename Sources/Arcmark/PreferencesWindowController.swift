import AppKit

final class PreferencesWindowController: NSWindowController {
    init() {
        let viewController = PreferencesViewController()
        let window = NSWindow(contentViewController: viewController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 140))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PreferencesViewController: NSViewController {
    private let browserPopup = NSPopUpButton()
    private var browsers: [BrowserInfo] = []

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadBrowsers()
    }

    private func setupUI() {
        let label = NSTextField(labelWithString: "Default Browser")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        browserPopup.translatesAutoresizingMaskIntoConstraints = false
        browserPopup.target = self
        browserPopup.action = #selector(browserChanged)

        view.addSubview(label)
        view.addSubview(browserPopup)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),

            browserPopup.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            browserPopup.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            browserPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    private func loadBrowsers() {
        browsers = BrowserManager.installedBrowsers()
        browserPopup.removeAllItems()
        if browserPopup.menu == nil {
            browserPopup.menu = NSMenu()
        }
        for browser in browsers {
            let item = NSMenuItem(title: browser.name, action: nil, keyEquivalent: "")
            item.representedObject = browser.bundleId
            if let icon = browser.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            browserPopup.menu?.addItem(item)
        }

        let defaultId = BrowserManager.resolveDefaultBrowserBundleId()
        if let defaultId, let index = browsers.firstIndex(where: { $0.bundleId == defaultId }) {
            browserPopup.selectItem(at: index)
        } else if !browsers.isEmpty {
            browserPopup.selectItem(at: 0)
            UserDefaults.standard.set(browsers[0].bundleId, forKey: UserDefaultsKeys.defaultBrowserBundleId)
        }
    }

    @objc private func browserChanged() {
        if let bundleId = browserPopup.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(bundleId, forKey: UserDefaultsKeys.defaultBrowserBundleId)
        }
    }
}
