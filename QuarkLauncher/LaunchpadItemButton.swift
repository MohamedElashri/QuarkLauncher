import SwiftUI
import AppKit
// Shared animations

struct LaunchpadItemButton: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isSelected: Bool
    var shouldAllowHover: Bool = true
    var externalScale: CGFloat? = nil
    let onTap: () -> Void
    let onDoubleClick: (() -> Void)?
    
    @State private var isHovered = false
    @State private var lastTapTime = Date.distantPast
    @State private var forceRefreshTrigger: UUID = UUID()
    @State private var cachedIcon: NSImage? = nil
    private let doubleTapThreshold: TimeInterval = 0.3
    
    private var effectiveScale: CGFloat {
        if let s = externalScale { return s }
        return (isHovered && shouldAllowHover) ? 1.2 : 1.0
    }
    
    init(item: LaunchpadItem,
         iconSize: CGFloat = 72,
         labelWidth: CGFloat = 80,
         isSelected: Bool = false,
          shouldAllowHover: Bool = true,
          externalScale: CGFloat? = nil,
         onTap: @escaping () -> Void,
         onDoubleClick: (() -> Void)? = nil) {
        self.item = item
        self.iconSize = iconSize
        self.labelWidth = labelWidth
        self.isSelected = isSelected
        self.shouldAllowHover = shouldAllowHover
        self.externalScale = externalScale
        self.onTap = onTap
        self.onDoubleClick = onDoubleClick
    }

    var body: some View {
        Button(action: handleTap) {
            VStack(spacing: 8) {
                ZStack {
                    let renderedIcon: NSImage = getOptimizedIcon()
                    let isFolderIcon: Bool = {
                        if case .folder = item { return true } else { return false }
                    }()
                    
                    if isFolderIcon {
                        RoundedRectangle(cornerRadius: 8)
                            .foregroundStyle(Color.clear)
                            .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                            )
                    }
                    
                    Image(nsImage: renderedIcon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: iconSize, height: iconSize)
                        .id(item.id + "_" + forceRefreshTrigger.uuidString) // Use combined ID to force refresh, ensuring folder icons update correctly
                }
                .scaleEffect(isSelected ? 1.05 : effectiveScale)
                .animation(LNAnimations.springFast, value: isHovered || isSelected)

                Text(item.name)
                    .font(.default)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .frame(width: labelWidth)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .onHover { isHovered = $0 }
    }
    
    private func handleTap() {
        let now = Date()
        let timeSinceLastTap = now.timeIntervalSince(lastTapTime)
        
        if timeSinceLastTap <= doubleTapThreshold, let doubleClick = onDoubleClick {
            // Double click
            doubleClick()
        } else {
            // Single click
            onTap()
        }
        
        lastTapTime = now
    }
    
    // Optimized icon loading with caching
    private func getOptimizedIcon() -> NSImage {
        // Use cached icon if available
        if let cached = cachedIcon {
            return cached
        }
        
        let icon: NSImage = {
            switch item {
            case .app(let app):
                // Try to get icon from cache
                if let cachedIcon = AppCacheManager.shared.getCachedIcon(for: app.url.path), cachedIcon.size.width > 0, cachedIcon.size.height > 0 {
                    return cachedIcon
                }
                // Use app's own icon or fallback to system icon
                let base = app.icon
                if base.size.width > 0 && base.size.height > 0 {
                    return base
                } else {
                    return NSWorkspace.shared.icon(forFile: app.url.path)
                }
            case .folder(let folder):
                return folder.icon(of: iconSize)
            case .empty:
                return item.icon
            }
        }()
        
        cachedIcon = icon
        return icon
    }
}
