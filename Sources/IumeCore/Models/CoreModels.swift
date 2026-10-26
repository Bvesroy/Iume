import Foundation
import CoreGraphics
import ApplicationServices

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
    /// Auto-tiles all open windows into a clean grid of boxes (e.g. 2x2, 2x3).
    case grid = "Grid / Boxes"
    /// Primary main window occupies the left pane, remaining windows stack vertically on the right.
    case tall = "Tall (Main + Stack)"
    /// Primary main window occupies the top pane, remaining windows stack horizontally on the bottom.
    case wide = "Wide (Top + Bottom)"
    /// Binary Space Partitioning recursively splits the screen alternating horizontal and vertical boxes.
    case bsp = "Binary Space Partitioning"
    /// All windows share the screen in a single horizontal row.
    case row = "Row"
    /// All windows share the screen in a single vertical column.
    case column = "Column"
    
    /// Whether this mode lays windows out on a horizontal strip that can wrap end-to-start.
    /// Box tiling and manual modes ignore `loopMode` entirely.
    public var supportsLoop: Bool {
        switch self {
        case .scrollStrip, .focusColumn, .centeredFocus:
            return true
        case .manualLayout, .grid, .tall, .wide, .bsp, .row, .column:
            return false
        }
    }

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
        case .grid:
            return "All open windows are automatically tiled into an optimal grid of boxes (e.g. 2x2 quarters, 2x3)."
        case .tall:
            return "Master pane on the left with configurable width ratio; secondary open windows stacked on the right."
        case .wide:
            return "Master pane on top with configurable height ratio; secondary open windows stacked below."
        case .bsp:
            return "Binary space partitioning splits screen space recursively into alternating horizontal and vertical boxes."
        case .row:
            return "Every open window sits side by side in one horizontal row, each sized to share the screen equally."
        case .column:
            return "Every open window is stacked in one vertical column, each sized to share the screen height equally."
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

/// Controls when and how the focused column is centered in the viewport.
public enum CenterMode: String, Codable, CaseIterable, Sendable {
    /// Scrolls just far enough to bring focused column cleanly inside outer margins
    case never = "never"
    /// Centers focused column only when total strip width exceeds usable viewport width
    case onOverflow = "onOverflow"
    /// Always centers focused column on screen
    case always = "always"
}

/// Defines the visual presentation of the floating minimap / scroll bar HUD.
public enum MinimapHUDStyle: String, Codable, CaseIterable, Sendable {
    /// 270° radial chronograph dial instrument with draggable app orbs.
    case circularDial = "circularDial"
    /// Wide half-ellipse dome docked to the bottom edge, with an elliptical window track.
    case semicircle = "semicircle"
    /// 360° full-circle floating orbital halo ring with glowing app nodes.
    case orbitalRing = "orbitalRing"
    /// Tactile concentric grooved rotary turntable disc with needle indicator.
    case turntableDisc = "turntableDisc"
    /// Minimalist floating glass capsule bar with draggable app pills.
    case linearStrip = "linearStrip"
    /// Editing-timeline track: proportional window segments under a ruler with a sliding lens.
    case timeline = "timeline"
    /// Equaliser bars: one capsule bar per window, height encoding column width.
    case spectrum = "spectrum"
    /// Vertical window rail docked to the right edge of the screen.
    case edgeRail = "edgeRail"
    /// Fixed-reticle tape that scrolls a short section of the strip under a centre needle.
    case tape = "tape"
    /// 3D carousel drum where windows turn around a loop in perspective — built for Loop Mode.
    case loop3D = "loop3D"

