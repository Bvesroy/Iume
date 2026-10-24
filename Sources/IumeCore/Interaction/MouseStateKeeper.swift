import AppKit
import Foundation

/// Delegate protocol for responding to coordinated mouse state transitions.
@MainActor
public protocol MouseStateKeeperDelegate: AnyObject {
    func mouseStateDidBeginDragging(windowId: WindowId)
    func mouseStateDidEndDragging(windowId: WindowId, initialFrame: CGRect)
    func mouseStateDidEndResizing(windowId: WindowId, initialFrame: CGRect)
}

/// Represents the explicit state of mouse interaction for window management operations,
/// modeled after Amethyst's proven MouseStateKeeper architecture.
public enum MouseInteractionState: Equatable, Sendable {
    case pointing
    case clicking(atTime: Date)
    case dragging
    case moving(windowId: WindowId, initialFrame: CGRect)
    case resizing(windowId: WindowId, initialFrame: CGRect)
    case doneDragging(atTime: Date, windowId: WindowId?, initialFrame: CGRect?)
}

/// Coordinates mouse-based window movement, resizing, and magnetic snapping.
/// Eliminates race conditions between asynchronous macOS EventTap / NSEvent streams
/// and delayed Accessibility (AXObserver) notifications.
@MainActor
public final class MouseStateKeeper {
    
    /// Threshold to tolerate delayed AX notifications arriving after physical mouse release (Amethyst parity: 150-200ms).
    public let dragRaceThresholdSeconds: TimeInterval = 0.20
    
    public private(set) var state: MouseInteractionState = .pointing
    public private(set) var lastClick: Date?
    
    private weak var delegate: MouseStateKeeperDelegate?
    private var globalMonitor: Any?
    
    public init(delegate: MouseStateKeeperDelegate? = nil) {
        self.delegate = delegate
        startMonitoring()
    }
    
    isolated deinit {
        stopMonitoring()
    }
    
    public func setDelegate(_ delegate: MouseStateKeeperDelegate?) {
        self.delegate = delegate
    }
    
    public func startMonitoring() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseEvent(event)
            }
        }
    }
    
    public func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
    
    public func handleMouseDown() {
        state = .clicking(atTime: Date())
        lastClick = Date()
    }
    
    public func handleMouseDragged() {
        switch state {
        case .moving, .resizing:
            break
        case .pointing, .clicking, .dragging, .doneDragging:
            state = .dragging
        }
    }
    
    public func handleMouseUp() {
        switch state {
        case .dragging:
            state = .doneDragging(atTime: Date(), windowId: nil, initialFrame: nil)
        case let .moving(windowId, initialFrame):
            state = .pointing
            delegate?.mouseStateDidEndDragging(windowId: windowId, initialFrame: initialFrame)
        case let .resizing(windowId, initialFrame):
            state = .pointing
            delegate?.mouseStateDidEndResizing(windowId: windowId, initialFrame: initialFrame)
        case .doneDragging, .clicking, .pointing:
            if case .clicking = state {
                lastClick = Date()
            }
            state = .pointing
        @unknown default:
            state = .pointing
        }
    }
    
    public func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            handleMouseDown()
        case .leftMouseDragged:
            handleMouseDragged()
        case .leftMouseUp:
            handleMouseUp()
        default:
            break
        }
    }
    
    /// Upgrades a generic mouse drag to a window movement state once an AX notification identifies the target window.
    public func upgradeToMoving(windowId: WindowId, initialFrame: CGRect) {
        switch state {
        case .dragging, .clicking, .pointing:
            state = .moving(windowId: windowId, initialFrame: initialFrame)
            delegate?.mouseStateDidBeginDragging(windowId: windowId)
        case .moving:
            break // Already in moving state
        case .resizing:
            break
        case let .doneDragging(atTime, _, _):
            // Delayed AX event arrived right after mouse release within the race threshold
            let elapsed = Date().timeIntervalSince(atTime)
            if elapsed < dragRaceThresholdSeconds {
                state = .pointing // Flip first
                delegate?.mouseStateDidEndDragging(windowId: windowId, initialFrame: initialFrame)
            } else {
                state = .pointing
            }
        }
    }
    
    /// Upgrades a generic mouse drag to a window edge resize state once an AX notification indicates a size change.
    public func upgradeToResizing(windowId: WindowId, initialFrame: CGRect) {
        switch state {
        case .dragging, .clicking, .pointing:
            state = .resizing(windowId: windowId, initialFrame: initialFrame)
        case .resizing:
            break
        case .moving:
            state = .resizing(windowId: windowId, initialFrame: initialFrame)
        case let .doneDragging(atTime, _, _):
            let elapsed = Date().timeIntervalSince(atTime)
            if elapsed < dragRaceThresholdSeconds {
                state = .pointing
                delegate?.mouseStateDidEndResizing(windowId: windowId, initialFrame: initialFrame)
            } else {
                state = .pointing
            }
        }
    }
    
    /// Resets state after a layout reflow.
    public func handleReflowEvent() {
        switch state {
        case .doneDragging:
            state = .pointing
        case .moving:
            state = .dragging
        default:
            break
        }
    }
    
    /// Force reset to .pointing (e.g. on workspace reset or disable).
    public func reset() {
        state = .pointing
    }
}
