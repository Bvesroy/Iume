import Testing
import CoreGraphics
@testable import IumeCore

@Suite("3D Loop Carousel HUD Tests", .serialized)
struct LoopCarouselHUDTests {
    @Test("Carousel places the focused window at the front of the drum")
    func testFocusedCardSitsFront() {
        let cards = LoopCarouselGeometry.cards(count: 5, focusedIndex: 2)
        #expect(cards.count == 5)

        let front = cards.first { $0.isFocused }
        #expect(front?.index == 2)
        #expect(front?.angle == 0)
        #expect(abs((front?.x ?? 0) - LoopCarouselGeometry.panelWidth / 2) < 0.5)

        // The front card is the biggest one on the drum and drawn last (nearest the viewer).
        let maxSide = cards.map(\.side).max() ?? 0
        #expect(front?.side == maxSide)
        #expect(cards.last?.isFocused == true)
    }

    @Test("The last column wraps to the short side, so the strip reads as an endless loop")
    func testWrapAroundOrdering() {
        // Focused on the first column: the last one is the previous lap, one slot to the LEFT,
        // not four slots to the right.
        let cards = LoopCarouselGeometry.cards(count: 5, focusedIndex: 0)
        let last = cards.first { $0.index == 4 }
        let second = cards.first { $0.index == 1 }

        #expect(last?.angle == -LoopCarouselGeometry.spacingDegrees)
        #expect(second?.angle == LoopCarouselGeometry.spacingDegrees)
        #expect((last?.x ?? 0) < LoopCarouselGeometry.panelWidth / 2)
        #expect((second?.x ?? 0) > LoopCarouselGeometry.panelWidth / 2)
    }

    @Test("Cards behind the drum fade out instead of piling up")
    func testRearCardsFade() {
        let cards = LoopCarouselGeometry.cards(count: 12, focusedIndex: 0)
        for card in cards {
            if abs(card.angle) > 150 {
                #expect(card.opacity == 0)
            } else if abs(card.angle) < 90 {
                #expect(card.opacity == 1)
            }
        }
    }

    @Test("Visible cards stay inside the panel and clear of the chrome")
    func testLayoutBounds() {
        for count in [1, 2, 3, 5, 9, 20] {
            let cards = LoopCarouselGeometry.cards(count: count, focusedIndex: 0)
            #expect(cards.count == count)
            for card in cards where card.opacity > 0 {
                let frame = card.frame
                #expect(frame.minX >= -8)
                #expect(frame.maxX <= LoopCarouselGeometry.panelWidth + 8)
                #expect(frame.minY >= 56) // header band
                #expect(frame.maxY <= LoopCarouselGeometry.panelHeight - 28) // footer band
            }
        }
    }

    @Test("Clicking a drawn card resolves to that column")
    func testHitTestingRoundTrips() {
        let cards = LoopCarouselGeometry.cards(count: 6, focusedIndex: 3)

        // Cards close to the front are fully visible and never overlap at their centres, so a
        // click on one must select exactly that window.
        let frontCards = cards.filter { abs($0.angle) <= LoopCarouselGeometry.spacingDegrees * 1.5 }
        #expect(frontCards.count == 3)
        for card in frontCards {
            let hit = LoopCarouselGeometry.columnIndex(
                at: CGPoint(x: card.x, y: card.y),
                cards: cards
            )
            #expect(hit == card.index)
        }

        // Where a faded card sits behind a nearer one, the nearer card wins the click.
        let overlap = LoopCarouselGeometry.columnIndex(
            at: CGPoint(x: LoopCarouselGeometry.panelWidth / 2, y: LoopCarouselGeometry.centreY),
            cards: cards
        )
        #expect(overlap == 3)

        // Empty space far from the drum belongs to no column.
        let miss = LoopCarouselGeometry.columnIndex(
            at: CGPoint(x: 4, y: 4),
            cards: cards
        )
        #expect(miss == nil)
    }

    @Test("A drag across the panel turns exactly one lap of the drum")
    func testScrubScaleIsPhysical() {
        let count = 5
        let perPoint = LoopCarouselGeometry.scrubRatioPerPoint(count: count)
        let sweep = Double(LoopCarouselGeometry.panelWidth) * perPoint
        // One column per card spacing, so the whole panel width is one full trip round the
        // strip: the drum turns at hand speed instead of teleporting the focus.
        #expect(abs(sweep - 1.0) < 0.12)
    }

    @Test("Lap counter follows the endless offset and allows negative laps")
    func testLapIndex() {
        #expect(LoopCarouselGeometry.lapIndex(viewportOffset: 10, totalStripWidth: 1000) == 0)
        #expect(LoopCarouselGeometry.lapIndex(viewportOffset: 1200, totalStripWidth: 1000) == 1)
        #expect(LoopCarouselGeometry.lapIndex(viewportOffset: -1200, totalStripWidth: 1000) == -1)
        #expect(LoopCarouselGeometry.lapIndex(viewportOffset: 5, totalStripWidth: 0) == 0)
    }

    @MainActor
    @Test("The 3D loop carousel is a selectable HUD style with its own panel size")
    func testStyleIsRegistered() {
        #expect(MinimapHUDStyle.allCases.contains(.loop3D))
        #expect(!MinimapHUDStyle.loop3D.displayName.isEmpty)
        #expect(!MinimapHUDStyle.loop3D.subtitle.isEmpty)
        #expect(!MinimapHUDStyle.loop3D.symbol.isEmpty)

        let size = MinimapHUDController.shared.panelSize(for: .loop3D)
        #expect(size.width == MinimapLoopCarouselView.panelWidth)
        #expect(size.height == MinimapLoopCarouselView.panelHeight)
    }
}
