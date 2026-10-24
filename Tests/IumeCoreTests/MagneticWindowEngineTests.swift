import Testing
import CoreGraphics
import Foundation
import AppKit
@testable import IumeCore

@Suite("Magnetic Window Snapping & Adhesion Tests", .serialized)
@MainActor
struct MagneticWindowEngineTests {
    
    @Test("Windows brought closer horizontally snap together like a magnet (left to right)")
    func testMagneticSnapLeftToRight() {
        let engine = MagneticWindowEngine(snapRadius: 32.0)
        let win1 = WindowId(pid: 100, rawId: 1)
        let win2 = WindowId(pid: 200, rawId: 2)
        
        let candidateFrame = CGRect(x: 800, y: 50, width: 600, height: 900)
        // Dragged window right edge is at 780 (distance to 800 is 20pt <= 32pt snapRadius)
        let draggedFrame = CGRect(x: 180, y: 50, width: 600, height: 900)
        
        let snap = engine.evaluateMagneticSnap(
            draggedWindowId: win1,
            draggedFrame: draggedFrame,
            candidateWindows: [(id: win2, frame: candidateFrame)],
            gap: 12.0
        )
        
        #expect(snap != nil)
        #expect(snap?.edge == .leftOfCandidate)
        #expect(snap?.candidateWindowId == win2)
        // Snapped frame right edge should be at 800 - 12 = 788 -> origin.x = 788 - 600 = 188
        #expect(snap?.snappedFrame.origin.x == 188)
        #expect(snap?.snappedFrame.maxX == 788)
        #expect(snap?.snappedFrame.origin.y == 50)
    }
    
    @Test("Windows brought closer horizontally snap together with zero gap (appsEdgeTogether)")
    func testMagneticSnapLeftToRightZeroGap() {
        let engine = MagneticWindowEngine(snapRadius: 32.0)
        let win1 = WindowId(pid: 101, rawId: 1)
        let win2 = WindowId(pid: 201, rawId: 2)
        
        let candidateFrame = CGRect(x: 700, y: 30, width: 700, height: 1000)
        // Dragged window right edge is at 685 (distance to 700 is 15pt <= 32pt snapRadius)
        let draggedFrame = CGRect(x: -15, y: 30, width: 700, height: 1000)
        
        let snap = engine.evaluateMagneticSnap(
            draggedWindowId: win1,
            draggedFrame: draggedFrame,
            candidateWindows: [(id: win2, frame: candidateFrame)],
            gap: 0.0 // Zero gap flush
        )
        
        #expect(snap != nil)
        #expect(snap?.edge == .leftOfCandidate)
        // Snapped right edge touches candidate left edge at exactly 700 -> origin.x = 0
        #expect(snap?.snappedFrame.origin.x == 0)
        #expect(snap?.snappedFrame.maxX == 700)
    }
    
    @Test("Windows brought closer from right snap to candidate's right edge")
    func testMagneticSnapRightToLeft() {
        let engine = MagneticWindowEngine(snapRadius: 32.0)
        let win1 = WindowId(pid: 102, rawId: 1)
        let win2 = WindowId(pid: 202, rawId: 2)
        
        let candidateFrame = CGRect(x: 100, y: 50, width: 600, height: 900)
        // Candidate right edge is at 700. With 12pt gap, target minX is 712.
        // Dragged window is at x=725 (distance is 13pt <= 32pt)
        let draggedFrame = CGRect(x: 725, y: 50, width: 500, height: 900)
        
        let snap = engine.evaluateMagneticSnap(
            draggedWindowId: win1,
            draggedFrame: draggedFrame,
            candidateWindows: [(id: win2, frame: candidateFrame)],
            gap: 12.0
        )
        
        #expect(snap != nil)
        #expect(snap?.edge == .rightOfCandidate)
        #expect(snap?.snappedFrame.origin.x == 712)
        #expect(snap?.snappedFrame.origin.y == 50)
    }
    
    @Test("No magnetic snap triggers when distance exceeds snap radius")
    func testNoSnapBeyondRadius() {
        let engine = MagneticWindowEngine(snapRadius: 32.0)
        let win1 = WindowId(pid: 103, rawId: 1)
        let win2 = WindowId(pid: 203, rawId: 2)
        
        let candidateFrame = CGRect(x: 800, y: 50, width: 600, height: 900)
        // Dragged window right edge is at 700 (distance to 800 - 12 = 788 is 88pt > 32pt)
        let draggedFrame = CGRect(x: 100, y: 50, width: 600, height: 900)
        
        let snap = engine.evaluateMagneticSnap(
            draggedWindowId: win1,
            draggedFrame: draggedFrame,
            candidateWindows: [(id: win2, frame: candidateFrame)],
            gap: 12.0
        )
        
        #expect(snap == nil)
    }
    