    public var displayName: String {
        switch self {
        case .circularDial: return "Chrono Circular Dial"
        case .semicircle: return "Horizon Half-Ellipse"
        case .orbitalRing: return "360° Orbital Halo Ring"
        case .turntableDisc: return "Rotary Turntable Disc"
        case .linearStrip: return "Floating Glass Capsule"
        case .timeline: return "Editing Timeline Lens"
        case .spectrum: return "Desktop Spectrum Bars"
        case .edgeRail: return "Edge Window Rail"
        case .tape: return "Focus Tape Compass"
        case .loop3D: return "3D Loop Carousel"
        }
    }

    public var subtitle: String {
        switch self {
        case .circularDial:
            return "270° precision radial gauge with draggable app orbs and center live readout."
        case .semicircle:
            return "Aerodynamic half-ellipse arch docked at screen bottom with glowing elliptical track and swap orbs."
        case .orbitalRing:
            return "Full 360° floating glass orbit ring where open windows revolve as interactive nodes."
        case .turntableDisc:
            return "Tactile grooved dark-glass rotary disc with a sweeping needle arm and rim medallions."
        case .linearStrip:
            return "Compact horizontal glass dock with proportional draggable window pills."
        case .timeline:
            return "Editor-style timeline where every window is a proportional clip and the viewport is a lens."
        case .spectrum:
            return "Equaliser bars sized by window width, with the visible range glowing as a band."
        case .edgeRail:
            return "A vertical rail of window rows docked to the right edge — no desktop covered."
        case .tape:
            return "Camera-style focus tape: windows scroll under a fixed centre reticle, one drag to scrub."
        case .loop3D:
            return "Windows ride a turning 3D drum: they swing across the front, rotate away and pass behind each other, so Loop Mode reads as a real loop."
        }
    }

    public var symbol: String {
        switch self {
        case .circularDial: return "dial.medium.fill"
        case .semicircle: return "oval.bottomhalf.filled"
        case .orbitalRing: return "circle.hexagongrid.fill"
        case .turntableDisc: return "opticaldisc.fill"
        case .linearStrip: return "dock.rectangle"
        case .timeline: return "timeline.selection"
        case .spectrum: return "chart.bar.fill"
        case .edgeRail: return "sidebar.right"
        case .tape: return "camera.aperture"
        case .loop3D: return "rotate.3d"
        }
    }
}

/// Selectable transition styles when two window edges approach each other and snap like a magnet.
public enum MagneticSnapTransitionStyle: String, Codable, CaseIterable, Sendable {
    /// Harmonic liquid spring glide with a glowing cyan/accent seam pulse along the locked edge.
    case liquidSpring = "liquidSpring"
    /// Tactile magnetic pull with a subtle elastic bounce and dual-edge attraction flash.
    case elasticMagnet = "elasticMagnet"
    /// Fast precision magnetic lock with a crisp specular seam line and detent click.
    case crispLock = "crispLock"
    /// Smooth, critically damped velvet glide with a warm diffused border aura.
    case velvetGlide = "velvetGlide"
    /// Zero-latency immediate edge weld with a brief seam highlight.
    case instantWeld = "instantWeld"

    public var displayName: String {
        switch self {
        case .liquidSpring: return "Liquid Spring Pulse"
        case .elasticMagnet: return "Elastic Magnet Pull"
        case .crispLock: return "Crisp Precision Lock"
        case .velvetGlide: return "Velvet Smooth Glide"
        case .instantWeld: return "Instant Edge Weld"
        }
    }

    public var subtitle: String {
        switch self {
        case .liquidSpring:
            return "Smooth 120Hz harmonic spring with a glowing energy seam along the joined edges."
        case .elasticMagnet:
            return "Snappy magnetic attraction with a tactile elastic overshoot as edges lock together."
        case .crispLock:
            return "Fast, decisive lock with a sharp specular border flash and mechanical detent click."
        case .velvetGlide:
            return "Soft, critically damped glide with zero overshoot and a subtle seam aura."
        case .instantWeld:
            return "Immediate zero-delay edge weld the instant windows enter the attraction zone."
        }
    }

