//
//  WindowAttachmentService.swift
//  Arcmark
//
//  Service for attaching Arcmark window to browser windows using macOS Accessibility API.
//

import AppKit
import ApplicationServices

protocol WindowAttachmentServiceDelegate: AnyObject {
    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect)
    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService)
    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService)
}

@MainActor
final class WindowAttachmentService {
    static let shared = WindowAttachmentService()

    weak var delegate: WindowAttachmentServiceDelegate?

    // State tracking
    private var browserApp: NSRunningApplication?
    private var browserWindowElement: AXUIElement?
    private var observers: [AXObserver] = []
    private var isEnabled: Bool = false
    private var currentBrowserBundleId: String?
    private var sidebarPosition: SidebarPosition = .right

    // Notification observers
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?

    // Debouncing
    private var positionUpdateTimer: Timer?
    private let positionDebounceInterval: TimeInterval = 0.05

    private init() {}

    // MARK: - Public Interface

    func enable(browserBundleId: String, position: SidebarPosition) {
        guard checkAccessibilityPermissions() else {
            print("WindowAttachmentService: Accessibility permissions not granted")
            return
        }

        print("WindowAttachmentService: Enabling attachment to \(browserBundleId), position: \(position)")

        self.currentBrowserBundleId = browserBundleId
        self.sidebarPosition = position
        self.isEnabled = true

        setupWorkspaceObservers()
        setupScreenChangeObserver()
        attachToBrowser()
    }

    func disable() {
        print("WindowAttachmentService: Disabling attachment")

        isEnabled = false
        cleanupObservers()
        cleanupWorkspaceObservers()
        cleanupScreenChangeObserver()

        browserApp = nil
        browserWindowElement = nil
        currentBrowserBundleId = nil
    }

    func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Browser Window Discovery

    private func findFrontmostBrowserWindow() -> AXUIElement? {
        guard let bundleId = currentBrowserBundleId else { return nil }

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
              app.isActive else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowList: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success,
              let windows = windowList as? [AXUIElement],
              let firstWindow = windows.first else {
            return nil
        }

        // Check if window is minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(firstWindow, kAXMinimizedAttribute as CFString, &minimized)
        if let isMinimized = minimized as? Bool, isMinimized {
            return nil
        }

        return firstWindow
    }

    // MARK: - Window Frame Extraction

    private func getWindowFrame(_ windowElement: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef,
              let size = sizeRef else {
            return nil
        }

        var cgPoint = CGPoint.zero
        var cgSize = CGSize.zero

        AXValueGetValue(position as! AXValue, .cgPoint, &cgPoint)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)

