import AppKit

@MainActor
final class ClipboardMonitorService {
    static let shared = ClipboardMonitorService()

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    var onURLDetected: ((URL) -> Void)?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's a URL
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return }

        onURLDetected?(url)
    }
}