    public var symbol: String {
        switch self {
        case .liquidSpring: return "waveform.path"
        case .elasticMagnet: return "link.circle.fill"
        case .crispLock: return "bolt.horizontal.circle.fill"
        case .velvetGlide: return "wind"
        case .instantWeld: return "rectangle.connected.to.line.below"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .liquidSpring: return 0.22
        case .elasticMagnet: return 0.28
        case .crispLock: return 0.12
        case .velvetGlide: return 0.30
        case .instantWeld: return 0.0
        }
    }

    public var dampingRatio: Double {
        switch self {
        case .liquidSpring: return 0.82
        case .elasticMagnet: return 0.66
        case .crispLock: return 0.96
        case .velvetGlide: return 0.99
        case .instantWeld: return 1.0
        }
    }
}

/// Selectable animation styles when a newly opened app/window inserts itself next to the focused strip column.
public enum WindowInsertionAnimationStyle: String, Codable, CaseIterable, Sendable {
    /// Neighboring columns visibly part outward like a wave while the new window emerges in the gap.
    case partingWave = "partingWave"
    /// New window glides in smoothly from the top seam while neighbors slide aside on a spring curve.
    case harmonicSlideIn = "harmonicSlideIn"
    /// New window starts as a glowing center sliver beside the focused window and blooms to full width.
    case bloomExpand = "bloomExpand"
    /// Immediate placement beside the focused column without insertion choreography.
    case instantSlot = "instantSlot"

    public var displayName: String {
        switch self {
        case .partingWave: return "Parting Strip Wave"
        case .harmonicSlideIn: return "Harmonic Cascade Slide"
        case .bloomExpand: return "Center Sliver Bloom"
        case .instantSlot: return "Instant Slot"
        }
    }

    public var subtitle: String {
        switch self {
        case .partingWave:
            return "Open windows part outward to carve a space right beside the focused window as the new app emerges."
        case .harmonicSlideIn:
            return "The new window cascades smoothly into position next to focus while neighbors glide aside."
        case .bloomExpand:
            return "Starts as a luminous vertical seam beside the focused window and expands outward to push neighbors."
        case .instantSlot:
            return "Places the newly opened window beside the focused window immediately with zero delay."
        }
    }

    public var symbol: String {
        switch self {
        case .partingWave: return "arrow.left.and.line.vertical.and.arrow.right"
        case .harmonicSlideIn: return "rectangle.badge.plus"
        case .bloomExpand: return "sparkles.rectangle.stack.fill"
        case .instantSlot: return "bolt.fill"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .partingWave: return 0.28
        case .harmonicSlideIn: return 0.24
        case .bloomExpand: return 0.26
        case .instantSlot: return 0.0
        }
    }
}


/// How windows are visually arranged within a single strip column.
public enum ColumnPresentationMode: String, Codable, CaseIterable, Sendable {
    /// Windows split column height vertically (min 200pt each)
    case stacked = "stacked"
    /// Each window gets full column height; top 28pt reserved for TabBarOverlay
    case tabbed = "tabbed"
}

/// Entry representing a window in a column stack with custom height ratio.
public struct StackedWindowEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: WindowId
    public var heightRatio: CGFloat // Proportional vertical height weight
    
    public init(id: WindowId, heightRatio: CGFloat = 0.50) {
        self.id = id
        self.heightRatio = heightRatio
    }
}

/// Outer screen margins surrounding the tiling strip (configurable down to 0px).
public struct EdgeMargins: Codable, Sendable, Equatable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat
    public var right: CGFloat
    
    public init(top: CGFloat = 8, bottom: CGFloat = 8, left: CGFloat = 8, right: CGFloat = 8) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
    
    public static let zero = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
}

