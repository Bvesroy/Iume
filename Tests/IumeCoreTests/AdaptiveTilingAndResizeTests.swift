import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

@Suite("Adaptive Tiling and Neighbor-Aware Resize Tests")
struct AdaptiveTilingAndResizeTests {

    let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let engine = BoxTilingEngine(
        windowGap: 10,
        edgeMargins: EdgeMargins(top: 20, bottom: 20, left: 15, right: 15),
        mainPaneRatio: 0.55,
        minimumWindowDimension: 150
    )

    private func windows(_ count: Int) -> [WindowId] {
        (1...count).map { WindowId(pid: 100, rawId: UInt64($0)) }
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 1.0 && intersection.height > 1.0
    }

    // MARK: - Adaptive grid

    @Test("Five windows tile as 3+2 with every row filling the screen")
    func testGridFiveWindowsFillsScreen() {
        let ids = windows(5)
        let bounds = engine.usableBounds(in: screenFrame)
        let frames = engine.computeGridLayout(windowIds: ids, in: screenFrame)

        #expect(frames.count == 5)
        for frame in frames.values {
            #expect(frame.minX >= bounds.minX - 1)
            #expect(frame.maxX <= bounds.maxX + 1)
            #expect(frame.minY >= bounds.minY - 1)
            #expect(frame.maxY <= bounds.maxY + 1)
        }

        // Top row holds three windows, bottom row holds two.
        let topRow = ids.prefix(3).compactMap { frames[$0] }
        let bottomRow = ids.suffix(2).compactMap { frames[$0] }
        #expect(Set(topRow.map { round($0.minY) }).count == 1)
        #expect(Set(bottomRow.map { round($0.minY) }).count == 1)
        #expect(topRow.first!.minY < bottomRow.first!.minY)

        // Neither row leaves a hole: they start at the left margin and reach the right one.
        #expect(abs(topRow.first!.minX - bounds.minX) < 1)
        #expect(abs(topRow.last!.maxX - bounds.maxX) < 1)
        #expect(abs(bottomRow.first!.minX - bounds.minX) < 1)
        #expect(abs(bottomRow.last!.maxX - bounds.maxX) < 1)

        // Every window is a sensible size and nothing overlaps.
        for (index, id) in ids.enumerated() {
            for other in ids[(index + 1)...] {
                #expect(!overlaps(frames[id]!, frames[other]!))
            }
        }
    }

    @Test("Seven windows tile into balanced rows without empty cells")
    func testGridSevenWindowsBalancedRows() {
        let ids = windows(7)
        let bounds = engine.usableBounds(in: screenFrame)
        let frames = engine.computeGridLayout(windowIds: ids, in: screenFrame)

        #expect(frames.count == 7)
        let rows = Dictionary(grouping: ids) { round(frames[$0]!.minY) }
        #expect(rows.count == 3)

        for (_, rowIds) in rows {
            let rowFrames = rowIds.map { frames[$0]! }
            #expect(abs(rowFrames.map { $0.minX }.min()! - bounds.minX) < 1)
            #expect(abs(rowFrames.map { $0.maxX }.max()! - bounds.maxX) < 1)
            for (index, frame) in rowFrames.enumerated() {
                for other in rowFrames[(index + 1)...] {
                    #expect(!overlaps(frame, other))
                }
            }
        }
    }

    @Test("Four windows keep the classic 2x2 grid")
    func testGridFourWindowsIs2x2() {
        let ids = windows(4)
        let frames = engine.computeGridLayout(windowIds: ids, in: screenFrame)
        let distinctX = Set(frames.values.compactMap { Int(round($0.minX)) })
        let distinctY = Set(frames.values.compactMap { Int(round($0.minY)) })
        #expect(distinctX.count == 2)
        #expect(distinctY.count == 2)
    }

    // MARK: - Row & Column layouts

    @Test("Row layout puts every window side by side at equal widths")
    func testRowLayout() {
        let ids = windows(4)
        let bounds = engine.usableBounds(in: screenFrame)
        let frames = engine.computeRowLayout(windowIds: ids, in: screenFrame)

        #expect(frames.count == 4)
        let rowFrames = ids.compactMap { frames[$0] }
        #expect(Set(rowFrames.map { round($0.minY) }).count == 1)
        #expect(Set(rowFrames.map { round($0.height) }).count == 1)
        #expect(abs(rowFrames.first!.minX - bounds.minX) < 1)
        #expect(abs(rowFrames.last!.maxX - bounds.maxX) < 1)
        let widths = rowFrames.map { $0.width }
        #expect(widths.max()! - widths.min()! < 2)
    }

