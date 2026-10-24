import AppKit
import SwiftUI

/// Minimalist horizontal Floating Glass Capsule HUD with interactive, draggable app pills
/// so open windows can be reordered directly from the linear bar.
public struct MinimapLinearView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth: CGFloat = 420
    nonisolated public static let panelHeight: CGFloat = 76

    public init(controller: MinimapHUDController) {
        self.controller = controller
    }

    private var hoveredIndex: Int? {
        if case .hovering(let c) = controller.interaction { return c }
        return nil
    }

    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let count = max(1, st.columns.count)
        let dragState: (column: Int, insertion: Int)? = {
            if case .dragging(let c, let i) = controller.interaction { return (c, i) }
            return nil
        }()

        VStack(spacing: 6) {
            // Header Info Line
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: Color.accentColor.opacity(0.8), radius: 3)

                Text(st.activeTitle.isEmpty ? "Strip" : st.activeTitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                if let dragState {
                    Text("Drop at Position \(dragState.insertion + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Color.accentColor)
                } else {
                    Text("Drag pill to reorder • \(min(count, st.focusedIndex + 1))/\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.68))
                }
            }
            .padding(.horizontal, 4)

            // Track & Draggable Window Pills
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let trackHeight = geo.size.height

                ZStack(alignment: .leading) {
                    // Track Background
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))

                    // Viewport Indicator Box
                    let vpRatio = min(1.0, st.visibleWidth / totalW)
                    let vpWidth = max(28.0, vpRatio * trackWidth)
                    let offsetRatio = min(max(0, st.viewportOffset / totalW), 1.0 - (vpWidth / trackWidth))
                    let vpX = offsetRatio * trackWidth

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                        )
                        .frame(width: vpWidth, height: trackHeight)
                        .offset(x: max(0, vpX))

                    // Draggable Column Pills with App Icons
                    HStack(spacing: 4) {
                        ForEach(0..<st.columns.count, id: \.self) { idx in
                            let col = st.columns[idx]
                            let fraction = col.width / totalW
                            let isFocused = (idx == st.focusedIndex)
                            let isHovered = (hoveredIndex == idx)
                            let isDragged = (dragState?.column == idx)
                            let isDropTarget = (dragState?.insertion == idx && dragState?.column != idx)
                            let pillW = max(24, fraction * (trackWidth - CGFloat(count * 4)))

                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        isFocused
                                            ? Color.accentColor.opacity(0.85)
                                            : (isHovered ? Color.white.opacity(0.32) : Color.white.opacity(0.16))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(
                                                isDropTarget
                                                    ? Color.white
                                                    : (isFocused ? Color.white.opacity(0.85) : Color.white.opacity(0.18)),
                                                lineWidth: isDropTarget ? 2.0 : 1.0
                                            )
                                    )

                                HStack(spacing: 4) {
                                    if let icon = controller.icon(for: col.bundleIdentifier) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: 14, height: 14)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    if pillW >= 54 {
                                        Text(col.appName)
                                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            .frame(width: pillW, height: trackHeight - 4)
                            .opacity(isDragged ? 0.28 : 1.0)
                            .scaleEffect(isHovered ? 1.04 : 1.0)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.62))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 6)
    }
}
