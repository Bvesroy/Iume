import AppKit
import SwiftUI

/// How a tape maps strip ratios onto panel points.
///
/// Short strips fit entirely and the playhead travels; long strips scroll under a fixed centre
/// reticle showing about seven windows at a time.
public struct TapeLayout: Equatable, Sendable {
    /// Strip ratio sitting at panel x = 0.
    public var originRatio: Double
    /// Strip ratio travelled per point of pointer movement.
    public var ratioPerPoint: Double
    /// Where the viewport playhead is drawn.
    public var reticleX: CGFloat

    public init(originRatio: Double, ratioPerPoint: Double, reticleX: CGFloat) {
        self.originRatio = originRatio
        self.ratioPerPoint = ratioPerPoint
        self.reticleX = reticleX
    }

    public func x(forRatio ratio: Double) -> CGFloat {
        CGFloat((ratio - originRatio) / max(1e-9, ratioPerPoint))
    }

    public func ratio(atX x: CGFloat) -> Double {
        originRatio + Double(x) * ratioPerPoint
    }
}

/// Tape HUD: a short section of the strip rides under a fixed centre reticle, like the focus
/// ring of a camera lens. Because it only shows the windows around the current position it stays
/// readable even with thirty windows open.
public struct MinimapTapeView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 320
    nonisolated public static let panelHeight: CGFloat = 96
    nonisolated public static let edgeInset: CGFloat = 26
    nonisolated public static let topRailY: CGFloat = 34
    nonisolated public static let bottomRailY: CGFloat = 72
    nonisolated public static let iconY: CGFloat = 53
    nonisolated public static let visibleColumns = 7

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

    // MARK: - Layout maths (shared with hit-testing and the 1:1 scrub anchor)

    nonisolated public static var usableWidth: CGFloat { panelWidth - edgeInset * 2 }

    /// Ratio span the tape shows. Everything fits up to `visibleColumns`; beyond that the tape
    /// keeps a constant zoom rather than squeezing thirty windows into 268 points.
    nonisolated public static func visibleSpan(columnCount: Int) -> Double {
        guard columnCount > 0 else { return 1 }
        return min(1.0, Double(visibleColumns) / Double(columnCount))
    }

    nonisolated public static func layout(
        columnCount: Int,
        viewportCentreRatio: Double
    ) -> TapeLayout {
        let centre = min(1, max(0, viewportCentreRatio))
        let usable = usableWidth

        if columnCount <= visibleColumns {
            // The whole strip fits: span the usable width and let the playhead travel.
            let perPoint = 1.0 / Double(usable)
            return TapeLayout(
                originRatio: -Double(edgeInset) / Double(usable),
                ratioPerPoint: perPoint,
                reticleX: edgeInset + CGFloat(centre) * usable
            )
        }

        let span = visibleSpan(columnCount: columnCount)
        let perPoint = span / Double(usable)
        return TapeLayout(
            originRatio: centre - Double(panelWidth / 2) * perPoint,
            ratioPerPoint: perPoint,
            reticleX: panelWidth / 2
        )
    }

    nonisolated public static func iconFrames(
        geometries: [DialColumnGeometry],
        viewportCentreRatio: Double,
        size: CGFloat = 24
    ) -> [CGRect] {
        let layout = layout(columnCount: geometries.count, viewportCentreRatio: viewportCentreRatio)
        return geometries.map { geo in
            let x = layout.x(forRatio: geo.centerRatio)
            return CGRect(x: x - size / 2, y: iconY - size / 2, width: size, height: size)
        }
    }

    // MARK: - Body

    public var body: some View {
        let st = controller.state
        let geometries = st.columnGeometries
        let centre = Self.viewportCentreRatio(of: st)
        let layout = Self.layout(columnCount: geometries.count, viewportCentreRatio: centre)
        let drag = dragState

        ZStack {
            HUDGlassSurface(cornerRadius: 22)

            if st.columns.isEmpty {
                emptyState
            } else {
                rails
                ticks(geometries: geometries, layout: layout)
                reticle(at: layout.reticleX)
                icons(state: st, geometries: geometries, layout: layout)
                header(state: st, drag: drag)
                if let drag {
                    insertionMarker(
                        ratio: hudInsertionRatio(for: drag.insertion, draggingIndex: drag.column, geometries: geometries),
                        layout: layout
                    )
                }
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .opacity(isIdle ? 0.9 : 1)
        .animation(.easeOut(duration: 0.22), value: isIdle)
        // No spring on the scroll offset: the tape is grabbed 1:1, so it must track the pointer
        // exactly rather than trailing it.
        .animation(.spring(response: 0.26, dampingFraction: 0.80), value: hoveredIndex)
        .contentShape(Rectangle())
    }

    private var isIdle: Bool {
        if case .idle = controller.interaction { return true }
        return false
    }

    nonisolated public static func viewportCentreRatio(of state: MinimapState) -> Double {
        guard state.totalStripWidth > 0 else { return 0.5 }
        let centre = (state.viewportOffset + state.visibleWidth / 2) / state.totalStripWidth
        return min(1, max(0, Double(centre)))
    }

    // MARK: - Layers

    private var rails: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: Self.panelWidth - 16, height: 1)
                .position(x: Self.panelWidth / 2, y: Self.topRailY)
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: Self.panelWidth - 16, height: 1)
                .position(x: Self.panelWidth / 2, y: Self.bottomRailY)
        }
    }

    private func ticks(geometries: [DialColumnGeometry], layout: TapeLayout) -> some View {
        ForEach(geometries, id: \.index) { geo in
            let x = layout.x(forRatio: geo.centerRatio)
            let focused = controller.state.focusedIndex == geo.index
            Rectangle()
                .fill(Color.white.opacity(focused ? 0.55 : 0.16))
                .frame(width: focused ? 1.5 : 1, height: focused ? 10 : 6)
                .position(x: x, y: Self.bottomRailY - 4)
                .opacity(abs(x - Self.panelWidth / 2) < Self.panelWidth / 2 - 6 ? 1 : 0)
        }
    }

    private func icons(
        state: MinimapState,
        geometries: [DialColumnGeometry],
        layout: TapeLayout
    ) -> some View {
        ForEach(Array(state.columns.enumerated()), id: \.element.id) { index, column in
            let x = geometries.indices.contains(index) ? layout.x(forRatio: geometries[index].centerRatio) : Self.panelWidth / 2
            let focused = state.focusedIndex == index
            let hovered = hoveredIndex == index
            let dragged = dragState?.column == index
            // A strip that fits is shown whole, so nothing should fade at its edges.
            let dx = abs(x - layout.reticleX)
            let fade = state.columns.count <= Self.visibleColumns
                ? 1
                : max(0, 1 - pow(min(1, dx / (Self.panelWidth / 2 - 8)), 2.4))
            let size: CGFloat = focused ? 27 : 23

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.35))

                if let icon = controller.icon(for: column.bundleIdentifier) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .padding(2.5)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        focused ? Color.white.opacity(0.9) : (hovered ? Color.white.opacity(0.55) : Color.white.opacity(0.12)),
                        lineWidth: focused ? 1.4 : 1
                    )
            )
            .shadow(color: focused ? Color.accentColor.opacity(0.75) : .clear, radius: 9)
            .opacity((dragged ? 0.22 : 1) * fade)
            .position(x: x, y: Self.iconY)
        }
    }

    private func reticle(at x: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 1.5, height: 48)
                .shadow(color: Color.accentColor.opacity(0.65), radius: 5)

            Circle()
                .fill(Color.white)
                .frame(width: 4, height: 4)
                .offset(y: -24)

            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 3.5, height: 3.5)
                .offset(y: 24)
        }
        .position(x: x, y: Self.iconY)
    }

    private func header(state: MinimapState, drag: (column: Int, insertion: Int)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let drag {
                HUDMicroLabel(text: "DROP AT", opacity: 0.5)
                Text(String(format: "%02d", drag.insertion + 1))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                size: 11
            )
        }
        .padding(.horizontal, 18)
        .position(x: Self.panelWidth / 2, y: 19)
    }

    private func insertionMarker(ratio: Double, layout: TapeLayout) -> some View {
        let x = layout.x(forRatio: ratio)
        return ZStack {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2.5, height: Self.bottomRailY - Self.topRailY + 8)
                .shadow(color: Color.accentColor.opacity(0.95), radius: 7)

            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .offset(y: -(Self.bottomRailY - Self.topRailY + 8) / 2)
        }
        .position(x: x, y: (Self.topRailY + Self.bottomRailY) / 2)
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