    @Test("Two adjacent windows remain together when dragging left window")
    func testChainedAdjacentNeighborsDragLeft() {
        let engine = MagneticWindowEngine()
        let win1 = WindowId(pid: 104, rawId: 1)
        let win2 = WindowId(pid: 204, rawId: 2)
        
        let cols = [
            WindowColumn(windowIds: [win1], width: 600),
            WindowColumn(windowIds: [win2], width: 600)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 104, bundleIdentifier: "a", appName: "A", title: "A", frame: CGRect(x: 0, y: 25, width: 600, height: 1000)),
            win2: ManagedWindow(id: win2, pid: 204, bundleIdentifier: "b", appName: "B", title: "B", frame: CGRect(x: 612, y: 25, width: 600, height: 1000))
        ]
        
        // Drag win1 to x = 80
        let draggedFrame1 = CGRect(x: 80, y: 25, width: 600, height: 1000)
        let chained = engine.computeChainedNeighborFrames(
            draggedWindowId: win1,
            draggedFrame: draggedFrame1,
            columns: cols,
            windows: windows,
            gap: 12.0,
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)
        )
        
        #expect(chained[win2] != nil)
        // win2 should be chained directly at draggedFrame1.maxX + 12 = 680 + 12 = 692
        #expect(chained[win2]?.origin.x == 692)
        #expect(chained[win2]?.origin.y == 25)
        #expect(chained[win2]?.width == 600)
    }
    
    @Test("Two adjacent windows remain together when dragging right window")
    func testChainedAdjacentNeighborsDragRight() {
        let engine = MagneticWindowEngine()
        let win1 = WindowId(pid: 105, rawId: 1)
        let win2 = WindowId(pid: 205, rawId: 2)
        
        let cols = [
            WindowColumn(windowIds: [win1], width: 600),
            WindowColumn(windowIds: [win2], width: 600)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 105, bundleIdentifier: "a", appName: "A", title: "A", frame: CGRect(x: 0, y: 25, width: 600, height: 1000)),
            win2: ManagedWindow(id: win2, pid: 205, bundleIdentifier: "b", appName: "B", title: "B", frame: CGRect(x: 612, y: 25, width: 600, height: 1000))
        ]
        
        // Drag win2 to x = 500 (moving it left by 112pt)
        let draggedFrame2 = CGRect(x: 500, y: 25, width: 600, height: 1000)
        let chained = engine.computeChainedNeighborFrames(
            draggedWindowId: win2,
            draggedFrame: draggedFrame2,
            columns: cols,
            windows: windows,
            gap: 12.0,
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)
        )
        
        #expect(chained[win1] != nil)
        // win1 should be chained directly to the left of win2: 500 - 12 - 600 = -112
        #expect(chained[win1]?.origin.x == -112)
        #expect(chained[win1]?.maxX == 488) // 488 + 12 = 500
        #expect(chained[win1]?.origin.y == 25)
    }
    
    @Test("Magnetic seam ratio snapping locks to clean proportional splits")
    func testMagneticSeamRatioSnapping() {
        let combined: CGFloat = 1200.0
        
        // 50% split is 600. Target is 590 (diff 10 <= 18) -> snaps to 600
        let snapped50 = MagneticWindowEngine.snapSeamRatio(combinedWidth: combined, targetWidth: 590, snapRadius: 18.0)
        #expect(snapped50 == 600.0)
        
        // 33.3% split is 400. Target is 410 (diff 10 <= 18) -> snaps to 400
        let snapped33 = MagneticWindowEngine.snapSeamRatio(combinedWidth: combined, targetWidth: 410, snapRadius: 18.0)
        #expect(snapped33 == 400.0)
        
        // 75% split is 900. Target is 912 (diff 12 <= 18) -> snaps to 900
        let snapped75 = MagneticWindowEngine.snapSeamRatio(combinedWidth: combined, targetWidth: 912, snapRadius: 18.0)
        #expect(snapped75 == 900.0)
        
        // Unsnapped: Target is 550 (midway between 400, 600, diff > 18) -> stays 550
        let unsnapped = MagneticWindowEngine.snapSeamRatio(combinedWidth: combined, targetWidth: 550, snapRadius: 18.0)
        #expect(unsnapped == 550.0)
    }
    
    @Test("WorkspaceManager live drag of adjacent window moves companion without flickering")
    func testWorkspaceManagerChainedLiveMovement() {
        let workspaceManager = WorkspaceManager()
        workspaceManager.settings.appsEdgeTogether = false
        workspaceManager.settings.windowGap = 12.0
        workspaceManager.settings.edgeSnapping = true
        workspaceManager.settings.dragToReorder = false // test pure magnetic tracking
        
        let win0 = WindowId(pid: 50, rawId: 1)
        let win1 = WindowId(pid: 51, rawId: 2)
        
        workspaceManager.registry.register(window: ManagedWindow(id: win0, pid: 50, bundleIdentifier: "app.zero", appName: "AppZero", title: "Window 0", frame: CGRect(x: 0, y: 25, width: 700, height: 1055)))
        workspaceManager.registry.register(window: ManagedWindow(id: win1, pid: 51, bundleIdentifier: "app.one", appName: "AppOne", title: "Window 1", frame: CGRect(x: 712, y: 25, width: 700, height: 1055)))
        
        let display = DisplayGeometry(
            id: 1,
            name: "Main Display",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            isPrimary: true
        )
        workspaceManager.setWorkspace(
            DisplayWorkspace(
                displayGeometry: display,
                columns: [
                    WindowColumn(windowIds: [win0], width: 700),
                    WindowColumn(windowIds: [win1], width: 700)
                ],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: 1
        )
        workspaceManager.setActiveDisplayId(1)
        
        // User drags Window 0 to the right (x from 0 to 60)
        let draggedFrame0 = CGRect(x: 60, y: 25, width: 700, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: win0, newFrame: draggedFrame0)
        
        // Window 0 should be at 60
        #expect(workspaceManager.registry.get(windowId: win0)?.frame.origin.x == 60)
        
        // Window 1 MUST REMAIN TOGETHER with Window 0: 60 + 700 + 12 = 772
        let companionFrame = workspaceManager.registry.get(windowId: win1)?.frame
        #expect(companionFrame != nil)
        #expect(companionFrame?.origin.x == 772)
        #expect(companionFrame?.origin.y == 25)
    }
    
    @Test("Screen edge magnetic snapping snaps window flush to left and right screen boundaries")
    func testScreenEdgeMagneticSnapping() {
        let engine = MagneticWindowEngine(snapRadius: 36.0)
        let win = WindowId(pid: 300, rawId: 1)
        let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        
        // Dragged near left screen edge (x = 18, distance to 0 is 18 <= 36)
        let nearLeftFrame = CGRect(x: 18, y: 100, width: 800, height: 900)
        let snapLeft = engine.evaluateMagneticSnap(
            draggedWindowId: win,
            draggedFrame: nearLeftFrame,
            candidateWindows: [],
            gap: 12.0,
            visibleFrame: screen
        )
        
        #expect(snapLeft != nil)
        #expect(snapLeft?.edge == .screenLeftEdge)
        #expect(snapLeft?.snappedFrame.origin.x == 0)
        #expect(snapLeft?.snappedFrame.origin.y == 100)
        
        // Dragged near right screen edge (maxX = 1905, distance to 1920 is 15 <= 36)
        let nearRightFrame = CGRect(x: 1105, y: 100, width: 800, height: 900)
        let snapRight = engine.evaluateMagneticSnap(
            draggedWindowId: win,
            draggedFrame: nearRightFrame,
            candidateWindows: [],
            gap: 12.0,
            visibleFrame: screen
        )
        
        #expect(snapRight != nil)
        #expect(snapRight?.edge == .screenRightEdge)
        #expect(snapRight?.snappedFrame.maxX == 1920)
        #expect(snapRight?.snappedFrame.origin.x == 1120)
    }
    
    @Test("Breakaway threshold decouples magnetic chain when pulled vertically")
    func testBreakawayThresholdDecoupling() {
        let engine = MagneticWindowEngine(snapRadius: 36.0, breakawayThreshold: 160.0)
        let win1 = WindowId(pid: 400, rawId: 1)
        let win2 = WindowId(pid: 401, rawId: 2)
        
        let cols = [
            WindowColumn(windowIds: [win1], width: 600),
            WindowColumn(windowIds: [win2], width: 600)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 400, bundleIdentifier: "a", appName: "A", title: "A", frame: CGRect(x: 0, y: 25, width: 600, height: 1000)),
            win2: ManagedWindow(id: win2, pid: 401, bundleIdentifier: "b", appName: "B", title: "B", frame: CGRect(x: 612, y: 25, width: 600, height: 1000))
        ]
        
        // 1. Normal horizontal movement (deltaY = 10 <= 160 threshold): companion remains attached!
        let attachedFrame = CGRect(x: 50, y: 35, width: 600, height: 1000)
        let attachedChained = engine.computeChainedNeighborFrames(
            draggedWindowId: win1,
            draggedFrame: attachedFrame,
            columns: cols,
            windows: windows,
            gap: 12.0
        )
        #expect(!attachedChained.isEmpty)
        #expect(attachedChained[win2] != nil)
        
        // 2. Intentional vertical pull away (deltaY = 225 > 160 threshold): clean breakaway!
        let breakawayFrame = CGRect(x: 50, y: 250, width: 600, height: 1000)
        let breakawayChained = engine.computeChainedNeighborFrames(
            draggedWindowId: win1,
            draggedFrame: breakawayFrame,
            columns: cols,
            windows: windows,
            gap: 12.0
        )
        #expect(breakawayChained.isEmpty)
    }
    
    @Test("Three adjacent windows chain symmetrically when middle window is dragged")
    func testThreeWindowsChainSymmetrically() {
        let engine = MagneticWindowEngine()
        let win0 = WindowId(pid: 500, rawId: 0)
        let win1 = WindowId(pid: 501, rawId: 1)
        let win2 = WindowId(pid: 502, rawId: 2)
        
        let cols = [
            WindowColumn(windowIds: [win0], width: 500),
            WindowColumn(windowIds: [win1], width: 500),
            WindowColumn(windowIds: [win2], width: 500)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win0: ManagedWindow(id: win0, pid: 500, bundleIdentifier: "0", appName: "0", title: "0", frame: CGRect(x: 0, y: 30, width: 500, height: 900)),
            win1: ManagedWindow(id: win1, pid: 501, bundleIdentifier: "1", appName: "1", title: "1", frame: CGRect(x: 512, y: 30, width: 500, height: 900)),
            win2: ManagedWindow(id: win2, pid: 502, bundleIdentifier: "2", appName: "2", title: "2", frame: CGRect(x: 1024, y: 30, width: 500, height: 900))
        ]
        
        // Drag center window (win1) to x = 600
        let draggedMiddle = CGRect(x: 600, y: 30, width: 500, height: 900)
        let chained = engine.computeChainedNeighborFrames(
            draggedWindowId: win1,
            draggedFrame: draggedMiddle,
            columns: cols,
            windows: windows,
            gap: 12.0
        )
        
        // Left neighbor win0 should be chained at: 600 - 12 - 500 = 88
        #expect(chained[win0] != nil)
        #expect(chained[win0]?.origin.x == 88)
        #expect(chained[win0]?.maxX == 588) // 588 + 12 = 600
        
        // Right neighbor win2 should be chained at: 600 + 500 + 12 = 1112
        #expect(chained[win2] != nil)
        #expect(chained[win2]?.origin.x == 1112)
    }
    
    @Test("MouseStateKeeper state transitions and delayed AX event handling (Amethyst parity)")
    func testMouseStateKeeperLifecycle() {
        final class TestDelegate: MouseStateKeeperDelegate {
            var didBegin = false
            var didEndDrag = false
            var didEndResize = false
            var endedWindowId: WindowId?
            
            func mouseStateDidBeginDragging(windowId: WindowId) {
                didBegin = true
            }
            func mouseStateDidEndDragging(windowId: WindowId, initialFrame: CGRect) {
                didEndDrag = true
                endedWindowId = windowId
            }
            func mouseStateDidEndResizing(windowId: WindowId, initialFrame: CGRect) {
                didEndResize = true
            }
        }
        
        let delegate = TestDelegate()
        let keeper = MouseStateKeeper(delegate: delegate)
        #expect(keeper.state == .pointing)
        
        let testWin = WindowId(pid: 600, rawId: 1)
        let initialFrame = CGRect(x: 100, y: 100, width: 500, height: 500)
        
        // 1. Upgrade to moving
        keeper.upgradeToMoving(windowId: testWin, initialFrame: initialFrame)
        #expect(delegate.didBegin)
        #expect(keeper.state == .moving(windowId: testWin, initialFrame: initialFrame))
        
        // 2. Delayed AX event arrival when mouse was released before AX notification (.doneDragging)
        keeper.reset()
        #expect(keeper.state == .pointing)
        
        keeper.handleMouseDragged()
        #expect(keeper.state == .dragging)
        
        // Simulate mouse up arriving before AX notification
        keeper.handleMouseUp()
        
        // Lagging AX notification arrives within race threshold -> triggers completion smoothly!
        keeper.upgradeToMoving(windowId: testWin, initialFrame: initialFrame)
        #expect(delegate.didEndDrag)
        #expect(delegate.endedWindowId == testWin)
        #expect(keeper.state == .pointing)
    }
}