    @Test("Column layout stacks every window at equal heights")
    func testColumnLayout() {
        let ids = windows(3)
        let bounds = engine.usableBounds(in: screenFrame)
        let frames = engine.computeColumnLayout(windowIds: ids, in: screenFrame)

        #expect(frames.count == 3)
        let columnFrames = ids.compactMap { frames[$0] }
        #expect(Set(columnFrames.map { round($0.minX) }).count == 1)
        #expect(Set(columnFrames.map { round($0.width) }).count == 1)
        #expect(abs(columnFrames.first!.minY - bounds.minY) < 1)
        #expect(abs(columnFrames.last!.maxY - bounds.maxY) < 1)
        let heights = columnFrames.map { $0.height }
        // The last window absorbs the sub-pixel remainder of the equal division.
        #expect(heights.max()! - heights.min()! <= 3)
    }

    @Test("LayoutEngine routes Row and Column modes to the box engine")
    func testLayoutEngineRowAndColumnModes() {
        let layout = LayoutEngine(windowGap: 10, defaultColumnWidthRatio: 0.5)
        let ids = windows(3)
        let columns = [WindowColumn(windowIds: ids, width: 400)]
        var managed: [WindowId: ManagedWindow] = [:]
        for id in ids {
            managed[id] = ManagedWindow(
                id: id, pid: 100, bundleIdentifier: "test.app", appName: "Test",
                title: "Test", frame: CGRect(x: 0, y: 0, width: 400, height: 760)
            )
        }

        let row = layout.computeLayout(
            columns: columns, windows: managed, focusedColumnIndex: 0,
            visibleFrame: screenFrame, viewportOffset: 0, layoutMode: .row,
            edgeMargins: EdgeMargins.zero, gap: 10
        )
        #expect(Set(row.targetFrames.values.map { round($0.minY) }).count == 1)
        #expect(row.targetFrames[ids[0]]!.width > row.targetFrames[ids[2]]!.width - 2)

        let column = layout.computeLayout(
            columns: columns, windows: managed, focusedColumnIndex: 0,
            visibleFrame: screenFrame, viewportOffset: 0, layoutMode: .column,
            edgeMargins: EdgeMargins.zero, gap: 10
        )
        #expect(Set(column.targetFrames.values.map { round($0.minX) }).count == 1)
        #expect(column.targetFrames[ids[0]]!.height > column.targetFrames[ids[2]]!.height - 2)
    }

    // MARK: - Neighbor-aware resize