        // Convert from Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
        if let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - cgPoint.y - cgSize.height
            return NSRect(x: cgPoint.x, y: flippedY, width: cgSize.width, height: cgSize.height)
        }

        return NSRect(origin: cgPoint, size: cgSize)
    }

    // MARK: - Position Calculation

    private func calculateArcmarkFrame(browserFrame: NSRect, arcmarkWidth: CGFloat) -> NSRect? {
        // Check minimum browser width requirement
        let minBrowserWidth: CGFloat = 600
        guard browserFrame.width >= minBrowserWidth else {
            print("WindowAttachmentService: Browser window too narrow (\(browserFrame.width)px)")
            return nil
        }

        // Detect which screen contains the browser window
        guard let screen = detectScreen(for: browserFrame) else {
            print("WindowAttachmentService: Could not detect screen for browser window")
            return nil
        }

        let screenFrame = screen.visibleFrame

        // Calculate Arcmark X position based on sidebar position
        let arcmarkX: CGFloat
        switch sidebarPosition {
        case .left:
            arcmarkX = browserFrame.minX - arcmarkWidth
            // Check if there's enough space on the left
            if arcmarkX < screenFrame.minX {
                print("WindowAttachmentService: Not enough space on left side")
                return nil
            }
        case .right:
            arcmarkX = browserFrame.maxX
            // Check if there's enough space on the right
            if arcmarkX + arcmarkWidth > screenFrame.maxX {
                print("WindowAttachmentService: Not enough space on right side")
                return nil
            }
        }

        // Match browser height exactly
        let arcmarkY = browserFrame.minY
        let arcmarkHeight = browserFrame.height

        let calculatedFrame = NSRect(x: arcmarkX, y: arcmarkY, width: arcmarkWidth, height: arcmarkHeight)
        print("WindowAttachmentService: Calculated frame: \(calculatedFrame)")
        return calculatedFrame
    }

    private func detectScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        var bestScreen: NSScreen?
        var bestOverlap: CGFloat = 0

        for screen in screens {
            let intersection = frame.intersection(screen.frame)
            let overlap = intersection.width * intersection.height
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestScreen = screen
            }
        }

        return bestScreen ?? NSScreen.main
    }

    // MARK: - Main Update Loop

    private func schedulePositionUpdate() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: positionDebounceInterval, repeats: false) { [weak self] _ in
            self?.updateArcmarkPosition()
        }
    }

    private func updateArcmarkPosition() {
        guard isEnabled else { return }

        // Find the frontmost browser window
        guard let windowElement = findFrontmostBrowserWindow() else {
            print("WindowAttachmentService: No valid browser window found")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Get the browser window frame
        guard let browserFrame = getWindowFrame(windowElement) else {
            print("WindowAttachmentService: Could not get browser window frame")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Get current Arcmark window width (user may have resized it)
        let arcmarkWidth: CGFloat = 340 // Default width, will be updated by delegate if needed

        // Calculate new Arcmark frame
        guard let newFrame = calculateArcmarkFrame(browserFrame: browserFrame, arcmarkWidth: arcmarkWidth) else {
            // Invalid frame (browser too narrow, not enough space, etc.)
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Position the window
        delegate?.attachmentService(self, shouldPositionWindow: newFrame)
    }

    // MARK: - Browser Attachment

    private func attachToBrowser() {
        guard let bundleId = currentBrowserBundleId else { return }

        // Check if browser is running and active
        guard BrowserManager.isRunning(bundleId: bundleId) else {
            print("WindowAttachmentService: Browser not running")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        guard let frontmost = BrowserManager.frontmostApp(),
              frontmost.bundleIdentifier == bundleId else {
            print("WindowAttachmentService: Browser not active")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Find browser window
        guard let windowElement = findFrontmostBrowserWindow() else {
            print("WindowAttachmentService: Could not find browser window")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        browserWindowElement = windowElement
        browserApp = frontmost

        // Setup observers for this window
        observeBrowserWindow()

        // Perform initial position update
        updateArcmarkPosition()
    }

    // MARK: - AX Observers

    private func observeBrowserWindow() {
        guard let windowElement = browserWindowElement,
              let app = browserApp else { return }

        var observer: AXObserver?
        let error = AXObserverCreate(app.processIdentifier, { (_, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let service = Unmanaged<WindowAttachmentService>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                let notificationName = notification as String
                print("WindowAttachmentService: Received notification: \(notificationName)")

                switch notificationName {
                case kAXMovedNotification as String, kAXResizedNotification as String:
                    service.schedulePositionUpdate()
                case kAXUIElementDestroyedNotification as String:
                    print("WindowAttachmentService: Browser window destroyed")
                    service.delegate?.attachmentServiceShouldHideWindow(service)
                    service.cleanupObservers()
                default:
                    break
                }
            }
        }, &observer)

        guard error == .success, let observer = observer else {
            print("WindowAttachmentService: Failed to create AX observer")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register for notifications
        AXObserverAddNotification(observer, windowElement, kAXMovedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, windowElement, kAXResizedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, windowElement, kAXUIElementDestroyedNotification as CFString, selfPtr)

        // Add observer to run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        observers.append(observer)
        print("WindowAttachmentService: AX observer setup complete")
    }

    private func cleanupObservers() {
        for observer in observers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        print("WindowAttachmentService: Cleaned up AX observers")
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let activatedObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            print("WindowAttachmentService: App activated: \(app.bundleIdentifier ?? "unknown")")

            if app.bundleIdentifier == self.currentBrowserBundleId {
                // Browser became active - attach and show
                self.attachToBrowser()
            } else {
                // Different app became active - hide Arcmark
                self.delegate?.attachmentServiceShouldHideWindow(self)
            }
        }

        let terminatedObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            print("WindowAttachmentService: App terminated: \(app.bundleIdentifier ?? "unknown")")

            if app.bundleIdentifier == self.currentBrowserBundleId {
                // Browser quit - hide and cleanup
                self.delegate?.attachmentServiceShouldHideWindow(self)
                self.cleanupObservers()
            }
        }

        let launchedObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            print("WindowAttachmentService: App launched: \(app.bundleIdentifier ?? "unknown")")

            if app.bundleIdentifier == self.currentBrowserBundleId {
                // Browser launched - wait for activation
                // Will be handled by didActivateApplicationNotification
            }
        }

        workspaceObservers = [activatedObserver, terminatedObserver, launchedObserver]
        print("WindowAttachmentService: Workspace observers setup complete")
    }

    private func cleanupWorkspaceObservers() {
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        print("WindowAttachmentService: Cleaned up workspace observers")
    }

    // MARK: - Screen Change Observer

    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("WindowAttachmentService: Screen parameters changed")

            // Use longer debounce for screen changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateArcmarkPosition()
            }
        }
        print("WindowAttachmentService: Screen change observer setup complete")
    }

    private func cleanupScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        print("WindowAttachmentService: Cleaned up screen change observer")
    }
}
