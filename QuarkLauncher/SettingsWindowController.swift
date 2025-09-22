import Cocoa
import SwiftUI

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var appStore: AppStore
    
    init(appStore: AppStore) {
        self.appStore = appStore
        
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 800
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 600
        
        let windowWidth = max(700, screenWidth * 0.5)
        let windowHeight = max(500, screenHeight * 0.6)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        
        super.init(window: window)
        
        window.delegate = self
        
        // Create the SwiftUI view
        let settingsView = SettingsView(appStore: appStore)
            .frame(minWidth: 700, minHeight: 500)
        
        // Set the content view
        let hostingController = NSHostingController(rootView: settingsView)
        window.contentViewController = hostingController
        
        // Make the window key and order it front
        window.makeKeyAndOrderFront(nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // When the window loses focus, hide it
        if let window = notification.object as? NSWindow {
            window.orderOut(nil)
        }
    }
}