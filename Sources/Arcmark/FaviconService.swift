import AppKit

@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private let store = DataStore()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

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

        Task {
            let scheme = url.scheme ?? "https"
            guard let faviconURL = URL(string: "\(scheme)://\(host)/favicon.ico") else {
                inFlight.remove(key)
                completion(nil, nil)
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: faviconURL)
                guard let image = NSImage(data: data) else {
                    inFlight.remove(key)
                    completion(nil, nil)
                    return
                }
                try? data.write(to: fileURL, options: [.atomic])
                cache[key] = image
                inFlight.remove(key)
                completion(image, fileURL.path)
            } catch {
                inFlight.remove(key)
                completion(nil, nil)
            }
        }
    }
}