/// Represents a single column in the horizontal strip with vertical stack and tabbed support.
public struct WindowColumn: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var windowIds: [WindowId] {
        didSet {
            // Keep windowEntries in sync with windowIds without discarding
            // custom stack heights for windows that remain in the column.
            var newEntries: [StackedWindowEntry] = []
            for winId in windowIds {
                if let existing = windowEntries.first(where: { $0.id == winId }) {
                    newEntries.append(existing)
                } else {
                    newEntries.append(StackedWindowEntry(id: winId))
                }
            }
            windowEntries = newEntries
            if activeWindowIndex >= windowIds.count {
                activeWindowIndex = max(0, windowIds.count - 1)
            }
        }
    }
    public var width: CGFloat
    public var presentationMode: ColumnPresentationMode
    public var activeWindowIndex: Int
    public var windowEntries: [StackedWindowEntry]
    public var isFullWidth: Bool
    public var savedPreFullWidthRatio: CGFloat
    /// Set when the user explicitly asked to keep a single-window tab bar visible.
    public var tabBarPinned: Bool
    /// Optional user-defined custom group name (e.g. "Research", "Development", "Project").
    public var customGroupName: String?
    /// Optional custom accent color hex code for the tab group.
    public var customColorHex: String?
    /// When true, the tab group is collapsed in the strip (shows compact chip with active tab).
    public var isCollapsed: Bool
    /// Set of window IDs that are locked against accidental closure.
    public var lockedWindowIds: Set<WindowId>
    /// Custom user-renamed titles for tabs in this column.
    public var customTabTitles: [WindowId: String]
    
    public init(
        id: UUID = UUID(),
        windowIds: [WindowId] = [],
        width: CGFloat = 800,
        presentationMode: ColumnPresentationMode = .stacked,
        activeWindowIndex: Int = 0,
        windowEntries: [StackedWindowEntry]? = nil,
        isFullWidth: Bool = false,
        savedPreFullWidthRatio: CGFloat = 0.50,
        tabBarPinned: Bool = false,
        customGroupName: String? = nil,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        lockedWindowIds: Set<WindowId> = [],
        customTabTitles: [WindowId: String] = [:]
    ) {
        self.id = id
        self.windowIds = windowIds
        self.width = width
        self.presentationMode = presentationMode
        self.activeWindowIndex = activeWindowIndex
        self.windowEntries = windowEntries ?? windowIds.map { StackedWindowEntry(id: $0) }
        self.isFullWidth = isFullWidth
        self.savedPreFullWidthRatio = savedPreFullWidthRatio
        self.tabBarPinned = tabBarPinned
        self.customGroupName = customGroupName
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.lockedWindowIds = lockedWindowIds
        self.customTabTitles = customTabTitles
    }
    
    // MARK: - Tab Group Helpers
    
    /// True when this column renders as a browser-style tab group.
    public var isTabGroup: Bool {
        presentationMode == .tabbed && windowIds.count > 1
    }
    
    /// The window currently displayed by the tab group.
    public var activeWindowId: WindowId? {
        guard windowIds.indices.contains(activeWindowIndex) else { return nil }
        return windowIds[activeWindowIndex]
    }
    
    /// The tab bar is visible for multi-tab groups, or when the user pinned it
    /// (which is how a single window is explicitly kept in tabbed presentation).
    public var showsTabBar: Bool {
        guard presentationMode == .tabbed, !windowIds.isEmpty else { return false }
        return windowIds.count > 1 || tabBarPinned
    }
    
    /// Removes a member window while keeping the active tab stable.
    /// Returns true when the window belonged to this column.
    @discardableResult
    public mutating func removeWindow(_ windowId: WindowId) -> Bool {
        guard let index = windowIds.firstIndex(of: windowId) else { return false }
        if index < activeWindowIndex {
            activeWindowIndex -= 1
        } else if index == activeWindowIndex {
            activeWindowIndex = min(index, max(0, windowIds.count - 2))
        }
        windowIds.remove(at: index)
        lockedWindowIds.remove(windowId)
        customTabTitles.removeValue(forKey: windowId)
        return true
    }
    
    /// Moves a tab to a new position, preserving the active window identity.
    @discardableResult
    public mutating func moveWindow(_ windowId: WindowId, to newIndex: Int) -> Bool {
        guard let fromIndex = windowIds.firstIndex(of: windowId), windowIds.count > 1 else { return false }
        let clamped = max(0, min(newIndex, windowIds.count - 1))
        guard clamped != fromIndex else { return false }
        let activeId = activeWindowId
        var reordered = windowIds
        let moved = reordered.remove(at: fromIndex)
        reordered.insert(moved, at: clamped)
        windowIds = reordered
        if let activeId, let newActiveIndex = windowIds.firstIndex(of: activeId) {
            activeWindowIndex = newActiveIndex
        }
        return true
    }
    
    /// Selects the tab for the given window. Returns true when it is a member.
    @discardableResult
    public mutating func selectWindow(_ windowId: WindowId) -> Bool {
        guard let index = windowIds.firstIndex(of: windowId) else { return false }
        activeWindowIndex = index
        return true
    }
    
    /// Keeps tabbed presentation honest: a group that shrinks to a single tab
    /// reverts to a normal column unless the user pinned the tab bar.
    public mutating func normalizeTabPresentation() {
        if presentationMode == .tabbed && windowIds.count <= 1 && !tabBarPinned {
            presentationMode = .stacked
        }
    }
    
    /// Retrieves the display title for a window, honoring custom renames.
    public func effectiveTitle(for windowId: WindowId, defaultTitle: String) -> String {
        if let custom = customTabTitles[windowId], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return defaultTitle
    }
    
    /// Sets or removes a custom user title for a tab.
    public mutating func setCustomTitle(_ title: String?, for windowId: WindowId) {
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            customTabTitles[windowId] = title
        } else {
            customTabTitles.removeValue(forKey: windowId)
        }
    }
    
    /// Returns true if the tab is protected against accidental closure.
    public func isLocked(_ windowId: WindowId) -> Bool {
        lockedWindowIds.contains(windowId)
    }
    
    /// Toggles the locked status of a tab.
    public mutating func toggleLock(_ windowId: WindowId) {
        if lockedWindowIds.contains(windowId) {
            lockedWindowIds.remove(windowId)
        } else {
            lockedWindowIds.insert(windowId)
        }
    }
    
    /// Closes all unlocked tabs other than the specified window. Returns the removed window IDs.
    @discardableResult
    public mutating func closeOtherWindows(except windowId: WindowId) -> [WindowId] {
        guard windowIds.contains(windowId) else { return [] }
        var removed: [WindowId] = []
        let retained = windowIds.filter { id in
            if id == windowId || isLocked(id) {
                return true
            } else {
                removed.append(id)
                return false
            }
        }
        windowIds = retained
        if let newActiveIdx = windowIds.firstIndex(of: windowId) {
            activeWindowIndex = newActiveIdx
        } else {
            activeWindowIndex = max(0, min(activeWindowIndex, windowIds.count - 1))
        }
        normalizeTabPresentation()
        return removed
    }
    
    /// Closes all unlocked tabs situated to the right of the specified window. Returns the removed window IDs.
    @discardableResult
    public mutating func closeWindowsToRight(of windowId: WindowId) -> [WindowId] {
        guard let idx = windowIds.firstIndex(of: windowId) else { return [] }
        var removed: [WindowId] = []
        var retained: [WindowId] = []
        for (i, id) in windowIds.enumerated() {
            if i <= idx || isLocked(id) {
                retained.append(id)
            } else {
                removed.append(id)
            }
        }
        windowIds = retained
        if let newActiveIdx = windowIds.firstIndex(of: windowId) {
            activeWindowIndex = newActiveIdx
        } else {
            activeWindowIndex = max(0, min(activeWindowIndex, windowIds.count - 1))
        }
        normalizeTabPresentation()
        return removed
    }
}

