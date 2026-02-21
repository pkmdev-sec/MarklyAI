import Foundation

final class DataStore {
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let dataURL: URL

    // Background save infrastructure
    private let saveQueue = DispatchQueue(label: "com.marklyai.datastore.save", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("MarklyAI", isDirectory: true)
        }
        self.dataURL = self.baseDirectory.appendingPathComponent("data.json")
    }

    func load() -> AppState {
        ensureDirectories()
        guard fileManager.fileExists(atPath: dataURL.path) else {
            let defaultState = Self.defaultState()
            save(defaultState)
            return defaultState
        }

        do {
            let data = try Data(contentsOf: dataURL)
            let decoder = JSONDecoder()
            let state = try decoder.decode(AppState.self, from: data)
            return state
        } catch {
            let fallback = Self.defaultState()
            save(fallback)
            return fallback
        }
    }

    /// Asynchronously saves the app state to disk with a 300ms debounce.
    /// This method is non-blocking and safe to call from the main thread.
    /// The state struct is copied and saved on a background queue.
    func saveAsync(_ state: AppState) {
        // Cancel any pending save
        pendingSaveWorkItem?.cancel()

        // Schedule a new save with debounce
        // Weak capture avoids retain cycle (DataStore → workItem → DataStore)
        // If DataStore is deallocated, the pending save is correctly skipped
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSave(state)
        }
        pendingSaveWorkItem = workItem
        saveQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Synchronously saves the app state to disk immediately.
    /// Used for app termination or explicit flush operations.
    func save(_ state: AppState) {
        performSave(state)
    }

    /// Flushes any pending async saves and performs an immediate synchronous save.
    /// Call this before app termination to ensure all changes are persisted.
    /// This runs synchronously on the calling thread and blocks until complete.
    func flush(_ state: AppState) {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        // Synchronous save on current thread — must complete before app exits
        performSave(state)
    }

    /// Internal save implementation that performs the actual JSON encoding and disk write.
    /// Can be called from any queue.
    private func performSave(_ state: AppState) {
        ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: dataURL, options: [.atomic])
        } catch {
            NSLog("DataStore: CRITICAL - Failed to save state: %@", error.localizedDescription)
        }
    }

    func iconsDirectory() -> URL {
        let iconsURL = baseDirectory.appendingPathComponent("Icons", isDirectory: true)
        if !fileManager.fileExists(atPath: iconsURL.path) {
            try? fileManager.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        }
        return iconsURL
    }

    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    static func defaultState() -> AppState {
        let workspace = Workspace(
            id: UUID(),
            name: "Inbox",
            colorId: .defaultColor(),
            items: []
        )
        return AppState(schemaVersion: 2, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)
    }
}
