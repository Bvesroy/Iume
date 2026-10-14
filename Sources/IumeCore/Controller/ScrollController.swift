import Foundation
import CoreGraphics
import QuartzCore

/// Controls smooth horizontal viewport scrolling, easing animations, snapping,
/// and intercepts 2-finger continuous trackpad swipe / mouse wheel gestures.
@MainActor
public final class ScrollController {
    
    // Callbacks
    public var onViewportOffsetChanged: ((CGFloat) -> Void)?
    public var onScrollDeltaReceived: ((CGFloat) -> Void)?
    public var onScrollActivity: ((CGFloat, CGFloat, CGFloat) -> Void)? // offset, maxOffset, velocity
    public var onSettleRequested: ((CGFloat) -> Void)? // projectedOffset
    
    // Viewport & Physics State
    public private(set) var currentOffset: CGFloat = 0.0
    public private(set) var currentVelocity: CGFloat = 0.0
    public var maxOffset: CGFloat = 0.0
    
    private var targetOffset: CGFloat = 0.0
    private var animationTimer: Timer?
    private var animationStartTime: CFTimeInterval = 0
    private var animationStartOffset: CGFloat = 0
    private var animationDuration: CFTimeInterval = 0.18
    
    private var lastScrollTime: CFTimeInterval = 0
    private var settleTimer: Timer?
    private var coastingTimer: Timer?
    
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFrameUpdatePending = false
    
    public init() {}
    