    @Test("Dragging the right edge takes space from the neighbour on that side")
    func testResizeRightEdge() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 500, height: 800),
            w2: CGRect(x: 510, y: 0, width: 500, height: 800)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w1, frames: frames, edge: .right, delta: 60,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w1]!.width == 560)
        #expect(updated[w2]!.minX == 570)
        #expect(updated[w2]!.width == 440)
        #expect(updated[w1]!.maxX + 10 == updated[w2]!.minX)
    }

    @Test("Dragging the left edge grows the left neighbour in lockstep")
    func testResizeLeftEdge() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 500, height: 800),
            w2: CGRect(x: 510, y: 0, width: 500, height: 800)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w2, frames: frames, edge: .left, delta: 50,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w2]!.minX == 560)
        #expect(updated[w2]!.width == 450)
        #expect(updated[w1]!.width == 550)
    }

    @Test("Dragging a bottom edge shortens the window below it")
    func testResizeBottomEdge() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 800, height: 390),
            w2: CGRect(x: 0, y: 400, width: 800, height: 400)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w1, frames: frames, edge: .bottom, delta: 50,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w1]!.height == 440)
        #expect(updated[w2]!.minY == 450)
        #expect(updated[w2]!.height == 350)
    }

    @Test("Dragging a top edge shortens the window above it")
    func testResizeTopEdge() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 800, height: 390),
            w2: CGRect(x: 0, y: 400, width: 800, height: 400)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w2, frames: frames, edge: .top, delta: 50,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w2]!.minY == 450)
        #expect(updated[w2]!.height == 350)
        #expect(updated[w1]!.height == 440)
    }

    @Test("A stacked column of neighbours all follow the shared edge")
    func testResizeStackedColumn() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let w3 = WindowId(pid: 100, rawId: 3)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 500, height: 800),
            w2: CGRect(x: 510, y: 0, width: 500, height: 390),
            w3: CGRect(x: 510, y: 400, width: 500, height: 390)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w1, frames: frames, edge: .right, delta: 40,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w1]!.width == 540)
        #expect(updated[w2]!.minX == 550)
        #expect(updated[w3]!.minX == 550)
        #expect(updated[w2]!.width == 460)
        #expect(updated[w3]!.width == 460)
        #expect(updated[w2]!.maxY < updated[w3]!.minY)
    }

    @Test("Resize clamps to the minimum window size instead of collapsing a neighbour")
    func testResizeMinimumSizeClamp() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let frames = [
            w1: CGRect(x: 0, y: 0, width: 500, height: 800),
            w2: CGRect(x: 510, y: 0, width: 200, height: 800)
        ]

        let updated = engine.resizeTiledWindow(
            windowId: w1, frames: frames, edge: .right, delta: 300,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w2]!.width == 150)
        #expect(updated[w1]!.width == 550)
    }

    @Test("Resize clamps to the screen edge when there is no neighbour")
    func testResizeScreenEdgeClamp() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let frames = [w1: CGRect(x: 0, y: 0, width: 500, height: 800)]

        let updated = engine.resizeTiledWindow(
            windowId: w1, frames: frames, edge: .right, delta: 5000,
            screenBounds: screenFrame, gap: 10
        )

        #expect(updated[w1]!.width == 1200)
    }

    // MARK: - Manual / free layout

    @Test("Manual layout preserves the exact frames the user chose")
    func testManualLayoutPreservesFrames() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let layout = LayoutEngine(windowGap: 8, defaultColumnWidthRatio: 0.5)
        let columns = [
            WindowColumn(windowIds: [w1], width: 500),
            WindowColumn(windowIds: [w2], width: 500)
        ]
        var managed: [WindowId: ManagedWindow] = [:]
        for (index, id) in [w1, w2].enumerated() {
            managed[id] = ManagedWindow(
                id: id, pid: 100, bundleIdentifier: "test.app", appName: "Test",
                title: "Test", frame: CGRect(x: CGFloat(index) * 500, y: 0, width: 500, height: 760)
            )
        }
        let free1 = CGRect(x: 40, y: 60, width: 620, height: 430)
        let free2 = CGRect(x: 700, y: 120, width: 410, height: 610)

        let computation = layout.computeLayout(
            columns: columns, windows: managed, focusedColumnIndex: 0,
            visibleFrame: screenFrame, viewportOffset: 0, layoutMode: .manualLayout,
            edgeMargins: EdgeMargins.zero, gap: 8,
            manualFrames: [w1: free1, w2: free2]
        )

        #expect(computation.targetFrames[w1] == free1)
        #expect(computation.targetFrames[w2] == free2)
    }

    // MARK: - Free resize (edge-aware)

    @Test("Free-resize edge detection moves one edge, a corner, or both axes")
    func testFreeResizeEdges() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)

        // Grab near the right border at mid height -> only the right edge moves.
        let rightGrab = engine.freeResizeEdges(forCursorIn: frame, cursor: CGPoint(x: 690, y: 300))
        #expect(rightGrab == [.right])

        // Grab near the left border -> only the left edge moves.
        let leftGrab = engine.freeResizeEdges(forCursorIn: frame, cursor: CGPoint(x: 110, y: 300))
        #expect(leftGrab == [.left])

        // Grab near the bottom-right corner -> both of those edges move.
        let cornerGrab = engine.freeResizeEdges(forCursorIn: frame, cursor: CGPoint(x: 660, y: 460))
        #expect(cornerGrab == [.right, .bottom])

        // Dead centre falls back to the nearest corner so the gesture always does something.
        let centreGrab = engine.freeResizeEdges(forCursorIn: frame, cursor: CGPoint(x: 420, y: 320))
        #expect(centreGrab == [.right, .bottom])
    }

    @Test("Horizontal-only free resize never changes height or the anchored edges")
    func testFreeResizeHorizontalOnly() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let (resized, edges) = engine.computeFreeResizeFrame(
            initialFrame: frame,
            initialCursor: CGPoint(x: 690, y: 300),
            currentCursor: CGPoint(x: 790, y: 360)
        )

        #expect(edges == [.right])
        #expect(resized.minX == frame.minX)
        #expect(resized.minY == frame.minY)
        #expect(resized.height == frame.height)
        #expect(resized.width == frame.width + 100)
    }

    @Test("Vertical-only free resize never changes width")
    func testFreeResizeVerticalOnly() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let (resized, edges) = engine.computeFreeResizeFrame(
            initialFrame: frame,
            initialCursor: CGPoint(x: 400, y: 490),
            currentCursor: CGPoint(x: 520, y: 590)
        )

        #expect(edges == [.bottom])
        #expect(resized.minX == frame.minX)
        #expect(resized.width == frame.width)
        #expect(resized.height == frame.height + 100)
    }

    // MARK: - Neighbour propagation from a free-resize drag

    @Test("Dragging a box edge pushes the adjacent box instead of overlapping it")
    @MainActor
    func testFreeResizePushesNeighbour() {
        let manager = WorkspaceManager()
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let prior = CGRect(x: 0, y: 0, width: 500, height: 760)
        let proposed = CGRect(x: 0, y: 0, width: 600, height: 760)
        let neighbour = CGRect(x: 510, y: 0, width: 490, height: 760)

        let frames = manager.boxFreeResizeFrames(
            windowId: w1,
            proposedFrame: proposed,
            previousFrame: prior,
            tiledFrames: [w2: neighbour],
            gap: 10,
            screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 760)
        )

        #expect(frames[w1] == proposed)
        #expect(frames[w2]?.minX == 610)
        #expect(frames[w2]?.width == 390)
        #expect(frames[w2]?.height == 760)
        #expect(!overlaps(frames[w1]!, frames[w2]!))
    }

    @Test("Free resize without a previous frame is a no-op, which is why the drag tracks it")
    @MainActor
    func testFreeResizeRequiresPreviousFrame() {
        let manager = WorkspaceManager()
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)

        let frames = manager.boxFreeResizeFrames(
            windowId: w1,
            proposedFrame: CGRect(x: 0, y: 0, width: 600, height: 760),
            previousFrame: nil,
            tiledFrames: [w2: CGRect(x: 510, y: 0, width: 490, height: 760)],
            gap: 10,
            screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 760)
        )

        #expect(frames.isEmpty)
    }

    // MARK: - Stale box overrides

    @Test("Hand-placed boxes survive an unchanged window set but reset when windows change")
    @MainActor
    func testStaleBoxOverridesAreCleared() {
        let manager = WorkspaceManager()
        let display = DisplayGeometry(
            id: 77, name: "Test",
            frame: screenFrame, visibleFrame: screenFrame, isPrimary: true
        )
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let custom = CGRect(x: 40, y: 40, width: 500, height: 600)

        manager.settings.layoutMode = .grid
        var ws = DisplayWorkspace(
            displayGeometry: display,
            columns: [WindowColumn(windowIds: [w1], width: 500)],
            customBoxFrames: [w1: custom]
        )

        // First evaluation just records the signature.
        #expect(manager.clearStaleBoxOverridesIfNeeded(&ws) == false)
        #expect(ws.customBoxFrames[w1] == custom)

        // Same window set: the user's box is preserved.
        #expect(manager.clearStaleBoxOverridesIfNeeded(&ws) == false)
        #expect(ws.customBoxFrames[w1] == custom)

        // A second window opens: the stale override would leave a hole, so it is dropped.
        ws.columns.append(WindowColumn(windowIds: [w2], width: 500))
        #expect(manager.clearStaleBoxOverridesIfNeeded(&ws) == true)
        #expect(ws.customBoxFrames.isEmpty)

        manager.settings.layoutMode = .scrollStrip
    }

    @Test("Manual layout falls back to the current frame for unpinned windows")
    func testManualLayoutFallback() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let current = CGRect(x: 123, y: 45, width: 480, height: 300)
        let layout = LayoutEngine(windowGap: 8, defaultColumnWidthRatio: 0.5)
        let managed = ManagedWindow(
            id: w1, pid: 100, bundleIdentifier: "test.app", appName: "Test",
            title: "Test", frame: current
        )

        let computation = layout.computeLayout(
            columns: [WindowColumn(windowIds: [w1], width: 480)],
            windows: [w1: managed], focusedColumnIndex: 0,
            visibleFrame: screenFrame, viewportOffset: 0, layoutMode: .manualLayout
        )

        #expect(computation.targetFrames[w1] == current)
    }
}
