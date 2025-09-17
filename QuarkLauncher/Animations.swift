import SwiftUI

enum LNAnimations {
    // MARK: - Springs - Performance optimized animation configurations
    static let springFast: Animation = .spring(response: 0.3, dampingFraction: 0.8) // Faster response
    
    // MARK: - Performance optimized animations
    static let dragPreview: Animation = .easeOut(duration: 0.3) // Use simpler animation for drag preview
    static let gridUpdate: Animation = .easeInOut(duration: 0.3) // Grid update animation
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .scale(scale: 0.8)
        .animation(LNAnimations.springFast)
    }
}