    private func notifyOffsetChanged() {
        guard !isFrameUpdatePending else { return }
        isFrameUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isFrameUpdatePending = false
            self.onViewportOffsetChanged?(self.currentOffset)
            self.onScrollActivity?(self.currentOffset, self.maxOffset, self.currentVelocity)
        }
    }
    
    // MARK: - Direct Offset Update
    
    public func setOffset(_ offset: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        self.maxOffset = max(0, maxOffset)
        currentOffset = min(max(0, offset), self.maxOffset)
        currentVelocity = 0.0
        onViewportOffsetChanged?(currentOffset)
        onScrollActivity?(currentOffset, self.maxOffset, 0.0)
    }
    
    // MARK: - Animated Scroll
    
    public func scrollTo(
        target: CGFloat,
        maxOffset: CGFloat,
        duration: Double = 0.18
    ) {
        self.maxOffset = max(0, maxOffset)
        let clampedTarget = min(max(0, target), self.maxOffset)
        guard abs(currentOffset - clampedTarget) > 0.5 else {
            currentOffset = clampedTarget
            onViewportOffsetChanged?(currentOffset)
            onScrollActivity?(currentOffset, self.maxOffset, 0.0)
            return
        }
        
        cancelAnimation()
        
        self.targetOffset = clampedTarget
        self.animationStartOffset = currentOffset
        self.animationDuration = max(0.05, duration)
        self.animationStartTime = CACurrentMediaTime()
        
        // 120Hz ProMotion pacing
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stepAnimation()
            }
        }
    }
    
    // MARK: - Incremental Scroll (Discrete / Shortcut Step)
    
    public func scrollBy(deltaX: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        self.maxOffset = max(0, maxOffset)
        let newOffset = min(max(0, currentOffset + deltaX), self.maxOffset)
        guard newOffset != currentOffset else { return }
        currentOffset = newOffset
        currentVelocity = 0.0
        onViewportOffsetChanged?(currentOffset)
        onScrollActivity?(currentOffset, self.maxOffset, 0.0)
    }
    
    public func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        coastingTimer?.invalidate()
        coastingTimer = nil
        settleTimer?.invalidate()
        settleTimer = nil
    }
    
    // MARK: - Continuous 2-Finger Trackpad Gesture Processing
    
    public func handleContinuousScrollDelta(
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags
    ) {
        cancelAnimation()
        
        let settings = SettingsStore.shared
        let naturalMultiplier: CGFloat = settings.trackpadNaturalScroll ? -1.0 : 1.0
        let sensitivity = CGFloat(settings.scrollSensitivity)
        
        // Determine primary delta
        let isHorizontalIntent = abs(dx) > abs(dy)
        let primaryDelta = isHorizontalIntent ? dx : dy
        let effectiveDelta = primaryDelta * naturalMultiplier * sensitivity
        
        let now = CACurrentMediaTime()
        let dt = max(0.005, now - lastScrollTime)
        lastScrollTime = now
        
        let instVelocity = effectiveDelta / CGFloat(dt)
        currentVelocity = currentVelocity * 0.70 + instVelocity * 0.30
        
        // Apply rubber-banded movement
        let rubberLimit: CGFloat = 180.0
        var newOffset = currentOffset + effectiveDelta
        
        if newOffset < 0 {
            let overshoot = -newOffset
            let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
            newOffset = currentOffset + (effectiveDelta * resistance)
        } else if newOffset > maxOffset {
            let overshoot = newOffset - maxOffset
            let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
            newOffset = currentOffset + (effectiveDelta * resistance)
        }
        
        currentOffset = newOffset
        notifyOffsetChanged()
        
        // Debounce settle timer (130ms)
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.settle()
            }
        }
        
        // Gesture ended or momentum ended (4 = Ended, 8 = Cancelled)
        if phase == 4 || phase == 8 || momentumPhase == 4 {
            isFrameUpdatePending = false
            onViewportOffsetChanged?(currentOffset)
            onScrollActivity?(currentOffset, maxOffset, currentVelocity)
            settle()
        }
    }
    
    // MARK: - Settle / Snapping
    
    public func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        
        let settings = SettingsStore.shared
        
        // Overshot boundaries: spring back
        if currentOffset < 0 {
            scrollTo(target: 0, maxOffset: maxOffset, duration: settings.animationDuration)
            return
        }
        if currentOffset > maxOffset {
            scrollTo(target: maxOffset, maxOffset: maxOffset, duration: settings.animationDuration)
            return
        }
        
        if settings.snapToColumn {
            // Project target offset with rolling velocity
            let projection = currentOffset + currentVelocity * 0.18
            currentVelocity = 0.0
            onSettleRequested?(projection)
        } else if settings.momentumScrolling && abs(currentVelocity) > 20.0 {
            startInertialCoasting()
        } else {
            currentVelocity = 0.0
        }
    }
    
    private func startInertialCoasting() {
        coastingTimer?.invalidate()
        coastingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stepCoasting()
            }
        }
    }
    
    private func stepCoasting() {
        currentVelocity *= 0.91 // Friction decay
        let step = currentVelocity * (1.0 / 120.0)
        let target = currentOffset + step
        
        if abs(currentVelocity) < 4.0 || target < 0 || target > maxOffset {
            currentVelocity = 0.0
            coastingTimer?.invalidate()
            coastingTimer = nil
            settle()
            return
        }
        
        currentOffset = min(max(0, target), maxOffset)
        onViewportOffsetChanged?(currentOffset)
        onScrollActivity?(currentOffset, maxOffset, currentVelocity)
    }
    
    // MARK: - Easing Interpolation
    
    private func stepAnimation() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(1.0, elapsed / animationDuration)
        
        // Ease-out cubic curve: f(t) = 1 - (1 - t)^3
        let easedProgress = 1.0 - pow(1.0 - progress, 3.0)
        
        currentOffset = animationStartOffset + (targetOffset - animationStartOffset) * CGFloat(easedProgress)
        onViewportOffsetChanged?(currentOffset)
        onScrollActivity?(currentOffset, maxOffset, 0.0)
        
        if progress >= 1.0 {
            currentOffset = targetOffset
            cancelAnimation()
            onViewportOffsetChanged?(currentOffset)
            onScrollActivity?(currentOffset, maxOffset, 0.0)
        }
    }
    
    // MARK: - Trackpad & Wheel Interception Tap
    
    public func shouldInterceptScroll(dx: CGFloat, dy: CGFloat, flags: CGEventFlags) -> Bool {
        let settings = SettingsStore.shared
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        
        switch settings.scrollTriggerMode {
        case .seamlessHorizontal:
            // Holding Option or Control always intercepts
            if hasOption || hasControl { return true }
            // Intercept horizontal 2-finger scroll when horizontal intent exceeds vertical
            let absX = abs(dx)
            let absY = abs(dy)
            return absX > absY && absX > 0.05
            
        case .withOption:
            return hasOption
            
        case .withControl:
            return hasControl
            
        case .always:
            return true
        }
    }
    
    public func startEventTap() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ScrollController>.fromOpaque(userInfo).takeUnretainedValue()
            
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            var dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            var dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            
            // Fallback to line delta if point delta is 0 (mouse wheel or discrete trackpad)
            if dx == 0 && dy == 0 {
                dx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 14.0
                dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 14.0
            }
            
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let flags = event.flags
            
            if controller.shouldInterceptScroll(dx: dx, dy: dy, flags: flags) {
                DispatchQueue.main.async {
                    controller.handleContinuousScrollDelta(
                        dx: dx,
                        dy: dy,
                        phase: phase,
                        momentumPhase: momentumPhase,
                        flags: flags
                    )
                }
                return nil // Consume event to prevent underlying window scrolling
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) {
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    public func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        cancelAnimation()
    }
}