public typealias StripColumn = WindowColumn

/// User-configurable window placement policy per application bundle identifier.
public enum AppRulePolicy: Codable, Sendable, Equatable {
    case alwaysFloat
    case alwaysTile
    case fixedSlot(Int)
}

public struct AppWindowRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var policy: AppRulePolicy
    
    public init(bundleIdentifier: String, policy: AppRulePolicy) {
        self.bundleIdentifier = bundleIdentifier
        self.policy = policy
    }
}

/// Low-level window placement descriptor for WindowController actuation and Z-ordering.
public struct WindowPlacement: @unchecked Sendable {
    public let windowId: WindowId
    public let axElement: AXUIElement
    public let cgWindowID: UInt32
    public let targetFrame: CGRect
    
    public init(windowId: WindowId, axElement: AXUIElement, cgWindowID: UInt32, targetFrame: CGRect) {
        self.windowId = windowId
        self.axElement = axElement
        self.cgWindowID = cgWindowID
        self.targetFrame = targetFrame
    }
}

/// Identifies a unique workspace strip scoped to a specific display and virtual space.
public struct WorkspaceKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let displayId: CGDirectDisplayID
    public let spaceId: UInt64
    public let workspaceIndex: Int
    
    public init(displayId: CGDirectDisplayID, spaceId: UInt64 = 1, workspaceIndex: Int = 1) {
        self.displayId = displayId
        self.spaceId = spaceId
        self.workspaceIndex = workspaceIndex
    }
    
    public var description: String {
        "Workspace(Display: \(displayId), Space: \(spaceId), Slot: \(workspaceIndex))"
    }
    
    public var storageKey: String {
        "\(displayId)_\(spaceId)_\(workspaceIndex)"
    }
}

