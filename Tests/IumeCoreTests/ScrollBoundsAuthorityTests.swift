import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

/// Executable regression coverage for the shared scroll-geometry authority
/// (D03 loop eligibility, D08 loop-aware snap, D16 single-column bounds,
/// D18 one max-offset value).
///
/// These tests are pure: they never touch `SettingsStore` or a controller, so
/// they can run in parallel with the motion suites.
@Suite("Scroll Bounds Authority")
struct ScrollBoundsAuthorityTests {

    private let engine = LayoutEngine(windowGap: 20)
    private let gap: CGFloat = 20
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func windowId(_ n: Int) -> WindowId {
        WindowId(pid: 1, rawId: UInt64(n + 1))
    }

    private func columns(widths: [CGFloat]) -> [WindowColumn] {
        widths.enumerated().map { index, width in
            WindowColumn(windowIds: [windowId(index)], width: width)
        }
    }

    private func windows(for columns: [WindowColumn]) -> [WindowId: ManagedWindow] {
        var result: [WindowId: ManagedWindow] = [:]
        for column in columns {
            for id in column.windowIds {
                result[id] = ManagedWindow(
                    id: id,
                    pid: 1,
                    bundleIdentifier: "test",
                    appName: "Test",
                    title: "Test",
                    frame: CGRect(x: 0, y: 0, width: column.width, height: frame.height)
                )
            }
        }
        return result
    }

    // MARK: - D16 / D03: single column

