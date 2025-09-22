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
                    DispatchQueue.main.async {
                        AppDelegate.shared?.showAboutAction()
                    }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    DispatchQueue.main.async {
                        AppDelegate.shared?.showSettingsAction()
                    }
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
    private var lastMenuActionTime: Date = Date.distantPast
    private let menuActionThrottle: TimeInterval = 0.3 // Prevent rapid clicks
    private var globalClickMonitor: Any? = nil
    
    let appStore = AppStore()
    var modelContainer: ModelContainer?
    
    override init() {
        super.init()
        // Set shared instance immediately during initialization
        Self.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // shared is already set in init(), so we can proceed with setup
        setupWindow()
        appStore.performInitialScanIfNeeded()
        appStore.startAutoRescan()
        
        if appStore.isFullscreenMode { updateWindowMode(isFullscreen: true) }
    }
    
    @objc func showAboutAction() {
        // Throttle rapid menu clicks
        let now = Date()
        guard now.timeIntervalSince(lastMenuActionTime) > menuActionThrottle else { return }
        lastMenuActionTime = now
        
        // Prevent multiple dialogs
        guard !isShowingAboutDialog else { return }
        
        isShowingAboutDialog = true
        
        // Create and configure alert on main thread but make it non-blocking
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let alert = NSAlert()
            alert.messageText = "QuarkLauncher"
            alert.informativeText = """
            Version \(self.getVersion())
            
            
            Email: app@elashri.com
            Website: melashri.net/QuarkLauncher
            
            © 2025 Mohamed Elashri
            """
            alert.alertStyle = .informational
            alert.icon = NSApplication.shared.applicationIconImage
            alert.addButton(withTitle: "OK")
            
            // Use beginSheetModal for non-blocking behavior
            if let window = self.window {
                alert.beginSheetModal(for: window) { _ in
                    self.isShowingAboutDialog = false
                }
            } else {
                // Fallback to modal if no window available
                alert.runModal()
                self.isShowingAboutDialog = false
            }
        }
    }
    
    private func getVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    @objc func showSettingsAction() {
        // Throttle rapid menu clicks
        let now = Date()
        guard now.timeIntervalSince(lastMenuActionTime) > menuActionThrottle else { return }
        lastMenuActionTime = now
        
        // Ensure we're on the main thread and the app is ready
        DispatchQueue.main.async { [weak self] in
            self?.showSettings()
        }
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
        
        // Apply theme preference
        appStore.applyThemePreference()
        
        lastShowAt = Date()
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
        
        if let contentView = window?.contentView {
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleBackgroundClick))
            contentView.addGestureRecognizer(clickGesture)
        }
    }
    
    func showSettings() {
        // Quick state update first
        appStore.isSetting = true
        
        // Then show the window - this is now more responsive since state change happens immediately
        showWindow()
    }
    
    func showWindow() {
        guard let window = window else { return }
        
        // Cache frequently accessed values to reduce computation
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        let rect = appStore.isFullscreenMode ? screen.frame : calculateContentRect(for: screen)
        
        // Batch window operations to minimize redraws
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1 // Even faster animation for immediate response
            context.allowsImplicitAnimation = true
            
            window.setFrame(rect, display: false) // Don't display immediately
            applyCornerRadius()
            
            // Set properties that don't require redraw
            window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        } completionHandler: {
            // Do final operations after animation
            window.makeKey()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            
            // Apply theme preference
            self.appStore.applyThemePreference()
            
            // Update state and post notifications last
            self.lastShowAt = Date()
            NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
            
            // Set up global click monitoring for window mode
            self.setupGlobalClickMonitoring()
        }
    }
    
    func hideWindow() {
        window?.orderOut(nil)
        appStore.isSetting = false
        appStore.currentPage = 0
        appStore.searchText = ""
        appStore.openFolder = nil
        appStore.saveAllOrder()
        NotificationCenter.default.post(name: .launchpadWindowHidden, object: nil)
        
        // Remove global click monitoring when window is hidden
        removeGlobalClickMonitoring()
    }
    
    func updateWindowMode(isFullscreen: Bool) {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        
        // Pre-calculate all values to avoid computation during animation
        let targetFrame = isFullscreen ? screen.frame : calculateContentRect(for: screen)
        let targetShadow = !isFullscreen
        let targetCornerRadius: CGFloat = isFullscreen ? 0 : 30
        let targetAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 4, height: 3)
        
        // Use CATransaction for more precise animation control
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08) // Ultra-fast transition
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        
        // Batch all window changes for optimal performance
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08 // Match CATransaction duration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            // Apply all changes simultaneously
            window.animator().setFrame(targetFrame, display: false)
            window.hasShadow = targetShadow
            window.contentAspectRatio = targetAspectRatio
            
            // Apply corner radius changes immediately using layer properties
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                if let layer = contentView.layer {
                    layer.cornerRadius = targetCornerRadius
                    layer.masksToBounds = true
                    // Use implicit animations for smoother corner radius transition
                    let animation = CABasicAnimation(keyPath: "cornerRadius")
                    animation.duration = 0.08
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(animation, forKey: "cornerRadius")
                }
            }
        } completionHandler: {
            // Single display update after all changes complete
            window.display()
            
            // Update global click monitoring based on new mode
            if window.isVisible {
                self.setupGlobalClickMonitoring()
            }
        }
        
        CATransaction.commit()
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
        // Hide window when clicking background in fullscreen mode or when folders/editing aren't active
        if (appStore.isFullscreenMode || !appStore.isFullscreenMode) && appStore.openFolder == nil && !appStore.isFolderNameEditing {
            hideWindow()
        }
    }
    
    // MARK: - Global Click Monitoring
    private func setupGlobalClickMonitoring() {
        // Only set up global monitoring for window mode (not fullscreen)
        guard !appStore.isFullscreenMode else { return }
        
        removeGlobalClickMonitoring() // Remove any existing monitor first
        
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window else { return }
            
            // Don't hide if settings are open or showing dialogs
            guard !self.appStore.isSetting && !self.isShowingAboutDialog else { return }
            
            // Get the click location in screen coordinates
            let clickLocation = NSEvent.mouseLocation
            let windowFrame = window.frame
            
            // Check if click is outside the window
            if !windowFrame.contains(clickLocation) {
                // Only hide if no folder is open and not editing folder names
                if self.appStore.openFolder == nil && !self.appStore.isFolderNameEditing {
                    self.hideWindow()
                }
            }
        }
    }
    
    private func removeGlobalClickMonitoring() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalClickMonitoring()
    }
    
    // MARK: - Theme Handling
    func applyThemePreference(_ preference: String) {
        guard let window = window else { return }
        
        switch preference {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default: // "system"
            window.appearance = nil // Use system default
        }
    }
}
