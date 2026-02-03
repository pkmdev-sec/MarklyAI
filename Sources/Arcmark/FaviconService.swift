import AppKit

final class FaviconService {
    static let shared = FaviconService()

    private let store = DataStore()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "favicon.queue", qos: .utility)

    private init() {}

    func favicon(for url: URL, cachedPath: String?, completion: @escaping (NSImage?, String?) -> Void) {
        guard let host = url.host else {
            completion(nil, nil)
            return
        }

        let key = host.lowercased()
        if let image = cache[key] {
            completion(image, cachedPath)
            return
        }

        let iconsDir = store.iconsDirectory()
        let fileName = key.replacingOccurrences(of: ":", with: "_") + ".ico"
        let fileURL = iconsDir.appendingPathComponent(fileName)

        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath),
           let image = NSImage(contentsOfFile: cachedPath) {
            cache[key] = image
            completion(image, cachedPath)
            return
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let image = NSImage(contentsOf: fileURL) {
            cache[key] = image
            completion(image, fileURL.path)
            return
        }

        if inFlight.contains(key) {
            completion(nil, nil)
            return
        }

        inFlight.insert(key)
        queue.async { [weak self] in
            guard let self else { return }
            let scheme = url.scheme ?? "https"
            guard let faviconURL = URL(string: "\(scheme)://\(host)/favicon.ico") else {
                DispatchQueue.main.async {
                    self.inFlight.remove(key)
                    completion(nil, nil)
                }
                return
            }

            let task = URLSession.shared.dataTask(with: faviconURL) { data, _, _ in
                defer {
                    DispatchQueue.main.async {
                        self.inFlight.remove(key)
                    }
                }
                guard let data, let image = NSImage(data: data) else {
                    DispatchQueue.main.async { completion(nil, nil) }
                    return
                }

                do {
                    try data.write(to: fileURL, options: [.atomic])
                } catch {
                    // ignore
                }

                DispatchQueue.main.async {
                    self.cache[key] = image
                    completion(image, fileURL.path)
                }
            }
            task.resume()
        }
    }
}