    @Test("A single wide column has a real scroll range but never loops")
    func singleWideColumnHasRangeAndNoLoop() {
        let cols = columns(widths: [1400])
        #expect(abs(engine.maxScrollOffset(columns: cols, visibleWidth: 1000, centerMode: .never, gap: gap) - 400) <= 0.001)
        #expect(!engine.isLoopEligible(columns: cols, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap))

        let looped = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: nil,
            currentViewportOffset: 5000,
            visibleWidth: 1000,
            layoutMode: .scrollStrip,
            centerMode: .never,
            gap: gap,
            loopMode: true
        )
        #expect(abs(looped - 400) <= 0.001)
    }

    @Test("A single wide column's snap target preserves its scroll range")
    func singleWideColumnSnapPreservesRange() {
        let cols = columns(widths: [1400])

        let inRange = engine.computeSnapTarget(
            for: 250,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap
        )
        #expect(abs(inRange.targetOffset - 250) <= 0.001)
        #expect(inRange.focusedColumnIndex == 0)

        let overshoot = engine.computeSnapTarget(
            for: 900,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap
        )
        #expect(abs(overshoot.targetOffset - 400) <= 0.001)

        let fits = engine.computeSnapTarget(
            for: 75,
            columns: columns(widths: [600]),
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap
        )
        #expect(abs(fits.targetOffset) <= 0.001)

        let infinite = engine.computeSnapTarget(
            for: .infinity,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap
        )
        #expect(abs(infinite.targetOffset - 400) <= 0.001)

        let nan = engine.computeSnapTarget(
            for: .nan,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap
        )
        #expect(abs(nan.targetOffset) <= 0.001)
    }

    @Test("A single column narrower than the viewport has no range")
    func singleNarrowColumnHasNoRange() {
        let cols = columns(widths: [600])
        #expect(engine.maxScrollOffset(columns: cols, visibleWidth: 1000, centerMode: .never, gap: gap) == 0)
    }

    // MARK: - D03: short strip and non-strip modes

    @Test("A strip shorter than the viewport never loops")
    func shortStripNeverLoops() {
        let cols = columns(widths: [300, 300])
        #expect(abs(engine.cyclicStripPeriod(columns: cols, gap: gap) - 640) <= 0.001)
        #expect(!engine.isLoopEligible(columns: cols, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap))

        let looped = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 5000,
            visibleWidth: 1000,
            layoutMode: .scrollStrip,
            centerMode: .always,
            gap: gap,
            loopMode: true
        )
        let linear = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 5000,
            visibleWidth: 1000,
            layoutMode: .scrollStrip,
            centerMode: .always,
            gap: gap,
            loopMode: false
        )
        #expect(abs(looped - linear) <= 0.001)
        #expect(looped == 0)

        let loopedSnap = engine.computeSnapTarget(
            for: 5000,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .always,
            gap: gap,
            loopMode: true,
            layoutMode: .scrollStrip
        )
        let linearSnap = engine.computeSnapTarget(
            for: 5000,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .always,
            gap: gap,
            loopMode: false,
            layoutMode: .scrollStrip
        )
        #expect(abs(loopedSnap.targetOffset - linearSnap.targetOffset) <= 0.001)
        #expect(loopedSnap.targetOffset == 0)
    }

    @Test("Loop mode is inert outside strip layouts", arguments: [
        LayoutMode.manualLayout, .grid, .tall, .wide, .bsp, .row, .column
    ])
    func nonStripModesNeverLoop(mode: LayoutMode) {
        let cols = columns(widths: [1100, 1100, 1100, 1100])
        #expect(!engine.isLoopEligible(columns: cols, visibleWidth: 1000, layoutMode: mode, gap: gap))

        let snap = engine.computeSnapTarget(
            for: 4470,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap,
            loopMode: true,
            layoutMode: mode
        )
        let maxOffset = engine.maxScrollOffset(columns: cols, visibleWidth: 1000, centerMode: .never, gap: gap)
        #expect(snap.targetOffset >= -0.001)
        #expect(snap.targetOffset <= maxOffset + 0.001)
    }

    // MARK: - D08: loop-aware snap

    @Test("Loop snap wraps across the cycle seam")
    func loopSnapWrapsAcrossSeam() {
        let cols = columns(widths: [1100, 1100, 1100, 1100])
        #expect(abs(engine.cyclicStripPeriod(columns: cols, gap: gap) - 4480) <= 0.001)
        #expect(engine.isLoopEligible(columns: cols, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap))

        let forward = engine.computeSnapTarget(
            for: 4470,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap,
            loopMode: true,
            layoutMode: .scrollStrip
        )
        #expect(abs(forward.targetOffset - 4480) <= 0.001)
        #expect(forward.focusedColumnIndex == 0)

        let backward = engine.computeSnapTarget(
            for: -30,
            velocity: -120,
            columns: cols,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap,
            loopMode: true,
            layoutMode: .scrollStrip
        )
        #expect(abs(backward.targetOffset - (-1120)) <= 0.001)
        #expect(backward.focusedColumnIndex == 3)
    }

    // MARK: - D18: one authoritative bounds value

    @Test("ScrollBounds resolves margins, gap, range and loop once")
    func scrollBoundsResolvesGeometryOnce() {
        let cols = columns(widths: [600, 600])
        let bounds = engine.scrollBounds(
            columns: cols,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            edgeMargins: EdgeMargins(top: 8, bottom: 8, left: 10, right: 10),
            totalWindowCount: 2,
            smartWindowMargins: false,
            disablePaddingOnBuiltinDisplay: false,
            isBuiltinDisplay: false,
            centerMode: .never,
            windowGap: gap,
            layoutMode: .scrollStrip,
            loopMode: true
        )

        #expect(abs(bounds.usableWidth - 1180) <= 0.001)
        #expect(abs(bounds.gap - 20) <= 0.001)
        #expect(abs(bounds.maxOffset - 40) <= 0.001)
        #expect(bounds.loopEligible)
        #expect(
            abs(engine.maxScrollOffset(columns: cols, visibleWidth: bounds.usableWidth, centerMode: .never, gap: bounds.gap) - bounds.maxOffset) <= 0.001
        )
        #expect(
            engine.isLoopEligible(columns: cols, visibleWidth: bounds.usableWidth, layoutMode: .scrollStrip, gap: bounds.gap) == bounds.loopEligible
        )
    }

    @Test("Smart margins collapse one window's margins and gap in the same place")
    func smartMarginsCollapseOnce() {
        let cols = columns(widths: [1200])
        let bounds = engine.scrollBounds(
            columns: cols,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            edgeMargins: EdgeMargins(top: 8, bottom: 8, left: 10, right: 10),
            totalWindowCount: 1,
            smartWindowMargins: true,
            disablePaddingOnBuiltinDisplay: false,
            isBuiltinDisplay: false,
            centerMode: .never,
            windowGap: gap,
            layoutMode: .scrollStrip,
            loopMode: true
        )

        #expect(bounds.usableWidth == 1200)
        #expect(bounds.gap == 0)
        #expect(bounds.maxOffset == 0)
        #expect(!bounds.loopEligible)
    }

    @Test("Viewport, layout and snap agree on the same bounds")
    func allPathsRespectBounds() {
        let cols = columns(widths: [400, 500, 600, 700])
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bounds = engine.scrollBounds(
            columns: cols,
            visibleFrame: visibleFrame,
            edgeMargins: .zero,
            totalWindowCount: 4,
            smartWindowMargins: false,
            disablePaddingOnBuiltinDisplay: false,
            isBuiltinDisplay: false,
            centerMode: .never,
            windowGap: 10,
            layoutMode: .scrollStrip,
            loopMode: false
        )
        #expect(abs(bounds.maxOffset - 1230) <= 0.001)
        #expect(!bounds.loopEligible)

        let winMap = windows(for: cols)
        for focused in cols.indices {
            let offset = engine.computeViewportOffset(
                columns: cols,
                focusedColumnIndex: focused,
                currentViewportOffset: 5000,
                visibleWidth: bounds.usableWidth,
                layoutMode: .scrollStrip,
                centerMode: .never,
                gap: bounds.gap,
                loopMode: bounds.loopEligible
            )
            #expect(offset >= -0.001)
            #expect(offset <= bounds.maxOffset + 0.001)

            let computation = engine.computeLayout(
                columns: cols,
                windows: winMap,
                focusedColumnIndex: focused,
                visibleFrame: visibleFrame,
                viewportOffset: 5000,
                layoutMode: .scrollStrip,
                centerMode: .never,
                edgeMargins: .zero,
                gap: bounds.gap,
                loopMode: bounds.loopEligible
            )
            #expect(computation.targetViewportOffset >= -0.001)
            #expect(computation.targetViewportOffset <= bounds.maxOffset + 0.001)
        }

        for projected in stride(from: CGFloat(-500), through: 3000, by: 250) {
            let snap = engine.computeSnapTarget(
                for: projected,
                columns: cols,
                visibleWidth: bounds.usableWidth,
                centerMode: .never,
                gap: bounds.gap,
                loopMode: bounds.loopEligible,
                layoutMode: .scrollStrip
            )
            #expect(snap.targetOffset >= -0.001)
            #expect(snap.targetOffset <= bounds.maxOffset + 0.001)
        }
    }
}
