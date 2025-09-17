import SwiftUI

enum LNAnimations {
    // MARK: - Springs - Performance optimized animation configurations
    static let springFast: Animation = .spring(response: 0.3, dampingFraction: 0.8) // Faster response
    static let springSnappy: Animation = .spring(response: 0.15, dampingFraction: 0.85) // Ultra-snappy for mode transitions
    static let springUltraFast: Animation = .spring(response: 0.1, dampingFraction: 0.9) // Instant feel for fullscreen
    
    // MARK: - Performance optimized animations
    static let dragPreview: Animation = .easeOut(duration: 0.3) // Use simpler animation for drag preview
    static let gridUpdate: Animation = .easeInOut(duration: 0.25) // Slightly faster grid updates
    static let fullscreenTransition: Animation = .spring(response: 0.1, dampingFraction: 0.9) // Ultra-fast spring for fullscreen
    static let fullscreenWindow: Animation = .easeOut(duration: 0.08) // Very fast window transition
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .scale(scale: 0.8)
        .animation(LNAnimations.springFast)
    }
    
    static var fullscreenModeTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.98).combined(with: .opacity),
            removal: .scale(scale: 1.02).combined(with: .opacity)
        )
        .animation(LNAnimations.springUltraFast)
    }
}


