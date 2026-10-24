import AppKit
import SwiftUI

/// Vertical edge rail: the strip turned into a column of window rows docked against the right
/// edge of the screen. Rows inside the on-screen window brighten together, so the rail answers
/// "what is visible?" without covering the desktop.
public struct MinimapEdgeRailView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 244
    nonisolated public static let headerHeight: CGFloat = 66
    nonisolated public static let bottomPadding: CGFloat = 14
    nonisolated public static let rowInset: CGFloat = 12
    nonisolated public static let rowGap: CGFloat = 4
    nonisolated public static let minRowHeight: CGFloat = 16
    nonisolated public static let preferredRowHeight: CGFloat = 50
    nonisolated public static let maxPanelHeight: CGFloat = 560

    /// The rail hugs its rows: a two-window desktop gets a short rail, twenty windows get a
    /// tall one that stops at `maxPanelHeight` and compresses the rows instead of overflowing.
    nonisolated public static func panelHeight(for count: Int) -> CGFloat {
        let n = max(1, count)
        let natural = headerHeight + bottomPadding
            + CGFloat(n) * preferredRowHeight
            + CGFloat(n - 1) * rowGap
        return min(maxPanelHeight, max(132, natural))
    }

    /// Panel height for the style-only queries the controller makes before it knows the count.
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

    nonisolated public static func rowFrames(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let height = panelHeight(for: count)
        let available = height - headerHeight - bottomPadding
        let pitch = min(
            preferredRowHeight + rowGap,
            max(minRowHeight + rowGap, available / CGFloat(count))
        )
        let rowHeight = max(8, pitch - rowGap)
        let total = CGFloat(count) * pitch - rowGap
        let startY = headerHeight + max(0, (available - total) / 2)
        return (0..<count).map { index in
            CGRect(
                x: rowInset,
                y: startY + CGFloat(index) * pitch,
                width: panelWidth - rowInset * 2,
                height: rowHeight
            )
        }
    }

    nonisolated public static func y(
        forRatio ratio: Double,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> CGFloat {
        let pairs = zip(geometries, frames).map { (ratio: $0.centerRatio, y: $1.midY) }
        guard let first = pairs.first, let last = pairs.last else {
            return (headerHeight + panelHeight(for: geometries.count) - bottomPadding) / 2
        }
        guard pairs.count > 1 else { return first.y }

        if ratio <= first.ratio {
            let next = pairs[1]
            let slope = (next.y - first.y) / CGFloat(max(1e-9, next.ratio - first.ratio))
            return first.y + CGFloat(ratio - first.ratio) * slope
        }
        if ratio >= last.ratio {
            let prev = pairs[pairs.count - 2]
            let slope = (last.y - prev.y) / CGFloat(max(1e-9, last.ratio - prev.ratio))
            return last.y + CGFloat(ratio - last.ratio) * slope
        }
        for i in 1..<pairs.count where ratio <= pairs[i].ratio {
            let a = pairs[i - 1]
            let b = pairs[i]
            let t = (ratio - a.ratio) / max(1e-9, b.ratio - a.ratio)
            return a.y + CGFloat(t) * (b.y - a.y)
        }
        return last.y
    }

    nonisolated public static func ratio(
        forY y: CGFloat,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> Double {
        let pairs = zip(geometries, frames).map { (ratio: $0.centerRatio, y: $1.midY) }
        guard let first = pairs.first, let last = pairs.last else { return 0 }
        guard pairs.count > 1 else { return first.ratio }

        if y <= first.y {
            let next = pairs[1]
            let slope = (next.ratio - first.ratio) / Double(max(1e-9, next.y - first.y))
            return first.ratio + Double(y - first.y) * slope
        }
        if y >= last.y {
            let prev = pairs[pairs.count - 2]
            let slope = (last.ratio - prev.ratio) / Double(max(1e-9, last.y - prev.y))
            return last.ratio + Double(y - last.y) * slope
        }
        for i in 1..<pairs.count where y <= pairs[i].y {
            let a = pairs[i - 1]
            let b = pairs[i]
            let t = Double((y - a.y) / max(1e-9, b.y - a.y))
            return a.ratio + t * (b.ratio - a.ratio)
        }
        return last.ratio
    }

    // MARK: - Body

    public var body: some View {
        let st = controller.state
        let geometries = st.columnGeometries
        let frames = Self.rowFrames(count: st.columns.count)
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: max(1, st.totalStripWidth)
        )
        let drag = dragState

        ZStack {
            HUDGlassSurface(cornerRadius: 24)

            if st.columns.isEmpty {
                emptyState
            } else {
                header(state: st, drag: drag)
                viewportLens(viewport: viewport, geometries: geometries, frames: frames)
                rows(state: st, geometries: geometries, frames: frames, viewport: viewport, drag: drag)
                if let drag {
                    insertionMarker(
                        ratio: hudInsertionRatio(for: drag.insertion, draggingIndex: drag.column, geometries: geometries),
                        geometries: geometries,
                        frames: frames
                    )
                }
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight(for: st.columns.count))
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

    private func header(state: MinimapState, drag: (column: Int, insertion: Int)?) -> some View {
        ZStack {
            HStack {
                HUDMicroLabel(text: "WINDOWS", opacity: 0.42, size: 7)
                Spacer()
                HUDCounter(
                    index: drag?.insertion ?? state.focusedIndex,
                    count: state.columns.count,
                    accented: drag != nil,
                    size: 11
                )
            }
            .padding(.horizontal, 16)
            .position(x: Self.panelWidth / 2, y: 22)

            Text(drag == nil ? (state.activeTitle.isEmpty ? "Desktop" : state.activeTitle) : "Release to move")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.panelWidth - 32, alignment: .leading)
                .position(x: Self.panelWidth / 2, y: 44)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: Self.panelWidth - 32, height: 1)
                .position(x: Self.panelWidth / 2, y: 58)
        }
    }

    private func viewportLens(
        viewport: (start: Double, end: Double),
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> some View {
        let top = Self.y(forRatio: viewport.start, geometries: geometries, frames: frames)
        let bottom = Self.y(forRatio: viewport.end, geometries: geometries, frames: frames)
        let height = max(10, bottom - top)
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .frame(width: Self.panelWidth - 12, height: height)
            .position(x: Self.panelWidth / 2, y: top + height / 2)
    }

    private func rows(
        state: MinimapState,
        geometries: [DialColumnGeometry],
        frames: [CGRect],
        viewport: (start: Double, end: Double),
        drag: (column: Int, insertion: Int)?
    ) -> some View {
        let maxWidth = max(1, state.columns.map(\.width).max() ?? 1)
        return ForEach(Array(state.columns.enumerated()), id: \.element.id) { index, column in
            let frame = frames[index]
            let focused = state.focusedIndex == index
            let hovered = hoveredIndex == index
            let center = geometries.indices.contains(index) ? geometries[index].centerRatio : 0
            let inViewport = center >= viewport.start && center <= viewport.end
            let dragged = drag?.column == index
            let dropTarget = drag?.insertion == index && drag?.column != index

            HStack(spacing: 8) {
                if let icon = controller.icon(for: column.bundleIdentifier) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 17, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 17, height: 17)
                }

                Text(column.appName)
                    .font(.system(size: 10.5, weight: focused ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(focused ? 0.95 : (inViewport ? 0.72 : 0.42)))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Capsule()
                    .fill(.white.opacity(focused ? 0.75 : (inViewport ? 0.36 : 0.18)))
                    .frame(width: max(6, 32 * (column.width / maxWidth)), height: 3)
            }
            .padding(.horizontal, 9)
            .frame(width: frame.width, height: frame.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill(focused: focused, hovered: hovered, inViewport: inViewport))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        dropTarget ? Color.white.opacity(0.9) : (focused ? Color.white.opacity(0.45) : .clear),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .leading) {
                if focused {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: max(8, frame.height - 14))
                        .padding(.leading, 3)
                        .shadow(color: Color.accentColor.opacity(0.8), radius: 4)
                }
            }
            .shadow(color: focused ? Color.accentColor.opacity(0.30) : .clear, radius: 8)
            .opacity(dragged ? 0.22 : 1)
            .position(x: frame.midX, y: frame.midY)
        }
    }

    private func rowFill(focused: Bool, hovered: Bool, inViewport: Bool) -> Color {
        if focused { return Color.accentColor.opacity(0.20) }
        if hovered { return .white.opacity(0.10) }
        if inViewport { return .white.opacity(0.055) }
        return .white.opacity(0.02)
    }

    private func insertionMarker(
        ratio: Double,
        geometries: [DialColumnGeometry],
        frames: [CGRect]
    ) -> some View {
        let y = Self.y(forRatio: ratio, geometries: geometries, frames: frames)
        return Capsule()
            .fill(Color.white)
            .frame(width: Self.panelWidth - 24, height: 2)
            .shadow(color: Color.accentColor.opacity(0.9), radius: 6)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .offset(x: -2)
            }
            .position(x: Self.panelWidth / 2, y: y)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            HUDMicroLabel(text: "NO OPEN WINDOWS", opacity: 0.55, size: 8)
            Text("Open a window to map your desktop")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.28))
        }
    }
}
