import AppKit
import SwiftUI

/// The default Iume HUD: a 270° precision dial.
///
/// The dial is built as concentric instruments so that every layer answers one question and no
/// two layers fight for the same radius:
///
/// - **Graduations** (outer): a 60-step scale, so the gauge reads as a measuring instrument
///   rather than a decorated circle.
/// - **Track** (middle): one capsule per column in strip order. This is the content: the windows
///   themselves, in the order they sit on the strip.
/// - **Viewport** (light on the track): a soft accent wash marking which part of the strip is on
///   screen, with crop marks at its exact edges. It sits *behind* the capsules, so it reads as
///   illumination instead of competing with them as a second ring.
/// - **Core** (centre): the focused window — icon, app, title — plus the position readout in the
///   gap at the bottom, where a real gauge keeps its digital window.
///
/// Windows are dragged by their app orb, which sits threaded on its own column capsule.
public struct MinimapHUDView: View {
    @ObservedObject var controller: MinimapHUDController

    /// The instrument's geometry, measured from the dial's centre.
    ///
    /// The controller derives its hit-testing bands from the same radii, so the artwork and the
    /// interaction maths cannot drift apart.
    private enum Metrics {
        static let bezelRadius: CGFloat = 108.5
        static let tickOuterRadius: CGFloat = 104
        static let tickMinorLength: CGFloat = 3.5
        static let tickMajorLength: CGFloat = 7
        static let tickCount = 60
        static let trackRadius: CGFloat = MinimapHUDController.dialTrackRadius
        static let trackWidth: CGFloat = 9
        static let trackWidthFocused: CGFloat = 12.5
        static let orbSize: CGFloat = 20
        static let orbSizeFocused: CGFloat = 24
        static let coreRadius: CGFloat = MinimapHUDController.dialCoreRadius
        static let counterRadius: CGFloat = 70
    }

