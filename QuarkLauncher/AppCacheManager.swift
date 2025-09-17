import Foundation
import AppKit
import Combine

/// Application cache manager - responsible for caching app icons, app info, and grid layout data to improve performance
final class AppCacheManager: ObservableObject {
    static let shared = AppCacheManager()
    
    // MARK: - Cache Storage
    private var iconCache: [String: NSImage] = [:]
    private var appInfoCache: [String: AppInfo] = [:]
    private var gridLayoutCache: [String: Any] = [:]
    private let cacheLock = NSLock()
    
    // MARK: - Cache Configuration
    private let maxIconCacheSize = 200
    private let maxAppInfoCacheSize = 300
    private var iconCacheOrder: [String] = [] // Changed to mutable array for proper LRU implementation
    
    // MARK: - Cache State
    @Published var isCacheValid = false
    @Published var lastCacheUpdate = Date.distantPast
    @Published var cacheSize: Int = 0
    // MARK: - Cache Key Generation
    private let cacheKeyGenerator = CacheKeyGenerator()
    
    private init() {}
    // MARK: - Public Interface
    
    /// Generate application cache - called after app startup or scanning
    func generateCache(from apps: [AppInfo], items: [LaunchpadItem]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Clear old cache
            self.clearAllCaches()
            
            // Collect all applications that need to be cached, including apps in folders
            var allApps: [AppInfo] = []
            allApps.append(contentsOf: apps)
            
            // Extract apps from folders in items
            for item in items {
                if case let .folder(folder) = item {
                    allApps.append(contentsOf: folder.apps)
                }
            }
            
            // Deduplicate to avoid caching the same app multiple times
            var uniqueApps: [AppInfo] = []
            var seenPaths = Set<String>()
            for app in allApps {
                if !seenPaths.contains(app.url.path) {
                    seenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // Cache app information
            self.cacheAppInfos(uniqueApps)
            
            // Cache app icons
            self.cacheAppIcons(uniqueApps)
            
            // Cache grid layout data
            self.cacheGridLayout(items)
            
            DispatchQueue.main.async {
                self.isCacheValid = true
                self.lastCacheUpdate = Date()
                self.calculateCacheSize()
        
            }
        }
    }
    
    /// Get cached app icon
    func getCachedIcon(for appPath: String) -> NSImage? {
        let key = cacheKeyGenerator.generateIconKey(for: appPath)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let icon = iconCache[key] {
            if let index = iconCacheOrder.firstIndex(of: key) {
                iconCacheOrder.remove(at: index)
                iconCacheOrder.append(key)
            }
            return icon
        } else {
            return nil
        }
    }
    
    /// Get cached app information
    func getCachedAppInfo(for appPath: String) -> AppInfo? {
        let key = cacheKeyGenerator.generateAppInfoKey(for: appPath)
        return appInfoCache[key]
    }
    
    /// Get cached grid layout data
    func getCachedGridLayout(for layoutKey: String) -> Any? {
        let key = cacheKeyGenerator.generateGridLayoutKey(for: layoutKey)
        return gridLayoutCache[key]
    }
    
    /// Preload app icons to cache
    func preloadIcons(for appPaths: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            for path in appPaths {
                if self.getCachedIcon(for: path) == nil {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let key = self.cacheKeyGenerator.generateIconKey(for: path)
                    self.cacheLock.lock()
                    self.iconCache[key] = icon
                    self.iconCacheOrder.append(key)
                    if self.iconCache.count > self.maxIconCacheSize {
                        if let oldestKey = self.iconCacheOrder.first {
                            self.iconCache.removeValue(forKey: oldestKey)
                            self.iconCacheOrder.removeFirst()
                        }
                    }
                    self.cacheLock.unlock()
                }
            }
            
            DispatchQueue.main.async {
                self.calculateCacheSize()
            }
        }
    }
    
    /// Smart preloading: preload icons for current page and adjacent pages
    func smartPreloadIcons(for items: [LaunchpadItem], currentPage: Int, itemsPerPage: Int) {
        let startIndex = max(0, (currentPage - 1) * itemsPerPage)
        let endIndex = min(items.count, (currentPage + 2) * itemsPerPage)
        
        let relevantItems = Array(items[startIndex..<endIndex])
        let appPaths = relevantItems.compactMap { item -> String? in
            if case let .app(app) = item {
                return app.url.path
            }
            return nil
        }
        
        preloadIcons(for: appPaths)
    }
    
    /// Clear all caches
    func clearAllCaches() {
        cacheLock.lock()
        iconCache.removeAll()
        appInfoCache.removeAll()
        gridLayoutCache.removeAll()
        iconCacheOrder.removeAll()
        cacheLock.unlock()
        
        DispatchQueue.main.async {
            self.isCacheValid = false
            self.cacheSize = 0
        }
    }
    
    /// Clear expired cache
    func clearExpiredCache() {
        let now = Date()
        let cacheAgeThreshold: TimeInterval = 24 * 60 * 60 // 24 hours
        
        if now.timeIntervalSince(lastCacheUpdate) > cacheAgeThreshold {
            clearAllCaches()
        }
    }
    
    /// Manually refresh cache
    func refreshCache(from apps: [AppInfo], items: [LaunchpadItem]) {
        // Collect all applications that need to be cached, including apps in folders
        var allApps: [AppInfo] = []
        allApps.append(contentsOf: apps)
        
        // Extract apps from folders in items
        for item in items {
            if case let .folder(folder) = item {
                allApps.append(contentsOf: folder.apps)
            }
        }
        
        // Deduplicate to avoid caching the same app multiple times
        var uniqueApps: [AppInfo] = []
        var seenPaths = Set<String>()
        for app in allApps {
            if !seenPaths.contains(app.url.path) {
                seenPaths.insert(app.url.path)
                uniqueApps.append(app)
            }
        }
        
        generateCache(from: uniqueApps, items: items)
    }
    
