import SwiftUI
import AppKit
import SwiftData
import Combine

extension Notification.Name {
    static let launchpadWindowShown = Notification.Name("LaunchpadWindowShown")
    static let launchpadWindowHidden = Notification.Name("LaunchpadWindowHidden")
}

class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About QuarkLauncher") {
                    AppDelegate.shared?.showAboutAction()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    AppDelegate.shared?.showSettingsAction()
                }
                .keyboardShortcut(",")
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    
    private var window: NSWindow?
    private let minimumContentSize = NSSize(width: 800, height: 600)
    private var lastShowAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var isShowingAboutDialog = false
    
    let appStore = AppStore()
    var modelContainer: ModelContainer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        
        setupWindow()
        appStore.performInitialScanIfNeeded()
        appStore.startAutoRescan()
        
        if appStore.isFullscreenMode { updateWindowMode(isFullscreen: true) }
    }
    
    @objc func showAboutAction() {
        isShowingAboutDialog = true
        let alert = NSAlert()
        alert.messageText = "QuarkLauncher"
        alert.informativeText = """
        Version \(getVersion())
        
        
        Email: app@elashri.com
        Website: melashri.net/QuarkLauncher
        
        © 2025 Mohamed Elashri
        """
        alert.alertStyle = .informational
        alert.icon = NSApplication.shared.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.runModal()
        isShowingAboutDialog = false
    }
    
    private func getVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    @objc func showSettingsAction() {
        showSettings()
    }
    
    func applicationShouldShowAbout(_ application: NSApplication) -> Bool {
        showAboutAction()
        return false
    }
    
    func applicationShouldOpenPreferences(_ application: NSApplication) -> Bool {
        showSettingsAction()
        return false
    }
    
    private func setupWindow() {
        guard let screen = NSScreen.main else { return }
        let rect = calculateContentRect(for: screen)
        
        window = BorderlessWindow(contentRect: rect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        window?.delegate = self
        window?.isMovable = false
        window?.level = .floating
        window?.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window?.isOpaque = true
        window?.backgroundColor = .clear
        window?.hasShadow = true
        window?.contentAspectRatio = NSSize(width: 4, height: 3)
        window?.contentMinSize = minimumContentSize
        window?.minSize = window?.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size ?? minimumContentSize
        
        // SwiftData support (fixed to Application Support directory to avoid data loss after app replacement)
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let storeDir = appSupport.appendingPathComponent("QuarkLauncher", isDirectory: true)
            if !fm.fileExists(atPath: storeDir.path) {
                try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            }
            let storeURL = storeDir.appendingPathComponent("Data.store")

            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: TopItemData.self, PageEntryData.self, configurations: configuration)
            modelContainer = container
            appStore.configure(modelContext: container.mainContext)
            window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore).modelContainer(container))
        } catch {
            // Fall back to default container to ensure functionality
            if let container = try? ModelContainer(for: TopItemData.self, PageEntryData.self) {
                modelContainer = container
                appStore.configure(modelContext: container.mainContext)
                window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore).modelContainer(container))
            } else {
                window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore))
            }
        }
        
        applyCornerRadius()
        window?.orderFrontRegardless()
        window?.makeKey()
        lastShowAt = Date()
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
        
        if let contentView = window?.contentView {
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleBackgroundClick))
            contentView.addGestureRecognizer(clickGesture)
        }
    }
    
    func showSettings() {
        appStore.isSetting = true
        showWindow()
    }
    
    func showWindow() {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        let rect = appStore.isFullscreenMode ? screen.frame : calculateContentRect(for: screen)
        window.setFrame(rect, display: true)
        applyCornerRadius()
        window.makeKey()
        lastShowAt = Date()
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
    }
    
    func hideWindow() {
        window?.orderOut(nil)
        appStore.isSetting = false
        appStore.currentPage = 0
        appStore.searchText = ""
        appStore.openFolder = nil
        appStore.saveAllOrder()
        NotificationCenter.default.post(name: .launchpadWindowHidden, object: nil)
    }
    
    func updateWindowMode(isFullscreen: Bool) {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        
        // Optimized window transition with faster, smoother animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15 // Reduced from 0.25 for snappier feel
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut) // Better timing function
            
            // Apply all visual changes together for smoother transition
            window.animator().setFrame(isFullscreen ? screen.frame : calculateContentRect(for: screen), display: false)
            window.hasShadow = !isFullscreen
            window.contentAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 4, height: 3)
            
            // Apply corner radius changes immediately during animation
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = isFullscreen ? 0 : 30
                contentView.layer?.masksToBounds = true
            }
        } completionHandler: {
            // Final display update after animation completes
            window.display()
        }
    }
    
    private func applyCornerRadius() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = appStore.isFullscreenMode ? 0 : 30
        contentView.layer?.masksToBounds = true
    }
    
    private func calculateContentRect(for screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let width = max(frame.width * 0.4, minimumContentSize.width, minimumContentSize.height * 4/3)
        let height = width * 3/4
        return NSRect(x: frame.midX - width/2, y: frame.midY - height/2, width: width, height: height)
    }
    
    private func getCurrentActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = minimumContentSize
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: max(contentSize.width, minSize.width), height: max(contentSize.height, minSize.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }
    
    func windowDidResignKey(_ notification: Notification) { autoHideIfNeeded() }
    func windowDidResignMain(_ notification: Notification) { autoHideIfNeeded() }
    private func autoHideIfNeeded() {
        guard !appStore.isSetting && !isShowingAboutDialog else { return }
        hideWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true {
            hideWindow()
        } else {
            showWindow()
        }
        return false
    }
    
    @objc private func handleBackgroundClick() {
        if appStore.isFullscreenMode && appStore.openFolder == nil && !appStore.isFolderNameEditing {
            hideWindow()
        }
    }
}
