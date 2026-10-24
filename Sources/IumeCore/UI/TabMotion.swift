import SwiftUI
import AppKit

/// Resolves the user's Tab Motion preferences into concrete SwiftUI animations.
/// Keeping this in one place means the floating tab bar, the drag interactions,
/// and the settings preview always animate identically.
@MainActor
public struct TabMotionProfile {
    public let isEnabled: Bool
    public let switchEffect: TabSwitchEffect
    public let openCloseEffect: TabOpenCloseEffect
    public let speed: Double
    public let reduceMotion: Bool

    public init(
        isEnabled: Bool,
        switchEffect: TabSwitchEffect,
        openCloseEffect: TabOpenCloseEffect,
        speed: Double,
        reduceMotion: Bool
    ) {
        self.isEnabled = isEnabled
        self.switchEffect = switchEffect
        self.openCloseEffect = openCloseEffect
        self.speed = speed
        self.reduceMotion = reduceMotion
    }

    public static var current: TabMotionProfile {
        let settings = SettingsStore.shared
        return TabMotionProfile(
            isEnabled: settings.tabAnimationsEnabled,
            switchEffect: settings.tabSwitchEffect,
            openCloseEffect: settings.tabOpenCloseEffect,
            speed: settings.tabMotionSpeed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    // MARK: - Timing

    /// Motion is disabled both by the user toggle and by System Settings →
    /// Accessibility → Display → Reduce Motion.
    public var isMotionEnabled: Bool {
        isEnabled && !reduceMotion
    }

    private var clampedSpeed: Double {
        max(0.4, min(2.5, speed))
    }

    /// Converts a baseline duration into a user-scaled duration. Higher speed
    /// values produce shorter durations.
    private func scaled(_ base: Double) -> Double {
        guard isMotionEnabled else { return 0.001 }
        return max(0.001, base / clampedSpeed)
    }

    public var switchAnimation: Animation {
        guard isMotionEnabled, switchEffect != .none else {
            return .linear(duration: 0.001)
        }
        switch switchEffect {
        case .slide:
            return .spring(response: scaled(0.26), dampingFraction: 0.84)
        case .crossfade:
            return .easeInOut(duration: scaled(0.18))
        case .springPop:
            return .spring(response: scaled(0.34), dampingFraction: 0.62)
        case .none:
            return .linear(duration: 0.001)
        }
    }

    public var openCloseAnimation: Animation {
        guard isMotionEnabled, openCloseEffect != .none else {
            return .linear(duration: 0.001)
        }
        switch openCloseEffect {
        case .scaleFade:
            return .spring(response: scaled(0.26), dampingFraction: 0.78)
        case .slide:
            return .spring(response: scaled(0.28), dampingFraction: 0.86)
        case .fade:
            return .easeInOut(duration: scaled(0.18))
        case .materialize:
            return .easeOut(duration: scaled(0.24))
        case .none:
            return .linear(duration: 0.001)
        }
    }

    public var reorderAnimation: Animation {
        isMotionEnabled ? .spring(response: scaled(0.22), dampingFraction: 0.82) : .linear(duration: 0.001)
    }

    public var quickAnimation: Animation {
        isMotionEnabled ? .easeOut(duration: scaled(0.14)) : .linear(duration: 0.001)
    }

    /// Dedicated timing for the whole bar's entry/exit. An ease-out curve
    /// finishes predictably, so the panel can be released exactly when the
    /// last frame lands instead of clipping a spring's tail.
    public var barAnimation: Animation {
        guard isMotionEnabled, openCloseEffect != .none else {
            return .linear(duration: 0.001)
        }
        return .easeOut(duration: scaled(0.22))
    }

    /// How long the floating bar takes to fade/slide away before its panel is
    /// released.
    public var barDismissDelay: Double {
        guard isMotionEnabled, openCloseEffect != .none else { return 0.02 }
        return scaled(0.22) + 0.05
    }

    // MARK: - Transitions

    /// Per-tab insertion and removal transition used when a tab is added,
    /// closed, grouped, or detached.
    public var tabTransition: AnyTransition {
        guard isMotionEnabled, openCloseEffect != .none else {
            return .identity
        }
        switch openCloseEffect {
        case .scaleFade:
            return .asymmetric(
                insertion: .scale(scale: 0.78, anchor: .leading).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.90, anchor: .trailing))
            )
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        case .fade:
            return .opacity
        case .materialize:
            let active = TabMaterializeModifier(progress: 0)
            let identity = TabMaterializeModifier(progress: 1)
            return .asymmetric(
                insertion: .modifier(active: active, identity: identity),
                removal: .modifier(active: active, identity: identity)
            )
        case .none:
            return .identity
        }
    }

    // MARK: - Floating bar appearance

    /// Hidden-state geometry for the whole tab bar. The view interpolates
    /// between these values and their visible equivalents.
    public var barHiddenScale: CGFloat {
        guard isMotionEnabled else { return 1 }
        switch openCloseEffect {
        case .scaleFade:
            return 0.95
        case .slide:
            return 1
        case .fade:
            return 1
        case .materialize:
            return 0.93
        case .none:
            return 1
        }
    }

    public var barHiddenOffset: CGFloat {
        guard isMotionEnabled, openCloseEffect == .slide else { return 0 }
        return -10
    }

    public var barHiddenBlur: CGFloat {
        guard isMotionEnabled, openCloseEffect == .materialize else { return 0 }
        return 7
    }

    // MARK: - Highlight behaviour

    /// A single matched-geometry pill can glide between tabs. Crossfade and
    /// Instant render a per-tab pill instead so it softly fades in place.
    public var usesMorphingHighlight: Bool {
        isMotionEnabled && (switchEffect == .slide || switchEffect == .springPop)
    }

    public var showsAccentGlow: Bool {
        isMotionEnabled && switchEffect == .springPop
    }

    // MARK: - Haptics

    public var hapticsEnabled: Bool {
        isEnabled && SettingsStore.shared.tabHapticsEnabled
    }

    public func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Animatable blur/scale/pop transition used by the "Materialize" style.
private struct TabMaterializeModifier: ViewModifier, Animatable {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(Double(max(0, min(1, progress))))
            .blur(radius: max(0, (1 - progress) * 6))
            .scaleEffect(0.86 + 0.14 * progress, anchor: .center)
    }
}
