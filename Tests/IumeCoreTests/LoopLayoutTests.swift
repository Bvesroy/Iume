import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

/// Focused coverage for the pure circular loop-strip math.
///
/// Fixture (unless stated otherwise):
///   columns widths 400, 500, 600, 700 at gap 10
///   strip offsets 0, 410, 920, 1530
///   totalStripWidth 2230, cyclicStripPeriod 2240 (one trailing gap)
///   viewport width 1000
@Suite("Loop Layout Tests")
struct LoopLayoutTests {

    let engine = LayoutEngine(windowGap: 10, defaultColumnWidthRatio: 0.5, defaultMinimumColumnWidth: 400)
    let gap: CGFloat = 10
    let period: CGFloat = 2240
    let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - Fixtures

    private func windowId(_ n: Int) -> WindowId {
        WindowId(pid: 1, rawId: UInt64(n))
    }

    private func makeColumns(widths: [CGFloat] = [400, 500, 600, 700]) -> [WindowColumn] {
        var columns: [WindowColumn] = []
        for (index, width) in widths.enumerated() {
            columns.append(WindowColumn(windowIds: [windowId(index + 1)], width: width))
        }
        return columns
    }

    private func makeWindows(_ columns: [WindowColumn]) -> [WindowId: ManagedWindow] {
        var windows: [WindowId: ManagedWindow] = [:]
        for column in columns {
            for id in column.windowIds {
                windows[id] = ManagedWindow(
                    id: id,
                    pid: id.pid,
                    bundleIdentifier: "com.iume.loop-test",
                    appName: "LoopTest",
                    title: id.description,
                    frame: .zero
                )
            }
        }
        return windows
    }

    private func layout(
        _ columns: [WindowColumn],
        _ windows: [WindowId: ManagedWindow],
        offset: CGFloat,
        mode: LayoutMode = .scrollStrip,
        loop: Bool
    ) -> LayoutComputation {
        engine.computeLayout(
            columns: columns,
            windows: windows,
            focusedColumnIndex: nil,
            visibleFrame: visibleFrame,
            viewportOffset: offset,
            layoutMode: mode,
            gap: gap,
            loopMode: loop
        )
    }

    // MARK: - Requirement 1: mode capability

    @Test("supportsLoop is true only for horizontal strip modes")
    func supportsLoopMatrix() {
        let expected: [LayoutMode: Bool] = [
            .scrollStrip: true,
            .focusColumn: true,
            .centeredFocus: true,
            .manualLayout: false,
            .grid: false,
            .tall: false,
            .wide: false,
            .bsp: false,
            .row: false,
            .column: false
        ]

        #expect(LayoutMode.allCases.count == expected.count)
        for mode in LayoutMode.allCases {
            #expect(mode.supportsLoop == expected[mode], "unexpected supportsLoop for \(mode.rawValue)")
        }
    }

    @Test("loopMode has no effect outside strip modes")
    func loopIgnoredOutsideStripModes() {
        let columns = makeColumns()
        let windows = makeWindows(columns)
        let nonStripModes: [LayoutMode] = [.manualLayout, .grid, .tall, .wide, .bsp, .row, .column]

        for mode in nonStripModes {
            for focusedIndex in [2, nil] as [Int?] {
                let looped = engine.computeViewportOffset(
                    columns: columns,
                    focusedColumnIndex: focusedIndex,
                    currentViewportOffset: 5000,
                    visibleWidth: 1000,
                    layoutMode: mode,
                    gap: gap,
                    loopMode: true
                )
                let linear = engine.computeViewportOffset(
                    columns: columns,
                    focusedColumnIndex: focusedIndex,
                    currentViewportOffset: 5000,
                    visibleWidth: 1000,
                    layoutMode: mode,
                    gap: gap,
                    loopMode: false
                )
                #expect(looped == linear, "\(mode.rawValue) focused=\(String(describing: focusedIndex))")
            }

            let loopedLayout = layout(columns, windows, offset: 5000, mode: mode, loop: true)
            let linearLayout = layout(columns, windows, offset: 5000, mode: mode, loop: false)
            #expect(loopedLayout == linearLayout, "\(mode.rawValue) computeLayout")
        }
    }

