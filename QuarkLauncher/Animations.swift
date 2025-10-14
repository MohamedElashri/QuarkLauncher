import SwiftUI

enum LNAnimations {
    // MARK: - Performance optimized animations (minimized for performance)
    static let springFast: Animation = .easeOut(duration: 0).delay(0) // Minimal response
    static let springSnappy: Animation = .easeOut(duration: 0).delay(0) // Minimal response for mode transitions
    static let springUltraFast: Animation = .easeOut(duration: 0).delay(0) // Minimal response for fullscreen
    
    // MARK: - Performance optimized animations
    static let dragPreview: Animation = .easeOut(duration: 0).delay(0) // Minimal animation for drag preview
    static let gridUpdate: Animation = .easeInOut(duration: 0).delay(0) // Minimal grid updates
    static let fullscreenTransition: Animation = .easeOut(duration: 0).delay(0) // Minimal spring for fullscreen
    static let fullscreenWindow: Animation = .easeOut(duration: 0).delay(0) // Minimal window transition
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .identity // No transition effect for better performance
    }
    
    static var fullscreenModeTransition: AnyTransition {
        .identity // No transition effect for better performance
    }
}