// MARK: - Persistence Models

/// Metadata signature used to identify windows across application restarts.
public struct WindowSignature: Hashable, Codable, Sendable {
    public var bundleIdentifier: String
    public var appName: String
    public var title: String?
    
    public init(bundleIdentifier: String, appName: String, title: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
    }
}

/// A serialized column preserving width, tab grouping and member window signatures.
public struct SavedColumn: Codable, Sendable, Equatable {
    public var width: CGFloat
    public var windowSignatures: [WindowSignature]
    /// `.tabbed` when the column was a browser-style tab group.
    public var presentationMode: ColumnPresentationMode?
    /// The tab that was active when the layout was saved.
    public var activeWindowIndex: Int?
    /// Whether the tab bar was explicitly pinned for a single-window group.
    public var tabBarPinned: Bool?
    public var customGroupName: String?
    public var customColorHex: String?
    public var isCollapsed: Bool?
    public var lockedWindowIndices: [Int]?
    public var customTabTitlesBySignature: [String: String]?
    
    public init(
        width: CGFloat,
        windowSignatures: [WindowSignature],
        presentationMode: ColumnPresentationMode? = nil,
        activeWindowIndex: Int? = nil,
        tabBarPinned: Bool? = nil,
        customGroupName: String? = nil,
        customColorHex: String? = nil,
        isCollapsed: Bool? = nil,
        lockedWindowIndices: [Int]? = nil,
        customTabTitlesBySignature: [String: String]? = nil
    ) {
        self.width = width
        self.windowSignatures = windowSignatures
        self.presentationMode = presentationMode
        self.activeWindowIndex = activeWindowIndex
        self.tabBarPinned = tabBarPinned
        self.customGroupName = customGroupName
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.lockedWindowIndices = lockedWindowIndices
        self.customTabTitlesBySignature = customTabTitlesBySignature
    }
}

/// Persisted state for a specific display and space strip.
public struct SavedSpaceLayout: Codable, Sendable, Equatable {
    public var columns: [SavedColumn]
    public var focusedColumnIndex: Int?
    public var viewportOffset: CGFloat
    
