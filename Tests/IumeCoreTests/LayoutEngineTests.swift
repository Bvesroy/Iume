import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

@Suite("LayoutEngine Tests")
struct LayoutEngineTests {
    
    let engine = LayoutEngine(windowGap: 10, defaultColumnWidthRatio: 0.5, defaultMinimumColumnWidth: 400)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    
    @Test("Total strip width calculation")
    func testTotalStripWidth() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 400),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 500),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 600)
        ]
        // 400 + 10 + 500 + 10 + 600 = 1520
        let total = engine.totalStripWidth(columns: cols)
        #expect(total == 1520)
    }
    
    @Test("Column strip offsets")
    func testColumnStripOffsets() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 300),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 400),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 500)
        ]
        let offsets = engine.columnStripOffsets(columns: cols)
        #expect(offsets == [0, 310, 720])
    }
    
    @Test("Viewport scrolling in Scroll Strip mode")
    func testScrollStripViewport() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 500), // 0...500
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 500), // 510...1010
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 500)  // 1020...1520
        ]
        
        // Focus column 0: it is within 0...1000, viewport stays 0
        let offset0 = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 0,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .scrollStrip
        )
        #expect(offset0 == 0)
        
        // Focus column 2: 1020...1520 is offscreen right. Viewport should shift to 1520 - 1000 = 520
        let offset2 = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 2,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .scrollStrip
        )
        #expect(offset2 == 520)
        
        // Focus column 0 again from offset 520: 0 < 520, viewport should shift to 0
        let backTo0 = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 0,
            currentViewportOffset: 520,
            visibleWidth: 1000,
            layoutMode: .scrollStrip
        )
        #expect(backTo0 == 0)
    }
    
    @Test("Centered Focus mode")
    func testCenteredFocus() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 400), // 0..400
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 400), // 410..810
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 400)  // 820..1220
        ]
        // Focus column 1: colLeft = 410, center = 410 + 200 = 610. Screen width = 1000 -> target = 610 - 500 = 110
        let offset = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleWidth: 1000,
            layoutMode: .centeredFocus
        )
        #expect(offset == 110)
    }
    
    @Test("Window insertion policies")
    func testInsertionPolicies() {
        var cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 400),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 400)
        ]
        
        // Insert after focused (focused = 0)
        let newWinId = WindowId(pid: 2, rawId: 3)
        let insertedIdx = engine.insertWindow(
            newWinId,
            into: &cols,
            focusedColumnIndex: 0,
            policy: .afterFocused,
            visibleWidth: 1000
        )
        #expect(insertedIdx == 1)
        #expect(cols.count == 3)
        #expect(cols[1].windowIds == [newWinId])
        
        // Insert at end
        let endWinId = WindowId(pid: 2, rawId: 4)
        let endIdx = engine.insertWindow(
            endWinId,
            into: &cols,
            focusedColumnIndex: 0,
            policy: .atEnd,
            visibleWidth: 1000
        )
        #expect(endIdx == 3)
        #expect(cols[3].windowIds == [endWinId])
        
        // Insert in current column (stacking)
        let stackWinId = WindowId(pid: 2, rawId: 5)
        let stackIdx = engine.insertWindow(
            stackWinId,
            into: &cols,
            focusedColumnIndex: 0,
            policy: .inCurrentColumn,
            visibleWidth: 1000
        )
        #expect(stackIdx == 0)
        #expect(cols[0].windowIds.count == 2)
        #expect(cols[0].windowIds.contains(stackWinId))
    }
    
    @Test("Window removal and column cleanup")
    func testWindowRemoval() {
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        var cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 400)
        ]
        
        let newFocused = engine.removeWindow(win1, from: &cols, currentFocusedIndex: 0)
        #expect(cols.count == 1)
        #expect(cols[0].windowIds == [win2])
        #expect(newFocused == 0)
    }
    
    @Test("Move column reordering")
    func testMoveColumn() {
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        var cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 500)
        ]
        
        let newIdx = engine.moveColumn(at: 0, direction: 1, columns: &cols)
        #expect(newIdx == 1)
        #expect(cols[0].windowIds == [win2])
        #expect(cols[1].windowIds == [win1])
    }
    
    @Test("Target frames calculation with vertical stacking")
    func testTargetFramesComputation() {
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1, win2], width: 500)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 2", frame: .zero)
        ]
        
        let computation = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            viewportOffset: 0,
            layoutMode: .scrollStrip
        )
        
        let frame1 = computation.targetFrames[win1]!
        let frame2 = computation.targetFrames[win2]!
        
        #expect(frame1.width == 500)
        #expect(frame2.width == 500)
        // Available height: 800 - 10 = 790 -> 395 each
        #expect(frame1.height == 395)
        #expect(frame2.height == 395)
        #expect(frame1.origin.y == 0)
        #expect(frame2.origin.y == 405) // 0 + 395 + 10 = 405
    }
    
    @Test("Off-screen edge parking prevents WindowServer clamping loops")
    func testOffScreenEdgeParking() {
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let win3 = WindowId(pid: 1, rawId: 3)
        let cols = [
            WindowColumn(windowIds: [win1], width: 400), // Logical: 0...400
            WindowColumn(windowIds: [win2], width: 400), // Logical: 410...810
            WindowColumn(windowIds: [win3], width: 400)  // Logical: 820...1220
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "app", appName: "App", title: "W1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "app", appName: "App", title: "W2", frame: .zero),
            win3: ManagedWindow(id: win3, pid: 1, bundleIdentifier: "app", appName: "App", title: "W3", frame: .zero)
        ]
        
        // Display width 500, viewportOffset = 410 (focus on win2)
        // win1 colScreenX = 0 - 410 = -410 -> colScreenX + colWidth = -410 + 400 = -10 <= 0 + 14 -> parked left
        // win2 colScreenX = 410 - 410 = 0 -> visible
        // win3 colScreenX = 820 - 410 = 410 -> colScreenX (410) >= 500 - 14 (486) is false, but if viewport is 0:
        // Let's test with viewport offset = 410:
        // win3 colScreenX = 410, maxX = 500 -> win3 extends outside right (410 + 400 = 810).
        // If viewport = 0: win3 logical is 820 >= 500 - 14 (486) -> parked right!
        let computation = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 800),
            viewportOffset: 0,
            layoutMode: .manualLayout
        )
        
        #expect(computation.parkedWindowIds.contains(win3))
        let frame3 = computation.targetFrames[win3]!
        // Default zero-sliver parks cleanly offscreen-left: minVisibleX - colWidth - 200 = 0 - 400 - 200 = -600
        #expect(frame3.origin.x == -600)
        
        // When peek sliver is explicitly enabled (> 0)
        let sliverEngine = LayoutEngine(windowGap: 10, defaultColumnWidthRatio: 0.5, defaultMinimumColumnWidth: 400, offScreenPeekSliverWidth: 14.0)
        let sliverComputation = sliverEngine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 800),
            viewportOffset: 0,
            layoutMode: .manualLayout
        )
        let sliverFrame3 = sliverComputation.targetFrames[win3]!
        #expect(sliverFrame3.origin.x == 486)
    }
    
    @Test("Find closest column index for 2-finger scroll settle")
    func testFindClosestColumnIndex() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 500), // Center: 250
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 500), // Center: 510 + 250 = 760
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 500)  // Center: 1020 + 250 = 1270
        ]
        
        // Viewport center when offset = 0 on a 1000pt screen is 500 -> closest center is 250 or 760
        let idx0 = engine.findClosestColumnIndex(for: 0, columns: cols, visibleWidth: 1000)
        #expect(idx0 == 0 || idx0 == 1)
        
        // Viewport center when offset = 510 on a 1000pt screen is 510 + 500 = 1010 -> closest is column 1 (760, dist 250) or column 2 (1270, dist 260) -> 1
        let idx1 = engine.findClosestColumnIndex(for: 510, columns: cols, visibleWidth: 1000)
        #expect(idx1 == 1)
        
        // Viewport offset = 800 -> center is 1300 -> closest is column 2 (center 1270)
        let idx2 = engine.findClosestColumnIndex(for: 800, columns: cols, visibleWidth: 1000)
        #expect(idx2 == 2)
    }
    
    @Test("Cycle column width presets (TileMyMac / ChainYourMac style)")
    func testCycleColumnWidth() {
        var cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 500) // 50% of 1000
        ]
        
        // 50% -> cycles to 66.7% (667)
        let w1 = engine.cycleColumnWidth(at: 0, columns: &cols, visibleWidth: 1000)
        #expect(w1 == 667)
        
        // 66.7% -> cycles to 75% (750)
        let w2 = engine.cycleColumnWidth(at: 0, columns: &cols, visibleWidth: 1000)
        #expect(w2 == 750)
        
        // 75% -> cycles to 100% (1000)
        let w3 = engine.cycleColumnWidth(at: 0, columns: &cols, visibleWidth: 1000)
        #expect(w3 == 1000)
        
        // 100% -> wraps to minimum / 33.3% (clamped to defaultMinimumColumnWidth 400)
        let w4 = engine.cycleColumnWidth(at: 0, columns: &cols, visibleWidth: 1000)
        #expect(w4 == 400)
    }
    
    @Test("Center column offset calculation")
    func testCenterColumnOffsetCalculation() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 600), // 0..600, center = 300
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 600), // 610..1210, center = 910
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 600)  // 1220..1820
        ]
        // Center column 1 on 1000pt screen: centerTarget = 910 - 500 = 410
        let offset = engine.centerColumnOffset(at: 1, columns: cols, visibleWidth: 1000)
        #expect(offset == 410)
    }
    
    @Test("Maximize column to visible width")
    func testMaximizeColumn() {
        var cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 500)
        ]
        engine.maximizeColumn(at: 0, columns: &cols, visibleWidth: 1200)
        #expect(cols[0].width == 1200)
    }
    
    @Test("Continuous scrolling viewport shifts window frames horizontally")
    func testContinuousScrollingViewportShift() {
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1], width: 600), // 0..600
            WindowColumn(windowIds: [win2], width: 600)  // 610..1210
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "a", appName: "A", title: "W1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "b", appName: "B", title: "W2", frame: .zero)
        ]
        
        // Initial offset 0
        let comp0 = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            viewportOffset: 0,
            layoutMode: .scrollStrip
        )
        #expect(comp0.targetFrames[win1]!.origin.x == 0)
        #expect(comp0.targetFrames[win2]!.origin.x == 610)
        
        // Continuous scroll offset 150 (simulating 2-finger swipe right)
        let comp150 = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            viewportOffset: 150,
            layoutMode: .scrollStrip
        )
        // win1 shifts left by 150 pt: 0 - 150 = -150
        #expect(comp150.targetFrames[win1]!.origin.x == -150)
        // win2 shifts left by 150 pt: 610 - 150 = 460
        #expect(comp150.targetFrames[win2]!.origin.x == 460)
    }
}

