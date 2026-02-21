//
//  WindowAttachmentService.swift
//  MarklyAI
//
//  Service for attaching MarklyAI window to browser windows using macOS Accessibility API.
//

import AppKit
import OSLog
@preconcurrency import ApplicationServices

@MainActor
protocol WindowAttachmentServiceDelegate: AnyObject {
    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool)
    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService)
    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService)
}

@MainActor
final class WindowAttachmentService {
    static let shared = WindowAttachmentService()
    
    private let logger = Logger(subsystem: "com.marklyai.app", category: "attachment")
    
    weak var delegate: WindowAttachmentServiceDelegate?

    // State tracking
    private var browserApp: NSRunningApplication?
    private var browserWindowElement: AXUIElement?
    private var observers: [AXObserver] = []
    private var isEnabled: Bool = false
    private var currentBrowserBundleId: String?
    private var sidebarPosition: SidebarPosition = .right
    private var lastFrontmostBundleId: String?

    // Notification observers
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?

    // Debouncing - reduced from 0.05 to 0.016 (~60fps) for smoother tracking
    private var positionUpdateTimer: Timer?
    private let positionDebounceInterval: TimeInterval = 0.016

    // Frame caching to skip redundant updates
    private var lastBrowserFrame: NSRect?
    private var lastMarklyAIFrame: NSRect?

    // Screen caching to reduce detection overhead
    private var cachedScreen: NSScreen?
    private var cachedScreenFrame: NSRect?

    // Smooth animation using NSAnimationContext
    private var isAnimating: Bool = false
    private let animationDuration: TimeInterval = 0.12 // 120ms smooth animation

    private init() {
        logger.info("WindowAttachmentService initialized")
    }

    // MARK: - Public Interface

    func enable(position: SidebarPosition) {
        logger.debug("enable() called with position=\(String(describing: position))")

        guard checkAccessibilityPermissions() else {
            logger.warning("enable() failed: accessibility permissions not granted")
            requestAccessibilityPermissions()
            return
        }
        logger.debug("Accessibility permissions: granted")

        self.sidebarPosition = position
        self.isEnabled = true
        // currentBrowserBundleId is now set dynamically in findFrontmostBrowserWindow

        setupWorkspaceObservers()
        setupScreenChangeObserver()

        // Try to attach to current frontmost browser (if any)
        if let frontmost = BrowserManager.frontmostApp(),
           let bundleId = frontmost.bundleIdentifier,
           BrowserManager.isBrowser(bundleId: bundleId) {
            currentBrowserBundleId = bundleId
            attachToBrowser()
        }

        logger.info("enable() completed successfully")
    }

    func forceUpdate() {
        guard isEnabled else {
            logger.debug("forceUpdate() skipped: service not enabled")
            return
        }
        logger.debug("forceUpdate() called")
        updateMarklyAIPosition(forceShow: true)
    }

    func disable() {
        logger.info("disable() called")
        isEnabled = false
        cleanupObservers()
        cleanupWorkspaceObservers()
        cleanupScreenChangeObserver()

        browserApp = nil
        browserWindowElement = nil
        currentBrowserBundleId = nil
        lastBrowserFrame = nil
        lastMarklyAIFrame = nil
        lastFrontmostBundleId = nil
        logger.debug("disable() completed")
    }

    func checkAccessibilityPermissions() -> Bool {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermissions() {
        logger.info("requestAccessibilityPermissions() called")
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Browser Window Discovery

    private func findFrontmostBrowserWindow() -> AXUIElement? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmost.bundleIdentifier else {
            logger.debug("findFrontmostBrowserWindow() failed: no frontmost app")
            return nil
        }

        // Dynamically detect if frontmost app is a browser
        guard BrowserManager.isBrowser(bundleId: bundleId) else {
            logger.debug("findFrontmostBrowserWindow() failed: frontmost app \(bundleId) is not a browser")
            return nil
        }

        // Update current browser tracking
        currentBrowserBundleId = bundleId
        logger.debug("findFrontmostBrowserWindow() detected browser: \(bundleId)")

        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        var windowList: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success else {
            logger.warning("findFrontmostBrowserWindow() failed: AXUIElementCopyAttributeValue returned \(result.rawValue)")
            return nil
        }

        guard let windows = windowList as? [AXUIElement], let firstWindow = windows.first else {
            logger.debug("findFrontmostBrowserWindow() failed: no windows found")
            return nil
        }

        // Check if window is minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(firstWindow, kAXMinimizedAttribute as CFString, &minimized)
        if let isMinimized = minimized as? Bool, isMinimized {
            logger.debug("findFrontmostBrowserWindow() failed: window is minimized")
            return nil
        }

        // Check if window is in fullscreen
        var fullscreen: CFTypeRef?
        let fullScreenAttr = "AXFullScreen" as CFString
        AXUIElementCopyAttributeValue(firstWindow, fullScreenAttr, &fullscreen)
        if let isFullscreen = fullscreen as? Bool, isFullscreen {
            logger.debug("findFrontmostBrowserWindow() failed: window is fullscreen")
            return nil  // Don't attach to fullscreen windows
        }

        logger.debug("findFrontmostBrowserWindow() success: found window")
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
            logger.warning("getWindowFrame() failed: could not read position/size attributes")
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
            let frame = NSRect(x: cgPoint.x, y: flippedY, width: cgSize.width, height: cgSize.height)
            logger.debug("getWindowFrame() success: \(NSStringFromRect(frame))")
            return frame
        }

        logger.debug("getWindowFrame() fallback: no screen, using raw coordinates")
        return NSRect(origin: cgPoint, size: cgSize)
    }

