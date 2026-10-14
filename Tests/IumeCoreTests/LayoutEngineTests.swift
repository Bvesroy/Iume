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
}