    public init(columns: [SavedColumn], focusedColumnIndex: Int? = nil, viewportOffset: CGFloat = 0.0) {
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.viewportOffset = viewportOffset
    }
}

/// Top-level persisted state across all displays and spaces.
public struct PersistedLayoutState: Codable, Sendable, Equatable {
    public var spaces: [String: SavedSpaceLayout]
    
    public init(spaces: [String: SavedSpaceLayout] = [:]) {
        self.spaces = spaces
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

// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:KineticScrollingProfile]
// Description: KineticScrollingProfile enumeration defining the 4 physics deceleration curves.
/// Physics simulation profile governing kinetic, inertial, and momentum deceleration curves.
public enum KineticScrollingProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Classic exponential velocity decay matching standard macOS trackpad deceleration.
    case natural = "natural"
    /// Aerodynamic fluid resistance: brakes fast at high velocity, coasts softly at low velocity.
    case viscous = "viscous"
    /// Low friction momentum conservation for extended sweeps across wide multi-window strips.
    case highInertia = "highInertia"
    /// Linear plus exponential arrest for immediate, crisp stopping with zero drift.
    case snappy = "snappy"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .natural: return "Natural (macOS)"
        case .viscous: return "Viscous Fluid"
        case .highInertia: return "High Inertia (Glide)"
        case .snappy: return "Snappy Brake"
        }
    }

    public var description: String {
        switch self {
        case .natural:
            return "Classic exponential decay with uniform deceleration rate."
        case .viscous:
            return "Quadratic aerodynamic resistance that arrests fast flicks while keeping low speeds smooth."
        case .highInertia:
            return "Extended momentum conservation for effortless navigation across many monitors and windows."
        case .snappy:
            return "Crisp linear braking for rapid stopping without lingering drift."
        }
    }
}
// [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:KineticScrollingProfile]

/// Visual treatment used when the active tab changes inside a tab group.
public enum TabSwitchEffect: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The highlight glides between tabs on a spring.
    case slide = "Slide"
    /// The highlight gently fades from the old tab to the new one.
    case crossfade = "Crossfade"
    /// A springy highlight with an accent glow.
    case springPop = "Spring Pop"
    /// No motion; the highlight jumps immediately.
    case none = "Instant"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .slide:
            return "The active highlight glides between tabs along the strip."
        case .crossfade:
            return "The old highlight fades out while the new one fades in."
        case .springPop:
            return "A bouncier spring with a soft accent glow on the active tab."
        case .none:
            return "Switches tabs with no animation at all."
        }
    }
}

/// Visual treatment used when a tab opens, closes, or a whole tab bar appears
/// and disappears.
public enum TabOpenCloseEffect: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Tabs pop in and out with a scale and fade.
    case scaleFade = "Scale & Fade"
    /// Tabs slide in from the leading edge and out toward the trailing edge.
    case slide = "Slide"
    /// Tabs crossfade in place.
    case fade = "Fade"
    /// Tabs condense out of a soft blur.
    case materialize = "Materialize"
    /// No open/close animation.
    case none = "Instant"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .scaleFade:
            return "Tabs grow in and shrink away with a soft fade."
        case .slide:
            return "Tabs slide in from the leading edge and out toward the trailing edge."
        case .fade:
            return "Tabs gently crossfade in place."
        case .materialize:
            return "Tabs resolve out of a soft blur with a slight scale."
        case .none:
            return "Tabs appear and disappear instantly."
        }
    }
}

/// User preference policy for automatically grouping newly discovered or opened windows.
public enum SmartGroupingPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case sameApp = "sameApp"
    case manualOnly = "manualOnly"
    case askOnNewWindow = "askOnNewWindow"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .sameApp: return "Auto-Group Same Application"
        case .manualOnly: return "Manual Only (Drag or Shortcut)"
        case .askOnNewWindow: return "Ask / Follow Window Rules"
        }
    }
}


