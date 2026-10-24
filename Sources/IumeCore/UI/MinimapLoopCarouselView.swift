import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// One window drawn on the 3D loop drum.
///
/// The drum is a horizontal cylinder seen slightly from the front: each column sits at an angle
/// around it, so as the strip scrolls the cards swing across the front, turn away and pass behind
/// their neighbours. That motion is what makes the strip read as a loop rather than a flat rail.
public struct LoopCarouselCard: Equatable, Sendable {
    /// Column index in the strip.
    public var index: Int
    /// Signed angle (degrees) from the drum's front. Negative is left of centre.
    public var angle: Double
    /// Card centre in panel points (y grows downward, matching SwiftUI).
    public var x: CGFloat
    public var y: CGFloat
    /// Perspective size multiplier; 1.0 is the card sitting dead centre.
    public var scale: CGFloat
    /// Fades cards as they rotate towards the back of the drum.
    public var opacity: Double
    public var isFocused: Bool
    /// Drawn side length in points, already scaled.
    public var side: CGFloat

    public var frame: CGRect {
        CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }
}

/// Pure, AppKit-free mathematics for the 3D loop carousel.
///
/// Kept free of UI types so the drum can be unit tested directly: the same numbers drive the
/// artwork, the click targets and the 1:1 scrub mapping, which is the only way the drawn cards and
/// the pointer can never disagree.
public enum LoopCarouselGeometry {
    public nonisolated static let panelWidth: CGFloat = 480
    public nonisolated static let panelHeight: CGFloat = 262

    /// Angular distance between neighbouring columns on the drum.
    public nonisolated static let spacingDegrees: Double = 34
    /// Camera distance. Large enough that the perspective reads as a drum and not a fisheye.
    public nonisolated static let cameraDistance: CGFloat = 900

    public nonisolated static let cardSide: CGFloat = 46
    public nonisolated static let focusedCardSide: CGFloat = 58
    public nonisolated static let centreY: CGFloat = 148

    /// Radius of the drawn drum, matched to the panel width.
    public nonisolated static func radius(forPanelWidth width: CGFloat = panelWidth) -> CGFloat {
        max(96, width / 2 - 78)
    }

    /// Signed distance in column slots from the front of the drum, wrapped the short way round.
    ///
    /// Wrapping is what makes the loop feel endless: the column after the last one is one slot to
    /// the right of the front, not `count - 1` slots to the left.
    public nonisolated static func signedOffset(index: Int, focusedIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let raw = ((index - focusedIndex) % count + count) % count
        let half = count / 2
        if count % 2 == 0 {
            return raw <= half ? raw : raw - count
        }
        return raw < half ? raw : raw - count
    }

    /// Angle (degrees) of a column around the drum.
    public nonisolated static func angle(index: Int, focusedIndex: Int, count: Int) -> Double {
        Double(signedOffset(index: index, focusedIndex: focusedIndex, count: count)) * spacingDegrees
    }

    /// Full card layout, ordered back to front so a `ForEach` over it paints correctly.
    public nonisolated static func cards(
        count: Int,
        focusedIndex: Int,
        panelWidth: CGFloat = panelWidth
    ) -> [LoopCarouselCard] {
        guard count > 0 else { return [] }
        let radius = radius(forPanelWidth: panelWidth)
        let frontDepth = cameraDistance - radius

        let cards: [LoopCarouselCard] = (0..<count).map { index in
            let angle = angle(index: index, focusedIndex: focusedIndex, count: count)
            let theta = angle * .pi / 180
            let z = radius * CGFloat(cos(theta))
            let scale = max(0.55, min(1.35, frontDepth / max(1, cameraDistance - z)))
            let focused = index == focusedIndex
            let baseSide = focused ? focusedCardSide : cardSide
            let side = baseSide * scale
            let magnitude = abs(angle)
            let opacity = magnitude <= 92
                ? 1.0
                : max(0, 1 - (magnitude - 92) / 52)

            return LoopCarouselCard(
                index: index,
                angle: angle,
                x: panelWidth / 2 + radius * CGFloat(sin(theta)),
                y: centreY + (1 - scale) * 26,
                scale: scale,
                opacity: opacity,
                isFocused: focused,
                side: side
            )
        }

        // cos(angle) is the depth: smallest first (back of the drum) so nearer cards paint on top.
        return cards.sorted { cos($0.angle * .pi / 180) < cos($1.angle * .pi / 180) }
    }

