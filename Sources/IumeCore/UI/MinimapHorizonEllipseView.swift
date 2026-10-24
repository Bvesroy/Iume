import AppKit
import SwiftUI

/// A wide, shallow half-ellipse: the flat base sits on the bottom edge of the panel and the
/// arched rim rises from it. Used as the HUD's backdrop, so the dock reads as a horizon rather
/// than as a floating rectangle.
public struct HorizonEllipseShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        // Cubic approximation of a half ellipse (kappa for a quarter arc).
        let k: CGFloat = 0.5522847498
        let midX = rect.midX
        let baseY = rect.maxY
        let rx = rect.width / 2.0
        let ry = rect.height

        path.move(to: CGPoint(x: rect.minX, y: baseY))
        path.addCurve(
            to: CGPoint(x: midX, y: baseY - ry),
            control1: CGPoint(x: rect.minX, y: baseY - ry * k),
            control2: CGPoint(x: midX - rx * k, y: baseY - ry)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: baseY),
            control1: CGPoint(x: midX + rx * k, y: baseY - ry),
            control2: CGPoint(x: rect.maxX, y: baseY - ry * k)
        )
        path.closeSubpath()
        return path
    }
}

/// One ratio-space segment of the elliptical track, sampled as a smooth polyline.
public struct HorizonEllipseArc: Shape {
    public var startRatio: Double
    public var endRatio: Double
    public var radiusX: CGFloat
    public var radiusY: CGFloat

    public init(startRatio: Double, endRatio: Double, radiusX: CGFloat, radiusY: CGFloat) {
        self.startRatio = startRatio
        self.endRatio = endRatio
        self.radiusX = radiusX
        self.radiusY = radiusY
    }

    public func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let baseY = rect.maxY
        let start = MinimapHorizonEllipseView.angle(forStripRatio: min(1, max(0, startRatio)))
        let end = MinimapHorizonEllipseView.angle(forStripRatio: min(1, max(0, endRatio)))
        let steps = max(2, Int(abs(end - start) / 1.5))

        var path = Path()
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let radians = (start + (end - start) * t) * .pi / 180.0
            let point = CGPoint(
                x: cx + radiusX * CGFloat(cos(radians)),
                y: baseY + radiusY * CGFloat(sin(radians))
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// The half-ellipse HUD ("Horizon"): a wide shallow glass dome docked flush to the bottom of the
/// screen. The strip is drawn along an elliptical arc that rises no higher than a third of the
/// panel, leaving the centre of the dome free for the live readout.
///
/// Every position on the strip — column arcs, app orbs, viewport wash and drop needle — is
/// expressed in the same ratio space, so the artwork and the hit-testing maths cannot drift.
public struct MinimapHorizonEllipseView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 620
    nonisolated public static let panelHeight: CGFloat = 168

    /// Centreline of the elliptical track. The glass dome itself is slightly larger.
    nonisolated public static let trackRadiusX: CGFloat = 262
    nonisolated public static let trackRadiusY: CGFloat = 124

    /// The strip occupies the upper arc only. Ending above the base keeps the first and last
    /// orbs clear of the screen edge, and the shallow sweep keeps the instrument wide and calm.
    nonisolated public static let startAngleDegrees: Double = 202
    nonisolated public static let endAngleDegrees: Double = 338

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let geometries = DialGeometry.columnGeometries(widths: st.columns.map(\.width), gap: st.gap)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: totalW
        )
        let dragState: (column: Int, insertion: Int)? = {
            if case .dragging(let c, let i) = controller.interaction { return (c, i) }
            return nil
        }()

        ZStack {
            backdrop

            if !st.columns.isEmpty {
                viewportWash(viewport: viewport)
            }

            tickLadder

            HorizonEllipseArc(
                startRatio: 0,
                endRatio: 1,
                radiusX: Self.trackRadiusX,
                radiusY: Self.trackRadiusY
            )
            .stroke(Color.white.opacity(0.075), style: StrokeStyle(lineWidth: 6, lineCap: .round))

            columnArcs(geometries: geometries, viewport: viewport, dragState: dragState)

            if !st.columns.isEmpty {
                cropMarks(viewport: viewport)
            }

            appOrbs(geometries: geometries, dragState: dragState)

            if let dragState {
                insertionMarker(insertion: dragState.insertion)
            }

            coreReadout(state: st, dragState: dragState)

            if let ghost = dragGhost(dragState: dragState) {
                ghost
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .opacity(controller.interaction == .idle ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.20), value: controller.interaction)
    }

