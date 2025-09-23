import Foundation
import AppKit
import Combine
import SwiftData
import UniformTypeIdentifiers
import CoreServices
import IOKit.ps

/// AppStore manages the application data and provides battery-optimized monitoring
/// Battery optimizations implemented:
/// 1. FSEvents with 2-5s latency (vs 0s) based on app state and power source
/// 2. Increased async dispatch delays from 0.05-0.1s to 0.2-0.5s
/// 3. Combine debouncing increased from 0.5s to 2.0s for auto-save operations
/// 4. App state awareness: reduced monitoring when in background or on battery power
final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var folders: [FolderInfo] = []
    @Published var items: [LaunchpadItem] = []
    @Published var isSetting = false
    
    @Published var currentPage = 0
    @Published var searchText: String = ""
    @Published var isStartOnLogin: Bool = false
    @Published var isFullscreenMode: Bool = false {
        didSet {
            // Only proceed if the value actually changed
            guard oldValue != isFullscreenMode else { return }
            
            UserDefaults.standard.set(isFullscreenMode, forKey: "isFullscreenMode")
            performFullscreenModeTransition()
        }
    }
    
    // Debouncing timer for fullscreen mode transitions (prevent rapid toggles)
    private var fullscreenTransitionTimer: Timer?
    private var lastFullscreenToggle: Date = Date.distantPast
    
    @Published var scrollSensitivity: Double = 0.15 {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: "scrollSensitivity")
        }
    }
    
    // Navigation keyboard shortcuts
    @Published var previousPageKey: UInt16 = 123 { // Default: Left Arrow
        didSet {
            UserDefaults.standard.set(Int(previousPageKey), forKey: "previousPageKey")
        }
    }
    
    @Published var nextPageKey: UInt16 = 124 { // Default: Right Arrow
        didSet {
            UserDefaults.standard.set(Int(nextPageKey), forKey: "nextPageKey")
        }
    }
    
    @Published var useShiftModifier: Bool = false { // Default: no modifier needed
        didSet {
            UserDefaults.standard.set(useShiftModifier, forKey: "useShiftModifier")
        }
    }
    
    // Theme preference
    @Published var themePreference: String = "system" { // "system", "light", "dark"
        didSet {
            UserDefaults.standard.set(themePreference, forKey: "themePreference")
        }
    }
    
    // Cache manager
    private let cacheManager = AppCacheManager.shared
    
    // Folder related state
    @Published var openFolder: FolderInfo? = nil
    @Published var isDragCreatingFolder = false
    @Published var folderCreationTarget: AppInfo? = nil
    @Published var openFolderActivatedByKeyboard: Bool = false
    @Published var isFolderNameEditing: Bool = false
    @Published var handoffDraggingApp: AppInfo? = nil
    @Published var handoffDragScreenLocation: CGPoint? = nil
    
    // Triggers
    @Published var folderUpdateTrigger: UUID = UUID()
    @Published var gridRefreshTrigger: UUID = UUID()
    
    // MARK: - Search (fast, debounced)
    @Published var searchResults: [LaunchpadItem] = []
    private let searchQueue = DispatchQueue(label: "app.store.search", qos: .userInitiated)
    private var searchUpdateWorkItem: DispatchWorkItem?
    private var lowerCacheApps: [String: String] = [:]     // key: app.id (path)
    private var lowerCacheFolders: [String: String] = [:]  // key: folder.id
    private func clearSearchNameCaches() {
        lowerCacheApps.removeAll(keepingCapacity: false)
        lowerCacheFolders.removeAll(keepingCapacity: false)
    }
    
    var modelContext: ModelContext?

    // MARK: - Auto rescan (FSEvents)
    private var fsEventStream: FSEventStreamRef?
    private var pendingChangedAppPaths: Set<String> = []
    private var pendingForceFullScan: Bool = false
    private let fullRescanThreshold: Int = 50

    // Status flags
    private var hasPerformedInitialScan: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    private var hasAppliedOrderFromStore: Bool = false
    
    // Background refresh queue and throttling
    private let refreshQueue = DispatchQueue(label: "app.store.refresh", qos: .userInitiated)
    private var gridRefreshWorkItem: DispatchWorkItem?
    private var rescanWorkItem: DispatchWorkItem?
    private let fsEventsQueue = DispatchQueue(label: "app.store.fsevents")
    
    // Battery optimization: App state awareness
    @Published private var isAppInBackground: Bool = false
    @Published private var isOnBatteryPower: Bool = false
    private var appStateObserver: Any?
    private var powerSourceObserver: Any?
    
    // Computed properties
    private var itemsPerPage: Int { 35 }
    


    private let applicationSearchPaths: [String] = [
        "/Applications",
        "\(NSHomeDirectory())/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications",
        "/Library/Developer/Applications",
        "/Developer/Applications",
        "/Network/Applications"
    ]
    
    private let homebrewSearchPaths: [String] = [
        "/opt/homebrew/Caskroom",
        "/usr/local/Caskroom",
        "/opt/homebrew/Applications",
        "/usr/local/bin",
    ]

    init() {
        self.isFullscreenMode = UserDefaults.standard.bool(forKey: "isFullscreenMode")
        self.scrollSensitivity = UserDefaults.standard.double(forKey: "scrollSensitivity")
        // If no setting has been saved, use default value
        if self.scrollSensitivity == 0.0 {
            self.scrollSensitivity = 0.15
        }
        
        // Load navigation key settings
        let savedPreviousKey = UserDefaults.standard.object(forKey: "previousPageKey") as? Int
        self.previousPageKey = UInt16(savedPreviousKey ?? 123) // Default: Left Arrow
        
        let savedNextKey = UserDefaults.standard.object(forKey: "nextPageKey") as? Int
        self.nextPageKey = UInt16(savedNextKey ?? 124) // Default: Right Arrow
        
        self.useShiftModifier = UserDefaults.standard.bool(forKey: "useShiftModifier")
        
        // Load theme preference
        self.themePreference = UserDefaults.standard.string(forKey: "themePreference") ?? "system"
        
        // Battery optimization: Setup app state monitoring
        setupAppStateMonitoring()
        
        // Observe theme preference changes
        $themePreference
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyThemePreference()
                }
            }
            .store(in: &cancellables)

        // Fast search: react to text and data changes with a short debounce
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSearchUpdate() }
            .store(in: &cancellables)

        $items
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.clearSearchNameCaches()
                self?.scheduleSearchUpdate()
            }
            .store(in: &cancellables)

        $folderUpdateTrigger
            .sink { [weak self] _ in
                self?.clearSearchNameCaches()
                self?.scheduleSearchUpdate()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Keyboard Shortcut Helpers
    func keyCodeName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 123: return "←"
        case 124: return "→"
        case 126: return "↑"
        case 125: return "↓"
        case 48: return "Tab"
        case 36: return "Enter"
        case 49: return "Space"
        case 53: return "Escape"
        default: return "Key \(keyCode)"
        }
    }
    
    func navigationKeysDescription() -> String {
        let prevKey = keyCodeName(for: previousPageKey)
        let nextKey = keyCodeName(for: nextPageKey)
        let modifier = useShiftModifier ? "Shift + " : ""
        return "\(modifier)\(prevKey) / \(modifier)\(nextKey)"
    }

    // MARK: - Theme Handling
    func applyThemePreference() {
        // Call AppDelegate to apply the theme
        DispatchQueue.main.async {
            AppDelegate.shared?.applyThemePreference(self.themePreference)
        }
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Immediately try to load persisted data (if data exists) - don't set flag too early, wait for loading to complete
        if !hasAppliedOrderFromStore {
            loadAllOrder()
        }
        
        $apps
            .map { !$0.isEmpty }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.hasAppliedOrderFromStore {
                    self.loadAllOrder()
                }
            }
            .store(in: &cancellables)
        
        // Listen for items changes, auto-save ordering - battery-optimized debouncing
        $items
            .debounce(for: .seconds(2.0), scheduler: DispatchQueue.main) // Increased from 0.5s for better battery life
            .sink { [weak self] _ in
                guard let self = self, !self.items.isEmpty else { return }
                // Battery-optimized delayed save to avoid frequent saves
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.saveAllOrder()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Order Persistence
    func applyOrderAndFolders() {
        self.loadAllOrder()
    }

    // MARK: - Initial scan (once)
    func performInitialScanIfNeeded() {
        // First try to load persisted data to avoid being overridden by scan (don't set flag too early)
        if !hasAppliedOrderFromStore {
            loadAllOrder()
        }
        
        // Then perform scan while preserving existing order
        hasPerformedInitialScan = true
        scanApplicationsWithOrderPreservation()
        
        // Generate cache after scan completes - battery-optimized delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.generateCacheAfterScan()
        }
    }

    func scanApplications(loadPersistedOrder: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            for path in self.applicationSearchPaths {
                let url = URL(fileURLWithPath: path)
                
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        if !seenPaths.contains(resolved.path) {
                            seenPaths.insert(resolved.path)
                            found.append(self.appInfo(from: resolved))
                        }
                    }
                }
            }

            let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = sorted
                if loadPersistedOrder {
                    self.rebuildItems()
                    self.loadAllOrder()
                } else {
                    self.items = sorted.map { .app($0) }
                    self.saveAllOrder()
                }
                
                // Generate cache after scan completes
                self.generateCacheAfterScan()
                // Update search results after data change
                self.scheduleSearchUpdate()
            }
        }
    }
    
    /// Smart scan applications: preserve existing order, add new apps to end, remove missing apps, auto fill gaps within pages
    func scanApplicationsWithOrderPreservation() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            // Use concurrent queue to accelerate scanning
            let scanQueue = DispatchQueue(label: "app.scan", attributes: .concurrent)
            let group = DispatchGroup()
            let lock = NSLock()
            
            // First, discover applications using LaunchServices (system registry)
            group.enter()
            scanQueue.async {
                let launchServicesApps = self.discoverApplicationsUsingLaunchServices()
                lock.lock()
                for app in launchServicesApps {
                    if !seenPaths.contains(app.url.path) {
                        seenPaths.insert(app.url.path)
                        found.append(app)
                    }
                }
                lock.unlock()
                group.leave()
            }
            
            // Then scan filesystem paths for any missed applications
            for path in self.applicationSearchPaths {
                group.enter()
                scanQueue.async {
                    let pathApps = self.scanApplicationsInPath(path)
                    lock.lock()
                    for app in pathApps {
                        if !seenPaths.contains(app.url.path) {
                            seenPaths.insert(app.url.path)
                            found.append(app)
                        }
                    }
                    lock.unlock()
                    group.leave()
                }
            }
            
            // Scan Homebrew casks specifically
            for homebrewPath in self.homebrewSearchPaths {
                group.enter()
                scanQueue.async {
                    let homebrewApps = self.scanHomebrewApplications(in: homebrewPath)
                    lock.lock()
                    for app in homebrewApps {
                        if !seenPaths.contains(app.url.path) {
                            seenPaths.insert(app.url.path)
                            found.append(app)
                        }
                    }
                    lock.unlock()
                    group.leave()
                }
            }
            
            group.wait()
            
            // Deduplication and sorting - use safer method
            var uniqueApps: [AppInfo] = []
            var uniqueSeenPaths = Set<String>()
            
            for app in found {
                if !uniqueSeenPaths.contains(app.url.path) {
                    uniqueSeenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // Preserve existing app order, only sort new apps by name
            var newApps: [AppInfo] = []
            var existingAppPaths = Set<String>()
            
            // First preserve existing app order
            for app in self.apps {
                if uniqueApps.contains(where: { $0.url.path == app.url.path }) {
                    newApps.append(app)
                    existingAppPaths.insert(app.url.path)
                }
            }
            
            // Then add new apps, sorted by name
            let newAppPaths = uniqueApps.filter { !existingAppPaths.contains($0.url.path) }
            let sortedNewApps = newAppPaths.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            newApps.append(contentsOf: sortedNewApps)
            
            DispatchQueue.main.async {
                self.processScannedApplications(newApps)
                
                // Generate cache after scan completes
                self.generateCacheAfterScan()
            }
        }
    }
    
    /// Manually trigger complete rescan (for manual refresh in settings)
    func forceFullRescan() {
        // Clear cache
        cacheManager.clearAllCaches()
        
        hasPerformedInitialScan = false
        scanApplicationsWithOrderPreservation()
    }
    
    // MARK: - Enhanced Application Discovery
    
    /// Discover applications using LaunchServices (system registry)
    private func discoverApplicationsUsingLaunchServices() -> [AppInfo] {
        var applications: [AppInfo] = []
        
        // Use NSWorkspace to get all applications from LaunchServices database
        let workspace = NSWorkspace.shared
        
        // Get all application URLs from the system
        // This uses the private Launch Services database that Spotlight and Launchpad use
        let allApplications = workspace.runningApplications
        for app in allApplications {
            if let bundleURL = app.bundleURL,
               bundleURL.pathExtension == "app",
               FileManager.default.fileExists(atPath: bundleURL.path),
               isValidApp(at: bundleURL) && 
               shouldShowInLaunchpad(at: bundleURL) {
                let resolved = bundleURL.resolvingSymlinksInPath()
                if !applications.contains(where: { $0.url.path == resolved.path }) {
                    applications.append(appInfo(from: resolved))
                }
            }
        }
        
        // Alternative method: use mdfind (Spotlight) to find all .app bundles
        // This mimics what Launchpad actually does internally
        let spotlightApps = findApplicationsUsingSpotlight()
        for app in spotlightApps {
            if !applications.contains(where: { $0.url.path == app.url.path }) {
                applications.append(app)
            }
        }
        
        return applications
    }
    
    /// Use Spotlight (mdfind) to discover applications like Launchpad does
    private func findApplicationsUsingSpotlight() -> [AppInfo] {
        var applications: [AppInfo] = []
        
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        // Only look for actual application bundles, not all packages
        task.arguments = [
            "kMDItemContentType == 'com.apple.application-bundle'"
        ]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress errors
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .filter { $0.hasSuffix(".app") }
                
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    let resolved = url.resolvingSymlinksInPath()
                    
                    if isValidApp(at: resolved) && shouldShowInLaunchpad(at: resolved) {
                        applications.append(appInfo(from: resolved))
                    }
                }
            }
        } catch {
            // Fallback to regular filesystem scan if mdfind fails
            print("Failed to use mdfind for application discovery: \(error)")
        }
        
        return applications
    }
    
    /// Scan applications in a specific path
    private func scanApplicationsInPath(_ path: String) -> [AppInfo] {
        var applications: [AppInfo] = []
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else { return applications }
        
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .typeIdentifierKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let item as URL in enumerator {
                let resolved = item.resolvingSymlinksInPath()
                
                // Only look for .app bundles - don't scan for individual binaries
                if resolved.pathExtension == "app" &&
                   isValidApp(at: resolved) &&
                   !isInsideAnotherApp(resolved) &&
                   shouldShowInLaunchpad(at: resolved) {
                    applications.append(appInfo(from: resolved))
                }
            }
        }
        
        return applications
    }
    
    /// Scan Homebrew cask applications
    private func scanHomebrewApplications(in path: String) -> [AppInfo] {
        var applications: [AppInfo] = []
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else { return applications }
        
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let item as URL in enumerator {
                let resolved = item.resolvingSymlinksInPath()
                
                // Look for Applications folders within cask directories
                if resolved.lastPathComponent == "Applications" || 
                   resolved.pathExtension == "app" {
                    
                    if resolved.pathExtension == "app" &&
                       isValidApp(at: resolved) &&
                       shouldShowInLaunchpad(at: resolved) {
                        applications.append(appInfo(from: resolved))
                    } else if resolved.lastPathComponent == "Applications" {
                        // Scan inside the Applications folder
                        applications.append(contentsOf: scanApplicationsInPath(resolved.path))
                    }
                }
            }
        }
        
        return applications
    }
    
    /// Determine if an application should appear in Launchpad
    private func shouldShowInLaunchpad(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url) else { return false }
        
        // Check for LSUIElement (background-only apps)
        if let isUIElement = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, isUIElement {
            return false
        }
        
        // Check for LSBackgroundOnly (background-only apps)
        if let isBackgroundOnly = bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool, isBackgroundOnly {
            return false
        }
        
        // Check bundle type - only show actual applications
        if let bundleType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String {
            if bundleType != "APPL" { // Only standard applications
                return false
            }
        }
        
        // Check bundle identifier for system utilities
        if let bundleId = bundle.bundleIdentifier {
            let systemBundlePatterns = [
                "com.apple.inputmethod",
                "com.apple.CoreServices",
                "com.apple.systempreferences",
                "com.apple.scanner",
                "com.apple.AirScan",
                "com.apple.ScannerUtility",
                "com.apple.private",
                "com.apple.internal",
                "org.python",
                "com.python",
                "org.pythonmac",
                "container.",
                "plugin."
            ]
            
            for pattern in systemBundlePatterns {
                if bundleId.lowercased().contains(pattern.lowercased()) {
                    return false
                }
            }
        }
        
        // Exclude system utilities and internal applications that shouldn't appear in Launchpad
        let excludedPaths = [
            "/System/Library/CoreServices/",
            "/System/Library/PrivateFrameworks/",
            "/usr/libexec/",
            "/System/Library/Frameworks/",
            "/System/Library/Extensions/",
            "/Library/Application Support/",
            "/System/Installation/",
            "/System/Cryptexes/",
            "/usr/bin/",
            "/usr/sbin/",
            "/bin/",
            "/sbin/",
            "/System/Library/Input Methods/",
            "/Library/Input Methods/",
            "/System/Library/Image Capture/",
            "/Library/Image Capture/",
            "/System/Library/Services/",
            "/Library/Services/",
            "/System/Library/PreferencePanes/",
            "/Library/PreferencePanes/",
            "/System/Library/Screen Savers/",
            "/Library/Screen Savers/",
            "/System/Library/Components/",
            "/Library/Components/",
            "/System/Library/Spotlight/",
            "/Library/Spotlight/",
            "/System/Library/Containers/",
            "/Library/Containers/",
            "/usr/local/bin/",
            "/opt/homebrew/bin/"
        ]
        
        for excludedPath in excludedPaths {
            if url.path.hasPrefix(excludedPath) {
                return false
            }
        }
        
        // Exclude specific system applications that shouldn't be in Launchpad
        let excludedApps = [
            "Wireless Diagnostics.app",
            "Database Events.app",
            "Directory Utility.app",
            "Network Utility.app",
            "System Information.app",
            "Console.app",
            "SCIM.app",
            "AirScanScanner.app",
            "AirScan Scanner.app",
            "AirScanLegacyDiscovery.app",
            "Python Launcher.app",
            "Python.app"
        ]
        
        let appName = url.lastPathComponent
        if excludedApps.contains(appName) {
            return false
        }
        
        // Check if it's a developer/debug application or system utility
        let appNameLower = appName.lowercased()
        if appNameLower.contains("debug") || 
           appNameLower.contains("test") ||
           appNameLower.contains("diagnostic") ||
           appNameLower.contains("scanner") ||
           appNameLower.contains("scim") ||
           appNameLower.contains("inputmethod") ||
           appNameLower.contains("input method") ||
           appNameLower.contains("utility") ||
           appNameLower.contains("helper") ||
           appNameLower.contains("daemon") ||
           appNameLower.contains("service") ||
           appNameLower.contains("python") ||
           appNameLower.contains("plugin") ||
           appNameLower.contains("container") {
            return false
        }
        
        // Include by default if it passes all filters
        return true
    }
    
    /// Process scanned applications, intelligently match existing order
    private func processScannedApplications(_ newApps: [AppInfo]) {
        // Save current items order and structure
        let currentItems = self.items
        
        // Create new app list while preserving existing order
        var updatedApps: [AppInfo] = []
        var newAppsToAdd: [AppInfo] = []
        
        // Step 1: Preserve existing app order, only update apps that still exist
        for app in self.apps {
            if newApps.contains(where: { $0.url.path == app.url.path }) {
                // App still exists, maintain original position
                updatedApps.append(app)
            } else {
                // App deleted, remove from all related positions
                self.removeDeletedApp(app)
            }
        }
        
        // Step 2: Find newly added applications
        for newApp in newApps {
            if !self.apps.contains(where: { $0.url.path == newApp.url.path }) {
                newAppsToAdd.append(newApp)
            }
        }
        
        // Step 3: Add new apps to the end, keeping existing app order unchanged
        updatedApps.append(contentsOf: newAppsToAdd)
        
        // Update app list
        self.apps = updatedApps
        
        // Step 4: Intelligently rebuild item list, preserving user order
        self.smartRebuildItemsWithOrderPreservation(currentItems: currentItems, newApps: newAppsToAdd)
        
        // Step 5: Auto-compact within pages
        self.compactItemsWithinPages()
        
        // Step 6: Save new order
        self.saveAllOrder()
        
        // Trigger UI updates
        self.triggerFolderUpdate()
        self.triggerGridRefresh()
        
        // Remove any empty pages that might have been created
        DispatchQueue.main.async {
            self.removeEmptyPages()
        }
    }
    
    /// Remove deleted applications
    private func removeDeletedApp(_ deletedApp: AppInfo) {
        // Remove from folders
        for folderIndex in self.folders.indices {
            self.folders[folderIndex].apps.removeAll { $0 == deletedApp }
        }
        
        // Clean up empty folders
        self.folders.removeAll { $0.apps.isEmpty }
        
        // Remove from top-level items, replace with empty slots
        for itemIndex in self.items.indices {
            if case let .app(app) = self.items[itemIndex], app == deletedApp {
                self.items[itemIndex] = .empty(UUID().uuidString)
            }
        }
    }
    
    
    /// Strict method for rebuilding while preserving existing order
    private func rebuildItemsWithStrictOrderPreservation(currentItems: [LaunchpadItem]) {
        
        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(self.folders.flatMap { $0.apps })
        
        // Strictly preserve existing item order and positions
        for (_, item) in currentItems.enumerated() {
            switch item {
            case .folder(let folder):
                // Check if the folder still exists
                if self.folders.contains(where: { $0.id == folder.id }) {
                    // Update folder reference, maintaining original position
                    if let updatedFolder = self.folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        // Folder has been deleted, maintain empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // Folder has been deleted, maintain empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .app(let app):
                // Check if the app still exists
                if self.apps.contains(where: { $0.url.path == app.url.path }) {
                    if !appsInFolders.contains(app) {
                        // App still exists and is not in a folder, maintain original position
                        newItems.append(.app(app))
                    } else {
                        // App is now in a folder, maintain empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // App has been deleted, maintain empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .empty(let token):
                // Maintain empty slot, preserving page layout
                newItems.append(.empty(token))
            }
        }

        // Add new free apps (not in any folder) to the end of the last page
        let existingAppPaths = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app.url.path } else { return nil }
        })
        
        let newFreeApps = self.apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(app.url.path)
        }
        
        if !newFreeApps.isEmpty {

            // Calculate last page information
            let itemsPerPage = self.itemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
            let lastPageEnd = newItems.count

            // If there is space on the last page, add directly to the end
            if lastPageEnd < lastPageStart + itemsPerPage {
                for app in newFreeApps {
                    newItems.append(.app(app))
                }
            } else {
                // If the last page is full, a new page needs to be created
                // First fill the last page to completion
                let remainingSlots = itemsPerPage - (lastPageEnd - lastPageStart)
                for _ in 0..<remainingSlots {
                    newItems.append(.empty(UUID().uuidString))
                }

                // Then add new apps to the new page
                for app in newFreeApps {
                    newItems.append(.app(app))
                }
            }
        }
        
        self.items = newItems
    }
    
    /// Intelligently rebuild item list while preserving user order
    private func smartRebuildItemsWithOrderPreservation(currentItems: [LaunchpadItem], newApps: [AppInfo]) {

        // Preserve current persistent data, but do not load it immediately (to avoid overwriting existing order)
        let hasPersistedData = self.hasPersistedOrderData()
        
        if hasPersistedData {

            // Intelligently merge existing order and persisted data
            self.mergeCurrentOrderWithPersistedData(currentItems: currentItems, newApps: newApps)
        } else {

            // If there is no persisted data, rebuild from scanned results
            self.rebuildFromScannedApps(newApps: newApps)
        }
        
    }
    
    /// Check if there is persisted data
    private func hasPersistedOrderData() -> Bool {
        guard let modelContext = self.modelContext else { return false }
        
        do {
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            let topItems = try modelContext.fetch(FetchDescriptor<TopItemData>())
            return !pageEntries.isEmpty || !topItems.isEmpty
        } catch {
            return false
        }
    }
    
    /// Intelligently merge existing order with persisted data
    private func mergeCurrentOrderWithPersistedData(currentItems: [LaunchpadItem], newApps: [AppInfo]) {

        // Preserve current item order
        let currentOrder = currentItems

        // Load persisted data, but only update folder information
        self.loadFoldersFromPersistedData()

        // Rebuild item list, strictly preserving existing order
        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(self.folders.flatMap { $0.apps })

        // Step 1: Process existing items, preserving order
        for (_, item) in currentOrder.enumerated() {
            switch item {
            case .folder(let folder):
                // Check if the folder still exists
                if self.folders.contains(where: { $0.id == folder.id }) {
                    // Update folder reference, preserving original position
                    if let updatedFolder = self.folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        // Folder has been deleted, keep empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // Folder has been deleted, keep empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .app(let app):
                // Check if the app still exists
                if self.apps.contains(where: { $0.url.path == app.url.path }) {
                    if !appsInFolders.contains(app) {
                        // App still exists and is not in a folder, keep original position
                        newItems.append(.app(app))
                    } else {
                        // App is now in a folder, keep empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // App has been deleted, keep empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .empty(let token):
                // Preserve empty slots, maintaining page layout
                newItems.append(.empty(token))
            }
        }

        // Step 2: Add new free apps (not in any folder) to existing pages with available space
        let existingAppPaths = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app.url.path } else { return nil }
        })
        
        let newFreeApps = self.apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(app.url.path)
        }
        
        if !newFreeApps.isEmpty {
            // Calculate items per page
            let itemsPerPage = self.itemsPerPage
            
            // Distribute new apps across existing pages with available space
            var appsToAdd = newFreeApps
            var currentIndex = 0
            
            // First, try to fill existing pages that have empty slots
            while !appsToAdd.isEmpty && currentIndex < newItems.count {
                let pageStart = (currentIndex / itemsPerPage) * itemsPerPage
                let pageEnd = min(pageStart + itemsPerPage, newItems.count)
                
                // Count empty slots on this page
                var emptySlots = 0
                for i in pageStart..<pageEnd {
                    if case .empty = newItems[i] {
                        emptySlots += 1
                    }
                }
                
                // Fill available empty slots with new apps
                let appsToPlace = min(emptySlots, appsToAdd.count)
                if appsToPlace > 0 {
                    var appIndex = 0
                    for i in pageStart..<pageEnd where appIndex < appsToPlace {
                        if case .empty = newItems[i] {
                            newItems[i] = .app(appsToAdd[appIndex])
                            appIndex += 1
                        }
                    }
                    appsToAdd.removeFirst(appsToPlace)
                }
                
                currentIndex = pageEnd
            }
            
            // If there are still apps to add, append them to the end
            if !appsToAdd.isEmpty {
                // Add remaining apps
                for app in appsToAdd {
                    newItems.append(.app(app))
                }
                
                // Ensure the last page is complete (fill with empty slots if needed)
                let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
                let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
                let lastPageEnd = newItems.count
                
                // If the last page is not complete, fill empty slots
                if lastPageEnd < lastPageStart + itemsPerPage {
                    let remainingSlots = itemsPerPage - (lastPageEnd - lastPageStart)
                    for _ in 0..<remainingSlots {
                        newItems.append(.empty(UUID().uuidString))
                    }
                }
            }
        }
        
        self.items = newItems

    }
    
    /// Rebuild from scan results (when there's no persisted data)
    private func rebuildFromScannedApps(newApps: [AppInfo]) {
        
        // Create a new app list

        var newItems: [LaunchpadItem] = []

        // Add all free apps (not in any folder), maintaining existing order
        let appsInFolders = Set(self.folders.flatMap { $0.apps })
        let freeApps = self.apps.filter { !appsInFolders.contains($0) }

        // Maintain existing order, do not reorder
        for app in freeApps {
            newItems.append(.app(app))
        }

        // Add folders
        for folder in self.folders {
            newItems.append(.folder(folder))
        }

        // Add new apps
        var appsToAdd = newApps.filter { !appsInFolders.contains($0) && !freeApps.contains($0) }
        
        if !appsToAdd.isEmpty {
            // Calculate items per page
            let itemsPerPage = self.itemsPerPage
            
            // Distribute new apps across existing pages with available space
            var currentIndex = 0
            
            // First, try to fill existing pages that have empty slots
            while !appsToAdd.isEmpty && currentIndex < newItems.count {
                let pageStart = (currentIndex / itemsPerPage) * itemsPerPage
                let pageEnd = min(pageStart + itemsPerPage, newItems.count)
                
                // Count empty slots on this page
                var emptySlots = 0
                for i in pageStart..<pageEnd {
                    if case .empty = newItems[i] {
                        emptySlots += 1
                    }
                }
                
                // Fill available empty slots with new apps
                let appsToPlace = min(emptySlots, appsToAdd.count)
                if appsToPlace > 0 {
                    var appIndex = 0
                    for i in pageStart..<pageEnd where appIndex < appsToPlace {
                        if case .empty = newItems[i] {
                            newItems[i] = .app(appsToAdd[appIndex])
                            appIndex += 1
                        }
                    }
                    appsToAdd.removeFirst(appsToPlace)
                }
                
                currentIndex = pageEnd
            }
            
            // If there are still apps to add, append them to the end
            for app in appsToAdd {
                newItems.append(.app(app))
            }
        }

        // Ensure the last page is complete (if not the last page, fill empty slots)
        let itemsPerPage = self.itemsPerPage
        let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
        let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
        let lastPageEnd = newItems.count
        
        // If the last page is not complete, fill empty slots
        if lastPageEnd < lastPageStart + itemsPerPage {
            let remainingSlots = itemsPerPage - (lastPageEnd - lastPageStart)
            for _ in 0..<remainingSlots {
                newItems.append(.empty(UUID().uuidString))
            }
        }
        
        self.items = newItems
    }
    
    /// Only load folder information, don't rebuild item order
    private func loadFoldersFromPersistedData() {
        guard let modelContext = self.modelContext else { return }
        
        do {
            // Attempt to read folder information from the new "page-slot" model
            let saved = try modelContext.fetch(FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            ))
            
            if !saved.isEmpty {
                // Build folders
                var folderMap: [String: FolderInfo] = [:]
                var foldersInOrder: [FolderInfo] = []
                
                for row in saved where row.kind == "folder" {
                    guard let fid = row.folderId else { continue }
                    if folderMap[fid] != nil { continue }
                    
                    let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                        if let existing = apps.first(where: { $0.url.path == path }) {
                            return existing
                        }
                        let url = URL(fileURLWithPath: path)
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return self.appInfo(from: url)
                    }
                    
                    let folder = FolderInfo(id: fid, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                    folderMap[fid] = folder
                    foldersInOrder.append(folder)
                }
                
                self.folders = foldersInOrder
            }
        } catch {
        }
    }

    // MARK: - Battery Optimization: App State Monitoring
    private func setupAppStateMonitoring() {
        // Monitor app activation/deactivation
        appStateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInBackground = false
        }
        
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInBackground = true
        }
        
        // Monitor power source changes
        powerSourceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("com.apple.system.powersources.source"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePowerSourceStatus()
        }
        
        // Initial power source check
        updatePowerSourceStatus()
    }
    
    private func updatePowerSourceStatus() {
        // Check if running on battery power
        let powerSources = IOPSCopyPowerSourcesInfo()
        guard let powerSourcesInfo = powerSources?.takeRetainedValue() else {
            isOnBatteryPower = false
            return
        }
        
        let powerSourcesList = IOPSCopyPowerSourcesList(powerSourcesInfo)
        guard let powerSourcesArray = powerSourcesList?.takeRetainedValue() as? [CFTypeRef] else {
            isOnBatteryPower = false
            return
        }
        
        for powerSource in powerSourcesArray {
            if let powerSourceDict = IOPSGetPowerSourceDescription(powerSourcesInfo, powerSource)?.takeUnretainedValue() as? [String: Any] {
                if let powerSourceState = powerSourceDict[kIOPSPowerSourceStateKey] as? String,
                   powerSourceState == kIOPSBatteryPowerValue {
                    isOnBatteryPower = true
                    return
                }
            }
        }
        isOnBatteryPower = false
    }
    
    private var shouldReduceMonitoring: Bool {
        return isAppInBackground || isOnBatteryPower
    }

    deinit {
        if let observer = appStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = powerSourceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopAutoRescan()
    }

    // MARK: - FSEvents wiring
    func startAutoRescan() {
        guard fsEventStream == nil else { return }

        let pathsToWatch: [String] = applicationSearchPaths + homebrewSearchPaths.filter { path in
            FileManager.default.fileExists(atPath: path) && !applicationSearchPaths.contains(path)
        }
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientInfo else { return }
            
            let appStore = Unmanaged<AppStore>.fromOpaque(info).takeUnretainedValue()

            guard numEvents > 0 else {
                appStore.handleFSEvents(paths: [], flagsPointer: eventFlags, count: 0)
                return
            }
            
            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let nsArray = cfArray as NSArray
            guard let pathsArray = nsArray as? [String] else { return }

            appStore.handleFSEvents(paths: pathsArray, flagsPointer: eventFlags, count: numEvents)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        // Battery optimization: Adjust latency based on app state and power source
        let latency: CFTimeInterval = shouldReduceMonitoring ? 5.0 : 2.0

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, fsEventsQueue)
        FSEventStreamStart(stream)
    }

    func stopAutoRescan() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    private func handleFSEvents(paths: [String], flagsPointer: UnsafePointer<FSEventStreamEventFlags>?, count: Int) {
        let maxCount = min(paths.count, count)
        var localForceFull = false
        
        for i in 0..<maxCount {
            let rawPath = paths[i]
            let flags = flagsPointer?[i] ?? 0

            let created = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
            let renamed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
            let modified = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
            let isDir = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0

            if isDir && (created || removed || renamed), (applicationSearchPaths + homebrewSearchPaths).contains(where: { rawPath.hasPrefix($0) }) {
                localForceFull = true
                break
            }

            guard let appBundlePath = self.canonicalAppBundlePath(for: rawPath) else { continue }
            if created || removed || renamed || modified {
                pendingChangedAppPaths.insert(appBundlePath)
            }
        }

        if localForceFull { pendingForceFullScan = true }
        scheduleRescan()
    }

    private func scheduleRescan() {
        // Battery-optimized debounce to avoid main thread pressure from frequent FSEvents triggers
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performImmediateRefresh() }
        rescanWorkItem = work
        
        // Battery optimization: Increase delay when app is in background or on battery
        let delay: TimeInterval = shouldReduceMonitoring ? 5.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performImmediateRefresh() {
        if pendingForceFullScan || pendingChangedAppPaths.count > fullRescanThreshold {
            pendingForceFullScan = false
            pendingChangedAppPaths.removeAll()
            scanApplications()
            return
        }
        
        let changed = pendingChangedAppPaths
        pendingChangedAppPaths.removeAll()
        
        if !changed.isEmpty {
            applyIncrementalChanges(for: changed)
        }
    }


    private func applyIncrementalChanges(for changedPaths: Set<String>) {
        guard !changedPaths.isEmpty else { return }

        // Move disk and icon resolution to the background, main thread only applies results to reduce stutter
        let snapshotApps = self.apps
        refreshQueue.async { [weak self] in
            guard let self else { return }
            
            enum PendingChange {
                case insert(AppInfo)
                case update(AppInfo)
                case remove(String) // path
            }
            var changes: [PendingChange] = []
            var pathToIndex: [String: Int] = [:]
            for (idx, app) in snapshotApps.enumerated() { pathToIndex[app.url.path] = idx }
            
            for path in changedPaths {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let exists = FileManager.default.fileExists(atPath: url.path)
                let valid = exists && self.isValidApp(at: url) && !self.isInsideAnotherApp(url)
                if valid {
                    let info = self.appInfo(from: url)
                    if pathToIndex[url.path] != nil {
                        changes.append(.update(info))
                    } else {
                        changes.append(.insert(info))
                    }
                } else {
                    changes.append(.remove(url.path))
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                
                // 应用删除
                if changes.contains(where: { if case .remove = $0 { return true } else { return false } }) {
                    var indicesToRemove: [Int] = []
                    var map: [String: Int] = [:]
                    for (idx, app) in self.apps.enumerated() { map[app.url.path] = idx }
                    for change in changes {
                        if case .remove(let path) = change, let idx = map[path] {
                            indicesToRemove.append(idx)
                        }
                    }
                    for idx in indicesToRemove.sorted(by: >) {
                        let removed = self.apps.remove(at: idx)
                        for fIdx in self.folders.indices { self.folders[fIdx].apps.removeAll { $0 == removed } }
                        if !self.items.isEmpty {
                            for i in 0..<self.items.count {
                                if case let .app(a) = self.items[i], a == removed { self.items[i] = .empty(UUID().uuidString) }
                            }
                        }
                    }
                    self.compactItemsWithinPages()
                    self.rebuildItems()
                }
                
                // Application updates
                let updates: [AppInfo] = changes.compactMap { if case .update(let info) = $0 { return info } else { return nil } }
                if !updates.isEmpty {
                    var map: [String: Int] = [:]
                    for (idx, app) in self.apps.enumerated() { map[app.url.path] = idx }
                    for info in updates {
                        if let idx = map[info.url.path], self.apps.indices.contains(idx) { self.apps[idx] = info }
                        for fIdx in self.folders.indices {
                            for aIdx in self.folders[fIdx].apps.indices where self.folders[fIdx].apps[aIdx].url.path == info.url.path {
                                self.folders[fIdx].apps[aIdx] = info
                            }
                        }
                        for iIdx in self.items.indices {
                            if case .app(let a) = self.items[iIdx], a.url.path == info.url.path { self.items[iIdx] = .app(info) }
                        }
                    }
                    self.rebuildItems()
                }
                
                // New applications

                let inserts: [AppInfo] = changes.compactMap { if case .insert(let info) = $0 { return info } else { return nil } }
                if !inserts.isEmpty {
                    self.apps.append(contentsOf: inserts)
                    self.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.rebuildItems()
                }

                // Refresh and persist
                self.triggerFolderUpdate()
                self.triggerGridRefresh()
                self.saveAllOrder()
                self.updateCacheAfterChanges()
            }
        }
    }

    private func canonicalAppBundlePath(for rawPath: String) -> String? {
        guard let range = rawPath.range(of: ".app") else { return nil }
        let end = rawPath.index(range.lowerBound, offsetBy: 4)
        let bundlePath = String(rawPath[..<end])
        return bundlePath
    }

    private func isInsideAnotherApp(_ url: URL) -> Bool {
        let appCount = url.pathComponents.filter { $0.hasSuffix(".app") }.count
        return appCount > 1
    }

    private func isValidApp(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) &&
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private func appInfo(from url: URL) -> AppInfo {
        let name = url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AppInfo(name: name, icon: icon, url: url)
    }
    
    // MARK: - Folder Management
    func createFolder(with apps: [AppInfo], name: String = "Untitled") -> FolderInfo {
        return createFolder(with: apps, name: name, insertAt: nil)
    }

    func createFolder(with apps: [AppInfo], name: String = "Untitled", insertAt insertIndex: Int?) -> FolderInfo {
        let folder = FolderInfo(name: name, apps: apps)
        folders.append(folder)

        // Remove apps that have been added to the folder from the app list (top-level apps)
        for app in apps {
            if let index = self.apps.firstIndex(of: app) {
                self.apps.remove(at: index)
            }
        }

        // In the current items: replace the top-level entries of these apps with empty slots, and place the folder at the target position, maintaining the total length
        var newItems = self.items
        // Find the positions of these apps
        var indices: [Int] = []
        for (idx, item) in newItems.enumerated() {
            if case let .app(a) = item, apps.contains(a) { indices.append(idx) }
            if indices.count == apps.count { break }
        }
        // Set the involved app slots to empty
        for idx in indices { newItems[idx] = .empty(UUID().uuidString) }
        // Choose the position to place the folder: prefer insertIndex, otherwise use the minimum index; clamp the range and use replacement instead of insertion
        let baseIndex = indices.min() ?? min(newItems.count - 1, max(0, insertIndex ?? (newItems.count - 1)))
        let desiredIndex = insertIndex ?? baseIndex
        let safeIndex = min(max(0, desiredIndex), max(0, newItems.count - 1))
        if newItems.isEmpty {
            newItems = [.folder(folder)]
        } else {
            newItems[safeIndex] = .folder(folder)
        }
        self.items = newItems
        // Automatically fill empty slots within the page: move empty slots to the end of the page
        compactItemsWithinPages()

        // Trigger folder update, notifying all related views to refresh icons
        DispatchQueue.main.async { [weak self] in
            self?.triggerFolderUpdate()
        }

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()
        // Update search results
        scheduleSearchUpdate()

        // Refresh cache to ensure newly created folder apps can be found during search
        refreshCacheAfterFolderOperation()

        saveAllOrder()
        return folder
    }
    
    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }
        
        
        // Create a new FolderInfo instance to ensure SwiftUI can detect changes

        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.append(app)
        folders[folderIndex] = updatedFolder

        // Remove the app from the app list
        if let appIndex = apps.firstIndex(of: app) {
            apps.remove(at: appIndex)
        }

        // Set the app slot to empty (maintaining page independence)
        if let pos = items.firstIndex(of: .app(app)) {
            items[pos] = .empty(UUID().uuidString)
            // Automatically fill empty slots within the page
            compactItemsWithinPages()
        } else {
            // If not found, fall back to rebuilding
            rebuildItems()
        }

        // Ensure the corresponding folder entry in items is also updated to the latest content for immediate visibility in search
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }

        // Trigger folder update, notifying all related views to refresh icons and names
        triggerFolderUpdate()

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()
        // Update search results
        scheduleSearchUpdate()

        // Refresh cache to ensure newly created folder apps can be found during search
        refreshCacheAfterFolderOperation()
        
        saveAllOrder()
    }
    
    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }


        // Create a new FolderInfo instance to ensure SwiftUI can detect changes
        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.removeAll { $0 == app }


        // If the folder is empty, delete the folder
        if updatedFolder.apps.isEmpty {
            folders.remove(at: folderIndex)
        } else {
            // Update the folder
            folders[folderIndex] = updatedFolder
        }

        // Synchronize the update of the folder entry in items to avoid the interface continuing to reference the old folder content
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == folder.id {
                if updatedFolder.apps.isEmpty {
                    // If the folder is empty and deleted, mark the position as empty slot, waiting for subsequent filling
                    items[idx] = .empty(UUID().uuidString)
                } else {
                    items[idx] = .folder(updatedFolder)
                }
            }
        }

        // Re-add the app to the app list
        apps.append(app)
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Try to place the app directly into the first empty slot in items to avoid temporary blank spaces
        if let emptyIndex = items.firstIndex(where: { if case .empty = $0 { return true } else { return false } }) {
            items[emptyIndex] = .app(app)
        }

        // Trigger folder update, notifying all related views to refresh icons and names
        triggerFolderUpdate()

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()
        
        // Do not call rebuildItems() as it will move apps to the end
        // Directly compact items within the page to keep apps in their original positions on the first page
        compactItemsWithinPages()

        // Refresh cache to ensure newly created folder apps can be found during search
        refreshCacheAfterFolderOperation()
        // Update search results
        scheduleSearchUpdate()
        
        saveAllOrder()
    }
    
    func renameFolder(_ folder: FolderInfo, newName: String) {
        guard let index = folders.firstIndex(of: folder) else { return }


        // Create a new FolderInfo instance to ensure SwiftUI can detect changes
        var updatedFolder = folders[index]
        updatedFolder.name = newName
        folders[index] = updatedFolder

        // Synchronize the update of the folder entry in items to avoid the interface continuing to reference the old folder content
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }


        // Trigger folder update, notifying all related views to refresh icons and names
        triggerFolderUpdate()

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()

        // Refresh cache to ensure search functionality works correctly
        refreshCacheAfterFolderOperation()
        // Update search results
        scheduleSearchUpdate()
        
        rebuildItems()
        saveAllOrder()
    }
    
    // One-click layout reset: completely rescan applications, delete all folders, ordering and empty padding
    func resetLayout() {
        // Close the open folder
        openFolder = nil

        // Clear all folders and sorting data
        folders.removeAll()

        // Clear all persisted sorting data
        clearAllPersistedData()

        // Clear cache
        cacheManager.clearAllCaches()

        // Reset scan flag to force re-scan
        hasPerformedInitialScan = false

        // Clear current item list
        items.removeAll()

        // Rescan applications without loading persisted data
        scanApplications(loadPersistedOrder: false)

        // Reset to the first page
        currentPage = 0

        // Trigger folder update, notifying all related views to refresh icons and names
        triggerFolderUpdate()

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()

        // Refresh cache after scanning is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshCacheAfterFolderOperation()
        }
    }
    
    /// Auto-compact within pages: move each page's .empty slots to end of that page, preserving relative order of non-empty items
    func compactItemsWithinPages() {
        guard !items.isEmpty else { return }
        let itemsPerPage = self.itemsPerPage // Use computed property to ensure consistency
        var result: [LaunchpadItem] = []
        result.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])
            let nonEmpty = pageSlice.filter { if case .empty = $0 { return false } else { return true } }
            let emptyCount = pageSlice.count - nonEmpty.count

            // First add non-empty items, preserving original order
            result.append(contentsOf: nonEmpty)

            // Then add empty items to the end of the page
            if emptyCount > 0 {
                var empties: [LaunchpadItem] = []
                empties.reserveCapacity(emptyCount)
                for _ in 0..<emptyCount { empties.append(.empty(UUID().uuidString)) }
                result.append(contentsOf: empties)
            }
            
            index = end
        }
        items = result
    }

    // MARK: - Cross-page dragging: cascading insertion (if page is full, push last item to next page)
    func moveItemAcrossPagesWithCascade(item: LaunchpadItem, to targetIndex: Int) {
        guard items.indices.contains(targetIndex) || targetIndex == items.count else {
            return
        }
        guard let source = items.firstIndex(of: item) else { return }
        var result = items
        // Clear source position, keeping length
        result[source] = .empty(UUID().uuidString)
        // Perform cascading insertion
        result = cascadeInsert(into: result, item: item, at: targetIndex)
        items = result

        // After each drag ends, compact items to ensure empty slots move to the end of each page
        let targetPage = targetIndex / itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        
        if targetPage == currentPages - 1 {
            // Dragged to a new page, delay compaction to ensure app positions are stable
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.compactItemsWithinPages()
                self.triggerGridRefresh()
            }
        } else {
            // Dragged to an existing page, compact immediately
            compactItemsWithinPages()
        }

        // Trigger grid view refresh to ensure the interface is updated immediately
        triggerGridRefresh()
        
        saveAllOrder()
    }

    private func cascadeInsert(into array: [LaunchpadItem], item: LaunchpadItem, at targetIndex: Int) -> [LaunchpadItem] {
        var result = array
        let p = self.itemsPerPage // Use computed property to ensure consistency

        // Ensure length is filled to a full page for easier handling
        if result.count % p != 0 {
            let remain = p - (result.count % p)
            for _ in 0..<remain { result.append(.empty(UUID().uuidString)) }
        }

        var currentPage = max(0, targetIndex / p)
        var localIndex = max(0, min(targetIndex - currentPage * p, p - 1))
        var carry: LaunchpadItem? = item

        while let moving = carry {
            let pageStart = currentPage * p
            let pageEnd = pageStart + p
            if result.count < pageEnd {
                let need = pageEnd - result.count
                for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
            }
            var slice = Array(result[pageStart..<pageEnd])

            // Ensure insertion position is within valid range
            let safeLocalIndex = max(0, min(localIndex, slice.count))
            slice.insert(moving, at: safeLocalIndex)
            
            var spilled: LaunchpadItem? = nil
            if slice.count > p {
                spilled = slice.removeLast()
            }
            result.replaceSubrange(pageStart..<pageEnd, with: slice)
            if let s = spilled, case .empty = s {
                // Overflow is empty: end
                carry = nil
            } else if let s = spilled {
                // Overflow is non-empty: push to next page start
                carry = s
                currentPage += 1
                localIndex = 0
                // If it exceeds the length at the end, fill the next page
                let nextEnd = (currentPage + 1) * p
                if result.count < nextEnd {
                    let need = nextEnd - result.count
                    for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
                }
            } else {
                carry = nil
            }
        }
        return result
    }
    
    func rebuildItems() {
        // Add debouncing and optimization checks
        let currentItemsCount = items.count
        let appsInFolders: Set<AppInfo> = Set(folders.flatMap { $0.apps })
        let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        var newItems: [LaunchpadItem] = []
        newItems.reserveCapacity(currentItemsCount + 10) // Pre-allocate capacity
        var seenAppPaths = Set<String>()
        var seenFolderIds = Set<String>()
        seenAppPaths.reserveCapacity(apps.count)
        seenFolderIds.reserveCapacity(folders.count)

        for item in items {
            switch item {
            case .folder(let folder):
                if let updated = folderById[folder.id] {
                    newItems.append(.folder(updated))
                    seenFolderIds.insert(updated.id)
                }
                // If the folder has been deleted, skip it (no longer retained)
            case .app(let app):
                // If the app has entered a folder, remove it from the top level; otherwise, keep its original position
                if !appsInFolders.contains(app) {
                    newItems.append(.app(app))
                    seenAppPaths.insert(app.url.path)
                }
            case .empty(let token):
                // Keep empty as a placeholder to maintain page independence
                newItems.append(.empty(token))
            }
        }

        // Append missing free apps (not appearing at the top level, but not in any folder)
        let missingFreeApps = apps.filter { !appsInFolders.contains($0) && !seenAppPaths.contains($0.url.path) }
        newItems.append(contentsOf: missingFreeApps.map { .app($0) })

        // Note: Do not automatically append missing folders to the end,
        // to avoid pushing folders to the last page during incremental updates after loading persistent order.

        // Only update items when there are actual changes
        if newItems.count != items.count || !newItems.elementsEqual(items, by: { $0.id == $1.id }) {
            items = newItems
        }
    }
    
    // MARK: - Fast Search Implementation
    private func normalizedLower(_ s: String) -> String {
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
    
    private func lowerName(for app: AppInfo) -> String {
        if let cached = lowerCacheApps[app.id] { return cached }
        let v = normalizedLower(app.name)
        lowerCacheApps[app.id] = v
        return v
    }
    
    private func lowerName(for folder: FolderInfo) -> String {
        if let cached = lowerCacheFolders[folder.id] { return cached }
        let v = normalizedLower(folder.name)
        lowerCacheFolders[folder.id] = v
        return v
    }
    
    func scheduleSearchUpdate() {
        // Cancel previous scheduled work
        searchUpdateWorkItem?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = items // Snapshot to ensure consistency
        
        // Fast path: empty query -> use items directly
        if query.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.searchResults = snapshot
            }
            return
        }
        
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let q = self.normalizedLower(query)
            var results: [LaunchpadItem] = []
            results.reserveCapacity(min(64, snapshot.count))
            var seenPaths = Set<String>()
            seenPaths.reserveCapacity(256)
            
            for item in snapshot {
                switch item {
                case .app(let app):
                    if self.lowerName(for: app).contains(q) {
                        results.append(.app(app))
                        seenPaths.insert(app.url.path)
                    }
                case .folder(let folder):
                    // Match folder name
                    if self.lowerName(for: folder).contains(q) {
                        results.append(.folder(folder))
                    }
                    // Search apps within folder
                    for app in folder.apps {
                        if seenPaths.contains(app.url.path) { continue }
                        if self.lowerName(for: app).contains(q) {
                            results.append(.app(app))
                            seenPaths.insert(app.url.path)
                        }
                    }
                case .empty:
                    continue
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.searchResults = results
            }
        }
        searchUpdateWorkItem = work
        searchQueue.asyncAfter(deadline: .now() + 0.0, execute: work)
    }
    
    // MARK: - Persistence: per-page independent ordering (new) + legacy compatibility
    func loadAllOrder() {
        guard let modelContext else {
            print("QuarkLauncher: ModelContext is nil, cannot load persisted order")
            return
        }
        
        print("QuarkLauncher: Attempting to load persisted order data...")

        // Prioritize reading from the new "page-slot" model
        if loadOrderFromPageEntries(using: modelContext) {
            print("QuarkLauncher: Successfully loaded order from PageEntryData")
            return
        }
        
        print("QuarkLauncher: PageEntryData not found, trying legacy TopItemData...")
        // Fallback: Legacy global order model
        loadOrderFromLegacyTopItems(using: modelContext)
        print("QuarkLauncher: Finished loading order from legacy data")
    }

    private func loadOrderFromPageEntries(using modelContext: ModelContext) -> Bool {
        do {
            let descriptor = FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            )
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return false }

            // Build folders: in the order of first appearance
            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []

            // First collect all folder appPaths to avoid duplicate construction
            for row in saved where row.kind == "folder" {
                guard let fid = row.folderId else { continue }
                if folderMap[fid] != nil { continue }

                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = apps.first(where: { $0.url.path == path }) {
                        return existing
                    }
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return self.appInfo(from: url)
                }
                let folder = FolderInfo(id: fid, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                folderMap[fid] = folder
                foldersInOrder.append(folder)
            }

            let folderAppPathSet: Set<String> = Set(foldersInOrder.flatMap { $0.apps.map { $0.url.path } })

            // Combine top-level items (in order of pages and positions; retain empty slots to maintain independent slots per page)
            var combined: [LaunchpadItem] = []
            combined.reserveCapacity(saved.count)
            for row in saved {
                switch row.kind {
                case "folder":
                    if let fid = row.folderId, let folder = folderMap[fid] {
                        combined.append(.folder(folder))
                    }
                case "app":
                    if let path = row.appPath, !folderAppPathSet.contains(path) {
                        if let existing = apps.first(where: { $0.url.path == path }) {
                            combined.append(.app(existing))
                        } else {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                combined.append(.app(self.appInfo(from: url)))
                            }
                        }
                    }
                case "empty":
                    combined.append(.empty(row.slotId))
                default:
                    break
                }
            }

            DispatchQueue.main.async {
                self.folders = foldersInOrder
                if !combined.isEmpty {
                    self.items = combined
                    // If the app list is empty, restore the app list from persistent data
                    if self.apps.isEmpty {
                        let freeApps: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        self.apps = freeApps
                    }
                }
                self.hasAppliedOrderFromStore = true
            }
            return true
        } catch {
            return false
        }
    }

    private func loadOrderFromLegacyTopItems(using modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<TopItemData>(sortBy: [SortDescriptor(\.orderIndex, order: .forward)])
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return }

            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []
            let folderAppPathSet: Set<String> = Set(saved.filter { $0.kind == "folder" }.flatMap { $0.appPaths })
            for row in saved where row.kind == "folder" {
                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = apps.first(where: { $0.url.path == path }) { return existing }
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return self.appInfo(from: url)
                }
                let folder = FolderInfo(id: row.id, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                folderMap[row.id] = folder
                foldersInOrder.append(folder)
            }

            var combined: [LaunchpadItem] = saved.sorted { $0.orderIndex < $1.orderIndex }.compactMap { row in
                if row.kind == "folder" { return folderMap[row.id].map { .folder($0) } }
                if row.kind == "empty" { return .empty(row.id) }
                if row.kind == "app", let path = row.appPath {
                    if folderAppPathSet.contains(path) { return nil }
                    if let existing = apps.first(where: { $0.url.path == path }) { return .app(existing) }
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return .app(self.appInfo(from: url))
                }
                return nil
            }

            let appsInFolders = Set(foldersInOrder.flatMap { $0.apps })
            let appsInCombined: Set<AppInfo> = Set(combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } })
            let missingFreeApps = apps
                .filter { !appsInFolders.contains($0) && !appsInCombined.contains($0) }
                .map { LaunchpadItem.app($0) }
            combined.append(contentsOf: missingFreeApps)

            DispatchQueue.main.async {
                self.folders = foldersInOrder
                if !combined.isEmpty {
                    self.items = combined
                    // If the app list is empty, restore the app list from persistent data
                    if self.apps.isEmpty {
                        let freeAppsAfterLoad: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        self.apps = freeAppsAfterLoad
                    }
                }
                self.hasAppliedOrderFromStore = true
            }
        } catch {
            // ignore
        }
    }

    func saveAllOrder() {
        guard let modelContext else {
            print("QuarkLauncher: ModelContext is nil, cannot save order")
            return
        }
        guard !items.isEmpty else {
            print("QuarkLauncher: Items list is empty, skipping save")
            return
        }

        print("QuarkLauncher: Saving order data for \(items.count) items...")
        
        // Write to the new model: by page-slot
        do {
            let existing = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            print("QuarkLauncher: Found \(existing.count) existing entries, clearing...")
            for row in existing { modelContext.delete(row) }

            // Build folder lookup table
            let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            let itemsPerPage = self.itemsPerPage // Use computed property

            for (idx, item) in items.enumerated() {
                let pageIndex = idx / itemsPerPage
                let position = idx % itemsPerPage
                let slotId = "page-\(pageIndex)-pos-\(position)"
                switch item {
                case .folder(let folder):
                    let authoritativeFolder = folderById[folder.id] ?? folder
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "folder",
                        folderId: authoritativeFolder.id,
                        folderName: authoritativeFolder.name,
                        appPaths: authoritativeFolder.apps.map { $0.url.path }
                    )
                    modelContext.insert(row)
                case .app(let app):
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "app",
                        appPath: app.url.path
                    )
                    modelContext.insert(row)
                case .empty:
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "empty"
                    )
                    modelContext.insert(row)
                }
            }
            try modelContext.save()
            print("QuarkLauncher: Successfully saved order data")

            // Clean up legacy table to avoid occupying space (ignore errors)
            do {
                let legacy = try modelContext.fetch(FetchDescriptor<TopItemData>())
                for row in legacy { modelContext.delete(row) }
                try? modelContext.save()
            } catch { }
        } catch {
            print("QuarkLauncher: Error saving order data: \(error)")
        }
    }

    // Trigger folder update, notify all related views to refresh icons
    private func triggerFolderUpdate() {
        folderUpdateTrigger = UUID()
    }
    
    // Trigger grid view refresh, used for interface updates after drag operations
    func triggerGridRefresh() {
        // Only trigger if not already refreshing
        if !isGridRefreshing {
            isGridRefreshing = true
            gridRefreshTrigger = UUID()
            
            // Battery-optimized: reset flag after delay to allow for batching
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.isGridRefreshing = false
            }
        }
    }
    
    @Published private var isGridRefreshing = false
    
    // Optimized fullscreen mode transition with immediate visual feedback
    private func performFullscreenModeTransition() {
        let now = Date()
        
        // Debounce rapid toggles (prevent performance issues from rapid key presses)
        guard now.timeIntervalSince(lastFullscreenToggle) > 0.05 else { return }
        lastFullscreenToggle = now
        
        // Cancel any existing timer
        fullscreenTransitionTimer?.invalidate()
        
        // Immediate response for better UX - no additional delays
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Only trigger window animation - remove unnecessary cache optimization
            // and grid refresh which were causing performance issues
            if let appDelegate = AppDelegate.shared {
                appDelegate.updateWindowMode(isFullscreen: self.isFullscreenMode)
            }
        }
    }
    
    // Clear all persisted sorting and folder data
    private func clearAllPersistedData() {
        guard let modelContext else { return }
        
        do {
            // Clear new page-slot data
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            for entry in pageEntries {
                modelContext.delete(entry)
            }

            // Clear legacy global order data
            let legacyEntries = try modelContext.fetch(FetchDescriptor<TopItemData>())
            for entry in legacyEntries {
                modelContext.delete(entry)
            }
            
            // Save changes

            try modelContext.save()
        } catch {
            // Ignore errors to ensure reset process continues
        }
    }

    // MARK: - Auto-create new page during drag
    private var pendingNewPage: (pageIndex: Int, itemCount: Int)? = nil
    
    func createNewPageForDrag() -> Bool {
        let itemsPerPage = self.itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        let newPageIndex = currentPages

        // Add empty placeholders for the new page
        for _ in 0..<itemsPerPage {
            items.append(.empty(UUID().uuidString))
        }

        // Record the pending new page information
        pendingNewPage = (pageIndex: newPageIndex, itemCount: itemsPerPage)

        // Trigger grid view refresh
        triggerGridRefresh()
        
        return true
    }
    
    func cleanupUnusedNewPage() {
        guard let pending = pendingNewPage else { return }

        // Check if the new page is in use (i.e., has non-empty items)
        let pageStart = pending.pageIndex * pending.itemCount
        let pageEnd = min(pageStart + pending.itemCount, items.count)
        
        if pageStart < items.count {
            let pageSlice = Array(items[pageStart..<pageEnd])
            let hasNonEmptyItems = pageSlice.contains { item in
                if case .empty = item { return false } else { return true }
            }
            
            if !hasNonEmptyItems {
                // The new page is not in use, delete it
                items.removeSubrange(pageStart..<pageEnd)

                // Trigger grid view refresh
                triggerGridRefresh()
            }
        }

        // Clear pending information
        pendingNewPage = nil
    }

    // MARK: - Auto-delete empty pages
    /// Auto-delete empty pages: remove pages that are entirely filled with empty placeholders
    func removeEmptyPages() {
        guard !items.isEmpty else { return }
        let itemsPerPage = self.itemsPerPage
        
        var newItems: [LaunchpadItem] = []
        var index = 0
        
        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])

            // Check if the current page is entirely filled with empty placeholders
            let isEmptyPage = pageSlice.allSatisfy { item in
                if case .empty = item { return true } else { return false }
            }

            // If not an empty page, keep the content
            if !isEmptyPage {
                newItems.append(contentsOf: pageSlice)
            }
            // If it is an empty page, skip adding it

            index = end
        }

        // Only update items if empty pages were actually removed
        if newItems.count != items.count {
            items = newItems

            // After removing empty pages, ensure current page index is within valid range
            let maxPageIndex = max(0, (items.count - 1) / itemsPerPage)
            if currentPage > maxPageIndex {
                currentPage = maxPageIndex
            }

            // Trigger grid view refresh
            triggerGridRefresh()
        }
    }
    
    // MARK: - Export app sorting functionality
    /// Export app sorting as JSON format
    func exportAppOrderAsJSON() -> String? {
        let exportData = buildExportData()
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    /// Build export data
    private func buildExportData() -> [String: Any] {
        var pages: [[String: Any]] = []
        let itemsPerPage = self.itemsPerPage
        
        for (index, item) in items.enumerated() {
            let pageIndex = index / itemsPerPage
            let position = index % itemsPerPage
            
            var itemData: [String: Any] = [
                "pageIndex": pageIndex,
                "position": position,
                "kind": itemKind(for: item),
                "name": item.name,
                "path": itemPath(for: item),
                "folderApps": []
            ]
            
            // 如果是文件夹，添加文件夹内的应用信息
            if case let .folder(folder) = item {
                itemData["folderApps"] = folder.apps.map { $0.name }
                itemData["folderAppPaths"] = folder.apps.map { $0.url.path }
            }
            
            pages.append(itemData)
        }
        
        return [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "totalPages": (items.count + itemsPerPage - 1) / itemsPerPage,
            "totalItems": items.count,
            "fullscreenMode": isFullscreenMode,
            "pages": pages
        ]
    }
    
    /// Get item type description
    private func itemKind(for item: LaunchpadItem) -> String {
        switch item {
        case .app:
            return "Application"
        case .folder:
            return "文件夹"
        case .empty:
            return "空槽位"
        }
    }
    
    /// Get item path
    private func itemPath(for item: LaunchpadItem) -> String {
        switch item {
        case let .app(app):
            return app.url.path
        case let .folder(folder):
            return "文件夹: \(folder.name)"
        case .empty:
            return "空槽位"
        }
    }
    
    /// Use system file save dialog to save export file
    func saveExportFileWithDialog(content: String, filename: String, fileExtension: String, fileType: String) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.title = "保存导出文件"
        savePanel.nameFieldStringValue = filename
        savePanel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        // Set the default save location to the desktop
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = desktopURL
        }
        
        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        return false
    }
    
    // MARK: - Cache Management
    
    /// Generate cache after scanning
    private func generateCacheAfterScan() {

        // Check if the cache is valid
        if !cacheManager.isCacheValid {
            // Generate a new cache
            cacheManager.generateCache(from: apps, items: items)
        } else {
            // Cache is valid, but icons can be preloaded
            let appPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: appPaths)
        }
    }
    
    /// Manual refresh (simulate complete startup flow)
    func refresh() {
        print("QuarkLauncher: Manual refresh triggered")

        // Clear cache to ensure icons and search index are regenerated
        cacheManager.clearAllCaches()

        // Reset interface and state to resemble "first launch"
        openFolder = nil
        currentPage = 0
        if !searchText.isEmpty { searchText = "" }

        // Reset scan flag to force re-scan
        hasPerformedInitialScan = false

        // Execute the same scan paths as the first launch (keep existing order, new ones at the end)
        scanApplicationsWithOrderPreservation()

        // Battery-optimized: generate cache after scanning is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.generateCacheAfterScan()
        }

        // Force interface refresh
        triggerFolderUpdate()
        triggerGridRefresh()
    }
    
    /// Clear cache
    func clearCache() {
        cacheManager.clearAllCaches()
    }
    
    /// Get cache statistics
    var cacheStatistics: CacheStatistics {
        return cacheManager.cacheStatistics
    }
    
    /// Update cache after incremental changes
    private func updateCacheAfterChanges() {
        // Check if the cache needs to be updated
        if !cacheManager.isCacheValid {
            // Cache is invalid, regenerate
            cacheManager.generateCache(from: apps, items: items)
        } else {
            // Cache is valid, only update changed parts
            let changedAppPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: changedAppPaths)
        }
    }
    
    /// Refresh cache after folder operations, ensure search functionality works properly
    private func refreshCacheAfterFolderOperation() {
        // Directly refresh cache to ensure all applications are included (including those within folders)
        cacheManager.refreshCache(from: apps, items: items)

        // Battery-optimized: clear search text to ensure search state is reset
        if !searchText.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.searchText = ""
            }
        }
    }
    
    // MARK: - Import app sorting functionality
    /// Import app sorting from JSON data
    func importAppOrderFromJSON(_ jsonData: Data) -> Bool {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return processImportedData(importData)
        } catch {
            return false
        }
    }
    
    /// Process imported data and rebuild app layout
    private func processImportedData(_ importData: Any) -> Bool {
        guard let data = importData as? [String: Any],
              let pagesData = data["pages"] as? [[String: Any]] else {
            return false
        }

        // Build a mapping from app paths to app objects
        let appPathMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.path, $0) })

        // Rebuild items array
        var newItems: [LaunchpadItem] = []
        var importedFolders: [FolderInfo] = []

        // Process each page's data
        for pageData in pagesData {
            guard let kind = pageData["kind"] as? String,
                  let name = pageData["name"] as? String else { continue }
            
            switch kind {
            case "App":
                if let path = pageData["path"] as? String,
                   let app = appPathMap[path] {
                    newItems.append(.app(app))
                } else {
                    // App missing, add empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "Folder":
                if let folderApps = pageData["folderApps"] as? [String],
                   let folderAppPaths = pageData["folderAppPaths"] as? [String] {
                    // Rebuild folder - prioritize matching by app paths to ensure accuracy
                    let folderAppsList = folderAppPaths.compactMap { appPath in
                        // Match by application path, which is the most accurate method
                        if let app = apps.first(where: { $0.url.path == appPath }) {
                            return app
                        }
                        // If path matching fails, attempt to match by name (fallback solution)
                        if let appName = folderApps.first(where: { _ in true }), // Retrieve the corresponding app name
                           let app = apps.first(where: { $0.name == appName }) {
                            return app
                        }
                        return nil
                    }
                    
                    if !folderAppsList.isEmpty {
                        // Attempt to find a matching folder from existing ones, keeping the ID consistent
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // Use existing folder to keep ID consistent
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // Create new folder
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // Folder is empty, add empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else if let folderApps = pageData["folderApps"] as? [String] {
                    // Compatibility with old versions: only app names, no path information
                    let folderAppsList = folderApps.compactMap { appName in
                        apps.first { $0.name == appName }
                    }
                    
                    if !folderAppsList.isEmpty {
                        // Attempt to find a matching folder from existing ones, keeping the ID consistent
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // Use existing folder to keep ID consistent
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // Create new folder
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // Folder is empty, add empty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // Folder data is invalid, add empty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "Empty Slot":
                newItems.append(.empty(UUID().uuidString))
                
            default:
                // Unknown type, add empty slot
                newItems.append(.empty(UUID().uuidString))
            }
        }

        // Handle any extra apps (move to the last page)
        let usedApps = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app }
            return nil
        })
        
        let usedAppsInFolders = Set(importedFolders.flatMap { $0.apps })
        let allUsedApps = usedApps.union(usedAppsInFolders)
        
        let unusedApps = apps.filter { !allUsedApps.contains($0) }
        
        if !unusedApps.isEmpty {
            // Calculate the number of empty slots needed
            let itemsPerPage = self.itemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages * itemsPerPage
            let lastPageEnd = lastPageStart + itemsPerPage

            // Ensure the last page has enough space
            while newItems.count < lastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }

            // Add unused apps to the last page
            for (index, app) in unusedApps.enumerated() {
                let insertIndex = lastPageStart + index
                if insertIndex < newItems.count {
                    newItems[insertIndex] = .app(app)
                } else {
                    newItems.append(.app(app))
                }
            }
            
            // Ensure the last page is also complete
            let finalPageCount = newItems.count
            let finalPages = (finalPageCount + itemsPerPage - 1) / itemsPerPage
            let finalLastPageStart = (finalPages - 1) * itemsPerPage
            let finalLastPageEnd = finalLastPageStart + itemsPerPage

            // If the last page is not complete, add empty slots
            while newItems.count < finalLastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
        }

        // Validate the imported data structure

        // Update app status
        DispatchQueue.main.async {

            // Set new data
            self.folders = importedFolders
            self.items = newItems


            // Force trigger UI update
            self.triggerFolderUpdate()
            self.triggerGridRefresh()

            // Save new layout
            self.saveAllOrder()


            // Temporarily do not call page completion, keep the original import order
            // If we need to complete, we can trigger it after the user manually operates
        }
        
        return true
    }
    
    /// - Returns: (isValid: Bool, message: String)
    /// Validate import data structure and content
    func validateImportData(_ jsonData: Data) -> (isValid: Bool, message: String) {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let data = importData as? [String: Any] else {
                return (false, "Invalid data format")
            }
            
            guard let pagesData = data["pages"] as? [[String: Any]] else {
                return (false, "Missing page data")
            }
            
            let totalPages = data["totalPages"] as? Int ?? 0
            let totalItems = data["totalItems"] as? Int ?? 0
            
            if pagesData.isEmpty {
                return (false, "No app data found")
            }

            return (true, "Data validation passed, \(totalPages) pages, \(totalItems) items")
        } catch {
            return (false, "JSON parsing failed: \(error.localizedDescription)")
        }
    }
}
