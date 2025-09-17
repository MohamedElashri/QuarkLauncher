import SwiftUI

enum LNAnimations {
    // MARK: - Springs - Performance optimized animation configurations
    static let springFast: Animation = .spring(response: 0.3, dampingFraction: 0.8) // Faster response
    static let springSnappy: Animation = .spring(response: 0.2, dampingFraction: 0.9) // Snappier for mode transitions
    
    // MARK: - Performance optimized animations
    static let dragPreview: Animation = .easeOut(duration: 0.3) // Use simpler animation for drag preview
    static let gridUpdate: Animation = .easeInOut(duration: 0.3) // Grid update animation
    static let fullscreenTransition: Animation = .easeOut(duration: 0.15) // Fast, smooth fullscreen transition
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .scale(scale: 0.8)
        .animation(LNAnimations.springFast)
    }
    
    static var fullscreenModeTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 1.05).combined(with: .opacity)
        )
        .animation(LNAnimations.springSnappy)
    }
}