    /// The column under a point, preferring the card nearest the front.
    public nonisolated static func columnIndex(
        at point: CGPoint,
        cards: [LoopCarouselCard]
    ) -> Int? {
        var best: LoopCarouselCard?
        for card in cards.reversed() {
            let frame = card.frame.insetBy(dx: -6, dy: -6)
            guard frame.contains(point) else { continue }
            if best == nil || cos(card.angle * .pi / 180) > cos(best!.angle * .pi / 180) {
                best = card
            }
        }
        if let best { return best.index }

        // Between cards: accept the closest centre within a generous thumb-sized radius.
        var nearest: (index: Int, distance: CGFloat)?
        for card in cards {
            let distance = hypot(point.x - card.x, point.y - card.y)
            guard distance <= 22 else { continue }
            if nearest == nil || distance < nearest!.distance {
                nearest = (card.index, distance)
            }
        }
        return nearest?.index
    }

    /// Strip ratio travelled per point of horizontal pointer movement.
    ///
    /// One full column per card spacing on the drum, so dragging the carousel feels like turning
    /// the drum by hand instead of scrubbing a flat ruler.
    public nonisolated static func scrubRatioPerPoint(
        count: Int,
        panelWidth: CGFloat = panelWidth
    ) -> Double {
        guard count > 0 else { return 0 }
        let radius = Double(radius(forPanelWidth: panelWidth))
        let spacing = spacingDegrees * .pi / 180
        return (1.0 / Double(count)) / max(1, radius * spacing)
    }

    /// How many whole laps the strip has travelled past its start. Loop Mode allows negatives.
    ///
    /// Truncates toward zero: a few points past a lap boundary should not flip the badge before
    /// the lap has actually been completed in the direction of travel.
    public nonisolated static func lapIndex(viewportOffset: CGFloat, totalStripWidth: CGFloat) -> Int {
        guard totalStripWidth > 1 else { return 0 }
        return Int((viewportOffset / totalStripWidth).rounded(.towardZero))
    }
}

/// 3D loop carousel HUD: open windows ride a horizontal drum that turns as you scroll.
///
/// The flat instruments answer "where am I on the strip". This one answers "which way is it
/// turning": cards swing across the front, rotate away and pass behind their neighbours, so the
/// endless strip reads as a real loop rather than a line that stops at both ends. It is designed
/// for Loop Mode but works in every strip layout.
public struct MinimapLoopCarouselView: View {
    @ObservedObject var controller: MinimapHUDController

    nonisolated public static let panelWidth = LoopCarouselGeometry.panelWidth
    nonisolated public static let panelHeight = LoopCarouselGeometry.panelHeight

    /// Slow sweep around the drum's base, the one bit of motion that keeps turning while the
    /// strip is at rest. Animating a single trimmed arc keeps it on the compositor instead of
    /// re-rendering the whole drum every frame.
    @State private var sweepDegrees: Double = 0

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

    private var isLooping: Bool { SettingsStore.shared.loopMode }

    public var body: some View {
        let st = controller.state
        let cards = LoopCarouselGeometry.cards(
            count: st.columns.count,
            focusedIndex: st.focusedIndex
        )

        ZStack {
            HUDGlassSurface(cornerRadius: 26)

            if st.columns.isEmpty {
                emptyState
            } else {
                drum
                ForEach(cards, id: \.index) { card in
                    cardView(card, state: st)
                }
                focusedHalo(cards: cards)
                header(state: st)
                footer(state: st)
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .opacity(isIdle ? 0.92 : 1)
        .animation(.easeOut(duration: 0.22), value: isIdle)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: st.focusedIndex)
        .contentShape(Rectangle())
    }

    private var isIdle: Bool {
        if case .idle = controller.interaction { return true }
        return false
    }

    // MARK: - Drum

    private var drum: some View {
        let ringWidth = Self.panelWidth - 84
        let ringHeight: CGFloat = 58
        let center = CGPoint(x: Self.panelWidth / 2, y: LoopCarouselGeometry.centreY + 52)

        // Every ring layer is concentric and placed in panel coordinates, so the artwork stays
        // aligned with the cards no matter how wide the drum is.
        return ZStack {
            // Warm pool of light under the drum, so the cards sit on something.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.16), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: ringWidth / 2
                    )
                )
                .frame(width: ringWidth, height: ringHeight)
                .position(center)

            Ellipse()
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                .frame(width: ringWidth, height: ringHeight)
                .position(center)

            Ellipse()
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: ringWidth - 26, height: ringHeight - 12)
                .position(center)

