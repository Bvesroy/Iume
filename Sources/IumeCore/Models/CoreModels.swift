import Foundation
import CoreGraphics

/// Stable unique identifier for a managed window.
public struct WindowId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let pid: pid_t
    public let rawId: UInt64
    
    public init(pid: pid_t, rawId: UInt64) {
        self.pid = pid
        self.rawId = rawId
    }
    
    public var description: String {
        "Window(\(pid):\(rawId))"
    }
}

/// Defines how windows are placed and viewed in a workspace.
public enum LayoutMode: String, CaseIterable, Codable, Sendable {
    /// Continuous horizontal sequence where windows preserve their dimensions and viewport scrolls smoothly.
    case scrollStrip = "Scroll Strip"
    /// Focused column takes visual priority, with neighboring columns visible as space permits.
    case focusColumn = "Focus Column"
    /// Focused column is dynamically centered in the visible screen area.
    case centeredFocus = "Centered Focus"
    /// Manual positioning allows the user to freely resize or reposition windows without snapping back.
    case manualLayout = "Manual Layout"
    
    public var description: String {
        switch self {
        case .scrollStrip:
            return "Windows arranged side by side on a continuous horizontal strip. Viewport scrolls as focus moves."
        case .focusColumn:
            return "Priority given to the active column, keeping neighboring columns partially visible."
        case .centeredFocus:
            return "Active column is always centered on the screen."
        case .manualLayout:
            return "User can freely resize and move windows. Layout engine reconciles positions smoothly."
        }
    }
}

/// Where new windows are inserted into the strip.
public enum InsertionPolicy: String, CaseIterable, Codable, Sendable {
    case afterFocused = "After Focused Window"
    case atEnd = "At End of Strip"
    case inCurrentColumn = "In Current Column (Stacked)"
}

/// Represents the geometry of a physical display.
public struct DisplayGeometry: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isPrimary: Bool
    
    public init(id: CGDirectDisplayID, name: String, frame: CGRect, visibleFrame: CGRect, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
    }
}

/// Represents a single column in the horizontal strip.
public struct WindowColumn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var windowIds: [WindowId]
    public var width: CGFloat
    
    public init(id: UUID = UUID(), windowIds: [WindowId] = [], width: CGFloat = 800) {
        self.id = id
        self.windowIds = windowIds
        self.width = width
    }
}

/// Defines how trackpad 2-finger scroll gestures trigger strip navigation.
public enum ScrollTriggerMode: String, CaseIterable, Codable, Sendable {
    /// Seamless horizontal 2-finger scroll moves the strip; vertical scroll passes to applications.
    case seamlessHorizontal = "Seamless Horizontal (Smart)"
    /// Only intercept when Option (⌥) is held while scrolling with two fingers.
    case withOption = "Option + 2-Finger Scroll"
    /// Only intercept when Control (⌃) is held while scrolling with two fingers.
    case withControl = "Control + 2-Finger Scroll"
    /// Intercept all continuous scroll gestures.
    case always = "Always Scroll Strip"
    
    public var description: String {
        switch self {
        case .seamlessHorizontal:
            return "Glide across the infinite window strip using 2-finger horizontal swipes. Vertical scrolling stays inside apps."
        case .withOption:
            return "Hold Option (⌥) while scrolling with 2 fingers to glide the strip."
        case .withControl:
            return "Hold Control (⌃) while scrolling with 2 fingers to glide the strip."
        case .always:
            return "All 2-finger scroll gestures navigate the window strip."
        }
    }
}