    // MARK: - Position Calculation

    private func calculateMarklyAIFrame(browserFrame: NSRect, sidebarWidth: CGFloat) -> NSRect? {
        // Check minimum browser width requirement
        let minBrowserWidth: CGFloat = 600
        guard browserFrame.width >= minBrowserWidth else {
            logger.debug("calculateMarklyAIFrame() failed: browser too narrow (\(browserFrame.width) < \(minBrowserWidth))")
            return nil
        }

        // Detect which screen contains the browser window
        guard let screen = detectScreen(for: browserFrame) else {
            logger.debug("calculateMarklyAIFrame() failed: could not detect screen")
            return nil
        }

        let screenFrame = screen.visibleFrame

        // Calculate MarklyAI X position based on sidebar position
        let marklyAIX: CGFloat
        switch sidebarPosition {
        case .left:
            marklyAIX = browserFrame.minX - sidebarWidth
            // Check if there's enough space on the left
            if marklyAIX < screenFrame.minX {
                logger.debug("calculateMarklyAIFrame() failed: not enough space on left")
                return nil
            }
        case .right:
            marklyAIX = browserFrame.maxX
            // Check if there's enough space on the right
            if marklyAIX + sidebarWidth > screenFrame.maxX {
                logger.debug("calculateMarklyAIFrame() failed: not enough space on right")
                return nil
            }
        }

        // Match browser height exactly
        let marklyAIY = browserFrame.minY
        let marklyAIHeight = browserFrame.height

        let frame = NSRect(x: marklyAIX, y: marklyAIY, width: sidebarWidth, height: marklyAIHeight)
        logger.debug("calculateMarklyAIFrame() success: \(NSStringFromRect(frame))")
        return frame
    }

    private func detectScreen(for frame: NSRect) -> NSScreen? {
        // Use cached screen if the frame is still within the same screen bounds
        if let cached = cachedScreen,
           let cachedBounds = cachedScreenFrame,
           cachedBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            return cached
        }

        // Recalculate if cache miss
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

        let result = bestScreen ?? NSScreen.main
        cachedScreen = result
        cachedScreenFrame = result?.frame