            // The travelling glint that marks the loop as endless. Rotate the circle first, then
            // squash it into the drum's ellipse, or the arc would wobble as it turns.
            Circle()
                .trim(from: 0, to: 0.16)
                .stroke(
                    LinearGradient(
                        colors: [.clear, Color.accentColor.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
                .frame(width: ringWidth, height: ringWidth)
                .rotationEffect(.degrees(sweepDegrees))
                .scaleEffect(x: 1, y: ringHeight / ringWidth)
                .opacity(isLooping ? 1 : 0)
                .position(center)
                .onAppear(perform: startSweep)
                .onChange(of: isLooping) { _, looping in
                    if looping { startSweep() } else { sweepDegrees = 0 }
                }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .allowsHitTesting(false)
    }

    private func startSweep() {
        sweepDegrees = 0
        guard isLooping else { return }
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
            sweepDegrees = 360
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func cardView(_ card: LoopCarouselCard, state: MinimapState) -> some View {
        let column = state.columns.indices.contains(card.index) ? state.columns[card.index] : nil
        let hovered = hoveredIndex == card.index
        let dragged = dragState?.column == card.index
        let corner = max(7, card.side * 0.24)

        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.opacity(0.42))

            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if let bundle = column?.bundleIdentifier, let icon = controller.icon(for: bundle) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .padding(card.side * 0.12)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: max(9, card.side * 0.30), weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: card.side, height: card.side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    card.isFocused
                        ? Color.white.opacity(0.92)
                        : (hovered ? Color.white.opacity(0.55) : Color.white.opacity(0.14)),
                    lineWidth: card.isFocused ? 1.6 : 1
                )
        )
        .shadow(
            color: card.isFocused ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.35),
            radius: card.isFocused ? 12 : 5,
            y: 2
        )
        .opacity(card.opacity * (dragged ? 0.20 : 1))
        // Turning the card away from the viewer around the drum's axis is what sells the depth.
        .rotation3DEffect(
            .degrees(-card.angle * 0.55),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: 0.55
        )
        .position(x: card.x, y: card.y)
    }

    /// Soft accent pool under the front card, tying the focused window to the camera.
    private func focusedHalo(cards: [LoopCarouselCard]) -> some View {
        Group {
            if let front = cards.first(where: { $0.isFocused }) {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.22), .clear],
                            center: .center,
                            startRadius: 1,
                            endRadius: front.side * 0.75
                        )
                    )
                    .frame(width: front.side * 1.5, height: front.side * 0.55)
                    .position(x: front.x, y: front.y + front.side * 0.62)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Chrome

    private func header(state: MinimapState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(isLooping ? 0.9 : 0.35))
                HUDMicroLabel(text: isLooping ? "3D LOOP" : "3D STRIP", opacity: 0.55)
            }

            Text(state.activeTitle.isEmpty ? "DESKTOP" : state.activeTitle.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Spacer(minLength: 8)

            HUDCounter(
                index: dragState?.insertion ?? state.focusedIndex,
                count: state.columns.count,
                accented: dragState != nil,
                size: 11
            )
        }
        .padding(.horizontal, 22)
        .position(x: Self.panelWidth / 2, y: 24)
    }

    private func footer(state: MinimapState) -> some View {
        let lap = LoopCarouselGeometry.lapIndex(
            viewportOffset: state.viewportOffset,
            totalStripWidth: state.totalStripWidth
        )

        return HStack(spacing: 8) {
            if isLooping {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                        .font(.system(size: 7, weight: .bold))
                    Text(lap == 0 ? "LAP 01" : String(format: "LAP %@%02d", lap > 0 ? "+" : "-", abs(lap)))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.accentColor.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
            } else {
                HUDMicroLabel(text: "STRIP", opacity: 0.34, size: 8)
            }

            Spacer(minLength: 6)

            if let drag = dragState {
                Text(String(format: "DROP AT %02d", drag.insertion + 1))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("DRAG TO SPIN")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .padding(.horizontal, 22)
        .position(x: Self.panelWidth / 2, y: Self.panelHeight - 20)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            HUDMicroLabel(text: "NO OPEN WINDOWS", opacity: 0.55, size: 8)
            Text("Open a window to load the loop")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.28))
        }
    }
}
