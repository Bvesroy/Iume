import AppKit
import SwiftUI
import Combine

/// One column's identity as presented on the dial. Kept `Equatable` and free of AppKit types so
/// the published state stays cheap to diff during 120 Hz scrolling.
public struct DialColumnInfo: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var width: CGFloat
    public var windowCount: Int
    public var title: String
    public var appName: String
    public var bundleIdentifier: String

    public init(
        id: UUID,
        width: CGFloat,
        windowCount: Int,
        title: String,
        appName: String,
        bundleIdentifier: String
    ) {
        self.id = id
        self.width = width
        self.windowCount = windowCount
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Model passed to the dial view to render the strip state.
public struct MinimapState: Equatable, Sendable {
    public var columns: [DialColumnInfo]
    public var columnGeometries: [DialColumnGeometry]
    public var totalStripWidth: CGFloat
    public var viewportOffset: CGFloat
    public var visibleWidth: CGFloat
    public var focusedIndex: Int
    public var activeTitle: String
    public var gap: CGFloat
    /// Bumped whenever a newly-discovered app icon finishes loading, forcing a redraw.
    public var iconEpoch: Int

    public init(
        columns: [DialColumnInfo] = [],
        totalStripWidth: CGFloat = 0,
        viewportOffset: CGFloat = 0,
        visibleWidth: CGFloat = 0,
        focusedIndex: Int = 0,
        activeTitle: String = "",
        gap: CGFloat = 0,
        iconEpoch: Int = 0
    ) {
        self.columns = columns
        self.columnGeometries = DialGeometry.columnGeometries(widths: columns.map(\.width), gap: gap)
        self.totalStripWidth = totalStripWidth
        self.viewportOffset = viewportOffset
        self.visibleWidth = visibleWidth
        self.focusedIndex = focusedIndex
        self.activeTitle = activeTitle
        self.gap = gap
        self.iconEpoch = iconEpoch
    }
}

/// What the pointer is currently doing to the dial.
public enum DialInteraction: Equatable {
    case idle
    /// Hovering a column tick.
    case hovering(column: Int)
    /// Scrubbing the viewport offset directly via the ring.
    case scrubbing
    /// A column has been lifted and is following the pointer.
    case dragging(column: Int, insertionIndex: Int)
}

/// Native AppKit hosting view that guarantees 100% reliable mouse clicks, drags, hover, and hit-testing
/// for all minimap HUD styles inside non-activating floating panels.
public final class HUDHostingView: NSHostingView<AnyView> {
    public weak var controller: MinimapHUDController?
    private var trackingArea: NSTrackingArea?

    private var dragStartPoint: CGPoint = .zero
    private var lastHoverPoint: CGPoint = CGPoint(x: -9999, y: -9999)
    private var draggedColumn: Int?
    private var isScrubbing: Bool = false
    private var hasDraggedBeyondSlop: Bool = false
    private var hasPlayedGrabCue: Bool = false

    // Relative-drag styles (tape, 3D carousel) move the strip by the distance travelled from
    // the grab point, so scrubbing stays 1:1 while the focus slides underneath.
    private var scrubAnchorPoint: CGPoint = .zero
    private var scrubAnchorRatio: Double = 0
    private var scrubRatioPerPoint: Double = 0.0005

    /// By returning `true`, macOS delivers `mouseDown` directly to this view on the very first click,
    /// rather than treating it as an activation click and swallowing it.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    /// All hit-testing maths here uses AppKit's y-up space ((0,0) at bottom-left). The SwiftUI
    /// hosting view is *flipped* (y grows downward), so `hitTest` and `localPoint(for:)`
    /// normalise every incoming point at the boundary. Do not pass raw AppKit-local points to
    /// `ratio(for:)`, `columnTickHit(at:)`, `isTrackHit(at:)` or `hoverTarget(at:)`.

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        self.trackingArea = ta
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let raw = superview != nil ? convert(point, from: superview) : convert(point, from: nil)
        // `NSHostingView` is flipped (SwiftUI's y grows downward), while every geometry formula
        // in this view is written in AppKit's y-up space. Normalise at the boundary.
        let local = isFlipped ? CGPoint(x: raw.x, y: bounds.height - raw.y) : raw
        guard let controller = controller else { return nil }

        // While a drag or scrub is in flight, keep capturing all events until mouse up so the
        // gesture survives the pointer leaving the dial. Hovering must NOT do this — otherwise
        // the transparent corners of the square panel would swallow clicks aimed at the windows
        // underneath the moment the pointer crosses a column tick.
        switch controller.interaction {
        case .scrubbing, .dragging:
            return self
        case .idle, .hovering:
            break
        }

        let style = SettingsStore.shared.hudStyle
        switch style {
        case .semicircle:
            // The visible glass is a half ellipse whose flat base sits on the panel's bottom
            // edge. Only that dome is interactive; the transparent corners stay click-through.
            let nx = (local.x - bounds.midX) / max(1, bounds.width / 2.0)
            let ny = local.y / max(1, bounds.height)
            if nx * nx + ny * ny <= 1.06 {
                return self
            }
            return nil

        case .circularDial, .orbitalRing, .turntableDisc:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = local.x - center.x
            let dy = local.y - center.y
            let distSq = dx * dx + dy * dy
            let maxRadius = (MinimapHUDController.dialDiameter / 2.0) + 14.0
            if distSq <= maxRadius * maxRadius {
                return self
            }
            return nil

        case .linearStrip:
            if bounds.insetBy(dx: 2, dy: 2).contains(local) {
                return self
            }
            return nil

        case .timeline, .spectrum, .edgeRail, .tape, .loop3D:
            if bounds.insetBy(dx: 2, dy: 2).contains(local) {
                return self
            }
            return nil
        }
    }

    /// Mouse location in this view's geometry space (origin bottom-left). `NSHostingView` is
    /// flipped, so `convert(_:from:)` alone would hand back a y-down point and every angle,
    /// elliptical radius and band test below would be mirrored.
    private func localPoint(for event: NSEvent) -> CGPoint {
        let raw = convert(event.locationInWindow, from: nil)
        return isFlipped ? CGPoint(x: raw.x, y: bounds.height - raw.y) : raw
    }

    public override func mouseDown(with event: NSEvent) {
        guard let controller = controller else {
            super.mouseDown(with: event)
            return
        }
        let loc = localPoint(for: event)
        dragStartPoint = loc
        hasDraggedBeyondSlop = false
        hasPlayedGrabCue = false
        controller.clearDragPointer()
        // Keep the panel's background from ever being treated as a window-drag surface: a grab
        // that starts on an orb must always resolve as a reorder, not as the panel moving.
        window?.isMovableByWindowBackground = false
        window?.makeFirstResponder(self)
        // The tape maps pointer movement to strip movement relative to where the gesture began,
        // so capture that reference before anything can move.
        prepareScrubAnchor(at: loc, controller: controller)

        if let col = columnTickHit(at: loc) {
            draggedColumn = col
            isScrubbing = false
            // No cue yet: a press that turns into a tap should make exactly one sound, and a
            // press that turns into a drag gets its "lift" cue once the movement starts.
            controller.beginDrag(column: col)
        } else if isTrackHit(at: loc) {
            draggedColumn = nil
            isScrubbing = true
            let r = ratio(for: loc)
            controller.beginScrub()
            controller.updateScrub(ratio: r)
        } else {
            draggedColumn = nil
            isScrubbing = false
            super.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let controller = controller else {
            super.mouseDragged(with: event)
            return
        }
        let loc = localPoint(for: event)
        let dist = hypot(loc.x - dragStartPoint.x, loc.y - dragStartPoint.y)
        if dist > 3.0 {
            hasDraggedBeyondSlop = true
        }

        let r = ratio(for: loc)
        let st = controller.state
        let widths = st.columns.map(\.width)

        if let col = draggedColumn {
            if hasDraggedBeyondSlop && !hasPlayedGrabCue {
                hasPlayedGrabCue = true
                HudSoundEngine.shared.play(.grab)
            }
            if hasDraggedBeyondSlop {
                controller.updateDragPointer(loc)
            }
            let insertion = DialGeometry.insertionIndex(
                atStripRatio: r,
                widths: widths,
                gap: st.gap,
                draggingIndex: col
            )
            controller.updateDrag(insertionIndex: insertion)
        } else if isScrubbing {
            controller.updateScrub(ratio: r)
        } else {
            super.mouseDragged(with: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let controller = controller else {
            super.mouseUp(with: event)
            return
        }
        let loc = localPoint(for: event)
        let r = ratio(for: loc)

        if let col = draggedColumn {
            controller.clearDragPointer()
            if !hasDraggedBeyondSlop {
                // Quick tap/click without significant dragging -> focus window.
                // The drag state has to be cleared explicitly, otherwise the dial stays latched
                // in `.dragging` and never auto-hides again.
                controller.cancelDrag()
                controller.selectColumn(col)
            } else {
                // Drop to reorder. The insertion index is recomputed from the *release* position
                // so the column lands where the pointer actually was released.
                let insertion = DialGeometry.insertionIndex(
                    atStripRatio: r,
                    widths: controller.state.columns.map(\.width),
                    gap: controller.state.gap,
                    draggingIndex: col
                )
                controller.updateDrag(insertionIndex: insertion)
                controller.endDrag(commit: true)
            }
            draggedColumn = nil
        } else if isScrubbing {
            controller.endScrub(ratio: r)
            HudSoundEngine.shared.play(.snap)
            isScrubbing = false
        } else {
            super.mouseUp(with: event)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let controller = controller else { return }
        let loc = localPoint(for: event)
        let dx = loc.x - lastHoverPoint.x
        let dy = loc.y - lastHoverPoint.y
        if (dx * dx + dy * dy) < 1.5 {
            return
        }
        lastHoverPoint = loc
        if let col = hoverTarget(at: loc) {
            if case .hovering(let cur) = controller.interaction, cur == col {
                // Already hovering this column
            } else {
                controller.beginHover(column: col)
                HudSoundEngine.shared.play(.hover)
            }
        } else {
            controller.endHover()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        lastHoverPoint = CGPoint(x: -9999, y: -9999)
        controller?.endHover()
    }

    // MARK: - Geometry & Hit Calculations

    public func ratio(for local: CGPoint) -> Double {
        let style = SettingsStore.shared.hudStyle
        switch style {
        case .semicircle:
            let viewY = bounds.height - local.y
            return MinimapHorizonEllipseView.ratio(
                for: CGPoint(x: local.x, y: viewY)
            )

        case .circularDial, .orbitalRing, .turntableDisc:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = Double(local.x - center.x)
            let dySwiftUI = -Double(local.y - center.y)
            let angle = DialGeometry.normalizeAngle(atan2(dySwiftUI, dx) * 180.0 / Double.pi)
            return DialGeometry.stripRatio(forAngleDegrees: angle)

        case .linearStrip:
            let trackLeft: CGFloat = 14.0
            let trackWidth = bounds.width - 28.0
            guard trackWidth > 0 else { return 0.0 }
            let r = Double((local.x - trackLeft) / trackWidth)
            return min(1.0, max(0.0, r))

        case .timeline:
            guard MinimapTimelineView.trackWidth > 0 else { return 0 }
            let r = Double((local.x - MinimapTimelineView.insetX) / MinimapTimelineView.trackWidth)
            return min(1, max(0, r))

        case .spectrum:
            let st = controller?.state
            let geometries = st?.columnGeometries ?? []
            let frames = MinimapSpectrumView.barFrames(count: geometries.count)
            guard !frames.isEmpty else { return 0 }
            return min(1, max(0, MinimapSpectrumView.ratio(forX: local.x, geometries: geometries, frames: frames)))

        case .edgeRail:
            let st = controller?.state
            let geometries = st?.columnGeometries ?? []
            let frames = MinimapEdgeRailView.rowFrames(count: geometries.count)
            guard !frames.isEmpty else { return 0 }
            let viewY = bounds.height - local.y
            return min(1, max(0, MinimapEdgeRailView.ratio(forY: viewY, geometries: geometries, frames: frames)))

        case .tape, .loop3D:
            let moved = Double(local.x - scrubAnchorPoint.x) * scrubRatioPerPoint
            return min(1, max(0, scrubAnchorRatio + moved))
        }
    }

    /// Records the strip ratio under the pointer when a relative-drag gesture begins. Without this
    /// the mapping would shift every frame as the focus follows the scrub, fighting the pointer.
    private func prepareScrubAnchor(at loc: CGPoint, controller: MinimapHUDController) {
        let st = controller.state
        let geometries = st.columnGeometries
        guard !geometries.isEmpty else { return }

        switch SettingsStore.shared.hudStyle {
        case .tape:
            let layout = MinimapTapeView.layout(
                columnCount: geometries.count,
                viewportCentreRatio: MinimapTapeView.viewportCentreRatio(of: st)
            )
            scrubAnchorPoint = loc
            scrubAnchorRatio = layout.ratio(atX: loc.x)
            scrubRatioPerPoint = layout.ratioPerPoint

        case .loop3D:
            // The front of the drum is the viewport centre, so a drag anywhere turns the drum
            // from where it currently stands — exactly like pushing a physical wheel.
            scrubAnchorPoint = loc
            scrubAnchorRatio = MinimapTapeView.viewportCentreRatio(of: st)
            scrubRatioPerPoint = LoopCarouselGeometry.scrubRatioPerPoint(
                count: geometries.count,
                panelWidth: bounds.width
            )

        default:
            break
        }
    }

    public func columnTickHit(at local: CGPoint) -> Int? {
        guard let controller = controller else { return nil }
        let st = controller.state
        let geometries = st.columnGeometries
        guard !geometries.isEmpty else { return nil }

        let style = SettingsStore.shared.hudStyle
        switch style {
        case .semicircle:
            return ellipseColumnHit(at: local, geometries: geometries)

        case .circularDial, .orbitalRing, .turntableDisc:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = Double(local.x - center.x)
            let dy = Double(local.y - center.y)
            let dist = hypot(dx, dy)
            // The orb/tick band, not the whole disc: the core readout and the space between the
            // gaps must stay click-through, or the panel would swallow clicks aimed underneath.
            let outer = MinimapHUDController.dialTrackRadius + 16.0
            let inner = MinimapHUDController.dialCoreRadius + 8.0
            guard dist <= outer, dist >= inner else { return nil }

            let angle = DialGeometry.normalizeAngle(atan2(-dy, dx) * 180.0 / Double.pi)
            // Nearest column wins: taking the first one inside the tolerance collapses to the
            // left-most window as soon as columns are packed tighter than the tolerance.
            var bestIndex: Int?
            var bestDelta: Double = .greatestFiniteMagnitude
            for geo in geometries {
                let tickAngle = DialGeometry.angle(forStripRatio: geo.centerRatio)
                let diff = abs(DialGeometry.normalizeAngle(angle - tickAngle))
                let shortestDiff = min(diff, 360.0 - diff)
                if shortestDiff < bestDelta {
                    bestDelta = shortestDiff
                    bestIndex = geo.index
                }
            }
            return bestDelta <= 14.0 ? bestIndex : nil

        case .linearStrip:
            return linearColumn(at: local)

        case .timeline:
            return barColumnHit(
                at: local,
                frames: MinimapTimelineView.segmentFrames(for: geometries),
                geometries: geometries,
                bandTop: MinimapTimelineView.trackTop - 8,
                bandBottom: MinimapTimelineView.trackTop + MinimapTimelineView.trackHeight + 8
            )

        case .spectrum:
            return barColumnHit(
                at: local,
                frames: MinimapSpectrumView.barFrames(count: geometries.count),
                geometries: geometries,
                bandTop: MinimapSpectrumView.barsTop - 6,
                bandBottom: MinimapSpectrumView.baselineY + 8
            )

        case .edgeRail:
            return rowColumnHit(
                at: local,
                frames: MinimapEdgeRailView.rowFrames(count: geometries.count),
                geometries: geometries
            )

        case .tape:
            return iconColumnHit(
                at: local,
                frames: MinimapTapeView.iconFrames(
                    geometries: geometries,
                    viewportCentreRatio: MinimapTapeView.viewportCentreRatio(of: st)
                ),
                geometries: geometries
            )

        case .loop3D:
            let cards = LoopCarouselGeometry.cards(
                count: geometries.count,
                focusedIndex: st.focusedIndex,
                panelWidth: bounds.width
            )
            // Cards are laid out in SwiftUI space (y down); hit points arrive y up.
            let viewPoint = CGPoint(x: local.x, y: bounds.height - local.y)
            return LoopCarouselGeometry.columnIndex(at: viewPoint, cards: cards)
        }
    }

    /// Horizontally laid-out instruments: nearest column centre inside a vertical band.
    private func barColumnHit(
        at local: CGPoint,
        frames: [CGRect],
        geometries: [DialColumnGeometry],
        bandTop: CGFloat,
        bandBottom: CGFloat
    ) -> Int? {
        guard frames.count == geometries.count else { return nil }
        let viewY = bounds.height - local.y
        guard viewY >= bandTop, viewY <= bandBottom else { return nil }

        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (position, frame) in frames.enumerated() {
            let distance = abs(local.x - frame.midX)
            // Narrow columns keep a generous target; overlap resolves to the nearest centre.
            let tolerance = max(frame.width / 2, 9) + 2
            guard distance <= tolerance else { continue }
            if distance < bestDistance {
                bestDistance = distance
                best = geometries[position].index
            }
        }
        return best
    }

    /// Vertical rail: nearest row centre under the pointer.
    private func rowColumnHit(
        at local: CGPoint,
        frames: [CGRect],
        geometries: [DialColumnGeometry]
    ) -> Int? {
        guard frames.count == geometries.count else { return nil }
        let viewY = bounds.height - local.y
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (position, frame) in frames.enumerated() {
            guard local.x >= frame.minX - 4, local.x <= frame.maxX + 4 else { continue }
            let distance = abs(viewY - frame.midY)
            guard distance <= frame.height / 2 + 3 else { continue }
            if distance < bestDistance {
                bestDistance = distance
                best = geometries[position].index
            }
        }
        return best
    }

    /// Tape: nearest app icon under the pointer.
    private func iconColumnHit(
        at local: CGPoint,
        frames: [CGRect],
        geometries: [DialColumnGeometry]
    ) -> Int? {
        guard frames.count == geometries.count else { return nil }
        let viewY = bounds.height - local.y
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (position, frame) in frames.enumerated() {
            let distance = hypot(local.x - frame.midX, viewY - frame.midY)
            guard distance <= 18 else { continue }
            if distance < bestDistance {
                bestDistance = distance
                best = geometries[position].index
            }
        }
        return best
    }

    /// Half-ellipse hit resolution: the orb itself first (a generous circular target), then the
    /// elliptical band around the track, where the nearest column angle within a small tolerance
    /// wins. This makes the whole drawn arc of a column grabbable, not just its orb.
    private func ellipseColumnHit(at local: CGPoint, geometries: [DialColumnGeometry]) -> Int? {
        let viewPoint = CGPoint(x: local.x, y: bounds.height - local.y)

        var bestOrbIndex: Int?
        var bestOrbDistance: CGFloat = .greatestFiniteMagnitude
        for geo in geometries {
            let center = MinimapHorizonEllipseView.point(for: geo.centerRatio)
            let distance = hypot(viewPoint.x - center.x, viewPoint.y - center.y)
            if distance < bestOrbDistance {
                bestOrbDistance = distance
                bestOrbIndex = geo.index
            }
        }
        if bestOrbDistance <= 18.0 {
            return bestOrbIndex
        }

        // Track band. 1.0 is the drawn centreline. The band is tight enough to exclude the
        // readout capsule nested inside the dome: normalised radius grows quickly near the base
        // centre, so a wider band would turn clicks on the readout into column drags.
        let rho = MinimapHorizonEllipseView.normalizedRadius(of: viewPoint)
        guard rho >= 0.90, rho <= 1.10 else { return nil }

        let angle = MinimapHorizonEllipseView.angleDegrees(of: viewPoint)
        var bestBandIndex: Int?
        var bestDelta = Double.greatestFiniteMagnitude
        for geo in geometries {
            let tick = MinimapHorizonEllipseView.angle(forStripRatio: geo.centerRatio)
            let diff = abs(DialGeometry.normalizeAngle(angle - tick))
            let shortestDiff = min(diff, 360.0 - diff)
            if shortestDiff < bestDelta {
                bestDelta = shortestDiff
                bestBandIndex = geo.index
            }
        }
        return bestDelta <= 10.0 ? bestBandIndex : nil
    }

    /// The column whose pill sits under a point on the linear strip's track.
    ///
    /// Mirrors the pill layout in `MinimapLinearView` exactly so the hit targets line up with
    /// what is drawn.
    public func linearColumn(at local: CGPoint) -> Int? {
        guard let st = controller?.state, !st.columns.isEmpty else { return nil }
        let trackLeft: CGFloat = 14.0
        let trackWidth = bounds.width - 28.0
        guard trackWidth > 0 else { return nil }

        let count = st.columns.count
        let spacing: CGFloat = 3.0
        let pillSpace = trackWidth - CGFloat(count) * spacing
        var cursor = trackLeft
        for (idx, column) in st.columns.enumerated() {
            let fraction = column.width / max(1.0, st.totalStripWidth)
            let pillWidth = max(8, fraction * pillSpace)
            if local.x >= cursor && local.x <= cursor + pillWidth {
                return idx
            }
            cursor += pillWidth + spacing
        }
        return nil
    }

    /// The column the pointer is pointing at, for hover highlighting.
    public func hoverTarget(at local: CGPoint) -> Int? {
        switch SettingsStore.shared.hudStyle {
        case .linearStrip:
            return linearColumn(at: local)
        case .semicircle, .circularDial, .orbitalRing, .turntableDisc, .timeline, .spectrum, .edgeRail, .tape, .loop3D:
            return columnTickHit(at: local)
        }
    }

    public func isTrackHit(at local: CGPoint) -> Bool {
        let style = SettingsStore.shared.hudStyle
        switch style {
        case .semicircle:
            let viewPoint = CGPoint(x: local.x, y: bounds.height - local.y)
            let rho = MinimapHorizonEllipseView.normalizedRadius(of: viewPoint)
            return rho >= 0.90 && rho <= 1.10

        case .circularDial, .orbitalRing, .turntableDisc:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dist = hypot(local.x - center.x, local.y - center.y)
            return dist >= MinimapHUDController.dialCoreRadius + 10.0 && dist <= MinimapHUDController.dialTrackRadius + 16.0

        case .linearStrip:
            return bounds.insetBy(dx: 12, dy: 8).contains(local)

        case .timeline:
            let viewY = bounds.height - local.y
            return viewY >= 20 && viewY <= 84 && local.x >= 10 && local.x <= bounds.width - 10

        case .spectrum:
            let viewY = bounds.height - local.y
            return viewY >= 30 && viewY <= 116 && local.x >= 10 && local.x <= bounds.width - 10

        case .edgeRail:
            let viewY = bounds.height - local.y
            let bottom = bounds.height - MinimapEdgeRailView.bottomPadding
            return viewY >= MinimapEdgeRailView.headerHeight - 8 && viewY <= bottom + 8

        case .tape:
            let viewY = bounds.height - local.y
            return viewY >= MinimapTapeView.topRailY - 8 && viewY <= MinimapTapeView.bottomRailY + 12

        case .loop3D:
            let viewY = bounds.height - local.y
            return viewY >= 54 && viewY <= bounds.height - 6
                && local.x >= 14 && local.x <= bounds.width - 14
        }
    }
}

/// Floating Minimap HUD Controller managing multiple display styles (Semicircle dome, Circular dial, Linear bar).
/// Provides real-time strip visualization, 1:1 scrubbing, tick grabbing, and drag-and-drop window reordering.
@MainActor
public final class MinimapHUDController: ObservableObject {
    public static let shared = MinimapHUDController()

    /// Diameter of the circular dial artwork.
    public nonisolated static let dialDiameter: CGFloat = 220
    /// Centreline radius of the column track. Artwork and hit-testing both derive from this.
    public nonisolated static let dialTrackRadius: CGFloat = 88
    /// Radius of the centre readout well.
    public nonisolated static let dialCoreRadius: CGFloat = 47
    /// Panel side for the circular dial mode.
    public nonisolated static let panelSide: CGFloat = 300

    private var panel: NSPanel?
    private var hostingView: HUDHostingView?
    private var hideTimer: Timer?
    private var iconCache: [String: NSImage] = [:]
    private var cancellables = Set<AnyCancellable>()
    private weak var lastTargetScreen: NSScreen?

    @Published public private(set) var state = MinimapState()
    @Published public private(set) var interaction: DialInteraction = .idle
    /// Latest pointer position in the hosting view's AppKit coordinates while a column drag is
    /// in flight. The half-ellipse HUD draws a ghost orb at this point.
    @Published public private(set) var dragPointer: CGPoint?

    /// Set by WorkspaceManager. Invoked with a 0...1 ratio across the strip's scrollable range.
    public var onScrub: ((Double) -> Void)?
    /// Invoked when a scrub gesture ends, carrying the 0...1 ratio it landed on.
    public var onScrubEnded: ((Double) -> Void)?
    /// Invoked when a column tick is clicked without dragging.
    public var onSelectColumn: ((Int) -> Void)?
    /// Invoked when a dragged column is dropped.
    ///
    /// `fromIndex` is the column's index in the *current* ordering; `toIndex` is its index in
    /// the *resulting* ordering, i.e. the position the column was lifted out of and dropped into.
    public var onMoveColumn: ((Int, Int) -> Void)?

    /// The dial is a singleton: the panel hosts a view that observes the controller, so a
    /// second instance would retain itself in a cycle and leak for the life of the process.
    private init() {
        setupPanel()
    }

    private func setupPanel() {
        let style = SettingsStore.shared.hudStyle
        let size = panelSize(for: style)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.isFloatingPanel = true
        p.hasShadow = false
        p.alphaValue = 0.0
        // `.transient` removes a panel from the screen whenever its app deactivates. Iume is a
        // background window manager: focusing another app is routine, and a transient HUD would
        // blink out (then be re-shown by the next scroll update) every time that happened.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = false

        let host = HUDHostingView(rootView: makeRootView(for: style))
        host.controller = self
        // The dial artwork is smaller than the panel so its shadow, the drag chip and the
        // overhanging readouts have room. Without this, the hosting view publishes the root
        // view's fixed 220pt frame as the window's min/max size and the panel collapses onto
        // the dial, clipping everything that sits outside it.
        host.sizingOptions = []
        p.contentView = host
        p.setContentSize(size)

        self.panel = p
        self.hostingView = host

        SettingsStore.shared.$hudStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.reconfigureStyle(newStyle)
            }
            .store(in: &cancellables)

        SettingsStore.shared.$showMinimapHUD
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShown in
                if !isShown {
                    self?.hideImmediately()
                }
            }
            .store(in: &cancellables)
    }

    public func reconfigureStyle(_ style: MinimapHUDStyle = SettingsStore.shared.hudStyle) {
        guard let host = hostingView else { return }
        host.rootView = makeRootView(for: style)
        if let s = lastTargetScreen ?? NSScreen.main ?? NSScreen.screens.first {
            positionPanel(on: s, for: style)
        }
        host.updateTrackingAreas()
    }

    private func makeRootView(for style: MinimapHUDStyle) -> AnyView {
        switch style {
        case .semicircle:
            return AnyView(MinimapHorizonEllipseView(controller: self))
        case .circularDial:
            return AnyView(MinimapHUDView(controller: self))
        case .orbitalRing:
            return AnyView(MinimapOrbitalRingView(controller: self))
        case .turntableDisc:
            return AnyView(MinimapTurntableDiscView(controller: self))
        case .linearStrip:
            return AnyView(MinimapLinearView(controller: self))
        case .timeline:
            return AnyView(MinimapTimelineView(controller: self))
        case .spectrum:
            return AnyView(MinimapSpectrumView(controller: self))
        case .edgeRail:
            return AnyView(MinimapEdgeRailView(controller: self))
        case .tape:
            return AnyView(MinimapTapeView(controller: self))
        case .loop3D:
            return AnyView(MinimapLoopCarouselView(controller: self))
        }
    }

    public func panelSize(for style: MinimapHUDStyle) -> NSSize {
        switch style {
        case .semicircle:
            return NSSize(width: MinimapHorizonEllipseView.panelWidth, height: MinimapHorizonEllipseView.panelHeight)
        case .circularDial, .orbitalRing, .turntableDisc:
            return NSSize(width: Self.panelSide, height: Self.panelSide)
        case .linearStrip:
            return NSSize(width: MinimapLinearView.panelWidth, height: MinimapLinearView.panelHeight)
        case .timeline:
            return NSSize(width: MinimapTimelineView.panelWidth, height: MinimapTimelineView.panelHeight)
        case .spectrum:
            return NSSize(width: MinimapSpectrumView.panelWidth, height: MinimapSpectrumView.panelHeight)
        case .edgeRail:
            return NSSize(
                width: MinimapEdgeRailView.panelWidth,
                height: MinimapEdgeRailView.panelHeight(for: state.columns.count)
            )
        case .tape:
            return NSSize(width: MinimapTapeView.panelWidth, height: MinimapTapeView.panelHeight)
        case .loop3D:
            return NSSize(width: MinimapLoopCarouselView.panelWidth, height: MinimapLoopCarouselView.panelHeight)
        }
    }

    private var lastScreenId: CGDirectDisplayID?
    private var lastActivityTime: CFTimeInterval = 0
    private var lastStateUpdateTime: CFTimeInterval = 0
    /// Identifies the current visibility animation. Bumped only when the panel is shown or torn
    /// down, so a stale fade-out completion can never order out a panel that has just been
    /// revealed again. (The old code bumped this on *every* update, which could leave the panel
    /// alive at alpha 0 and still swallowing clicks.)
    private var presentationToken: Int = 0
    private var isFadingIn: Bool = false
    /// True from the moment a fade-out starts until its completion runs. `alphaValue` during
    /// that animation is the in-flight value, not the target, so the alpha check alone would
    /// let `present()` think the panel is still fully visible and skip cancelling the fade.
    private var isFadingOut: Bool = false

    public func update(
        columns: [WindowColumn],
        totalStripWidth: CGFloat,
        viewportOffset: CGFloat,
        visibleWidth: CGFloat,
        focusedIndex: Int?,
        activeTitle: String,
        screen: NSScreen?,
        gap: CGFloat = 0,
        isSettling: Bool = false,
        reveal: Bool = false
    ) {
        let dialCols = columns.map { col in
            DialColumnInfo(
                id: col.id,
                width: col.width,
                windowCount: col.windowIds.count,
                title: activeTitle,
                appName: "",
                bundleIdentifier: ""
            )
        }
        update(
            columns: dialCols,
            totalStripWidth: totalStripWidth,
            viewportOffset: viewportOffset,
            visibleWidth: visibleWidth,
            focusedIndex: focusedIndex,
            activeTitle: activeTitle,
            screen: screen,
            gap: gap,
            isSettling: isSettling,
            reveal: reveal
        )
    }

    public func update(
        columns: [DialColumnInfo],
        totalStripWidth: CGFloat,
        viewportOffset: CGFloat,
        visibleWidth: CGFloat,
        focusedIndex: Int?,
        activeTitle: String,
        screen: NSScreen?,
        gap: CGFloat = 0,
        isSettling: Bool = false,
        reveal: Bool = false
    ) {
        guard SettingsStore.shared.showMinimapHUD else {
            hideImmediately()
            return
        }

        let now = CACurrentMediaTime()

        // Refresh app icons for any column whose bundle we haven't drawn yet.
        var iconEpoch = state.iconEpoch
        for col in columns where !col.bundleIdentifier.isEmpty && iconCache[col.bundleIdentifier] == nil {
            if let icon = Self.loadIcon(for: col.bundleIdentifier) {
                iconCache[col.bundleIdentifier] = icon
                iconEpoch &+= 1
            }
        }

        let newFocusedIndex = focusedIndex ?? 0

        // Throttle SwiftUI state updates to ~30 FPS during live scrolling to avoid frame drops.
        let timeSinceLastUpdate = now - lastStateUpdateTime
        let shouldThrottle = !isSettling && timeSinceLastUpdate < 0.033

        let shouldUpdateState = !shouldThrottle && (
            abs(state.viewportOffset - viewportOffset) >= 0.75 ||
            state.focusedIndex != newFocusedIndex ||
            state.activeTitle != activeTitle ||
            state.columns != columns ||
            abs(state.totalStripWidth - totalStripWidth) >= 1.0 ||
            state.iconEpoch != iconEpoch ||
            isSettling
        )

        if shouldUpdateState {
            lastStateUpdateTime = now
            self.state = MinimapState(
                columns: columns,
                totalStripWidth: max(1, totalStripWidth),
                viewportOffset: viewportOffset,
                visibleWidth: max(1, visibleWidth),
                focusedIndex: newFocusedIndex,
                activeTitle: activeTitle,
                gap: gap,
                iconEpoch: iconEpoch
            )
        }

        let targetScreen = screen ?? NSScreen.main
        self.lastTargetScreen = targetScreen
        let screenId = targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let currentStyle = SettingsStore.shared.hudStyle
        let expectedSize = panelSize(for: currentStyle)

        guard let p = panel else { return }

        if let s = targetScreen, (screenId != lastScreenId || p.frame.size != expectedSize) {
            lastScreenId = screenId
            positionPanel(on: s, for: currentStyle)
        }

        // Visibility is driven only by a genuine reveal request (a scroll gesture, a settings
        // change) — or by always-visible mode. State syncs from window reflows must never fade
        // the panel back in: that was the source of the endless flicker in auto-hide mode.
        let alwaysVisible = SettingsStore.shared.hudAlwaysVisible
        if reveal || alwaysVisible {
            lastActivityTime = now
            present(animated: true)
        }
    }

    /// Fades the panel in if it is not already fully visible and, in auto-hide mode, arms the
    /// hide timer. Repeated calls while the panel is up only extend the timer.
    private func present(animated: Bool) {
        guard let p = panel else { return }
        let autoHide = !SettingsStore.shared.hudAlwaysVisible

        if p.isVisible && !isFadingOut {
            // A fade already in flight is left alone: restarting it on every 30 Hz scroll
            // update would stretch the ramp and churn animations for no visual gain.
            if isFadingIn {
                return
            }
            if p.alphaValue >= 0.99 {
                p.ignoresMouseEvents = false
                if autoHide { scheduleAutoHide() }
                return
            }
        }

        // Cancel any in-flight fade-out: the completion handler checks this token before it is
        // allowed to tear the panel down. A reveal that lands mid-fade must win, otherwise the
        // completion orders out a panel the user has just asked back.
        presentationToken &+= 1
        isFadingIn = true
        isFadingOut = false
        p.orderFront(nil)

        if animated && p.alphaValue < 0.99 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1.0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.isFadingIn = false
                    // Accept clicks only once the panel is actually visible; a panel still at
                    // near-zero alpha must not eat clicks aimed at the window underneath.
                    p.ignoresMouseEvents = false
                    if autoHide { self.scheduleAutoHide() }
                }
            })
        } else {
            p.alphaValue = 1.0
            isFadingIn = false
            p.ignoresMouseEvents = false
            if autoHide { scheduleAutoHide() }
        }
    }

    /// One timer, re-armed while the HUD is in use. It only hides after a full quiet interval
    /// with no interaction, so hover, drag and scrub gestures can never be cut short.
    private func scheduleAutoHide() {
        guard !SettingsStore.shared.hudAlwaysVisible else {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        guard let p = panel, p.isVisible else {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard self.interaction == .idle else { return }
                let quietFor = CACurrentMediaTime() - self.lastActivityTime
                guard quietFor >= 1.25 else { return }
                self.hideTimer?.invalidate()
                self.hideTimer = nil
                self.fadeOut()
            }
        }
    }

    /// Reveals the dial and, in auto-hide mode, keeps it up briefly.
    public func showWithAutohide() {
        lastActivityTime = CACurrentMediaTime()
        present(animated: true)
    }

    /// `force` exists because `@Published` emits in `willSet`: a synchronous sink that is
    /// toggling Always Visible off still reads the old `true` from the store.
    public func fadeOut(force: Bool = false) {
        guard let p = panel else { return }
        // In always-visible mode the dial only ever dims; it is never torn down.
        guard force || !SettingsStore.shared.hudAlwaysVisible else {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        hideTimer?.invalidate()
        hideTimer = nil

        // A gesture in progress owns the panel until it finishes.
        guard interaction == .idle else {
            scheduleAutoHide()
            return
        }

        guard p.isVisible, p.alphaValue > 0.01 else {
            // Defensive: a panel at alpha 0 must never stay on screen intercepting clicks.
            if p.isVisible { p.orderOut(nil) }
            p.alphaValue = 0
            p.ignoresMouseEvents = true
            isFadingOut = false
            return
        }

        isFadingIn = false
        isFadingOut = true
        presentationToken &+= 1
        let token = presentationToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.presentationToken == token else { return }
                self.isFadingOut = false
                p.orderOut(nil)
                // A torn-down panel must stop intercepting clicks meant for the windows
                // underneath it.
                p.ignoresMouseEvents = true
                p.alphaValue = 0
            }
        })
    }

    /// Tears the dial down without fading — used when the HUD setting is switched off entirely.
    public func hideImmediately() {
        guard let p = panel else { return }
        presentationToken &+= 1
        isFadingIn = false
        isFadingOut = false
        hideTimer?.invalidate()
        hideTimer = nil
        interaction = .idle
        clearDragPointer()
        p.alphaValue = 0.0
        p.orderOut(nil)
        p.ignoresMouseEvents = true
    }

    private func positionPanel(on screen: NSScreen, for style: MinimapHUDStyle = SettingsStore.shared.hudStyle) {
        guard let p = panel else { return }
        let screenFrame = screen.visibleFrame
        let size = panelSize(for: style)
        var x = screenFrame.origin.x + (screenFrame.width - size.width) / 2.0
        let y: CGFloat
        switch style {
        case .semicircle:
            y = screenFrame.origin.y // Flat base rests flush against screen bottom / dock
        case .circularDial, .orbitalRing, .turntableDisc:
            // The panel is larger than the dial so its shadow and overhanging readouts have
            // room; the dial itself therefore floats ~40pt above the visible frame's bottom.
            y = screenFrame.origin.y
        case .linearStrip, .timeline, .spectrum, .tape, .loop3D:
            y = screenFrame.origin.y + 24.0 // Floats comfortably above dock
        case .edgeRail:
            // The only style that leaves the bottom of the screen alone: it hugs the right
            // edge, vertically centred, so the desktop below stays untouched.
            x = screenFrame.maxX - size.width - 18.0
            y = screenFrame.origin.y + (screenFrame.height - size.height) / 2.0
        }
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: - Interaction

    public func beginHover(column: Int) {
        lastActivityTime = CACurrentMediaTime()
        guard case .hovering(let current) = interaction, current == column else {
            interaction = .hovering(column: column)
            return
        }
    }

    public func endHover() {
        if case .hovering = interaction {
            interaction = .idle
            noteInteractionEnded()
        }
    }

    public func beginScrub() {
        if case .dragging = interaction { return }
        interaction = .scrubbing
    }

    public func updateScrub(ratio: Double) {
        guard case .scrubbing = interaction else { return }
        let clamped = min(1, max(0, ratio))
        // Reaching either end of the strip is a limit, not a position — give it a dull thud so
        // the user can feel the end without looking.
        if clamped == 0 || clamped == 1 {
            HudSoundEngine.shared.play(.bump)
        }
        onScrub?(clamped)
    }

    public func endScrub(ratio: Double) {
        guard case .scrubbing = interaction else { return }
        interaction = .idle
        onScrubEnded?(min(1, max(0, ratio)))
        noteInteractionEnded()
    }

    public func beginDrag(column: Int) {
        interaction = .dragging(column: column, insertionIndex: column)
    }

    /// Updates the ghost-orb position while the pointer moves. Kept separate from
    /// `interaction` so a pointer move that does not cross a slot boundary still redraws.
    public func updateDragPointer(_ point: CGPoint) {
        if let current = dragPointer, hypot(current.x - point.x, current.y - point.y) < 0.5 {
            return
        }
        dragPointer = point
    }

    public func clearDragPointer() {
        if dragPointer != nil {
            dragPointer = nil
        }
    }

    public func updateDrag(insertionIndex: Int) {
        guard case .dragging(let column, let current) = interaction else { return }
        let upperBound = max(0, state.columns.count - 1)
        let clamped = min(upperBound, max(0, insertionIndex))
        guard clamped != current else { return }
        // A soft detent as the insertion marker crosses into a new slot.
        HudSoundEngine.shared.play(.snap)
        interaction = .dragging(column: column, insertionIndex: clamped)
    }

    /// Abandons an in-flight drag without committing and without any sound.
    ///
    /// Used when the press turns out to be a plain click rather than a drag — the dial must not
    /// stay latched in `.dragging`, or it would never auto-hide again.
    public func cancelDrag() {
        if case .dragging = interaction {
            interaction = .idle
            clearDragPointer()
            noteInteractionEnded()
        }
    }

    public func endDrag(commit: Bool) {
        guard case .dragging(let column, let insertion) = interaction else { return }
        interaction = .idle
        clearDragPointer()
        noteInteractionEnded()
        // Dropping a column back into its own slot selects it.
        guard commit, insertion != column else {
            selectColumn(column)
            return
        }
        HudSoundEngine.shared.play(.drop)
        onMoveColumn?(column, insertion)
    }

    public func selectColumn(_ index: Int) {
        HudSoundEngine.shared.play(.snap)
        onSelectColumn?(index)
    }

    /// Restarts the auto-hide countdown after a gesture finishes, so the user always gets a full
    /// beat to read the result before the HUD fades.
    private func noteInteractionEnded() {
        lastActivityTime = CACurrentMediaTime()
        scheduleAutoHide()
    }

    // MARK: - Icons

    public func icon(for bundleIdentifier: String) -> NSImage? {
        iconCache[bundleIdentifier]
    }

    private static func loadIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }
}