    private var diameter: CGFloat { MinimapHUDController.dialDiameter }

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let widths = st.columns.map(\.width)
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: st.gap)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: totalW
        )
        let dragState: (column: Int, insertion: Int)? = {
            if case .dragging(let c, let i) = controller.interaction { return (c, i) }
            return nil
        }()

        return ZStack {
            glassBackdrop
            if !st.columns.isEmpty {
                viewportWash(viewport: viewport)
            }
            tickLadder
            trackBase
            innerFramingRing
            columnCapsules(geometries: geometries, viewport: viewport, dragState: dragState)
            if !st.columns.isEmpty {
                viewportCropMarks(viewport: viewport)
            }
            appOrbs(geometries: geometries, dragState: dragState)
            if let dragState {
                insertionMarker(insertion: dragState.insertion)
            }
            coreReadout(state: st, dragState: dragState)
            counterReadout(state: st, dragState: dragState)
            dragChip(dragState: dragState)
        }
        .frame(width: diameter, height: diameter)
        .opacity(controller.interaction == .idle ? 0.84 : 1.0)
        .animation(.easeOut(duration: 0.22), value: controller.interaction)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: controller.state.focusedIndex)
        .contentShape(Circle())
    }

    // MARK: - Glass

    private var glassBackdrop: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // A cool near-black tint so white content stays legible over any wallpaper, with the
            // centre lifted a few points so the core disc reads as a recess rather than a hole.
            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.80), location: 0.00),
                            .init(color: Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.92), location: 0.62),
                            .init(color: Color(red: 0.01, green: 0.01, blue: 0.02).opacity(0.96), location: 1.00)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )

            // Specular rim: glass catching light at the top-left, and a thinner catch at the
            // bottom-right where the surface curves away.
            Circle()
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.58), location: 0.00),
                            .init(color: .white.opacity(0.05), location: 0.28),
                            .init(color: .white.opacity(0.00), location: 0.60),
                            .init(color: .white.opacity(0.13), location: 0.85),
                            .init(color: .white.opacity(0.30), location: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )

            Circle()
                .inset(by: 5)
                .stroke(Color.white.opacity(0.045), lineWidth: 0.75)
        }
        .clipShape(Circle())
        .compositingGroup()
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 10)
    }

    // MARK: - Graduations

    private var tickLadder: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = Metrics.tickOuterRadius

            for step in 0..<Metrics.tickCount {
                let ratio = Double(step) / Double(Metrics.tickCount - 1)
                let radians = DialGeometry.angle(forStripRatio: ratio) * .pi / 180
                let isMajor = step % 5 == 0
                let length = isMajor ? Metrics.tickMajorLength : Metrics.tickMinorLength

                var path = Path()
                path.move(
                    to: CGPoint(x: centre.x + cos(radians) * outer,
                                y: centre.y + sin(radians) * outer)
                )
                path.addLine(
                    to: CGPoint(x: centre.x + cos(radians) * (outer - length),
                                y: centre.y + sin(radians) * (outer - length))
                )
                context.stroke(
                    path,
                    with: .color(.white.opacity(isMajor ? 0.38 : 0.15)),
                    style: StrokeStyle(lineWidth: isMajor ? 1.4 : 1.0, lineCap: .round)
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    // MARK: - Track

    /// A hairline just inside the track. It frames the annulus the way a bezel frames a lens,
    /// and echoes the graduation ring so the dial reads as one instrument rather than three
    /// concentric decorations.
    private var innerFramingRing: some View {
        Circle()
            .trim(from: 0, to: DialGeometry.sweepAngleDegrees / 360.0)
            .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
            .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
            .padding(diameter / 2 - (Metrics.trackRadius - 15))
            .allowsHitTesting(false)
    }

    private var trackBase: some View {
        Circle()
            .trim(from: 0, to: DialGeometry.sweepAngleDegrees / 360.0)
            .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
            .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
            .padding(diameter / 2 - Metrics.trackRadius)
            .allowsHitTesting(false)
    }

    private func columnCapsules(
        geometries: [DialColumnGeometry],
        viewport: (start: Double, end: Double),
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        let trackFactor = DialGeometry.sweepAngleDegrees / 360.0
        // Keeps a hairline of track visible between touching columns even when the strip gap is 0.
        let trimInset = 0.0022

        return ZStack {
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == controller.state.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let isInViewport = geo.centerRatio >= viewport.start && geo.centerRatio <= viewport.end

                let from = min(trackFactor, max(0, geo.startRatio * trackFactor + trimInset))
                let to = min(trackFactor, max(from, geo.endRatio * trackFactor - trimInset))
                let width = isFocused ? Metrics.trackWidthFocused : Metrics.trackWidth
                let radiusInset = diameter / 2 - Metrics.trackRadius

                // Bloom sits under the crisp capsule so the focused column reads as lit, not
                // merely recoloured.
                if isFocused {
                    Circle()
                        .trim(from: from, to: to)
                        .stroke(
                            Color.accentColor.opacity(0.38),
                            style: StrokeStyle(lineWidth: width + 7, lineCap: .round)
                        )
                        .blur(radius: 8)
                        .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
                        .padding(radiusInset)
                }

                Circle()
                    .trim(from: from, to: to)
                    .stroke(
                        capsuleColor(
                            isFocused: isFocused,
                            isHovered: isHovered,
                            isDragged: isDragged,
                            isInViewport: isInViewport
                        ),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                    .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
                    .padding(radiusInset)
            }
        }
        .allowsHitTesting(false)
    }

    private func capsuleColor(isFocused: Bool, isHovered: Bool, isDragged: Bool, isInViewport: Bool) -> Color {
        if isDragged { return Color.white.opacity(0.10) }
        if isFocused { return Color.white.opacity(0.86) }
        if isHovered { return Color.white.opacity(0.62) }
        return Color.white.opacity(isInViewport ? 0.46 : 0.19)
    }

    // MARK: - Viewport

    /// The strip window, drawn as light falling on the track rather than as a second arc.
    private func viewportWash(viewport: (start: Double, end: Double)) -> some View {
        let sweep = max(0.006, viewport.end - viewport.start)
        let trackFactor = DialGeometry.sweepAngleDegrees / 360.0
        let from = viewport.start * trackFactor
        let to = min(trackFactor, (viewport.start + sweep) * trackFactor)
        let radiusInset = diameter / 2 - Metrics.trackRadius

        // Two passes, both behind the capsules: a wide halo that lights the surrounding glass,
        // and a tight pass that makes the track itself glow between the capsules. Nothing is
        // painted over the content, so the columns stay crisp inside the window.
        return ZStack {
            Circle()
                .trim(from: from, to: to)
                .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 36, lineCap: .round))
                .blur(radius: 18)
            Circle()
                .trim(from: from, to: to)
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .blur(radius: 3)
        }
        .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
        .padding(radiusInset)
        .allowsHitTesting(false)
    }

    /// Crop marks at the exact edges of the viewport: the part of the gauge that says "the screen
    /// shows this much, from here to here".
    private func viewportCropMarks(viewport: (start: Double, end: Double)) -> some View {
        ZStack {
            cropMark(at: DialGeometry.angle(forStripRatio: viewport.start))
            cropMark(at: DialGeometry.angle(forStripRatio: viewport.end))
        }
        .allowsHitTesting(false)
    }

    private func cropMark(at angle: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.75))
            .frame(width: 1.75, height: 18)
            .offset(y: -Metrics.trackRadius)
            .rotationEffect(.degrees(angle + 90))
            .shadow(color: Color.accentColor.opacity(0.85), radius: 5)
    }

    // MARK: - App Orbs

    private func appOrbs(
        geometries: [DialColumnGeometry],
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        let offset = diameter / 2
        let radius = Metrics.trackRadius
        // Keep at least a hairline between neighbouring orbs no matter how many columns exist.
        let step = geometries.isEmpty ? .pi / 2 : (DialGeometry.sweepAngleDegrees * .pi / 180) / Double(geometries.count)
        let ceiling = max(12, min(Metrics.orbSize, 2 * radius * sin(step / 2) * 0.62))

        return ZStack {
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == controller.state.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let column = controller.state.columns.indices.contains(geo.index)
                    ? controller.state.columns[geo.index]
                    : nil
                let radians = DialGeometry.angle(forStripRatio: geo.centerRatio) * .pi / 180
                let size = isFocused ? min(Metrics.orbSizeFocused, ceiling + 3) : ceiling

                orbView(
                    column: column,
                    size: size,
                    isFocused: isFocused,
                    isHovered: isHovered,
                    isDragged: isDragged
                )
                .position(
                    x: offset + cos(radians) * radius,
                    y: offset + sin(radians) * radius
                )
                .zIndex(isFocused ? 2 : 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func orbView(
        column: DialColumnInfo?,
        size: CGFloat,
        isFocused: Bool,
        isHovered: Bool,
        isDragged: Bool
    ) -> some View {
        ZStack {
            if isFocused {
                Circle()
                    .fill(Color.accentColor.opacity(0.38))
                    .frame(width: size + 13, height: size + 13)
                    .blur(radius: 7)
            }

            // The socket: a dark bezel that lets the icon punch through the track.
            Circle()
                .fill(Color(white: 0.05).opacity(0.94))
                .overlay(
                    Circle()
                        .stroke(
                            Color.white.opacity(isFocused ? 0.95 : (isHovered ? 0.55 : 0.16)),
                            lineWidth: isFocused ? 1.6 : (isHovered ? 1.0 : 0.75)
                        )
                )

            if let column, let icon = controller.icon(for: column.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size - 5.5, height: size - 5.5)
                    .clipShape(Circle())
            } else if let column {
                Text(String(column.appName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .opacity(isDragged ? 0.18 : 1.0)
        .animation(.spring(response: 0.26, dampingFraction: 0.80), value: isHovered)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isFocused)
    }

    // MARK: - Drop Marker

    private func insertionMarker(insertion: Int) -> some View {
        let st = controller.state
        let dragged = draggedIndex()
        let ratio = DialGeometry.insertionBoundaryRatio(
            insertion: insertion,
            widths: st.columns.map(\.width),
            gap: st.gap,
            draggingIndex: dragged
        )
        let angle = DialGeometry.angle(forStripRatio: ratio)

        // One needle across the track and the graduations: a drop point, not a bead on the rim.
        return Capsule()
            .fill(Color.white)
            .frame(width: 2.5, height: 30)
            .offset(y: -(Metrics.trackRadius + 1.5))
            .rotationEffect(.degrees(angle + 90))
            .shadow(color: Color.accentColor.opacity(0.85), radius: 6)
            .animation(.spring(response: 0.22, dampingFraction: 0.80), value: insertion)
            .allowsHitTesting(false)
    }

    private func draggedIndex() -> Int {
        if case .dragging(let column, _) = controller.interaction { return column }
        return -1
    }

    // MARK: - Core

    private func coreReadout(
        state st: MinimapState,
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        let displayIndex: Int? = {
            if let dragState { return dragState.column }
            if case .hovering(let c) = controller.interaction { return c }
            return st.columns.isEmpty ? nil : st.focusedIndex
        }()
        let column: DialColumnInfo? = displayIndex.flatMap { idx in
            st.columns.indices.contains(idx) ? st.columns[idx] : nil
        }

        return ZStack {
            // Inset well: the centre is a recess in the glass, so it gets a darker fill and a
            // lit top edge that falls away towards the bottom.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.055, green: 0.058, blue: 0.070).opacity(0.94),
                            Color(red: 0.012, green: 0.013, blue: 0.017).opacity(0.97)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: Metrics.coreRadius
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.075), lineWidth: 0.75)
            Circle()
                .trim(from: 0.55, to: 0.95)
                .stroke(Color.black.opacity(0.55), lineWidth: 2.2)
                .blur(radius: 2.5)
            Circle()
                .trim(from: 0.05, to: 0.45)
                .stroke(Color.white.opacity(0.10), lineWidth: 1.0)
                .blur(radius: 1.2)

            if let column {
                VStack(spacing: 6) {
                    iconView(for: column)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 5, x: 0, y: 2)

                    VStack(spacing: 2) {
                        Text(column.appName.isEmpty ? "Window" : column.appName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        if !column.title.isEmpty && column.title != column.appName {
                            Text(column.title)
                                .font(.system(size: 8.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.62)
                        }
                    }
                    .frame(width: Metrics.coreRadius * 1.5)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("NO WINDOWS")
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: Metrics.coreRadius * 2, height: Metrics.coreRadius * 2)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func iconView(for column: DialColumnInfo) -> some View {
        if let icon = controller.icon(for: column.bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    Text(String(column.appName.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                )
        }
    }

    // MARK: - Position Readout

    /// Sits in the open bottom of the gauge, where a real instrument keeps its counter.
    private func counterReadout(
        state st: MinimapState,
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        guard !st.columns.isEmpty else { return AnyView(EmptyView()) }

        let index = min(dragState?.insertion ?? st.focusedIndex, st.columns.count - 1)
        let current = String(format: "%02d", index + 1)
        let total = String(format: "%02d", st.columns.count)
        let isDragging = dragState != nil

        return AnyView(
            VStack(spacing: 0) {
                Text(isDragging ? "DROP AT" : "WINDOW")
                    .font(.system(size: 6.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(isDragging ? 0.55 : 0.30))

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(current)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDragging ? Color.accentColor : Color.white.opacity(0.95))
                    Text("/")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.22))
                    Text(total)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .monospacedDigit()
            }
            .offset(y: Metrics.counterRadius)
            .animation(.easeOut(duration: 0.16), value: index)
        )
    }

    // MARK: - Drag Chip

    @ViewBuilder
    private func dragChip(dragState: (column: Int, insertion: Int)?) -> some View {
        if let dragState {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("SLOT \(String(format: "%02d", dragState.insertion + 1))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.80)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.45), radius: 7, x: 0, y: 2)
            .offset(y: -(Metrics.bezelRadius + 20))
            .allowsHitTesting(false)
        }
    }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }
}

// MARK: - Design 3: 360° Orbital Halo Ring View (`.orbitalRing`)

/// Full 360° floating glass orbit ring where open windows revolve as interactive glowing app nodes
/// around a translucent core, with direct node drag-and-drop reordering.
public struct MinimapOrbitalRingView: View {
    @ObservedObject var controller: MinimapHUDController

    private var diameter: CGFloat { MinimapHUDController.dialDiameter }
    private var orbitRadius: CGFloat { diameter / 2.0 - 22.0 }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let widths = st.columns.map(\.width)
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: st.gap)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: totalW
        )
        let dragState: (column: Int, insertion: Int)? = {
            if case .dragging(let c, let i) = controller.interaction { return (c, i) }
            return nil
        }()
        let center = CGPoint(x: diameter / 2.0, y: diameter / 2.0)

        return ZStack {
            // Outer Halo Glass Ring
            Circle()
                .stroke(Color.black.opacity(0.58), lineWidth: 34)
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(Circle())
                )
                .overlay(
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.accentColor.opacity(0.45),
                                    Color.purple.opacity(0.35),
                                    Color.cyan.opacity(0.45),
                                    Color.accentColor.opacity(0.45)
                                ],
                                center: .center
                            ),
                            lineWidth: 2.0
                        )
                )

            // Glowing Viewport Sweep on Orbit
            let trackFactor = DialGeometry.sweepAngleDegrees / 360.0
            let startTrim = viewport.start * trackFactor
            let endTrim = min(trackFactor, max(startTrim + 0.01, viewport.end * trackFactor))
            Circle()
                .trim(from: startTrim, to: endTrim)
                .stroke(
                    LinearGradient(
                        colors: [Color.cyan, Color.accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .blur(radius: 4)
                .opacity(0.45)
                .rotationEffect(.degrees(DialGeometry.startAngleDegrees))
                .padding(22)

            // Orbiting Window Nodes
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == st.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let isDropTarget = dragState?.insertion == geo.index && dragState?.column != geo.index
                let colInfo = st.columns.indices.contains(geo.index) ? st.columns[geo.index] : nil
                let angleDeg = DialGeometry.angle(forStripRatio: geo.centerRatio)
                let rad = angleDeg * .pi / 180.0
                let x = center.x + cos(rad) * orbitRadius
                let y = center.y + sin(rad) * orbitRadius
                let nodeSize: CGFloat = isFocused ? 30 : 24

                ZStack {
                    if isFocused {
                        Circle()
                            .fill(Color.cyan.opacity(0.30))
                            .frame(width: nodeSize + 10, height: nodeSize + 10)
                            .blur(radius: 3)
                    }
                    Circle()
                        .fill(isFocused ? Color.accentColor : Color.black.opacity(0.80))
                        .overlay(
                            Circle()
                                .stroke(
                                    isDropTarget ? Color.cyan : (isFocused ? Color.white : Color.white.opacity(0.32)),
                                    lineWidth: isDropTarget ? 2.4 : 1.2
                                )
                        )

                    if let colInfo, let icon = controller.icon(for: colInfo.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: nodeSize - 8, height: nodeSize - 8)
                            .clipShape(Circle())
                    } else if let colInfo {
                        Text(String(colInfo.appName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: nodeSize, height: nodeSize)
                .scaleEffect(isHovered ? 1.18 : 1.0)
                .opacity(isDragged ? 0.25 : 1.0)
                .position(x: x, y: y)
            }

            // Floating Core Info
            let focusedCol = st.columns.indices.contains(st.focusedIndex) ? st.columns[st.focusedIndex] : nil
            VStack(spacing: 3) {
                if let dragState, st.columns.indices.contains(dragState.column) {
                    Text(st.columns[dragState.column].appName)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("Slot \(dragState.insertion + 1) of \(st.columns.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                } else if let focusedCol {
                    Text(focusedCol.appName)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("ORBIT \(st.focusedIndex + 1)/\(max(1, st.columns.count))")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.85))
                }
            }
            .frame(width: 96, height: 96)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.65))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            )
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Design 4: Rotary Turntable Disc View (`.turntableDisc`)

/// Tactile concentric grooved rotary disc with a sweeping viewport tonearm needle and rim medallions.
public struct MinimapTurntableDiscView: View {
    @ObservedObject var controller: MinimapHUDController

    private var diameter: CGFloat { MinimapHUDController.dialDiameter }
    private var rimRadius: CGFloat { diameter / 2.0 - 20.0 }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let widths = st.columns.map(\.width)
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: st.gap)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: totalW
        )
        let dragState: (column: Int, insertion: Int)? = {
            if case .dragging(let c, let i) = controller.interaction { return (c, i) }
            return nil
        }()
        let center = CGPoint(x: diameter / 2.0, y: diameter / 2.0)
        let vpCenterRatio = (viewport.start + viewport.end) * 0.5
        let needleAngle = DialGeometry.angle(forStripRatio: vpCenterRatio)

        return ZStack {
            // Grooved Vinyl / Brushed Metal Platter
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color.black.opacity(0.78),
                                Color(white: 0.16).opacity(0.78),
                                Color.black.opacity(0.78),
                                Color(white: 0.16).opacity(0.78),
                                Color.black.opacity(0.78)
                            ],
                            center: .center
                        )
                    )
                // Concentric micro-grooves
                ForEach([28.0, 40.0, 52.0, 64.0], id: \.self) { inset in
                    Circle()
                        .inset(by: inset)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.75)
                }
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
            }
            .clipShape(Circle())

            // Sweeping Viewport Needle / Indicator Arm
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.orange, Color.yellow.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3, height: rimRadius - 18)
                .offset(y: -(rimRadius - 18) / 2.0)
                .rotationEffect(.degrees(needleAngle + 90))
                .shadow(color: Color.orange.opacity(0.75), radius: 5)

            // Rim Medallions for Each Open Window
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == st.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let colInfo = st.columns.indices.contains(geo.index) ? st.columns[geo.index] : nil
                let angleDeg = DialGeometry.angle(forStripRatio: geo.centerRatio)
                let rad = angleDeg * .pi / 180.0
                let x = center.x + cos(rad) * rimRadius
                let y = center.y + sin(rad) * rimRadius
                let size: CGFloat = isFocused ? 27 : 22

                ZStack {
                    Circle()
                        .fill(isFocused ? Color.orange : Color.black.opacity(0.82))
                        .overlay(
                            Circle()
                                .stroke(isFocused ? Color.white : Color.white.opacity(0.28), lineWidth: 1.2)
                        )
                    if let colInfo, let icon = controller.icon(for: colInfo.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size - 7, height: size - 7)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let colInfo {
                        Text(String(colInfo.appName.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(isHovered ? 1.16 : 1.0)
                .opacity(isDragged ? 0.25 : 1.0)
                .position(x: x, y: y)
            }

            // Center Turntable Spindle Label
            let focusedCol = st.columns.indices.contains(st.focusedIndex) ? st.columns[st.focusedIndex] : nil
            VStack(spacing: 2) {
                if let dragState {
                    Text("TRACK \(dragState.insertion + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                } else if let focusedCol {
                    Text(focusedCol.appName)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(st.focusedIndex + 1) / \(max(1, st.columns.count))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 78, height: 78)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.82))
                    .overlay(Circle().stroke(Color.orange.opacity(0.55), lineWidth: 1.5))
            )
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Helpers

/// Helper NSVisualEffectView wrapper for SwiftUI.
public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