    // MARK: - Glass

    private var backdrop: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(HorizonEllipseShape())

            // Cool near-black glass, deepest at the base so the readout always has contrast.
            HorizonEllipseShape()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.86), location: 0.00),
                            .init(color: Color(red: 0.045, green: 0.05, blue: 0.07).opacity(0.92), location: 0.55),
                            .init(color: Color(red: 0.010, green: 0.012, blue: 0.018).opacity(0.95), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // A quiet accent bloom under the apex, like light catching the rim of a horizon.
            RadialGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.20),
                startRadius: 8,
                endRadius: 300
            )
            .clipShape(HorizonEllipseShape())

            HorizonEllipseShape()
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.42), location: 0.00),
                            .init(color: Color.white.opacity(0.07), location: 0.42),
                            .init(color: Color.white.opacity(0.03), location: 0.72),
                            .init(color: Color.white.opacity(0.18), location: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 6)
    }

    // MARK: - Graduations

    private var tickLadder: some View {
        Canvas { context, size in
            let cx = size.width / 2.0
            let baseY = size.height
            let count = 49

            for step in 0..<count {
                let ratio = Double(step) / Double(count - 1)
                let radians = Self.angle(forStripRatio: ratio) * .pi / 180.0
                let isMajor = step % 6 == 0
                let outer = isMajor ? 1.085 : 1.055
                let inner = isMajor ? 1.012 : 1.030
                let lineWidth: CGFloat = isMajor ? 1.25 : 0.8

                let p1 = CGPoint(
                    x: cx + Self.trackRadiusX * CGFloat(cos(radians)) * outer,
                    y: baseY + Self.trackRadiusY * CGFloat(sin(radians)) * outer
                )
                let p2 = CGPoint(
                    x: cx + Self.trackRadiusX * CGFloat(cos(radians)) * inner,
                    y: baseY + Self.trackRadiusY * CGFloat(sin(radians)) * inner
                )

                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(
                    path,
                    with: .color(.white.opacity(isMajor ? 0.30 : 0.12)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .allowsHitTesting(false)
    }

    // MARK: - Viewport

    private func viewportWash(viewport: (start: Double, end: Double)) -> some View {
        let sweep = max(0.006, viewport.end - viewport.start)
        let start = min(1.0, max(0.0, viewport.start))
        let end = min(1.0, max(start + 0.006, start + sweep))

        return ZStack {
            HorizonEllipseArc(
                startRatio: start,
                endRatio: end,
                radiusX: Self.trackRadiusX,
                radiusY: Self.trackRadiusY
            )
            .stroke(Color.accentColor.opacity(0.30), style: StrokeStyle(lineWidth: 16, lineCap: .round))
            .blur(radius: 9)

            HorizonEllipseArc(
                startRatio: start,
                endRatio: end,
                radiusX: Self.trackRadiusX,
                radiusY: Self.trackRadiusY
            )
            .stroke(Color.accentColor.opacity(0.38), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .blur(radius: 2.5)
        }
        .allowsHitTesting(false)
    }

    private func cropMarks(viewport: (start: Double, end: Double)) -> some View {
        ZStack {
            cropMark(at: viewport.start)
            cropMark(at: viewport.end)
        }
        .allowsHitTesting(false)
    }

    private func cropMark(at ratio: Double) -> some View {
        let point = Self.point(for: ratio)
        return Capsule()
            .fill(Color.white.opacity(0.72))
            .frame(width: 1.6, height: 15)
            .rotationEffect(.degrees(Self.radialAngle(for: ratio) + 90))
            .position(x: point.x, y: point.y)
            .shadow(color: Color.accentColor.opacity(0.8), radius: 4)
    }

    // MARK: - Columns

    private func columnArcs(
        geometries: [DialColumnGeometry],
        viewport: (start: Double, end: Double),
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        ZStack {
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == controller.state.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let isInViewport = geo.centerRatio >= viewport.start && geo.centerRatio <= viewport.end
                let from = min(geo.startRatio + 0.0015, geo.endRatio)
                let to = max(geo.startRatio + 0.0025, geo.endRatio - 0.0015)
                let width: CGFloat = isFocused ? 7.0 : 5.0

                if isFocused {
                    HorizonEllipseArc(
                        startRatio: from,
                        endRatio: to,
                        radiusX: Self.trackRadiusX,
                        radiusY: Self.trackRadiusY
                    )
                    .stroke(Color.accentColor.opacity(0.42), style: StrokeStyle(lineWidth: width + 7, lineCap: .round))
                    .blur(radius: 7)
                }

                HorizonEllipseArc(
                    startRatio: from,
                    endRatio: to,
                    radiusX: Self.trackRadiusX,
                    radiusY: Self.trackRadiusY
                )
                .stroke(
                    capsuleColor(
                        isFocused: isFocused,
                        isHovered: isHovered,
                        isDragged: isDragged,
                        isInViewport: isInViewport
                    ),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
                .opacity(isDragged ? 0.22 : 1.0)
            }
        }
        .allowsHitTesting(false)
    }

    private func capsuleColor(isFocused: Bool, isHovered: Bool, isDragged: Bool, isInViewport: Bool) -> Color {
        if isDragged { return Color.white.opacity(0.10) }
        if isFocused { return Color.white.opacity(0.88) }
        if isHovered { return Color.white.opacity(0.64) }
        return Color.white.opacity(isInViewport ? 0.44 : 0.18)
    }

    // MARK: - Orbs

    private func appOrbs(
        geometries: [DialColumnGeometry],
        dragState: (column: Int, insertion: Int)?
    ) -> some View {
        // Approximate arc radius, used only to keep orbs from colliding when the strip is busy.
        let approximateRadius = (Self.trackRadiusX + Self.trackRadiusY) / 2.0
        let step = geometries.isEmpty
            ? .pi / 2
            : ((Self.endAngleDegrees - Self.startAngleDegrees) * .pi / 180.0) / Double(geometries.count)
        let ceiling = max(14, min(26, 2 * approximateRadius * CGFloat(sin(step / 2.0)) * 0.62))

        return ZStack {
            ForEach(geometries, id: \.index) { geo in
                let isFocused = geo.index == controller.state.focusedIndex
                let isHovered = hoveredIndex == geo.index
                let isDragged = dragState?.column == geo.index
                let column = controller.state.columns.indices.contains(geo.index)
                    ? controller.state.columns[geo.index]
                    : nil
                let size = isFocused ? min(27, ceiling + 3) : ceiling
                let point = Self.point(for: geo.centerRatio)

                orbView(
                    column: column,
                    size: size,
                    isFocused: isFocused,
                    isHovered: isHovered,
                    isDragged: isDragged
                )
                .position(x: point.x, y: point.y)
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
                    .fill(Color.accentColor.opacity(0.40))
                    .frame(width: size + 14, height: size + 14)
                    .blur(radius: 8)
            }

            Circle()
                .fill(Color(white: 0.045).opacity(0.95))
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(isFocused ? 0.95 : (isHovered ? 0.55 : 0.16)),
                        lineWidth: isFocused ? 1.6 : (isHovered ? 1.0 : 0.75)
                    )
                )

            if let column, let icon = controller.icon(for: column.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size - 6, height: size - 6)
                    .clipShape(Circle())
            } else if let column {
                Text(String(column.appName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.10 : 1.0)
        .opacity(isDragged ? 0.16 : 1.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.80), value: isHovered)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isFocused)
    }

    // MARK: - Drop Marker

    private func insertionMarker(insertion: Int) -> some View {
        let st = controller.state
        let ratio = DialGeometry.insertionBoundaryRatio(
            insertion: insertion,
            widths: st.columns.map(\.width),
            gap: st.gap,
            draggingIndex: draggedIndex()
        )
        let point = Self.point(for: ratio)

        return ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .shadow(color: Color.accentColor.opacity(0.9), radius: 6)

            Capsule()
                .fill(Color.white)
                .frame(width: 2.4, height: 24)
                .offset(y: -7)
                .rotationEffect(.degrees(Self.radialAngle(for: ratio) + 90))
        }
        .position(x: point.x, y: point.y)
        .shadow(color: Color.accentColor.opacity(0.8), radius: 5)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: insertion)
        .allowsHitTesting(false)
    }

    private func draggedIndex() -> Int {
        if case .dragging(let column, _) = controller.interaction { return column }
        return -1
    }

    /// A light copy of the dragged orb that follows the pointer, so a grab always reads as a
    /// grab even before the drop needle lines up.
    private func dragGhost(dragState: (column: Int, insertion: Int)?) -> AnyView? {
        guard let dragState,
              let pointer = controller.dragPointer,
              controller.state.columns.indices.contains(dragState.column) else { return nil }
        let column = controller.state.columns[dragState.column]
        // The hosting view reports AppKit coordinates (origin bottom-left); SwiftUI measures
        // from the top.
        let x = min(Self.panelWidth - 22, max(22, pointer.x))
        let y = min(Self.panelHeight - 22, max(22, Self.panelHeight - pointer.y))

        return AnyView(
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.72))
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.2))
                if let icon = controller.icon(for: column.bundleIdentifier) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                } else {
                    Text(String(column.appName.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 4)
            .scaleEffect(1.05)
            .position(x: x, y: y)
            .allowsHitTesting(false)
        )
    }

    // MARK: - Readout

    private func coreReadout(state st: MinimapState, dragState: (column: Int, insertion: Int)?) -> some View {
        let displayIndex: Int? = {
            if let dragState { return dragState.column }
            if case .hovering(let c) = controller.interaction { return c }
            return st.columns.isEmpty ? nil : st.focusedIndex
        }()
        let column: DialColumnInfo? = displayIndex.flatMap { idx in
            st.columns.indices.contains(idx) ? st.columns[idx] : nil
        }

        return HStack(spacing: 10) {
            if let column {
                Group {
                    if let icon = controller.icon(for: column.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Text(String(column.appName.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 25, height: 25)
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(column.appName.isEmpty ? "Window" : column.appName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)

                    Text(readoutSubtitle(column: column, dragState: dragState))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%02d", (dragState?.insertion ?? displayIndex ?? 0) + 1))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                    Text("/")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.22))
                    Text(String(format: "%02d", max(1, st.columns.count)))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .monospacedDigit()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No windows on the strip")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 42)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.52))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.045)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
        .position(x: Self.panelWidth / 2.0, y: Self.panelHeight - 26)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: displayIndex)
    }

    private func readoutSubtitle(column: DialColumnInfo, dragState: (column: Int, insertion: Int)?) -> String {
        if let dragState {
            return "Release to move to position \(dragState.insertion + 1)"
        }
        let title = column.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && title != column.appName {
            return title
        }
        if column.windowCount > 1 {
            return "\(column.windowCount) windows in this column"
        }
        return "Focused window"
    }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }

    // MARK: - Geometry

    nonisolated public static func angle(forStripRatio ratio: Double) -> Double {
        let clamped = min(1.0, max(0.0, ratio))
        return startAngleDegrees + clamped * (endAngleDegrees - startAngleDegrees)
    }

    nonisolated public static func point(for ratio: Double) -> CGPoint {
        let radians = angle(forStripRatio: ratio) * .pi / 180.0
        return CGPoint(
            x: panelWidth / 2.0 + trackRadiusX * CGFloat(cos(radians)),
            y: panelHeight + trackRadiusY * CGFloat(sin(radians))
        )
    }

    /// Direction of the outward normal at a ratio, in screen degrees (0° = right, clockwise).
    nonisolated public static func radialAngle(for ratio: Double) -> Double {
        let radians = angle(forStripRatio: ratio) * .pi / 180.0
        let dx = Double(trackRadiusX) * cos(radians)
        let dy = Double(trackRadiusY) * sin(radians)
        var degrees = atan2(dy, dx) * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }
        return degrees
    }

    nonisolated public static func ratio(for point: CGPoint) -> Double {
        let nx = Double(point.x - panelWidth / 2.0) / Double(trackRadiusX)
        let ny = Double(point.y - panelHeight) / Double(trackRadiusY)
        var degrees = atan2(ny, nx) * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }

        let span = endAngleDegrees - startAngleDegrees
        let raw = (degrees - startAngleDegrees) / span
        if raw >= 0.0 && raw <= 1.0 {
            return raw
        }

        // Points in the bottom gap are ambiguous: snap to the angularly nearer end of the strip.
        let toStart = min(abs(degrees - startAngleDegrees), 360.0 - abs(degrees - startAngleDegrees))
        let toEnd = min(abs(degrees - endAngleDegrees), 360.0 - abs(degrees - endAngleDegrees))
        return toStart <= toEnd ? 0.0 : 1.0
    }

    /// Unit-normalised elliptical radius of a point: 1.0 sits exactly on the track.
    nonisolated public static func normalizedRadius(of point: CGPoint) -> Double {
        let nx = Double(point.x - panelWidth / 2.0) / Double(trackRadiusX)
        let ny = Double(point.y - panelHeight) / Double(trackRadiusY)
        return sqrt(nx * nx + ny * ny)
    }

    nonisolated public static func angleDegrees(of point: CGPoint) -> Double {
        let nx = Double(point.x - panelWidth / 2.0) / Double(trackRadiusX)
        let ny = Double(point.y - panelHeight) / Double(trackRadiusY)
        var degrees = atan2(ny, nx) * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }
        return degrees
    }
}
