import AppKit
import SwiftUI

/// Spectrum HUD: one bar per open window, bar height encoding how wide that column is, so a
/// glance reads the shape of the desktop like an equaliser. The on-screen window is a soft
/// band behind the bars.
public struct MinimapSpectrumView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 440
    nonisolated public static let panelHeight: CGFloat = 132
    nonisolated public static let insetX: CGFloat = 22
    nonisolated public static let baselineY: CGFloat = 104
    nonisolated public static let barsTop: CGFloat = 34
    nonisolated public static let maxBarHeight: CGFloat = 58
    nonisolated public static let barGap: CGFloat = 5
    nonisolated public static let maxBarWidth: CGFloat = 24

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }

    private var dragState: (column: Int, insertion: Int)? {
        if case .dragging(let c, let i) = controller.interaction { return (c, i) }
        return nil
    }

    // MARK: - Layout maths (shared with hit-testing)

    nonisolated public static func barFrames(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let available = panelWidth - insetX * 2
        let width = min(maxBarWidth, max(6, (available - CGFloat(count - 1) * barGap) / CGFloat(count)))
        let total = CGFloat(count) * width + CGFloat(count - 1) * barGap
        let startX = (panelWidth - total) / 2
        return (0..<count).map { i in
            CGRect(x: startX + CGFloat(i) * (width + barGap), y: 0, width: width, height: width)
        }
    }

    nonisolated public static func barHeight(for width: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let ratio = min(1, max(0, width / max(1, maxWidth)))
        return 12 + ratio * maxBarHeight
    }

    /// X position of a strip ratio, interpolated between bar centres so the viewport band lines
    /// up with the bars even though the bars are evenly spaced and the strip is not.
    nonisolated public static func x(
        forRatio ratio: Double,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> CGFloat {
        let pairs = zip(geometries, frames).map { (ratio: $0.centerRatio, x: $1.midX) }
        guard let first = pairs.first, let last = pairs.last else { return panelWidth / 2 }
        guard pairs.count > 1 else { return first.x }

        if ratio <= first.ratio {
            let next = pairs[1]
            let slope = (next.x - first.x) / CGFloat(max(1e-9, next.ratio - first.ratio))
            return first.x + CGFloat(ratio - first.ratio) * slope
        }
        if ratio >= last.ratio {
            let prev = pairs[pairs.count - 2]
            let slope = (last.x - prev.x) / CGFloat(max(1e-9, last.ratio - prev.ratio))
            return last.x + CGFloat(ratio - last.ratio) * slope
        }
        for i in 1..<pairs.count where ratio <= pairs[i].ratio {
            let a = pairs[i - 1]
            let b = pairs[i]
            let t = (ratio - a.ratio) / max(1e-9, b.ratio - a.ratio)
            return a.x + CGFloat(t) * (b.x - a.x)
        }
        return last.x
    }

    /// Inverse of `x(forRatio:)`, used for 1:1 scrubbing.
    nonisolated public static func ratio(
        forX x: CGFloat,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> Double {
        let pairs = zip(geometries, frames).map { (ratio: $0.centerRatio, x: $1.midX) }
        guard let first = pairs.first, let last = pairs.last else { return 0 }
        guard pairs.count > 1 else { return first.ratio }

        if x <= first.x {
            let next = pairs[1]
            let slope = (next.ratio - first.ratio) / Double(max(1e-9, next.x - first.x))
            return first.ratio + Double(x - first.x) * slope
        }
        if x >= last.x {
            let prev = pairs[pairs.count - 2]
            let slope = (last.ratio - prev.ratio) / Double(max(1e-9, last.x - prev.x))
            return last.ratio + Double(x - last.x) * slope
        }
        for i in 1..<pairs.count where x <= pairs[i].x {
            let a = pairs[i - 1]
            let b = pairs[i]
            let t = Double((x - a.x) / max(1e-9, b.x - a.x))
            return a.ratio + t * (b.ratio - a.ratio)
        }
        return last.ratio
    }

    // MARK: - Body

    public var body: some View {
        let st = controller.state
        let geometries = st.columnGeometries
        let frames = Self.barFrames(count: st.columns.count)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: max(1, st.totalStripWidth)
        )
        let drag = dragState

        ZStack {
            HUDGlassSurface(cornerRadius: 22)

            if st.columns.isEmpty {
                emptyState
            } else {
                viewportBand(viewport: viewport, geometries: geometries, frames: frames)
                bars(state: st, geometries: geometries, frames: frames, viewport: viewport, drag: drag)
                baseline(frames: frames)
                header(state: st, drag: drag)
                if let drag {
                    insertionMarker(
                        ratio: hudInsertionRatio(for: drag.insertion, draggingIndex: drag.column, geometries: geometries),
                        geometries: geometries,
                        frames: frames
                    )
                }
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .opacity(isIdle ? 0.9 : 1)
        .animation(.easeOut(duration: 0.22), value: isIdle)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: st.viewportOffset)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: st.focusedIndex)
        .animation(.spring(response: 0.26, dampingFraction: 0.80), value: hoveredIndex)
        .contentShape(Rectangle())
    }

    private var isIdle: Bool {
        if case .idle = controller.interaction { return true }
        return false
    }

    // MARK: - Layers

    private func viewportBand(
        viewport: (start: Double, end: Double),
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> some View {
        let startX = Self.x(forRatio: viewport.start, geometries: geometries, frames: frames)
        let endX = Self.x(forRatio: viewport.end, geometries: geometries, frames: frames)
        let width = max(18, endX - startX)
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.11), .white.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
            .frame(width: width, height: Self.baselineY - Self.barsTop + 10)
            .position(x: startX + width / 2, y: (Self.barsTop + Self.baselineY) / 2)
    }

    private func bars(
        state: MinimapState,
        geometries: [DialColumnGeometry],
        frames: [CGRect],
        viewport: (start: Double, end: Double),
        drag: (column: Int, insertion: Int)?
    ) -> some View {
        let maxWidth = max(1, state.columns.map(\.width).max() ?? 1)
        return ForEach(Array(state.columns.enumerated()), id: \.element.id) { index, column in
            let frame = frames[index]
            let height = Self.barHeight(for: column.width, maxWidth: maxWidth)
            let focused = state.focusedIndex == index
            let hovered = hoveredIndex == index
            let centre = geometries.indices.contains(index) ? geometries[index].centerRatio : 0
            let inViewport = centre >= viewport.start && centre <= viewport.end
            let dragged = drag?.column == index
            let radius = frame.width / 2

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(barFill(focused: focused, hovered: hovered, inViewport: inViewport))

                if focused {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: frame.width - 8, height: 1.6)
                        .padding(.top, 3)
                }
            }
            .frame(width: frame.width, height: height)
            .shadow(
                color: focused ? Color.accentColor.opacity(0.65) : .clear,
                radius: focused ? 10 : 0
            )
            .scaleEffect(x: 1, y: hovered && !focused ? 1.03 : 1, anchor: .bottom)
            .opacity(dragged ? 0.25 : 1)
            .position(x: frame.midX, y: Self.baselineY - height / 2)
        }
    }

    private func barFill(focused: Bool, hovered: Bool, inViewport: Bool) -> LinearGradient {
        let top: Color
        let bottom: Color
        if focused {
            top = Color.accentColor
            bottom = Color.accentColor.opacity(0.48)
        } else if hovered {
            top = .white.opacity(0.85)
            bottom = .white.opacity(0.30)
        } else if inViewport {
            top = .white.opacity(0.52)
            bottom = .white.opacity(0.16)
        } else {
            top = .white.opacity(0.24)
            bottom = .white.opacity(0.07)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func baseline(frames: [CGRect]) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: Self.panelWidth - Self.insetX * 2, height: 1)
                .position(x: Self.panelWidth / 2, y: Self.baselineY + 1)

            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1, height: 3)
                    .position(x: frame.midX, y: Self.baselineY + 4)
            }
        }
    }

    private func header(state: MinimapState, drag: (column: Int, insertion: Int)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let drag {
                HUDMicroLabel(text: "DROP AT", opacity: 0.5)
                Text(String(format: "%02d", drag.insertion + 1))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            } else {
                Text(state.activeTitle.isEmpty ? "DESKTOP" : state.activeTitle.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HUDCounter(
                index: drag?.insertion ?? state.focusedIndex,
                count: state.columns.count,
                accented: drag != nil,
                size: 12
            )
        }
        .padding(.horizontal, Self.insetX)
        .position(x: Self.panelWidth / 2, y: 20)
    }

    private func insertionMarker(
        ratio: Double,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> some View {
        let x = Self.x(forRatio: ratio, geometries: geometries, frames: frames)
        return ZStack {
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: Self.baselineY - Self.barsTop + 8)
                .shadow(color: Color.accentColor.opacity(0.9), radius: 6)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .offset(y: -(Self.baselineY - Self.barsTop + 8) / 2)
        }
        .position(x: x, y: (Self.barsTop + Self.baselineY) / 2)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            HUDMicroLabel(text: "NO OPEN WINDOWS", opacity: 0.55, size: 8)
            Text("Open a window to map your desktop")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.28))
        }
    }
}
