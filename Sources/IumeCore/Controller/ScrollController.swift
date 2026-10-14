import Foundation
import CoreGraphics
import QuartzCore

/// Controls smooth horizontal viewport scrolling, easing animations, and snapping.
@MainActor
public final class ScrollController {
    
    public var onViewportOffsetChanged: ((CGFloat) -> Void)?
    
    public private(set) var currentOffset: CGFloat = 0.0
    private var targetOffset: CGFloat = 0.0
    private var animationTimer: Timer?
    private var animationStartTime: CFTimeInterval = 0
    private var animationStartOffset: CGFloat = 0
    private var animationDuration: CFTimeInterval = 0.22
    
    public init() {}
    
    // MARK: - Direct Offset Update
    
    public func setOffset(_ offset: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        currentOffset = min(max(0, offset), max(0, maxOffset))
        onViewportOffsetChanged?(currentOffset)
    }
    
    // MARK: - Animated Scroll
    
    public func scrollTo(
        target: CGFloat,
        maxOffset: CGFloat,
        duration: Double = 0.22
    ) {
        let clampedTarget = min(max(0, target), max(0, maxOffset))
        guard abs(currentOffset - clampedTarget) > 1.0 else {
            currentOffset = clampedTarget
            onViewportOffsetChanged?(currentOffset)
            return
        }
        
        cancelAnimation()
        
        self.targetOffset = clampedTarget
        self.animationStartOffset = currentOffset
        self.animationDuration = max(0.05, duration)
        self.animationStartTime = CACurrentMediaTime()
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stepAnimation()
            }
        }
    }
    
    // MARK: - Incremental Scroll (Trackpad / Wheel)
    
    public func scrollBy(deltaX: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        let newOffset = min(max(0, currentOffset + deltaX), max(0, maxOffset))
        guard newOffset != currentOffset else { return }
        currentOffset = newOffset
        onViewportOffsetChanged?(currentOffset)
    }
    
    public func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    // MARK: - Easing Interpolation
    
    private func stepAnimation() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(1.0, elapsed / animationDuration)
        
        // Ease-out cubic curve: f(t) = 1 - (1 - t)^3
        let easedProgress = 1.0 - pow(1.0 - progress, 3.0)
        
        currentOffset = animationStartOffset + (targetOffset - animationStartOffset) * CGFloat(easedProgress)
        onViewportOffsetChanged?(currentOffset)
        
        if progress >= 1.0 {
            currentOffset = targetOffset
            cancelAnimation()
            onViewportOffsetChanged?(currentOffset)
        }
    }
}
