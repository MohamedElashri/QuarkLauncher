import Foundation
import AppKit

struct AppInfo: Identifiable, Equatable, Hashable {
    let name: String
    let icon: NSImage
    let url: URL

    // Use app path as stable unique identifier
    var id: String { url.path }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    // MARK: - Create AppInfo
    static func from(url: URL) -> AppInfo {
        let name = localizedAppName(for: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AppInfo(name: name, icon: icon, url: url)
    }

    // MARK: - Get localized app name
    private static func localizedAppName(for url: URL) -> String {
        guard let bundle = Bundle(url: url) else {
            return url.deletingPathExtension().lastPathComponent
        }
        
        // Prioritize localized display name
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return displayName
        }
        
        // Then get default bundle name
        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return bundleName
        }
        
        // Finally fallback to filename
        return url.deletingPathExtension().lastPathComponent
    }
}
