import Foundation
import AppKit

struct AppInfo: Identifiable, Equatable, Hashable {
    let name: String
    let icon: NSImage
    let url: URL

    // 使用应用路径作为稳定唯一标识
    var id: String { url.path }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    // MARK: - 创建 AppInfo
    static func from(url: URL) -> AppInfo {
        let name = localizedAppName(for: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AppInfo(name: name, icon: icon, url: url)
    }

    // MARK: - 获取本地化应用名
    private static func localizedAppName(for url: URL) -> String {
        guard let bundle = Bundle(url: url) else {
            return url.deletingPathExtension().lastPathComponent
        }
        
        // 优先取本地化显示名
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return displayName
        }
        
        // 再取默认 bundle 名
        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return bundleName
        }
        
        // 最后回退到文件名
        return url.deletingPathExtension().lastPathComponent
    }
}