    // MARK: - Private Methods
    
    private func cacheAppInfos(_ apps: [AppInfo]) {
        cacheLock.lock()
        for app in apps {
            let key = cacheKeyGenerator.generateAppInfoKey(for: app.url.path)
            appInfoCache[key] = app
        }
        cacheLock.unlock()
    }
    
    private func cacheAppIcons(_ apps: [AppInfo]) {
        cacheLock.lock()
        for app in apps {
            let key = cacheKeyGenerator.generateIconKey(for: app.url.path)
            if let existingIndex = iconCacheOrder.firstIndex(of: key) {
                iconCacheOrder.remove(at: existingIndex)
            }
            iconCache[key] = app.icon
            iconCacheOrder.append(key)
            if iconCache.count > maxIconCacheSize {
                if let oldestKey = iconCacheOrder.first {
                    iconCache.removeValue(forKey: oldestKey)
                    iconCacheOrder.removeFirst()
                }
            }
        }
        cacheLock.unlock()
    }
    
    private func cacheGridLayout(_ items: [LaunchpadItem]) {
        // Cache grid layout related calculation data
        let layoutData = GridLayoutCacheData(
            totalItems: items.count,
            itemsPerPage: 35,
            columns: 7,
            rows: 5,
            pageCount: (items.count + 34) / 35
        )
        let pageInfo = calculatePageInfo(for: items)
        let key = cacheKeyGenerator.generateGridLayoutKey(for: "main")
        let pageKey = cacheKeyGenerator.generateGridLayoutKey(for: "pages")
        cacheLock.lock()
        gridLayoutCache[key] = layoutData
        gridLayoutCache[pageKey] = pageInfo
        cacheLock.unlock()
        
    }
    
    /// Calculate page information
    private func calculatePageInfo(for items: [LaunchpadItem]) -> [PageInfo] {
        let itemsPerPage = 35
        let pageCount = (items.count + itemsPerPage - 1) / itemsPerPage
        
        var pages: [PageInfo] = []
        
        for pageIndex in 0..<pageCount {
            let startIndex = pageIndex * itemsPerPage
            let endIndex = min(startIndex + itemsPerPage, items.count)
            let pageItems = Array(items[startIndex..<endIndex])
            
            let appCount = pageItems.filter { if case .app = $0 { return true } else { return false } }.count
            let folderCount = pageItems.filter { if case .folder = $0 { return true } else { return false } }.count
            let emptyCount = pageItems.filter { if case .empty = $0 { return true } else { return false } }.count
            
            let pageInfo = PageInfo(
                pageIndex: pageIndex,
                startIndex: startIndex,
                endIndex: endIndex,
                appCount: appCount,
                folderCount: folderCount,
                emptyCount: emptyCount
            )
            
            pages.append(pageInfo)
        }
        
        return pages
    }
    
    private func calculateCacheSize() {
        cacheLock.lock()
        let iconSize = iconCache.count
        let appInfoSize = appInfoCache.count
        let gridLayoutSize = gridLayoutCache.count
        cacheLock.unlock()
        cacheSize = iconSize + appInfoSize + gridLayoutSize
    }
    
    /// Optimize cache for fullscreen mode transitions
    func optimizeForFullscreenTransition(items: [LaunchpadItem]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Preload critical icons for visible items
            let criticalItems = Array(items.prefix(35)) // First page items
            let apps = criticalItems.compactMap { item -> AppInfo? in
                if case .app(let app) = item {
                    return app
                }
                return nil
            }
            
            // Cache critical icons with higher priority
            self.cacheLock.lock()
            for app in apps {
                let key = self.cacheKeyGenerator.generateIconKey(for: app.url.path)
                if self.iconCache[key] == nil {
                    self.iconCache[key] = app.icon
                    self.iconCacheOrder.append(key)
                }
            }
            self.cacheLock.unlock()
        }
    }

    
    /// Get performance statistics
    var performanceStats: PerformanceStats {
        return PerformanceStats(cacheSize: cacheSize)
    }
}

// MARK: - Cache Key Generator

private struct CacheKeyGenerator {
    func generateIconKey(for appPath: String) -> String {
        return "icon_\(appPath.hashValue)"
    }
    
    func generateAppInfoKey(for appPath: String) -> String {
        return "appinfo_\(appPath.hashValue)"
    }
    
    func generateGridLayoutKey(for layoutKey: String) -> String {
        return "grid_\(layoutKey.hashValue)"
    }
}

// MARK: - Grid Layout Cache Data Structures

private struct GridLayoutCacheData {
    let totalItems: Int
    let itemsPerPage: Int
    let columns: Int
    let rows: Int
    let pageCount: Int
}

private struct PageInfo {
    let pageIndex: Int
    let startIndex: Int
    let endIndex: Int
    let appCount: Int
    let folderCount: Int
    let emptyCount: Int
}

// MARK: - Cache Statistics

extension AppCacheManager {
    var cacheStatistics: CacheStatistics {
        return CacheStatistics(
            iconCacheSize: iconCache.count,
            appInfoCacheSize: appInfoCache.count,
            gridLayoutCacheSize: gridLayoutCache.count,
            totalCacheSize: cacheSize,
            isCacheValid: isCacheValid,
            lastUpdate: lastCacheUpdate
        )
    }
}

struct CacheStatistics {
    let iconCacheSize: Int
    let appInfoCacheSize: Int
    let gridLayoutCacheSize: Int
    let totalCacheSize: Int
    let isCacheValid: Bool
    let lastUpdate: Date
}

struct PerformanceStats {
    let cacheSize: Int
}
