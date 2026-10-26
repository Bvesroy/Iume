import Foundation
import CoreGraphics

// Minimal, deterministic stand-ins for the app-wide settings singleton so the
// real ScrollController can be compiled and exercised without SwiftUI.

public enum ScrollTriggerMode: String, CaseIterable, Codable, Sendable {
    case seamlessHorizontal
    case withOption
    case withControl
    case always
}

public enum KineticScrollingProfile: String, CaseIterable, Codable, Sendable {
    case natural
    case viscous
    case highInertia
    case snappy
}

@MainActor
public final class SettingsStore {
    public static let shared = SettingsStore()

    public var freezeOnRelease: Bool = false
    public var freeformScroll: Bool = true
    public var scrollSmoothness: Double = 0.75
    public var scrollDeceleration: Double = 0.965
    public var scrollSensitivity: Double = 1.0
    public var trackpadNaturalScroll: Bool = true
    public var scrollTriggerMode: ScrollTriggerMode = .seamlessHorizontal
    public var momentumScrolling: Bool = true
    public var inertialScrolling: Bool = true
    public var momentumMultiplier: Double = 1.0
    public var kineticScrollingProfile: KineticScrollingProfile = .natural
    public var smoothScrollingEnabled: Bool = true
    public var snapToColumn: Bool = false
    public var animationDuration: Double = 0.22

    public init() {}
}
