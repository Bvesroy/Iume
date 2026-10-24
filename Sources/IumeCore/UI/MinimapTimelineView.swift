import AppKit
import SwiftUI

/// Editing-timeline HUD: the whole strip drawn as proportional segment blocks under a ruler,
/// with the on-screen window shown as a lens sliding across them.
///
/// Unlike the capsule strip, segment width *is* column width, so the bar reads as a miniature
/// of the desktop itself rather than a list of equal pills.
public struct MinimapTimelineView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 460
    nonisolated public static let panelHeight: CGFloat = 106
    nonisolated public static let insetX: CGFloat = 18
    nonisolated public static let trackTop: CGFloat = 28
    nonisolated public static let trackHeight: CGFloat = 46
    nonisolated public static let captionY: CGFloat = 89

    nonisolated public static var trackWidth: CGFloat { panelWidth - insetX * 2 }
    nonisolated public static var trackMidY: CGFloat { trackTop + trackHeight / 2 }

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

    nonisolated public static func segmentFrame(for geo: DialColumnGeometry) -> CGRect {
        let x = insetX + CGFloat(geo.startRatio) * trackWidth
        let w = max(6, CGFloat(geo.endRatio - geo.startRatio) * trackWidth)
        return CGRect(x: x, y: trackTop, width: w, height: trackHeight)
    }

    nonisolated public static func segmentFrames(for geometries: [DialColumnGeometry]) -> [CGRect] {
        geometries.map(segmentFrame(for:))
    }

    nonisolated public static func x(forRatio ratio: Double) -> CGFloat {
        insetX + CGFloat(min(1, max(0, ratio))) * trackWidth
    }

    // MARK: - Body

    public var body: some View {
        let st = controller.state
        let geometries = st.columnGeometries
        let viewport = DialGeometry.viewportRange(
            offset: st.viewportOffset,
            visibleWidth: st.visibleWidth,
            totalStripWidth: max(1, st.totalStripWidth)
        )
        let drag = dragState

        ZStack {
            HUDGlassSurface(cornerRadius: 20)

            if st.columns.isEmpty {
                emptyState
            } else {
                ruler(geometries: geometries)
                trackBed
                viewportGlow(viewport: viewport)
                segments(geometries: geometries, viewport: viewport, drag: drag)
                viewportFrame(viewport: viewport)
                if let drag {
                    insertionMarker(
                        ratio: hudInsertionRatio(
                            for: drag.insertion,
                            draggingIndex: drag.column,
                            geometries: geometries
                        )
                    )
                }
                caption(state: st, drag: drag)
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

    private func ruler(geometries: [DialColumnGeometry]) -> some View {
        ZStack {
            ForEach(0...40, id: \.self) { i in
                let major = i % 5 == 0
                Rectangle()
                    .fill(Color.white.opacity(major ? 0.20 : 0.08))
                    .frame(width: 1, height: major ? 7 : 3.5)
                    .position(x: Self.x(forRatio: Double(i) / 40.0), y: 15)
            }
            ForEach(geometries, id: \.index) { geo in
                Rectangle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: 1, height: 9)
                    .position(x: Self.x(forRatio: geo.startRatio), y: 15)
            }
        }
    }

    private var trackBed: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.75)
            )
            .frame(width: Self.trackWidth + 10, height: Self.trackHeight + 10)
            .position(x: Self.panelWidth / 2, y: Self.trackMidY)
    }

    private func viewportGlow(viewport: (start: Double, end: Double)) -> some View {
        let startX = Self.x(forRatio: viewport.start)
        let endX = Self.x(forRatio: viewport.end)
        let width = max(20, endX - startX)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .frame(width: width, height: Self.trackHeight + 8)
            .position(x: startX + width / 2, y: Self.trackMidY)
            .blur(radius: 5)
    }

    private func segments(
        geometries: [DialColumnGeometry],
        viewport: (start: Double, end: Double),
        drag: (column: Int, insertion: Int)?
    ) -> some View {
        ForEach(geometries, id: \.index) { geo in
            let frame = Self.segmentFrame(for: geo)
            let column: DialColumnInfo? = controller.state.columns.indices.contains(geo.index)
                ? controller.state.columns[geo.index]
                : nil
            let focused = controller.state.focusedIndex == geo.index
            let hovered = hoveredIndex == geo.index
            let inViewport = geo.centerRatio >= viewport.start && geo.centerRatio <= viewport.end
            let dragged = drag?.column == geo.index

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(segmentFill(focused: focused, hovered: hovered, inViewport: inViewport))

                if focused {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                }

                HStack(spacing: 6) {
                    if let column, let icon = controller.icon(for: column.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 17, height: 17)
                    }
                    if frame.width > 88, let column {
                        Text(column.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(focused ? 0.95 : 0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(width: frame.width, height: Self.trackHeight - 10)
            .shadow(
                color: focused ? Color.accentColor.opacity(0.55) : .clear,
                radius: focused ? 9 : 0
            )
            .opacity(dragged ? 0.25 : 1)
            .position(x: frame.midX, y: Self.trackMidY)
        }
    }

    private func segmentFill(focused: Bool, hovered: Bool, inViewport: Bool) -> LinearGradient {
        let top: Color
        let bottom: Color
        if focused {
            top = Color.accentColor.opacity(0.95)
            bottom = Color.accentColor.opacity(0.62)
        } else if hovered {
            top = .white.opacity(0.34)
            bottom = .white.opacity(0.20)
        } else if inViewport {
            top = .white.opacity(0.20)
            bottom = .white.opacity(0.11)
        } else {
            top = .white.opacity(0.10)
            bottom = .white.opacity(0.05)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func viewportFrame(viewport: (start: Double, end: Double)) -> some View {
        let startX = Self.x(forRatio: viewport.start)
        let endX = Self.x(forRatio: viewport.end)
        let width = max(20, endX - startX)
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.82), lineWidth: 1.4)

            // End caps make the lens read as an open window rather than a floating box.
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: 14)
                .position(x: 1, y: (Self.trackHeight + 6) / 2)
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: 14)
                .position(x: width - 1, y: (Self.trackHeight + 6) / 2)
        }
        .frame(width: width, height: Self.trackHeight + 6)
        .position(x: startX + width / 2, y: Self.trackMidY)
        .shadow(color: .white.opacity(0.22), radius: 5)
    }

    private func insertionMarker(ratio: Double) -> some View {
        let x = Self.x(forRatio: ratio)
        return ZStack {
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: Self.trackHeight + 26)
                .shadow(color: Color.accentColor.opacity(0.9), radius: 7)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(y: -(Self.trackHeight + 26) / 2)
        }
        .position(x: x, y: Self.trackMidY)
    }

    private func caption(state: MinimapState, drag: (column: Int, insertion: Int)?) -> some View {
        HStack(spacing: 6) {
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
                    .foregroundStyle(.white.opacity(0.46))
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
        .padding(.horizontal, 2)
        .frame(width: Self.trackWidth)
        .position(x: Self.panelWidth / 2, y: Self.captionY)
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
