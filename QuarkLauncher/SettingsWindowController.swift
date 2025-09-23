import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var appStore: AppStore
    private var hasUserMovedWindow = false
    
    init(appStore: AppStore) {
        self.appStore = appStore
        
        // Initialize with a modest default size; actual sizing done in present(...)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        
        super.init(window: window)
        
        window.delegate = self
        
        // SwiftUI settings view with reduced minimums
        let settingsView = SettingsView(appStore: appStore)
        let hostingController = NSHostingController(rootView: settingsView)
        window.contentViewController = hostingController
        
        // Enforce content min/max to avoid scrollbars and excessive size
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.contentMaxSize = NSSize(width: 900, height: 700)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Public API
    
    /// Present the window centered relative to the given parent window.
    /// - Parameters:
    ///   - parent: The app's main window to center relative to. If nil, uses the active screen.
    ///   - animate: Whether to fade-in when presenting.
    func present(centeredRelativeTo parent: NSWindow?, animate: Bool = true) {
        guard let window = self.window else { return }
        
        // Compute responsive size: adapt to screen, respect content min/max
        let screen = parent?.screen ?? NSScreen.screens.first { screen in
            parent?.frame.intersects(screen.frame) ?? false
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        
        // Target content size: responsive with caps
        let targetWidth = min(max(visible.width * 0.38, 640), 900)
        let targetHeight = min(max(visible.height * 0.50, 480), 700)
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        
        // Center relative to the parent window frame (respects full-screen and multi-monitor)
        if !window.isVisible || !hasUserMovedWindow {
            let referenceFrame: NSRect
            if let parent = parent {
                referenceFrame = parent.frame
            } else {
                referenceFrame = visible
            }
            let frame = window.frame
            let origin = NSPoint(
                x: referenceFrame.midX - frame.size.width / 2,
                y: referenceFrame.midY - frame.size.height / 2
            )
            // Clamp to the current screen's visible frame so it's fully on-screen
            let clampedX = max(visible.minX, min(origin.x, visible.maxX - frame.size.width))
            let clampedY = max(visible.minY, min(origin.y, visible.maxY - frame.size.height))
            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        }
        
        // Smooth fade-in presentation
        if animate {
            let previousAlpha = window.alphaValue
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = previousAlpha == 0 ? 1.0 : previousAlpha
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the window instead of closing it
        sender.orderOut(nil)
        appStore.isSetting = false
        return false
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // Don't automatically hide the window when it loses focus
        // Users should be able to keep the settings window open
    }
    
    func windowDidMove(_ notification: Notification) {
        // Respect user's manual placement on subsequent shows
        hasUserMovedWindow = true
    }
}