        return result
    }

    // MARK: - Main Update Loop

    private func schedulePositionUpdate() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: positionDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateMarklyAIPosition()
            }
        }
    }

    private func updateMarklyAIPosition(forceShow: Bool = false) {
        guard isEnabled else {
            logger.debug("updateMarklyAIPosition() skipped: service not enabled")
            return
        }
        logger.debug("updateMarklyAIPosition() called, forceShow=\(forceShow)")

        // Find the frontmost browser window
        guard let windowElement = findFrontmostBrowserWindow() else {
            logger.debug("updateMarklyAIPosition(): no frontmost browser window, hiding")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Get the browser window frame
        guard let browserFrame = getWindowFrame(windowElement) else {
            logger.debug("updateMarklyAIPosition(): could not get browser frame, hiding")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if frame has changed
        let frameChanged = lastBrowserFrame != browserFrame
        lastBrowserFrame = browserFrame

        // Try full-width frame first (340pt)
        if let fullFrame = calculateMarklyAIFrame(browserFrame: browserFrame, sidebarWidth: 340) {
            // Full mode fits
            let calculatedFrameChanged = lastMarklyAIFrame != fullFrame
            lastMarklyAIFrame = fullFrame

            if frameChanged || calculatedFrameChanged || forceShow {
                logger.info("updateMarklyAIPosition(): positioning window (full mode) at \(NSStringFromRect(fullFrame))")
                delegate?.attachmentService(self, shouldPositionWindow: fullFrame, animated: true)
            } else {
                logger.debug("updateMarklyAIPosition(): no change, skipping update")
            }
        } else if let conciseFrame = calculateMarklyAIFrame(browserFrame: browserFrame, sidebarWidth: 44) {
            // Concise mode - not enough space for full, but enough for thin bar
            let calculatedFrameChanged = lastMarklyAIFrame != conciseFrame
            lastMarklyAIFrame = conciseFrame

            if frameChanged || calculatedFrameChanged || forceShow {
                logger.info("updateMarklyAIPosition(): positioning window (concise mode) at \(NSStringFromRect(conciseFrame))")
                delegate?.attachmentService(self, shouldPositionWindow: conciseFrame, animated: true)
            } else {
                logger.debug("updateMarklyAIPosition(): no change, skipping update")
            }
        } else {
            // No space at all
            logger.debug("updateMarklyAIPosition(): no space for any mode, hiding")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }
    }

    // MARK: - Browser Attachment

    private func attachToBrowser() {
        logger.debug("attachToBrowser() called")

        // Find browser window (this will also update currentBrowserBundleId dynamically)
        guard let windowElement = findFrontmostBrowserWindow() else {
            logger.debug("attachToBrowser() failed: could not find frontmost browser window")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Get the frontmost app (we know it's a browser at this point)
        guard let frontmost = BrowserManager.frontmostApp() else {
            logger.debug("attachToBrowser() failed: no frontmost app")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if we're already observing this exact window
        if let existingElement = browserWindowElement,
           CFEqual(existingElement, windowElement) {
            // Same window, just update position without re-registering observers
            logger.debug("attachToBrowser(): same window, updating position")
            // Force show in case window was hidden and we're switching to browser
            updateMarklyAIPosition(forceShow: true)
            return
        }

        // Different window - cleanup old observers and setup new ones
        logger.info("attachToBrowser(): new window detected, setting up observers")
        cleanupObservers()
        browserWindowElement = windowElement
        browserApp = frontmost

        // Setup observers for this window
        observeBrowserWindow()

        // Perform initial position update and show window
        updateMarklyAIPosition(forceShow: true)
    }

    // MARK: - AX Observers

    private func observeBrowserWindow() {
        guard let windowElement = browserWindowElement,
              let app = browserApp else {
            logger.warning("observeBrowserWindow() failed: missing windowElement or browserApp")
            return
        }

        var observer: AXObserver?
        let error = AXObserverCreate(app.processIdentifier, { (_, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let service = Unmanaged<WindowAttachmentService>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                let notificationName = notification as String
                service.logger.debug("AX notification received: \(notificationName)")

                if notificationName == (kAXMovedNotification as String) || notificationName == (kAXResizedNotification as String) {
                    service.schedulePositionUpdate()
                } else if notificationName == (kAXUIElementDestroyedNotification as String) {
                    service.logger.info("Browser window destroyed")
                    service.delegate?.attachmentServiceShouldHideWindow(service)
                    service.cleanupObservers()
                }
            }
        }, &observer)

        guard error == .success, let observer = observer else {
            logger.warning("observeBrowserWindow() failed: AXObserverCreate returned \(error.rawValue)")
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
        logger.debug("observeBrowserWindow() success: registered AX observers")
    }

    private func cleanupObservers() {
        logger.debug("cleanupObservers() called, removing \(self.observers.count) observers")
        for observer in observers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        lastBrowserFrame = nil
        lastMarklyAIFrame = nil
        cachedScreen = nil
        cachedScreenFrame = nil
        isAnimating = false
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        logger.debug("setupWorkspaceObservers() called")
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let activatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let bundleId = app.bundleIdentifier
                self.logger.debug("App activated: \(bundleId ?? "nil")")

                if bundleId == Bundle.main.bundleIdentifier {
                    // MarklyAI itself activated - user explicitly clicked on it
                    self.logger.debug("MarklyAI activated, keeping window visible")
                    // Just keep window visible as-is. Do NOT call forceUpdate() here
                    // because MarklyAI is now frontmost, not the browser, so AX queries
                    // for the browser window would fail and hide the sidebar.
                    return
                }

                if let bundleId, BrowserManager.isBrowser(bundleId: bundleId) {
                    // A browser became active - attach to it
                    self.logger.info("Browser became active: \(bundleId)")
                    self.currentBrowserBundleId = bundleId
                    self.lastFrontmostBundleId = bundleId
                    self.attachToBrowser()
                } else {
                    // Non-browser app - hide sidebar
                    self.logger.debug("Non-browser app activated, hiding window")
                    self.lastFrontmostBundleId = bundleId
                    self.delegate?.attachmentServiceShouldHideWindow(self)
                }
            }
        }

        let terminatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if app.bundleIdentifier == self.currentBrowserBundleId {
                    self.logger.info("Browser terminated, hiding and cleaning up")
                    // Browser quit - hide and cleanup
                    self.delegate?.attachmentServiceShouldHideWindow(self)
                    self.cleanupObservers()
                }
            }
        }

        let launchedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if app.bundleIdentifier == self.currentBrowserBundleId {
                    self.logger.debug("Browser launched: \(app.bundleIdentifier ?? "nil")")
                    // Browser launched - wait for activation
                    // Will be handled by didActivateApplicationNotification
                }
            }
        }

        let spaceChangedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isEnabled else { return }
                self.logger.debug("Active space changed, forcing update")
                // Re-check if browser is still frontmost after space change
                self.forceUpdate()
            }
        }

        workspaceObservers = [activatedObserver, terminatedObserver, launchedObserver, spaceChangedObserver]
        spaceChangeObserver = spaceChangedObserver
    }

    private func cleanupWorkspaceObservers() {
        logger.debug("cleanupWorkspaceObservers() called")
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        spaceChangeObserver = nil
    }

    // MARK: - Screen Change Observer

    private func setupScreenChangeObserver() {
        logger.debug("setupScreenChangeObserver() called")
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.logger.debug("Screen parameters changed")

            // Use longer debounce for screen changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateMarklyAIPosition()
            }
        }
    }

    private func cleanupScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
            logger.debug("cleanupScreenChangeObserver() completed")
        }
    }
}