    // MARK: - Requirement 2: cyclic layout contract

    @Test("Cyclic period is the sum of widths plus one gap per column")
    func cyclicPeriodContract() {
        let columns = makeColumns()

        #expect(engine.columnStripOffsets(columns: columns, gap: gap) == [0, 410, 920, 1530])
        #expect(engine.totalStripWidth(columns: columns, gap: gap) == 2230)
        #expect(engine.cyclicStripPeriod(columns: columns, gap: gap) == 2240)
        // Exactly one gap after the last column closes the loop.
        #expect(engine.cyclicStripPeriod(columns: columns, gap: gap)
                - engine.totalStripWidth(columns: columns, gap: gap) == gap)
    }

    @Test("Columns without managed windows still occupy their strip slot")
    func emptyManagedColumnKeepsStripAlignment() {
        let first = windowId(1)
        let minimized = windowId(2)
        let last = windowId(3)
        let columns = [
            WindowColumn(windowIds: [first], width: 400),
            WindowColumn(windowIds: [minimized], width: 300),
            WindowColumn(windowIds: [last], width: 600)
        ]
        let windows: [WindowId: ManagedWindow] = [
            first: ManagedWindow(id: first, pid: 1, bundleIdentifier: "a", appName: "A", title: "A", frame: .zero),
            minimized: ManagedWindow(id: minimized, pid: 1, bundleIdentifier: "b", appName: "B", title: "B", frame: .zero, isMinimized: true),
            last: ManagedWindow(id: last, pid: 1, bundleIdentifier: "c", appName: "C", title: "C", frame: .zero)
        ]

        // 400 + 10 + 300 + 10 + 600 + 10 = 1330
        #expect(engine.columnStripOffsets(columns: columns, gap: gap) == [0, 410, 720])
        #expect(engine.cyclicStripPeriod(columns: columns, gap: gap) == 1330)

        let computation = engine.computeLayout(
            columns: columns,
            windows: windows,
            focusedColumnIndex: nil,
            visibleFrame: visibleFrame,
            viewportOffset: 720,
            layoutMode: .scrollStrip,
            gap: gap,
            loopMode: true
        )
        #expect(computation.targetFrames[last]!.minX == 0)
        #expect(computation.targetFrames[minimized] == nil)

        // Period identity still holds with the unmanaged column in the cycle.
        let atZero = layout(columns, windows, offset: 0, loop: true)
        let atPeriod = layout(columns, windows, offset: 1330, loop: true)
        #expect(atZero.targetFrames == atPeriod.targetFrames)
    }

    @Test("Frames at offset 0 and offset multiples of the period are identical")
    func periodIdentity() {
        let columns = makeColumns()
        let windows = makeWindows(columns)
        let base = layout(columns, windows, offset: 0, loop: true)

        #expect(base.targetFrames.count == 4)
        #expect(base.targetFrames[windowId(1)]!.minX == 0)
        #expect(base.targetFrames[windowId(2)]!.minX == 410)
        #expect(base.targetFrames[windowId(3)]!.minX == 920)

        // The last column sits before the first column in cycle order, so at offset 0
        // the previous-cycle copy is parked on the left rather than the right.
        #expect(base.parkedWindowIds.contains(windowId(4)))

        for offset in [period, 2 * period, -period, -2 * period] {
            let shifted = layout(columns, windows, offset: offset, loop: true)
            #expect(shifted.targetFrames == base.targetFrames, "offset \(offset)")
            #expect(shifted.parkedWindowIds == base.parkedWindowIds, "offset \(offset)")
        }
    }

    @Test("Last-to-first seam has exactly one gap and each window appears once")
    func seamHasExactlyOneGap() {
        let columns = makeColumns()
        let windows = makeWindows(columns)
        // Last column (1530..2230) lands at 30..730; the first column's next-cycle
        // copy starts at 2240 - 1500 = 740.
        let computation = layout(columns, windows, offset: 1500, loop: true)

        let first = computation.targetFrames[windowId(1)]!
        let second = computation.targetFrames[windowId(2)]!
        let third = computation.targetFrames[windowId(3)]!
        let last = computation.targetFrames[windowId(4)]!

        #expect(last.minX == 30)
        #expect(last.maxX == 730)
        #expect(first.minX == 740)
        #expect(first.minX - last.maxX == gap)

        // The previous seam (third -> last) is also exactly one gap.
        #expect(third.minX == -580)
        #expect(third.maxX == 20)
        #expect(last.minX - third.maxX == gap)

        // The next-cycle copy of the second column is the one following the seam,
        // so it is parked on the right edge (not the left).
        #expect(second.minX == 988)
        #expect(computation.parkedWindowIds.contains(windowId(2)))
        #expect(computation.targetFrames.count == windows.count)
        #expect(Set(computation.targetFrames.keys) == Set(windows.keys))
    }

    @Test("Negative offsets render the equivalent positive cycle")
    func negativeOffsets() {
        let columns = makeColumns()
        let windows = makeWindows(columns)

        #expect(layout(columns, windows, offset: -period, loop: true).targetFrames
                == layout(columns, windows, offset: 0, loop: true).targetFrames)

        // -1500 + 2240 == 740
        let negative = layout(columns, windows, offset: -1500, loop: true)
        let positive = layout(columns, windows, offset: 740, loop: true)
        #expect(negative.targetFrames == positive.targetFrames)
        #expect(negative.targetFrames[windowId(4)]!.minX == 790)
    }

    @Test("Centered focus can produce a negative offset that centers the column")
    func negativeCenteredOffsetLayout() {
        let columns = makeColumns()
        let windows = makeWindows(columns)

        let offset = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 0,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .centeredFocus,
            gap: gap,
            loopMode: true
        )
        #expect(offset == -300)

        let computation = layout(columns, windows, offset: offset, loop: true)
        let first = computation.targetFrames[windowId(1)]!
        #expect(first.minX == 300)
        #expect(first.midX == 500) // viewport center
    }

    @Test("Loop is inert when a whole cycle fits on screen")
    func loopInertWhenCycleFits() {
        let columns = makeColumns(widths: [300, 300])
        let windows = makeWindows(columns)

        #expect(engine.cyclicStripPeriod(columns: columns, gap: gap) == 620)

        let looped = layout(columns, windows, offset: 0, loop: true)
        let linear = layout(columns, windows, offset: 0, loop: false)
        #expect(looped == linear)

        let loopedOffset = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .centeredFocus,
            gap: gap,
            loopMode: true
        )
        let linearOffset = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .centeredFocus,
            gap: gap,
            loopMode: false
        )
        #expect(loopedOffset == linearOffset)
    }

    // MARK: - Requirement 3: shortest circular viewport delta

    @Test("Viewport focus takes the shortest circular delta across the seam")
    func shortestCircularViewportDelta() {
        let columns = makeColumns()

        // centeredFocus targets: column 0 -> -300, column 3 -> 1380.
        // From 1380 the short way to -300 is +560 (forward), not -1680.
        let toFirst = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 0,
            currentViewportOffset: 1380,
            visibleWidth: 1000,
            layoutMode: .centeredFocus,
            gap: gap,
            loopMode: true
        )
        #expect(toFirst == 1940)
        #expect(toFirst - 1380 == 560)
        #expect(toFirst == -300 + period)

        // From -300 the short way to 1380 is -560 (backward), not +1680.
        let toLast = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 3,
            currentViewportOffset: -300,
            visibleWidth: 1000,
            layoutMode: .centeredFocus,
            gap: gap,
            loopMode: true
        )
        #expect(toLast == -860)
        #expect(-300 - toLast == 560)

        // Left-edge focus just before the period boundary moves +5, not -2235.
        let acrossSeam = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 0,
            currentViewportOffset: 2235,
            visibleWidth: 1000,
            layoutMode: .focusColumn,
            gap: gap,
            loopMode: true
        )
        #expect(acrossSeam == 2240)
        #expect(acrossSeam - 2235 == 5)

        // Backward across the seam: -560, not +1680.
        let backwardAcrossSeam = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 3,
            currentViewportOffset: 5,
            visibleWidth: 1000,
            layoutMode: .focusColumn,
            gap: gap,
            loopMode: true
        )
        #expect(backwardAcrossSeam == -710) // 1530 - 2240
        #expect(5 - backwardAcrossSeam == 715)

        // Without loop the same request clamps to the left edge instead of wrapping.
        let linear = engine.computeViewportOffset(
            columns: columns,
            focusedColumnIndex: 0,
            currentViewportOffset: 2235,
            visibleWidth: 1000,
            layoutMode: .focusColumn,
            gap: gap,
            loopMode: false
        )
        #expect(linear == 0)
    }

    // MARK: - Requirement 4: closest column at cycle boundaries

    @Test("Closest column wraps offsets just below and above a period boundary")
    func closestColumnAtPeriodBoundary() {
        let columns = makeColumns()

        let justBelow = engine.findClosestColumnIndex(
            for: period - 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        )
        let justAbove = engine.findClosestColumnIndex(
            for: period + 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        )
        let justBelowZero = engine.findClosestColumnIndex(
            for: -1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        )
        let justAboveZero = engine.findClosestColumnIndex(
            for: 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        )

        // A boundary offset must be indistinguishable from the equivalent offset near zero.
        #expect(justBelow == justBelowZero)
        #expect(justAbove == justAboveZero)
        #expect(justBelow == justAbove)
        #expect(justBelow == 1) // viewport center lands on column 1

        // Negative boundaries behave the same way.
        #expect(engine.findClosestColumnIndex(
            for: -period - 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        ) == justBelow)
        #expect(engine.findClosestColumnIndex(
            for: -period + 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: true
        ) == justAbove)

        // The linear fallback runs off the end of the strip and selects the last column.
        #expect(engine.findClosestColumnIndex(
            for: period - 1, columns: columns, visibleWidth: 1000, gap: gap, loopMode: false
        ) == 3)
    }

    // MARK: - Requirement 5: snap targets

    @Test("Snap target stays on the projected cycle near the period boundary")
    func snapTargetStaysOnProjectedCycle() {
        let columns = makeColumns()

        let rest = engine.computeSnapTarget(
            for: 2235, velocity: 0, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: true
        )
        #expect(rest.targetOffset == 2240)
        #expect(rest.focusedColumnIndex == 0)
        // Near the projection, not a full period away (0 or 4480).
        #expect(abs(rest.targetOffset - 2235) == 5)

        let forward = engine.computeSnapTarget(
            for: 2235, velocity: 120, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: true
        )
        #expect(forward.targetOffset == 2240)
        #expect(forward.focusedColumnIndex == 0)

        let backward = engine.computeSnapTarget(
            for: -30, velocity: -120, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: true
        )
        #expect(backward.targetOffset == -710) // column 3's previous-cycle left edge
        #expect(backward.focusedColumnIndex == 3)
        #expect(abs(backward.targetOffset - (-30)) == 680)
        #expect(abs(backward.targetOffset - (-30)) < period)

        // Without loop the target is clamped inside the physical strip.
        let linear = engine.computeSnapTarget(
            for: 2235, velocity: 120, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: false
        )
        #expect(linear.targetOffset <= 1230)
    }

    @Test("Flicking forward at an exact snap position advances one column")
    func snapFlickAtExactSnap() {
        let columns = makeColumns()

        let forward = engine.computeSnapTarget(
            for: 2240, velocity: 120, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: true
        )
        #expect(forward.targetOffset == 2650) // 410 + one period
        #expect(forward.focusedColumnIndex == 1)

        let backward = engine.computeSnapTarget(
            for: 2240, velocity: -120, columns: columns, visibleWidth: 1000,
            centerMode: .never, gap: gap, loopMode: true
        )
        #expect(backward.targetOffset == 1530)
        #expect(backward.focusedColumnIndex == 3)
    }
}
