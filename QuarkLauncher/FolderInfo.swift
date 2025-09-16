import Foundation
import AppKit
import SwiftData

struct FolderInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var apps: [AppInfo]
    let createdAt: Date
    
    init(id: String = UUID().uuidString, name: String = "Untitled", apps: [AppInfo] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.apps = apps
        self.createdAt = createdAt
    }
    
    var folderIcon: NSImage {
        // Generate icon each time to reflect latest app state
        let icon = icon(of: 72)
        return icon
    }

    func icon(of side: CGFloat) -> NSImage {
        let normalizedSide = max(16, side)
        let icon = renderFolderIcon(side: normalizedSide)
        return icon
    }

    private func renderFolderIcon(side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high
            ctx.shouldAntialias = true
        }

        let rect = NSRect(origin: .zero, size: size)

        let outerInset = round(side * 0.12)
        let contentRect = rect.insetBy(dx: outerInset, dy: outerInset)
        let innerInset = round(contentRect.width * 0.08)
        let innerRect = contentRect.insetBy(dx: innerInset, dy: innerInset)

        let spacing = max(2, round(innerRect.width * 0.04))
        let tile = floor((innerRect.width - spacing) / 2)
        let startX = innerRect.minX
        let topY = innerRect.maxY

        for (index, app) in apps.prefix(4).enumerated() {
            let rowTopFirst = index / 2
            let col = index % 2
            let x = startX + CGFloat(col) * (tile + spacing)
            let y = topY - CGFloat(rowTopFirst + 1) * tile - CGFloat(rowTopFirst) * spacing
            let iconRect = NSRect(x: x, y: y, width: tile, height: tile)
            
            // Fallback: if app icon is 0x0, fall back to system icon
            let iconToDraw: NSImage = {
                if app.icon.size.width > 0 && app.icon.size.height > 0 {
                    return app.icon
                } else {
                    return NSWorkspace.shared.icon(forFile: app.url.path)
                }
            }()
            iconToDraw.draw(in: iconRect)
        }

        return image
    }
    
    static func == (lhs: FolderInfo, rhs: FolderInfo) -> Bool {
        lhs.id == rhs.id
    }
}

enum LaunchpadItem: Identifiable, Equatable {
    case app(AppInfo)
    case folder(FolderInfo)
    case empty(String)
    
    var id: String {
        switch self {
        case .app(let app):
            return "app_\(app.id)"
        case .folder(let folder):
            return "folder_\(folder.id)"
        case .empty(let token):
            return "empty_\(token)"
        }
    }
    
    var name: String {
        switch self {
        case .app(let app):
            return app.name
        case .folder(let folder):
            return folder.name
        case .empty:
            return ""
        }
    }
    
    var icon: NSImage {
        switch self {
        case .app(let app):
            return app.icon
        case .folder(let folder):
            let icon = folder.folderIcon
            return icon
        case .empty:
            // Transparent placeholder
            return NSImage(size: .zero)
        }
    }

    /// Convenience: returns AppInfo if the item is an app, otherwise nil.
    var appInfoIfApp: AppInfo? {
        if case let .app(app) = self { return app }
        return nil
    }
    
    static func == (lhs: LaunchpadItem, rhs: LaunchpadItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Legacy top-level persistence model (kept for backward compatibility)
@Model
final class TopItemData {
    // Unified primary key: appPath for apps; folderId for folders
    @Attribute(.unique) var id: String
    var kind: String                 // "app" or "folder" or "empty"
    var orderIndex: Int              // Top-level mixed order index
    // App fields
    var appPath: String?
    // Folder fields
    var folderName: String?
    var appPaths: [String]           // App order inside folder
    // Timestamps
    var createdAt: Date
    var updatedAt: Date

    // Folder initializer
    init(folderId: String,
         folderName: String,
         appPaths: [String],
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = folderId
        self.kind = "folder"
        self.orderIndex = orderIndex
        self.appPath = nil
        self.folderName = folderName
        self.appPaths = appPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // App initializer
    init(appPath: String,
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = appPath
        self.kind = "app"
        self.orderIndex = orderIndex
        self.appPath = appPath
        self.folderName = nil
        self.appPaths = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Empty slot initializer
    init(emptyId: String,
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = emptyId
        self.kind = "empty"
        self.orderIndex = orderIndex
        self.appPath = nil
        self.folderName = nil
        self.appPaths = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Page-slot persistence model (current)
@Model
final class PageEntryData {
    // Slot unique key, e.g., "page-0-pos-3"
    @Attribute(.unique) var slotId: String
    var pageIndex: Int
    var position: Int
    var kind: String          // "app" | "folder" | "empty"
    // app entry
    var appPath: String?
    // folder entry
    var folderId: String?
    var folderName: String?
    var appPaths: [String]
    // timestamps
    var createdAt: Date
    var updatedAt: Date

    init(slotId: String,
         pageIndex: Int,
         position: Int,
         kind: String,
         appPath: String? = nil,
         folderId: String? = nil,
         folderName: String? = nil,
         appPaths: [String] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.slotId = slotId
        self.pageIndex = pageIndex
        self.position = position
        self.kind = kind
        self.appPath = appPath
        self.folderId = folderId
        self.folderName = folderName
        self.appPaths = appPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
