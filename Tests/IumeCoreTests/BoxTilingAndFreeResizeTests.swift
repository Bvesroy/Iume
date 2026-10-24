import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

@Suite("Box Tiling and Free Resize Tests")
struct BoxTilingAndFreeResizeTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let engine = BoxTilingEngine(
        windowGap: 10,
        edgeMargins: EdgeMargins(top: 20, bottom: 20, left: 15, right: 15),
        mainPaneRatio: 0.55,
        minimumWindowDimension: 150
    )
    
    @Test("Usable screen bounds calculation with margins")
    func testUsableBounds() {
        let bounds = engine.usableBounds(in: screenFrame)
        // x: 0 + 15 = 15, y: 0 + 20 = 20, width: 1200 - 30 = 1170, height: 800 - 40 = 760
        #expect(bounds.origin.x == 15)
        #expect(bounds.origin.y == 20)
        #expect(bounds.width == 1170)
        #expect(bounds.height == 760)
    }
    
    @Test("Window box actions: Halves calculation")
    func testHalvesCalculation() {
        let bounds = engine.usableBounds(in: screenFrame)
        let gap: CGFloat = 10
        let expectedHalfWidth = floor((bounds.width - gap) * 0.5)
        let expectedHalfHeight = floor((bounds.height - gap) * 0.5)
        
        // Left half
        let leftFrame = engine.frame(for: .leftHalf, in: screenFrame)
        #expect(leftFrame.origin.x == bounds.origin.x)
        #expect(leftFrame.origin.y == bounds.origin.y)
        #expect(leftFrame.width == expectedHalfWidth)
        #expect(leftFrame.height == bounds.height)
        
        // Right half
        let rightFrame = engine.frame(for: .rightHalf, in: screenFrame)
        #expect(rightFrame.maxX == bounds.maxX)
        #expect(rightFrame.origin.y == bounds.origin.y)
        #expect(rightFrame.width == expectedHalfWidth)
        #expect(rightFrame.height == bounds.height)
        #expect(abs(rightFrame.minX - (leftFrame.maxX + gap)) <= 1.0)
        
        // Top half
        let topFrame = engine.frame(for: .topHalf, in: screenFrame)
        #expect(topFrame.origin.x == bounds.origin.x)
        #expect(topFrame.origin.y == bounds.origin.y)
        #expect(topFrame.width == bounds.width)
        #expect(topFrame.height == expectedHalfHeight)
        
        // Bottom half
        let bottomFrame = engine.frame(for: .bottomHalf, in: screenFrame)
        #expect(bottomFrame.origin.x == bounds.origin.x)
        #expect(bottomFrame.maxY == bounds.maxY)
        #expect(bottomFrame.width == bounds.width)
        #expect(bottomFrame.height == expectedHalfHeight)
        #expect(abs(bottomFrame.minY - (topFrame.maxY + gap)) <= 1.0)
    }
    
    @Test("Window box actions: Quarters and Corners")
    func testQuartersCalculation() {
        let bounds = engine.usableBounds(in: screenFrame)
        let gap: CGFloat = 10
        let quarterW = floor((bounds.width - gap) * 0.5)
        let quarterH = floor((bounds.height - gap) * 0.5)
        
        let tl = engine.frame(for: .topLeft, in: screenFrame)
        let tr = engine.frame(for: .topRight, in: screenFrame)
        let bl = engine.frame(for: .bottomLeft, in: screenFrame)
        let br = engine.frame(for: .bottomRight, in: screenFrame)
        
        #expect(tl.origin.x == bounds.origin.x)
        #expect(tl.origin.y == bounds.origin.y)
        #expect(tl.width == quarterW)
        #expect(tl.height == quarterH)
        
        #expect(tr.maxX == bounds.maxX)
        #expect(tr.origin.y == bounds.origin.y)
        #expect(tr.width == quarterW)
        #expect(tr.height == quarterH)
        
        #expect(bl.origin.x == bounds.origin.x)
        #expect(bl.maxY == bounds.maxY)
        #expect(bl.width == quarterW)
        #expect(bl.height == quarterH)
        
        #expect(br.maxX == bounds.maxX)
        #expect(br.maxY == bounds.maxY)
        #expect(br.width == quarterW)
        #expect(br.height == quarterH)
    }
    
    @Test("Window box actions: Thirds and Two-Thirds")
    func testThirdsCalculation() {
        let bounds = engine.usableBounds(in: screenFrame)
        let gap: CGFloat = 10
        let thirdW = floor((bounds.width - 2.0 * gap) / 3.0)
        
        let t1 = engine.frame(for: .firstThird, in: screenFrame)
        let t2 = engine.frame(for: .centerThird, in: screenFrame)
        let t3 = engine.frame(for: .lastThird, in: screenFrame)
        
        #expect(t1.origin.x == bounds.origin.x)
        #expect(t1.width == thirdW)
        #expect(abs(t2.minX - (t1.maxX + gap)) <= 1.0)
        #expect(t2.width == thirdW)
        #expect(t3.maxX == bounds.maxX)
        #expect(t3.width == thirdW)
        
        let twoThirds1 = engine.frame(for: .firstTwoThirds, in: screenFrame)
        let twoThirds2 = engine.frame(for: .lastTwoThirds, in: screenFrame)
        #expect(twoThirds1.origin.x == bounds.origin.x)
        #expect(twoThirds1.width > bounds.width * 0.6)
        #expect(twoThirds2.maxX == bounds.maxX)
        #expect(twoThirds2.width > bounds.width * 0.6)
    }
    
    @Test("Window box actions: Maximize, Almost Maximize, Center")
    func testMaximizeAndCenter() {
        let bounds = engine.usableBounds(in: screenFrame)
        
        let maxFrame = engine.frame(for: .maximize, in: screenFrame)
        #expect(maxFrame == bounds)
        
        let almostMax = engine.frame(for: .almostMaximize, in: screenFrame)
        #expect(almostMax.minX > bounds.minX)
        #expect(almostMax.maxX < bounds.maxX)
        #expect(almostMax.minY > bounds.minY)
        #expect(almostMax.maxY < bounds.maxY)
        
        let center = engine.frame(for: .center, in: screenFrame)
        #expect(center.minX >= bounds.minX)
        #expect(center.maxX <= bounds.maxX)
        #expect(abs(center.midX - bounds.midX) <= 1.0)
        #expect(abs(center.midY - bounds.midY) <= 1.0)
    }
    
    @Test("Cycle fraction progression (Rectangle parity)")
    func testCycleFractions() {
        var frac: CGFloat = 0.50
        frac = BoxTilingEngine.nextCycleFraction(after: frac)
        #expect(abs(frac - 0.667) < 0.01)
        frac = BoxTilingEngine.nextCycleFraction(after: frac)
        #expect(abs(frac - 0.333) < 0.01)
        frac = BoxTilingEngine.nextCycleFraction(after: frac)
        #expect(abs(frac - 0.25) < 0.01)
        frac = BoxTilingEngine.nextCycleFraction(after: frac)
        #expect(abs(frac - 0.75) < 0.01)
        frac = BoxTilingEngine.nextCycleFraction(after: frac)
        #expect(abs(frac - 0.50) < 0.01)
        
        // Frame with cycle fraction
        let left23 = engine.frame(for: .leftHalf, in: screenFrame, cycleFraction: 0.667)
        let bounds = engine.usableBounds(in: screenFrame)
        #expect(left23.width > bounds.width * 0.60)
    }
    
    @Test("Multi-window Grid Layout: 1, 2, 3, 4, 6 windows")
    func testGridLayout() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let w3 = WindowId(pid: 100, rawId: 3)
        let w4 = WindowId(pid: 100, rawId: 4)
        let w5 = WindowId(pid: 100, rawId: 5)
        let w6 = WindowId(pid: 100, rawId: 6)
        
        let bounds = engine.usableBounds(in: screenFrame)
        
        // 1 Window
        let grid1 = engine.computeGridLayout(windowIds: [w1], in: screenFrame)
        #expect(grid1[w1] == bounds)
        
        // 2 Windows
        let grid2 = engine.computeGridLayout(windowIds: [w1, w2], in: screenFrame)
        #expect(grid2.count == 2)
        #expect(grid2[w1]!.minX == bounds.minX)
        #expect(grid2[w2]!.maxX == bounds.maxX)
        #expect(grid2[w1]!.maxX < grid2[w2]!.minX)
        
        // 3 Windows (1 master half, 2 stacked quarters)
        let grid3 = engine.computeGridLayout(windowIds: [w1, w2, w3], in: screenFrame)
        #expect(grid3.count == 3)
        #expect(grid3[w1]!.height == bounds.height)
        #expect(grid3[w2]!.minX == grid3[w3]!.minX)
        #expect(grid3[w2]!.maxY < grid3[w3]!.minY)
        
        // 4 Windows (2x2)
        let grid4 = engine.computeGridLayout(windowIds: [w1, w2, w3, w4], in: screenFrame)
        #expect(grid4.count == 4)
        for (_, frame) in grid4 {
            #expect(frame.minX >= bounds.minX - 1)
            #expect(frame.maxX <= bounds.maxX + 1)
            #expect(frame.minY >= bounds.minY - 1)
            #expect(frame.maxY <= bounds.maxY + 1)
        }
        
        // 6 Windows (2x3 or 3x2)
        let grid6 = engine.computeGridLayout(windowIds: [w1, w2, w3, w4, w5, w6], in: screenFrame)
        #expect(grid6.count == 6)
        for (_, frame) in grid6 {
            #expect(frame.width >= 150)
            #expect(frame.height >= 150)
        }
    }
    
    @Test("Multi-window Tall Layout: Master pane on left, vertical stack on right")
    func testTallLayout() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let w3 = WindowId(pid: 100, rawId: 3)
        
        let bounds = engine.usableBounds(in: screenFrame)
        let tall = engine.computeTallLayout(windowIds: [w1, w2, w3], in: screenFrame, customRatio: 0.60)
        
        #expect(tall.count == 3)
        let master = tall[w1]!
        let stack1 = tall[w2]!
        let stack2 = tall[w3]!
        
        #expect(master.origin.x == bounds.origin.x)
        #expect(master.height == bounds.height)
        #expect(master.width > bounds.width * 0.55)
        
        #expect(stack1.minX == stack2.minX)
        #expect(stack1.maxX <= bounds.maxX)
        #expect(stack1.maxY < stack2.minY)
        #expect(stack2.maxY <= bounds.maxY)
    }
    
    @Test("Multi-window Wide Layout: Master pane on top, horizontal stack on bottom")
    func testWideLayout() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let w3 = WindowId(pid: 100, rawId: 3)
        
        let bounds = engine.usableBounds(in: screenFrame)
        let wide = engine.computeWideLayout(windowIds: [w1, w2, w3], in: screenFrame, customRatio: 0.50)
        
        #expect(wide.count == 3)
        let master = wide[w1]!
        let sub1 = wide[w2]!
        let sub2 = wide[w3]!
        
        #expect(master.origin.y == bounds.origin.y)
        #expect(master.width == bounds.width)
        #expect(sub1.minY == sub2.minY)
        #expect(sub1.maxX < sub2.minX)
        #expect(sub2.maxX <= bounds.maxX)
    }
    
    @Test("Multi-window BSP Layout: Recursive binary space partitioning")
    func testBSPLayout() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        let w3 = WindowId(pid: 100, rawId: 3)
        let w4 = WindowId(pid: 100, rawId: 4)
        
        let bounds = engine.usableBounds(in: screenFrame)
        let bsp = engine.computeBSPLayout(windowIds: [w1, w2, w3, w4], in: screenFrame)
        
        #expect(bsp.count == 4)
        for (id, frame) in bsp {
            #expect(frame.minX >= bounds.minX - 1)
            #expect(frame.maxX <= bounds.maxX + 1)
            #expect(frame.minY >= bounds.minY - 1)
            #expect(frame.maxY <= bounds.maxY + 1)
            
            // Check no other window overlaps this one significantly
            for (otherId, otherFrame) in bsp where otherId != id {
                let intersection = frame.intersection(otherFrame)
                #expect(intersection.isNull || intersection.width < 1.0 || intersection.height < 1.0)
            }
        }
    }
    
    @Test("Cooperative Edge Resizing: Horizontal neighbor adjusts flush in lockstep")
    func testCooperativeHorizontalResizing() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        
        // Window 1: (0, 0, 500, 800), Window 2: (510, 0, 500, 800) with gap 10
        let oldFrame1 = CGRect(x: 0, y: 0, width: 500, height: 800)
        let frame2 = CGRect(x: 510, y: 0, width: 500, height: 800)
        let tiled = [w1: oldFrame1, w2: frame2]
        
        // User drags right edge of Window 1 from 500 to 600
        let newFrame1 = CGRect(x: 0, y: 0, width: 600, height: 800)
        let adjustments = engine.computeCooperativeAdjustments(
            resizingWindowId: w1,
            oldFrame: oldFrame1,
            newFrame: newFrame1,
            tiledWindows: tiled,
            screenBounds: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        
        #expect(adjustments.count == 1)
        let adj = adjustments[0]
        #expect(adj.windowId == w2)
        // Window 2 left edge should move to 600 + 10 = 610, width shrinking from 500 to 400
        #expect(adj.adjustedFrame.minX == 610)
        #expect(adj.adjustedFrame.width == 400)
        #expect(adj.adjustedFrame.height == 800)
    }
    
    @Test("Cooperative Edge Resizing: Vertical neighbor adjusts flush in lockstep")
    func testCooperativeVerticalResizing() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        
        // Window 1 (top): (0, 0, 800, 390), Window 2 (bottom): (0, 400, 800, 400) with gap 10
        let oldFrame1 = CGRect(x: 0, y: 0, width: 800, height: 390)
        let frame2 = CGRect(x: 0, y: 400, width: 800, height: 400)
        let tiled = [w1: oldFrame1, w2: frame2]
        
        // User drags bottom edge of Window 1 down from 390 to 490
        let newFrame1 = CGRect(x: 0, y: 0, width: 800, height: 490)
        let adjustments = engine.computeCooperativeAdjustments(
            resizingWindowId: w1,
            oldFrame: oldFrame1,
            newFrame: newFrame1,
            tiledWindows: tiled,
            screenBounds: CGRect(x: 0, y: 0, width: 800, height: 800)
        )
        
        #expect(adjustments.count == 1)
        let adj = adjustments[0]
        #expect(adj.windowId == w2)
        // Window 2 top edge should move to 490 + 10 = 500, height shrinking from 400 to 300
        #expect(adj.adjustedFrame.minY == 500)
        #expect(adj.adjustedFrame.height == 300)
    }
    
    @Test("Screen edge and corner drag-to-snap zone detection")
    func testSnapZoneDetection() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        
        // Top edge -> maximize
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 720, y: 5), screenVisibleFrame: screen) == .topMaximize)
        
        // Left edge -> leftHalf
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 5, y: 450), screenVisibleFrame: screen) == .leftHalf)
        
        // Right edge -> rightHalf
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 1435, y: 450), screenVisibleFrame: screen) == .rightHalf)
        
        // Bottom edge -> bottomHalf
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 720, y: 895), screenVisibleFrame: screen) == .bottomHalf)
        
        // Corners -> Quarters
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 10, y: 10), screenVisibleFrame: screen) == .topLeftQuarter)
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 1430, y: 10), screenVisibleFrame: screen) == .topRightQuarter)
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 10, y: 890), screenVisibleFrame: screen) == .bottomLeftQuarter)
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 1430, y: 890), screenVisibleFrame: screen) == .bottomRightQuarter)
        
        // Center / non-edge -> nil
        #expect(engine.detectSnapZone(cursorPoint: CGPoint(x: 720, y: 450), screenVisibleFrame: screen) == nil)
    }
    
    @Test("Balance window sizes distributes screen space equally")
    func testBalanceSizes() {
        let w1 = WindowId(pid: 100, rawId: 1)
        let w2 = WindowId(pid: 100, rawId: 2)
        
        let balanced = engine.balanceSizes(for: [w1, w2], in: screenFrame, currentLayout: .tall)
        #expect(balanced.count == 2)
        let f1 = balanced[w1]!
        let f2 = balanced[w2]!
        #expect(abs(f1.width - f2.width) <= 2.0)
    }
    
    @Test("LayoutEngine integration with new Box Tiling modes")
    func testLayoutEngineBoxModes() {
        let layout = LayoutEngine(windowGap: 8, defaultColumnWidthRatio: 0.5)
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 400)
        ]
        let windows = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "test", appName: "Test", title: "1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "test", appName: "Test", title: "2", frame: .zero)
        ]
        // Grid mode
        let gridComp = layout.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: screenFrame,
            viewportOffset: 0,
            layoutMode: .grid,
            edgeMargins: EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
        )
        #expect(gridComp.targetFrames.count == 2)
        let w1Frame = gridComp.targetFrames[WindowId(pid: 1, rawId: 1)]!
        let w2Frame = gridComp.targetFrames[WindowId(pid: 1, rawId: 2)]!
        #expect(w1Frame.maxX <= w2Frame.minX)
        
        // Viewport offset in box modes is always 0.0
        let vpGrid = layout.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 50,
            visibleWidth: screenFrame.width,
            layoutMode: .grid
        )
        #expect(vpGrid == 0.0)
    }
    
    @Test("LayoutMode enum cases, descriptions, and cycling")
    func testLayoutModes() {
        #expect(!LayoutMode.grid.description.isEmpty)
        #expect(!LayoutMode.tall.description.isEmpty)
        #expect(!LayoutMode.wide.description.isEmpty)
        #expect(!LayoutMode.bsp.description.isEmpty)
        #expect(!LayoutMode.scrollStrip.description.isEmpty)
        
        let allModes = LayoutMode.allCases
        #expect(allModes.contains(.grid))
        #expect(allModes.contains(.tall))
        #expect(allModes.contains(.wide))
        #expect(allModes.contains(.bsp))
        #expect(allModes.contains(.scrollStrip))
    }
    
    // MARK: - Priority 1 Tests: Loop-Style Radial Menu & Live Footprint Preview
    
    @Test("Priority 1: Radial Menu 8-direction compass sectors and inner/outer rings")
    func testRadialMenuSelection() {
        let origin = CGPoint(x: 500, y: 500)
        
        // Deadzone (< 18pt) -> .center
        let centerSel = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 505, y: 505))
        #expect(centerSel.direction == .center)
        #expect(centerSel.ring == .center)
        #expect(centerSel.action == .center)
        
        // Inner ring East (dx = +40, dy = 0) -> .rightHalf
        let eastInner = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 540, y: 500))
        #expect(eastInner.direction == .east)
        #expect(eastInner.ring == .inner)
        #expect(eastInner.action == .rightHalf)
        
        // Outer ring East (dx = +85, dy = 0) -> .lastThird
        let eastOuter = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 585, y: 500))
        #expect(eastOuter.direction == .east)
        #expect(eastOuter.ring == .outer)
        #expect(eastOuter.action == .lastThird)
        
        // Inner ring West (dx = -40, dy = 0) -> .leftHalf
        let westInner = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 460, y: 500))
        #expect(westInner.direction == .west)
        #expect(westInner.action == .leftHalf)
        
        // Outer ring North in Quartz coordinates (dy = -85 is up) -> .maximize
        let northOuter = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 500, y: 415), yAxisIncreasesUpward: false)
        #expect(northOuter.direction == .north)
        #expect(northOuter.ring == .outer)
        #expect(northOuter.action == .maximize)
        
        // Inner ring North-West in Quartz coordinates (dx = -35, dy = -35) -> .topLeft
        let nwInner = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 465, y: 465), yAxisIncreasesUpward: false)
        #expect(nwInner.direction == .northWest)
        #expect(nwInner.action == .topLeft)
        
        // Inner ring South-East in Quartz coordinates (dx = +35, dy = +35) -> .bottomRight
        let seInner = engine.resolveRadialSelection(origin: origin, cursor: CGPoint(x: 535, y: 535), yAxisIncreasesUpward: false)
        #expect(seInner.direction == .southEast)
        #expect(seInner.action == .bottomRight)
    }
    
    @Test("Priority 1: Live screen footprint preview while dragging near edge or corner")
    func testLiveFootprintPreview() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let bounds = engine.usableBounds(in: screen)
        
        // Drag near left edge -> live preview of Left Half
        let leftPreview = engine.liveFootprintPreview(cursorPoint: CGPoint(x: 6, y: 400), screenVisibleFrame: screen)
        #expect(leftPreview != nil)
        #expect(leftPreview?.zone == .leftHalf)
        #expect(leftPreview?.action == .leftHalf)
        #expect(leftPreview?.targetFrame.origin.x == bounds.origin.x)
        #expect(leftPreview?.targetFrame.height == bounds.height)
        
        // Drag near top-right corner -> live preview of Top-Right Quarter
        let trPreview = engine.liveFootprintPreview(cursorPoint: CGPoint(x: 1192, y: 8), screenVisibleFrame: screen)
        #expect(trPreview != nil)
        #expect(trPreview?.zone == .topRightQuarter)
        #expect(trPreview?.action == .topRight)
        #expect(trPreview?.targetFrame.maxX == bounds.maxX)
        #expect(trPreview?.targetFrame.minY == bounds.minY)
        
        // Drag in middle of screen -> nil preview
        let centerPreview = engine.liveFootprintPreview(cursorPoint: CGPoint(x: 600, y: 400), screenVisibleFrame: screen)
        #expect(centerPreview == nil)
    }
    
    // MARK: - Priority 2 Tests: Interactive Custom Box Grid & Freeform Box Selector
    
    @Test("Priority 2: Custom NxM grid cell hit-testing and multi-cell span frame calculation")
    func testCustomGridSpanAndCellHitTesting() {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let cell00 = engine.gridCell(at: CGPoint(x: 20, y: 20), columns: 4, rows: 3, in: canvas)
        #expect(cell00 == BoxTilingEngine.GridCellCoord(col: 0, row: 0))
        
        let cell32 = engine.gridCell(at: CGPoint(x: 380, y: 280), columns: 4, rows: 3, in: canvas)
        #expect(cell32 == BoxTilingEngine.GridCellCoord(col: 3, row: 2))
        
        let bounds = engine.usableBounds(in: screenFrame)
        // Full 4x3 span should equal entire usable bounds
        let fullSpan = engine.frameForGridSpan(
            start: .init(col: 0, row: 0),
            end: .init(col: 3, row: 2),
            columns: 4,
            rows: 3,
            in: screenFrame
        )
        #expect(fullSpan == bounds)
        
        // Left 2 columns of 4x3 grid = left half
        let leftHalfSpan = engine.frameForGridSpan(
            start: .init(col: 0, row: 0),
            end: .init(col: 1, row: 2),
            columns: 4,
            rows: 3,
            in: screenFrame
        )
        #expect(leftHalfSpan.minX == bounds.minX)
        #expect(leftHalfSpan.height == bounds.height)
        #expect(abs(leftHalfSpan.width - (bounds.width - 10) * 0.5) <= 4.0)
    }
    
    @Test("Priority 2: Freeform normalized box and custom multi-window box tiling")
    func testFreeformNormalizedBox() {
        let bounds = engine.usableBounds(in: screenFrame)
        let normRect = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let frame = engine.frameForNormalizedBox(normRect, in: screenFrame, snapIncrement: 0.05)
        
        #expect(abs(frame.minX - (bounds.minX + bounds.width * 0.25)) <= 2.0)
        #expect(abs(frame.minY - (bounds.minY + bounds.height * 0.20)) <= 2.0)
        #expect(abs(frame.width - (bounds.width * 0.50)) <= 2.0)
        #expect(abs(frame.height - (bounds.height * 0.60)) <= 2.0)
        
        let w1 = WindowId(pid: 1, rawId: 1)
        let w2 = WindowId(pid: 1, rawId: 2)
        let customTiled = engine.tileWindowsIntoCustomBoxes(
            windowIds: [w1, w2],
            normalizedBoxes: [
                CGRect(x: 0.0, y: 0.0, width: 0.70, height: 1.0),
                CGRect(x: 0.70, y: 0.0, width: 0.30, height: 1.0)
            ],
            in: screenFrame
        )
        #expect(customTiled.count == 2)
        #expect(customTiled[w1]!.width > customTiled[w2]!.width)
    }
    
    // MARK: - Priority 3 Tests: 4-Way Corner Intersection Resize & Persistent Custom Box Frames
    
    @Test("Priority 3: 4-Way Corner Intersection drag resizes all 4 touching panes in lockstep")
    func testFourWayCornerIntersectionResize() {
        let wTL = WindowId(pid: 100, rawId: 1) // Top-Left
        let wTR = WindowId(pid: 100, rawId: 2) // Top-Right
        let wBL = WindowId(pid: 100, rawId: 3) // Bottom-Left
        let wBR = WindowId(pid: 100, rawId: 4) // Bottom-Right
        
        // 2x2 grid with gap = 10:
        // Top-Left: (0, 0, 500, 390), Top-Right: (510, 0, 500, 390)
        // Bottom-Left: (0, 400, 500, 390), Bottom-Right: (510, 400, 500, 390)
        let oldTL = CGRect(x: 0, y: 0, width: 500, height: 390)
        let oldTR = CGRect(x: 510, y: 0, width: 500, height: 390)
        let oldBL = CGRect(x: 0, y: 400, width: 500, height: 390)
        let oldBR = CGRect(x: 510, y: 400, width: 500, height: 390)
        let tiled = [wTL: oldTL, wTR: oldTR, wBL: oldBL, wBR: oldBR]
        
        // User drags Top-Left's bottom-right corner from (500, 390) to (600, 470) (+100X, +80Y)
        let newTL = CGRect(x: 0, y: 0, width: 600, height: 470)
        let adjustments = engine.computeCooperativeAdjustments(
            resizingWindowId: wTL,
            oldFrame: oldTL,
            newFrame: newTL,
            tiledWindows: tiled,
            screenBounds: CGRect(x: 0, y: 0, width: 1010, height: 790)
        )
        
        // All 3 other panes (TR, BL, and diagonal BR!) must be adjusted simultaneously
        #expect(adjustments.count == 3)
        let adjMap = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.windowId, $0.adjustedFrame) })
        
        // Top-Right shifted left edge to 610 (width 400) and bottom edge to 470 (height 470)
        #expect(adjMap[wTR]?.minX == 610)
        #expect(adjMap[wTR]?.width == 400)
        #expect(adjMap[wTR]?.height == 470)
        
        // Bottom-Left shifted top edge to 480 (height 310) and right edge to 600 (width 600)
        #expect(adjMap[wBL]?.minY == 480)
        #expect(adjMap[wBL]?.height == 310)
        #expect(adjMap[wBL]?.width == 600)
        
        // Diagonal Bottom-Right shifted both minX to 610 (width 400) and minY to 480 (height 310)
        #expect(adjMap[wBR]?.minX == 610)
        #expect(adjMap[wBR]?.width == 400)
        #expect(adjMap[wBR]?.minY == 480)
        #expect(adjMap[wBR]?.height == 310)
    }
    
    @Test("Priority 3: Persistent customBoxFrames survive LayoutEngine reflows")
    func testPersistentCustomBoxFramesInLayoutEngine() {
        let layout = LayoutEngine(windowGap: 8, defaultColumnWidthRatio: 0.5)
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 400)
        ]
        let windows = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "test", appName: "Test", title: "1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "test", appName: "Test", title: "2", frame: .zero)
        ]
        let customFrame1 = CGRect(x: 20, y: 20, width: 777, height: 555)
        let comp = layout.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: screenFrame,
            viewportOffset: 0,
            layoutMode: .grid,
            edgeMargins: .zero,
            customBoxFrames: [win1: customFrame1]
        )
        #expect(comp.targetFrames[win1] == customFrame1)
        #expect(comp.targetFrames[win2] != nil)
    }
    
    // MARK: - Priority 4 Tests: Modifier-Key Cursor Drag Move & Nearest-Quadrant Resize Anywhere
    
    @Test("Priority 4: Nearest-quadrant corner resize and modifier move from anywhere inside a window")
    func testModifierMoveAndQuadrantResizeAnywhere() {
        let initial = CGRect(x: 200, y: 150, width: 600, height: 400)
        
        // 1. Cursor in bottom-right quadrant (x: 650, y: 450) dragged by (+80, +60)
        let (brResized, brCorner) = engine.computeQuadrantResizeFrame(
            initialFrame: initial,
            initialCursor: CGPoint(x: 650, y: 450),
            currentCursor: CGPoint(x: 730, y: 510),
            screenBounds: screenFrame
        )
        #expect(brCorner == .bottomRight)
        #expect(brResized.minX == initial.minX)
        #expect(brResized.minY == initial.minY)
        #expect(brResized.width == 680)
        #expect(brResized.height == 460)
        
        // 2. Cursor in top-left quadrant (x: 260, y: 200) dragged by (-50, -40)
        let (tlResized, tlCorner) = engine.computeQuadrantResizeFrame(
            initialFrame: initial,
            initialCursor: CGPoint(x: 260, y: 200),
            currentCursor: CGPoint(x: 210, y: 160),
            screenBounds: screenFrame
        )
        #expect(tlCorner == .topLeft)
        #expect(tlResized.maxX == initial.maxX)
        #expect(tlResized.maxY == initial.maxY)
        #expect(tlResized.minX == 150)
        #expect(tlResized.minY == 110)
        #expect(tlResized.width == 650)
        #expect(tlResized.height == 440)
        
        // 3. Modifier move from anywhere inside the window by (+120, +75)
        let moved = engine.computeModifierMoveFrame(
            initialFrame: initial,
            initialCursor: CGPoint(x: 500, y: 350),
            currentCursor: CGPoint(x: 620, y: 425),
            screenBounds: screenFrame
        )
        #expect(moved.origin.x == 320)
        #expect(moved.origin.y == 225)
        #expect(moved.size == initial.size)
    }
}
