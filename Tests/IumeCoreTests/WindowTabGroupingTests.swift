import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import IumeCore

@Suite("Window Tab Grouping Tests", .serialized)
struct WindowTabGroupingTests {
    
    private func makeWindow(id: UInt64, pid: pid_t = 100, bundleId: String = "com.google.Chrome", appName: String = "Google Chrome", title: String = "New Tab") -> ManagedWindow {
        let winId = WindowId(pid: pid, rawId: id)
        return ManagedWindow(
            id: winId,
            pid: pid,
            bundleIdentifier: bundleId,
            appName: appName,
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    private func makeDisplay() -> DisplayGeometry {
        DisplayGeometry(
            id: 1,
            name: "Main Display",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            isPrimary: true
        )
    }

    // MARK: - 1. WindowColumn Tab Model Tests
    
    @Test("WindowColumn accurately identifies tab group and tab bar visibility")
    func testWindowColumnTabGroupProperties() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        
        var singleTabCol = WindowColumn(windowIds: [w1], presentationMode: .tabbed)
        #expect(!singleTabCol.isTabGroup)
        #expect(!singleTabCol.showsTabBar) // Single tab does not show tab bar by default
        
        singleTabCol.tabBarPinned = true
        #expect(singleTabCol.showsTabBar) // Pinning forces tab bar to stay visible
        
        let multiTabCol = WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed)
        #expect(multiTabCol.isTabGroup)
        #expect(multiTabCol.showsTabBar) // Multiple tabs show tab bar automatically
        
        let stackedCol = WindowColumn(windowIds: [w1, w2], presentationMode: .stacked)
        #expect(!stackedCol.isTabGroup)
        #expect(!stackedCol.showsTabBar)
    }

    @Test("WindowColumn tab selection and activeWindowId tracking")
    func testWindowColumnTabSelection() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 10, rawId: 3)
        
        var col = WindowColumn(windowIds: [w1, w2, w3], presentationMode: .tabbed)
        #expect(col.activeWindowId == w1)
        #expect(col.activeWindowIndex == 0)
        
        let didSelect2 = col.selectWindow(w2)
        #expect(didSelect2)
        #expect(col.activeWindowId == w2)
        #expect(col.activeWindowIndex == 1)
        
        let didSelect3 = col.selectWindow(w3)
        #expect(didSelect3)
        #expect(col.activeWindowId == w3)
        #expect(col.activeWindowIndex == 2)
        
        let nonMember = WindowId(pid: 10, rawId: 99)
        let didSelectNonMember = col.selectWindow(nonMember)
        #expect(!didSelectNonMember)
        #expect(col.activeWindowId == w3) // Unchanged
    }

    @Test("WindowColumn moveWindow preserves active tab identity during drag reordering")
    func testWindowColumnDragReordering() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 10, rawId: 3)
        
        var col = WindowColumn(windowIds: [w1, w2, w3], presentationMode: .tabbed)
        col.selectWindow(w2) // Active tab is w2 (index 1)
        #expect(col.activeWindowId == w2)
        
        // Move w1 from index 0 to index 2: [w2, w3, w1]
        let movedFirst = col.moveWindow(w1, to: 2)
        #expect(movedFirst)
        #expect(col.windowIds == [w2, w3, w1])
        #expect(col.activeWindowId == w2) // Still active!
        #expect(col.activeWindowIndex == 0) // Now at index 0
        
        // Move active tab w2 to the end: [w3, w1, w2]
        let movedActive = col.moveWindow(w2, to: 2)
        #expect(movedActive)
        #expect(col.windowIds == [w3, w1, w2])
        #expect(col.activeWindowId == w2) // Still active!
        #expect(col.activeWindowIndex == 2) // Index updated to 2
    }

    @Test("WindowColumn removeWindow safely clamps activeWindowIndex")
    func testWindowColumnRemoveTab() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 10, rawId: 3)
        
        var col = WindowColumn(windowIds: [w1, w2, w3], presentationMode: .tabbed)
        col.selectWindow(w3) // Active tab is w3 (index 2)
        
        // Remove active tab w3
        let removedActive = col.removeWindow(w3)
        #expect(removedActive)
        #expect(col.windowIds == [w1, w2])
        #expect(col.activeWindowIndex == 1) // Clamped to last index
        #expect(col.activeWindowId == w2)
        
        // Remove preceding tab w1
        let removedPreceding = col.removeWindow(w1)
        #expect(removedPreceding)
        #expect(col.windowIds == [w2])
        #expect(col.activeWindowIndex == 0)
        #expect(col.activeWindowId == w2)
    }

    // MARK: - 2. WorkspaceManager Same-App Tab Grouping Tests

    @Test("WorkspaceManager tabSameAppWindows groups windows of same app into tabs")
    @MainActor
    func testTabSameAppWindows() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let win1 = makeWindow(id: 101, pid: 501, bundleId: "com.google.Chrome", title: "GitHub - Iume")
        let win2 = makeWindow(id: 102, pid: 501, bundleId: "com.google.Chrome", title: "Google Docs")
        let win3 = makeWindow(id: 103, pid: 602, bundleId: "com.apple.Terminal", title: "zsh")
        
        wm.registry.register(window: win1)
        wm.registry.register(window: win2)
        wm.registry.register(window: win3)
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        ws.columns = [
            WindowColumn(windowIds: [win1.id]),
            WindowColumn(windowIds: [win3.id]),
            WindowColumn(windowIds: [win2.id])
        ]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = win1.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Group all Chrome windows together
        wm.tabSameAppWindows()
        
        let updatedWs = wm.workspaces[disp.id]!
        #expect(updatedWs.columns.count == 2)
        
        // Focused column should now be the tab group containing win1 and win2
        let tabCol = updatedWs.columns[updatedWs.focusedColumnIndex!]
        #expect(tabCol.presentationMode == .tabbed)
        #expect(tabCol.windowIds.contains(win1.id))
        #expect(tabCol.windowIds.contains(win2.id))
        #expect(!tabCol.windowIds.contains(win3.id)) // Terminal window remains separate!
        #expect(tabCol.isTabGroup)
        #expect(tabCol.showsTabBar)
    }

    @Test("WorkspaceManager tabAllSameAppWindows groups multiple applications across workspace")
    @MainActor
    func testTabAllSameAppWindows() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let c1 = makeWindow(id: 1, pid: 500, bundleId: "com.google.Chrome", title: "Chrome 1")
        let c2 = makeWindow(id: 2, pid: 500, bundleId: "com.google.Chrome", title: "Chrome 2")
        let t1 = makeWindow(id: 3, pid: 600, bundleId: "com.apple.Terminal", title: "Term 1")
        let t2 = makeWindow(id: 4, pid: 600, bundleId: "com.apple.Terminal", title: "Term 2")
        let f1 = makeWindow(id: 5, pid: 700, bundleId: "com.apple.finder", title: "Finder")
        
        for w in [c1, c2, t1, t2, f1] {
            wm.registry.register(window: w)
        }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        ws.columns = [
            WindowColumn(windowIds: [c1.id]),
            WindowColumn(windowIds: [t1.id]),
            WindowColumn(windowIds: [c2.id]),
            WindowColumn(windowIds: [t2.id]),
            WindowColumn(windowIds: [f1.id])
        ]
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        wm.tabAllSameAppWindows()
        
        let updatedWs = wm.workspaces[disp.id]!
        // Should produce 3 columns: Chrome tab group (2 tabs), Terminal tab group (2 tabs), Finder single column (1 window)
        #expect(updatedWs.columns.count == 3)
        
        let chromeCol = updatedWs.columns.first { $0.windowIds.contains(c1.id) }!
        #expect(chromeCol.presentationMode == .tabbed)
        #expect(chromeCol.windowIds.count == 2)
        #expect(chromeCol.windowIds.contains(c2.id))
        
        let termCol = updatedWs.columns.first { $0.windowIds.contains(t1.id) }!
        #expect(termCol.presentationMode == .tabbed)
        #expect(termCol.windowIds.count == 2)
        #expect(termCol.windowIds.contains(t2.id))
        
        let finderCol = updatedWs.columns.first { $0.windowIds.contains(f1.id) }!
        #expect(finderCol.windowIds == [f1.id])
    }

    // MARK: - 3. Tab Navigation & Operations

    @Test("WorkspaceManager cycleTabInFocusedColumn wraps forward and backward")
    @MainActor
    func testCycleTabInFocusedColumn() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        
        for w in [w1, w2, w3] { wm.registry.register(window: w) }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        let col = WindowColumn(windowIds: [w1.id, w2.id, w3.id], presentationMode: .tabbed)
        ws.columns = [col]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = w1.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Cycle forward: w1 -> w2
        wm.cycleTabInFocusedColumn(forward: true)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == w2.id)
        #expect(wm.registry.focusedId == w2.id)
        
        // Cycle forward: w2 -> w3
        wm.cycleTabInFocusedColumn(forward: true)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == w3.id)
        #expect(wm.registry.focusedId == w3.id)
        
        // Cycle forward wraps: w3 -> w1
        wm.cycleTabInFocusedColumn(forward: true)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == w1.id)
        
        // Cycle backward wraps: w1 -> w3
        wm.cycleTabInFocusedColumn(forward: false)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == w3.id)
    }

    @Test("WorkspaceManager detachTab ungroups a single tab into an independent column")
    @MainActor
    func testDetachTab() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        for w in [w1, w2] { wm.registry.register(window: w) }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        let col = WindowColumn(windowIds: [w1.id, w2.id], presentationMode: .tabbed)
        ws.columns = [col]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = w1.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Detach w2 from the tab group
        wm.detachTab(windowId: w2.id, fromColumnWithId: col.id)
        
        let updatedWs = wm.workspaces[disp.id]!
        #expect(updatedWs.columns.count == 2)
        #expect(updatedWs.columns[0].windowIds == [w1.id])
        #expect(updatedWs.columns[1].windowIds == [w2.id])
        #expect(wm.registry.focusedId == w2.id) // Detached tab receives focus
    }

    @Test("WorkspaceManager ungroupAllTabs dissolves tab group into sequential columns")
    @MainActor
    func testUngroupAllTabs() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        for w in [w1, w2, w3] { wm.registry.register(window: w) }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        let col = WindowColumn(windowIds: [w1.id, w2.id, w3.id], presentationMode: .tabbed)
        ws.columns = [col]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = w2.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        wm.ungroupAllTabs(inColumnWithId: col.id)
        
        let updatedWs = wm.workspaces[disp.id]!
        #expect(updatedWs.columns.count == 3)
        #expect(updatedWs.columns[0].windowIds == [w1.id])
        #expect(updatedWs.columns[1].windowIds == [w2.id])
        #expect(updatedWs.columns[2].windowIds == [w3.id])
        #expect(updatedWs.focusedColumnIndex == 1) // Focused index tracks w2
    }

    @Test("WorkspaceManager addExistingWindowAsTab attaches candidate window into tab group")
    @MainActor
    func testAddExistingWindowAsTab() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let w1 = makeWindow(id: 1, bundleId: "com.google.Chrome")
        let w2 = makeWindow(id: 2, bundleId: "com.google.Chrome")
        for w in [w1, w2] { wm.registry.register(window: w) }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        let col1 = WindowColumn(windowIds: [w1.id], presentationMode: .tabbed)
        let col2 = WindowColumn(windowIds: [w2.id], presentationMode: .stacked)
        ws.columns = [col1, col2]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = w1.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Add w2 into col1
        wm.addExistingWindowAsTab(w2.id, toColumnWithId: col1.id)
        
        let updatedWs = wm.workspaces[disp.id]!
        #expect(updatedWs.columns.count == 1)
        #expect(updatedWs.columns[0].windowIds == [w1.id, w2.id])
        #expect(updatedWs.columns[0].activeWindowId == w2.id) // Newly added tab becomes active
        #expect(wm.registry.focusedId == w2.id)
    }

    // MARK: - 4. Tab Bar Layout Geometry & Height Reservation

    @Test("LayoutEngine allocates 28pt tab bar height without overlapping content")
    func testTabBarGeometryPartitioning() {
        let engine = LayoutEngine()
        let win1 = makeWindow(id: 1, pid: 10)
        let win2 = makeWindow(id: 2, pid: 10)
        let w1 = win1.id
        let w2 = win2.id
        let windowMap = [w1: win1, w2: win2]
        
        let col = WindowColumn(windowIds: [w1, w2], width: 800, presentationMode: .tabbed, activeWindowIndex: 0)
        let visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        
        let computation = engine.computeLayout(
            columns: [col],
            windows: windowMap,
            focusedColumnIndex: 0,
            visibleFrame: visibleFrame,
            viewportOffset: 0,
            layoutMode: .scrollStrip,
            centerMode: .never,
            edgeMargins: EdgeMargins(top: 10, bottom: 10, left: 10, right: 10)
        )
        
        let activeFrame = computation.targetFrames[w1]!
        let usableHeight = visibleFrame.height - 20 // 10 top + 10 bottom margins
        
        // Active window starts exactly 28pt below the column top (reserving space for TabBar)
        let expectedY = visibleFrame.minY + 10 + PureStripLayoutEngine.tabBarHeight
        #expect(abs(activeFrame.origin.y - expectedY) < 1.0)
        
        // Active window height is usableHeight minus tabBarHeight
        let expectedHeight = usableHeight - PureStripLayoutEngine.tabBarHeight
        #expect(abs(activeFrame.height - expectedHeight) < 1.0)
        
        // Inactive tab w2 is parked offscreen without disturbing layout or content state
        #expect(computation.parkedWindowIds.contains(w2))
    }

    // MARK: - 5. LayoutEngine Tab Operations

    @Test("LayoutEngine moves a window into a tab group and removes the empty source column")
    func testMoveWindowToTabGroup() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 20, rawId: 3)

        var columns = [
            WindowColumn(windowIds: [w1, w2], width: 700, presentationMode: .tabbed, activeWindowIndex: 0),
            WindowColumn(windowIds: [w3], width: 500)
        ]

        let target = engine.moveWindowToTabGroup(
            windowId: w3,
            fromColumnIndex: 1,
            toColumnIndex: 0,
            columns: &columns
        )

        #expect(target == 0)
        #expect(columns.count == 1)
        #expect(columns[0].windowIds == [w1, w2, w3])
        #expect(columns[0].presentationMode == .tabbed)
        #expect(columns[0].activeWindowIndex == 2) // The moved window becomes the active tab
    }

    @Test("LayoutEngine detachTab restores an independent column with the group's width")
    func testLayoutEngineDetachTab() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 10, rawId: 3)

        var columns = [
            WindowColumn(windowIds: [w1, w2, w3], width: 720, presentationMode: .tabbed, activeWindowIndex: 1)
        ]

        let detachedIndex = engine.detachTab(windowId: w2, fromColumnIndex: 0, columns: &columns)

        #expect(detachedIndex == 1)
        #expect(columns.count == 2)
        #expect(columns[0].windowIds == [w1, w3])
        #expect(columns[0].presentationMode == .tabbed)
        #expect(columns[1].windowIds == [w2])
        #expect(columns[1].presentationMode == .stacked)
        #expect(columns[1].width == 720) // Detached tab keeps the group's width
        #expect(columns[1].activeWindowIndex == 0)
    }

    @Test("LayoutEngine detachTab collapses a two-tab group to a normal column")
    func testLayoutEngineDetachLastRemainingTab() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 11, rawId: 1)
        let w2 = WindowId(pid: 11, rawId: 2)

        var columns = [
            WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed)
        ]

        #expect(engine.detachTab(windowId: w2, fromColumnIndex: 0, columns: &columns) == 1)
        #expect(columns[0].windowIds == [w1])
        #expect(columns[0].presentationMode == .stacked) // Unpinned single tab reverts to stacked
        #expect(!columns[0].showsTabBar)
    }

    @Test("LayoutEngine ungroupAllTabs expands a group into sequential columns")
    func testLayoutEngineUngroupAllTabs() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 12, rawId: 1)
        let w2 = WindowId(pid: 12, rawId: 2)
        let w3 = WindowId(pid: 12, rawId: 3)

        var columns = [
            WindowColumn(windowIds: [w1, w2, w3], width: 640, presentationMode: .tabbed),
            WindowColumn(windowIds: [WindowId(pid: 99, rawId: 9)])
        ]

        let indices = engine.ungroupAllTabs(at: 0, columns: &columns)

        #expect(indices == [0, 1, 2])
        #expect(columns.count == 4)
        #expect(columns[0].windowIds == [w1])
        #expect(columns[1].windowIds == [w2])
        #expect(columns[2].windowIds == [w3])
        #expect(columns[0...2].allSatisfy { $0.presentationMode == .stacked })
        #expect(columns[0...2].allSatisfy { $0.width == 640 })
        #expect(columns[3].windowIds.count == 1) // Unrelated trailing column untouched
    }

    @Test("LayoutEngine columnScreenFrames aligns tab bars with columns and parks offscreen ones")
    func testColumnScreenFrames() {
        let engine = LayoutEngine(
            windowGap: 0,
            edgeMargins: EdgeMargins(top: 10, bottom: 10, left: 20, right: 20)
        )
        let w1 = WindowId(pid: 13, rawId: 1)
        let w2 = WindowId(pid: 13, rawId: 2)
        let col1 = WindowColumn(windowIds: [w1], width: 600)
        let col2 = WindowColumn(windowIds: [w2], width: 600)
        let visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)

        let atOrigin = engine.columnScreenFrames(
            columns: [col1, col2],
            viewportOffset: 0,
            visibleFrame: visibleFrame
        )
        #expect(atOrigin[col1.id]?.frame.minX == 20)
        #expect(atOrigin[col2.id]?.frame.minX == 620)
        #expect(atOrigin[col1.id]?.isParked == false)
        #expect(atOrigin[col1.id]?.frame.minY == visibleFrame.minY + 10)
        #expect(atOrigin[col1.id]?.frame.height == visibleFrame.height - 20)

        // Scrolling right parks the first column against the left edge while
        // the second remains on screen; the bar follows the same x geometry.
        let scrolled = engine.columnScreenFrames(
            columns: [col1, col2],
            viewportOffset: 1000,
            visibleFrame: visibleFrame
        )
        #expect(scrolled[col1.id]?.isParked == true)
        #expect(scrolled[col1.id]?.frame.minX == 20 - 600 + engine.offScreenPeekSliverWidth)
        #expect(scrolled[col2.id]?.isParked == false)
    }

    // MARK: - 6. Persistence Round-Trip

    @Test("Saved layout round-trips tab presentation, active tab and pin state")
    @MainActor
    func testTabStatePersistenceRoundTrip() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let testFile = tempDir.appendingPathComponent("tabs.json")
        let persistence = LayoutPersistenceManager(customStorageUrl: testFile)

        let c1 = makeWindow(id: 1, pid: 800, bundleId: "com.google.Chrome", title: "Docs")
        let c2 = makeWindow(id: 2, pid: 800, bundleId: "com.google.Chrome", title: "Mail")
        let t1 = makeWindow(id: 3, pid: 900, bundleId: "com.apple.Terminal", title: "zsh")
        let windowsMap = [c1.id: c1, c2.id: c2, t1.id: t1]

        let originalColumns = [
            WindowColumn(windowIds: [c1.id, c2.id], width: 900, presentationMode: .tabbed, activeWindowIndex: 1),
            WindowColumn(windowIds: [t1.id], width: 500, presentationMode: .tabbed, tabBarPinned: true)
        ]

        let saved = persistence.captureSpaceLayout(
            columns: originalColumns,
            windows: windowsMap,
            focusedColumnIndex: 0,
            viewportOffset: 42
        )
        persistence.save(state: PersistedLayoutState(spaces: ["1_1": saved]))

        let loaded = persistence.load()
        #expect(loaded?.spaces["1_1"]?.columns[0].presentationMode == .tabbed)
        #expect(loaded?.spaces["1_1"]?.columns[0].activeWindowIndex == 1)
        #expect(loaded?.spaces["1_1"]?.columns[0].tabBarPinned == false)
        #expect(loaded?.spaces["1_1"]?.columns[1].tabBarPinned == true)

        let restored = persistence.restoreSpaceLayout(
            savedLayout: loaded!.spaces["1_1"]!,
            availableWindows: [t1, c2, c1], // Deliberately scrambled
            visibleWidth: 1440
        )

        #expect(restored.restoredColumns.count == 2)
        #expect(restored.restoredColumns[0].windowIds == [c1.id, c2.id])
        #expect(restored.restoredColumns[0].presentationMode == .tabbed)
        #expect(restored.restoredColumns[0].activeWindowIndex == 1)
        #expect(restored.restoredColumns[0].activeWindowId == c2.id)
        #expect(restored.restoredColumns[1].windowIds == [t1.id])
        #expect(restored.restoredColumns[1].presentationMode == .tabbed) // Pinned single window stays tabbed
        #expect(restored.restoredColumns[1].showsTabBar)
    }

    // MARK: - 6. Navigation, Focus & Window Controls Tests

    @Test("FocusManager navigation respects boundaries when wrapAround is disabled")
    @MainActor
    func testFocusNavigationWithoutWrapAround() {
        let fm = FocusManager()
        let w1 = WindowId(pid: 1, rawId: 1)
        let w2 = WindowId(pid: 1, rawId: 2)
        let w3 = WindowId(pid: 1, rawId: 3)
        let cols = [
            WindowColumn(windowIds: [w1]),
            WindowColumn(windowIds: [w2]),
            WindowColumn(windowIds: [w3])
        ]
        
        var selectedWin: WindowId?
        var selectedCol: Int?
        fm.onFocusRequested = { winId, colIdx in
            selectedWin = winId
            selectedCol = colIdx
        }
        
        // At right edge (col 2), focusRight clamps to 2
        fm.focusRight(columns: cols, currentColumnIndex: 2, wrapAround: false)
        #expect(selectedCol == 2)
        #expect(selectedWin == w3)
        
        // At left edge (col 0), focusLeft clamps to 0
        fm.focusLeft(columns: cols, currentColumnIndex: 0, wrapAround: false)
        #expect(selectedCol == 0)
        #expect(selectedWin == w1)
    }

    @Test("FocusManager navigation loops seamlessly when wrapAround is enabled")
    @MainActor
    func testFocusNavigationWithWrapAround() {
        let fm = FocusManager()
        let w1 = WindowId(pid: 1, rawId: 1)
        let w2 = WindowId(pid: 1, rawId: 2)
        let w3 = WindowId(pid: 1, rawId: 3)
        let cols = [
            WindowColumn(windowIds: [w1]),
            WindowColumn(windowIds: [w2]),
            WindowColumn(windowIds: [w3])
        ]
        
        var selectedWin: WindowId?
        var selectedCol: Int?
        fm.onFocusRequested = { winId, colIdx in
            selectedWin = winId
            selectedCol = colIdx
        }
        
        // At right edge (col 2), focusRight loops to col 0
        fm.focusRight(columns: cols, currentColumnIndex: 2, wrapAround: true)
        #expect(selectedCol == 0)
        #expect(selectedWin == w1)
        
        // At left edge (col 0), focusLeft loops to col 2
        fm.focusLeft(columns: cols, currentColumnIndex: 0, wrapAround: true)
        #expect(selectedCol == 2)
        #expect(selectedWin == w3)
    }

    @Test("FocusManager vertical stack navigation supports wrapAround")
    @MainActor
    func testFocusVerticalStackWrapAround() {
        let fm = FocusManager()
        let w1 = WindowId(pid: 1, rawId: 1)
        let w2 = WindowId(pid: 1, rawId: 2)
        let stackCol = WindowColumn(windowIds: [w1, w2], presentationMode: .stacked)
        let cols = [stackCol]
        
        var selectedWin: WindowId?
        fm.onFocusRequested = { winId, _ in selectedWin = winId }
        
        // Focus down from bottom window (w2) wraps to top window (w1)
        fm.focusDown(columns: cols, currentColumnIndex: 0, currentWindowId: w2, wrapAround: true)
        #expect(selectedWin == w1)
        
        // Focus up from top window (w1) wraps to bottom window (w2)
        fm.focusUp(columns: cols, currentColumnIndex: 0, currentWindowId: w1, wrapAround: true)
        #expect(selectedWin == w2)
    }

    @Test("LayoutEngine maximizeColumn toggles between full width and previous ratio")
    func testMaximizeColumnToggleRestoration() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 1, rawId: 1)
        var cols = [
            WindowColumn(windowIds: [w1], width: 600)
        ]
        let visibleWidth: CGFloat = 1200.0
        
        // 1st trigger: Maximize to full visible width
        engine.maximizeColumn(at: 0, columns: &cols, visibleWidth: visibleWidth)
        #expect(cols[0].width == 1200.0)
        #expect(cols[0].isFullWidth == true)
        #expect(abs(cols[0].savedPreFullWidthRatio - 0.50) < 0.01)
        
        // 2nd trigger: Toggle back to original width
        engine.maximizeColumn(at: 0, columns: &cols, visibleWidth: visibleWidth)
        #expect(cols[0].width == 600.0)
        #expect(cols[0].isFullWidth == false)
    }

    @Test("WorkspaceManager moveColumnLeft and moveColumnRight reorders strip columns")
    @MainActor
    func testMoveColumnLeftAndRight() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        for w in [w1, w2, w3] { wm.registry.register(window: w) }
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        ws.columns = [
            WindowColumn(windowIds: [w1.id]),
            WindowColumn(windowIds: [w2.id]),
            WindowColumn(windowIds: [w3.id])
        ]
        ws.focusedColumnIndex = 0
        wm.registry.focusedId = w1.id
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Move col 0 right: [w2, w1, w3]
        wm.moveColumnRight()
        let ws1 = wm.workspaces[disp.id]!
        #expect(ws1.columns[0].windowIds == [w2.id])
        #expect(ws1.columns[1].windowIds == [w1.id])
        #expect(ws1.columns[2].windowIds == [w3.id])
        #expect(ws1.focusedColumnIndex == 1)
        
        // Move col 1 left: [w1, w2, w3]
        wm.moveColumnLeft()
        let ws2 = wm.workspaces[disp.id]!
        #expect(ws2.columns[0].windowIds == [w1.id])
        #expect(ws2.columns[1].windowIds == [w2.id])
        #expect(ws2.columns[2].windowIds == [w3.id])
        #expect(ws2.focusedColumnIndex == 0)
    }

    @Test("SettingsStore navigation preferences persist and reset cleanly")
    @MainActor
    func testNavigationSettingsPersistence() {
        let store = SettingsStore.shared
        
        store.wrapAroundFocus = true
        store.cycleTabsBeforeColumns = false
        store.fullWidthToggleRestoresRatio = false
        
        #expect(store.wrapAroundFocus == true)
        #expect(store.cycleTabsBeforeColumns == false)
        #expect(store.fullWidthToggleRestoresRatio == false)
        
        store.resetToDefaults()
        
        #expect(store.wrapAroundFocus == false)
        #expect(store.cycleTabsBeforeColumns == true)
        #expect(store.fullWidthToggleRestoresRatio == true)
    }

    @Test("Tab motion settings persist, validate effects, and reset cleanly")
    @MainActor
    func testTabMotionSettings() {
        let store = SettingsStore.shared

        store.tabAnimationsEnabled = true
        store.tabSwitchEffect = .springPop
        store.tabOpenCloseEffect = .materialize
        store.tabMotionSpeed = 1.35
        store.tabHapticsEnabled = false

        #expect(store.tabSwitchEffect == .springPop)
        #expect(store.tabOpenCloseEffect == .materialize)
        #expect(abs(store.tabMotionSpeed - 1.35) < 0.001)
        #expect(store.tabHapticsEnabled == false)

        store.resetToDefaults()

        #expect(store.tabAnimationsEnabled == true)
        #expect(store.tabSwitchEffect == .slide)
        #expect(store.tabOpenCloseEffect == .scaleFade)
        #expect(abs(store.tabMotionSpeed - 1.0) < 0.001)
        #expect(store.tabHapticsEnabled == true)
    }

    @Test("TabMotionProfile scales timing and honours Reduce Motion")
    @MainActor
    func testTabMotionProfileResolution() {
        let fast = TabMotionProfile(
            isEnabled: true,
            switchEffect: .slide,
            openCloseEffect: .scaleFade,
            speed: 2.0,
            reduceMotion: false
        )
        let slow = TabMotionProfile(
            isEnabled: true,
            switchEffect: .slide,
            openCloseEffect: .scaleFade,
            speed: 0.5,
            reduceMotion: false
        )
        let reduced = TabMotionProfile(
            isEnabled: true,
            switchEffect: .slide,
            openCloseEffect: .scaleFade,
            speed: 1.0,
            reduceMotion: true
        )
        let disabled = TabMotionProfile(
            isEnabled: false,
            switchEffect: .springPop,
            openCloseEffect: .slide,
            speed: 1.0,
            reduceMotion: false
        )

        #expect(fast.isMotionEnabled)
        #expect(fast.barDismissDelay < slow.barDismissDelay)
        #expect(fast.usesMorphingHighlight)
        #expect(!reduced.isMotionEnabled)
        #expect(reduced.barDismissDelay <= 0.021)
        #expect(!disabled.isMotionEnabled)
        #expect(!disabled.usesMorphingHighlight)
        #expect(disabled.barHiddenScale == 1)
        #expect(disabled.barHiddenOffset == 0)
        #expect(disabled.barHiddenBlur == 0)

        let materialize = TabMotionProfile(
            isEnabled: true,
            switchEffect: .crossfade,
            openCloseEffect: .materialize,
            speed: 1.0,
            reduceMotion: false
        )
        #expect(materialize.barHiddenScale < 1)
        #expect(materialize.barHiddenBlur > 0)
        #expect(!materialize.usesMorphingHighlight)
    }

    // MARK: - 11. Advanced Tab Grouping, Naming & Color Tests

    @Test("WindowColumn group naming, custom accent color, and collapse state")
    func testWindowColumnGroupCustomization() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        var col = WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed)
        
        #expect(col.customGroupName == nil)
        #expect(col.customColorHex == nil)
        #expect(!col.isCollapsed)
        
        col.customGroupName = "Research & Documentation"
        col.customColorHex = "#34C759"
        col.isCollapsed = true
        
        #expect(col.customGroupName == "Research & Documentation")
        #expect(col.customColorHex == "#34C759")
        #expect(col.isCollapsed)
    }

    @Test("WindowColumn custom tab titles override default titles and can be reset")
    func testWindowColumnCustomTabTitles() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        var col = WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed)
        
        #expect(col.effectiveTitle(for: w1, defaultTitle: "Google Chrome") == "Google Chrome")
        
        col.setCustomTitle("API Spec Editor", for: w1)
        #expect(col.effectiveTitle(for: w1, defaultTitle: "Google Chrome") == "API Spec Editor")
        #expect(col.effectiveTitle(for: w2, defaultTitle: "Terminal") == "Terminal")
        
        // Reset custom title
        col.setCustomTitle(nil, for: w1)
        #expect(col.effectiveTitle(for: w1, defaultTitle: "Google Chrome") == "Google Chrome")
    }

    @Test("WindowColumn tab locking prevents accidental closure in batch operations")
    func testWindowColumnTabLocking() {
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 10, rawId: 3)
        let w4 = WindowId(pid: 10, rawId: 4)
        var col = WindowColumn(windowIds: [w1, w2, w3, w4], presentationMode: .tabbed)
        
        #expect(!col.isLocked(w2))
        col.toggleLock(w2)
        #expect(col.isLocked(w2))
        
        // Close others except w1: w2 is locked, so w2 MUST be preserved!
        let removed = col.closeOtherWindows(except: w1)
        #expect(removed.contains(w3))
        #expect(removed.contains(w4))
        #expect(!removed.contains(w2)) // w2 was locked, protected!
        #expect(col.windowIds == [w1, w2])
    }

    @Test("LayoutEngine moveTabBetweenGroups transfers tabs seamlessly")
    func testLayoutEngineMoveTabBetweenGroups() {
        let le = LayoutEngine()
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        let w3 = WindowId(pid: 20, rawId: 3)
        let w4 = WindowId(pid: 20, rawId: 4)
        
        var columns = [
            WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed),
            WindowColumn(windowIds: [w3, w4], presentationMode: .tabbed)
        ]
        
        // Move w1 from column 0 to column 1 at index 1
        le.moveTabBetweenGroups(
            windowId: w1,
            fromColumnIndex: 0,
            toColumnIndex: 1,
            toIndex: 1,
            columns: &columns
        )
        
        #expect(columns[0].windowIds == [w2])
        #expect(columns[1].windowIds == [w3, w1, w4])
        #expect(columns[1].activeWindowId == w1)
    }

    @Test("LayoutPersistenceManager captures and restores extended tab group properties")
    @MainActor
    func testPersistenceExtendedTabGroupRoundTrip() {
        let persistence = LayoutPersistenceManager()
        let w1 = WindowId(pid: 10, rawId: 1)
        let w2 = WindowId(pid: 10, rawId: 2)
        
        let win1 = makeWindow(id: 1, pid: 10, bundleId: "com.apple.dt.Xcode", appName: "Xcode", title: "Project")
        let win2 = makeWindow(id: 2, pid: 10, bundleId: "com.apple.dt.Xcode", appName: "Xcode", title: "Tests")
        let windowMap = [w1: win1, w2: win2]
        
        var col = WindowColumn(windowIds: [w1, w2], presentationMode: .tabbed)
        col.customGroupName = "Compiler Dev"
        col.customColorHex = "#AF52DE"
        col.isCollapsed = true
        col.toggleLock(w1)
        col.setCustomTitle("Main Workspace", for: w1)
        
        let captured = persistence.captureSpaceLayout(
            columns: [col],
            windows: windowMap,
            focusedColumnIndex: 0,
            viewportOffset: 0
        )
        
        #expect(captured.columns.count == 1)
        #expect(captured.columns[0].customGroupName == "Compiler Dev")
        #expect(captured.columns[0].customColorHex == "#AF52DE")
        #expect(captured.columns[0].isCollapsed == true)
        #expect(captured.columns[0].lockedWindowIndices == [0])
        
        let restored = persistence.restoreSpaceLayout(
            savedLayout: captured,
            availableWindows: [win1, win2],
            visibleWidth: 1920
        )
        
        #expect(restored.restoredColumns.count == 1)
        let restoredCol = restored.restoredColumns[0]
        #expect(restoredCol.customGroupName == "Compiler Dev")
        #expect(restoredCol.customColorHex == "#AF52DE")
        #expect(restoredCol.isCollapsed == true)
        #expect(restoredCol.isLocked(w1))
        #expect(restoredCol.effectiveTitle(for: w1, defaultTitle: "Project") == "Main Workspace")
    }

    @Test("WorkspaceManager combineWindow transforms independent window into tab")
    @MainActor
    func testWorkspaceManagerCombineWindow() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let win1 = makeWindow(id: 101, pid: 501, bundleId: "com.google.Chrome", title: "Tab 1")
        let win2 = makeWindow(id: 102, pid: 501, bundleId: "com.google.Chrome", title: "Tab 2")
        
        wm.registry.register(window: win1)
        wm.registry.register(window: win2)
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        let col1 = WindowColumn(windowIds: [win1.id])
        let col2 = WindowColumn(windowIds: [win2.id])
        ws.columns = [col1, col2]
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Combine win2 into col1
        wm.combineWindow(win2.id, intoColumnWithId: col1.id)
        
        let updatedWs = wm.workspaces[disp.id]!
        #expect(updatedWs.columns.count == 1)
        #expect(updatedWs.columns[0].windowIds == [win1.id, win2.id])
        #expect(updatedWs.columns[0].presentationMode == .tabbed)
        #expect(updatedWs.columns[0].activeWindowId == win2.id)
    }

    @Test("WorkspaceManager tab selection by position and last tab")
    @MainActor
    func testWorkspaceManagerSelectTabByPosition() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let win1 = makeWindow(id: 101, pid: 501, bundleId: "com.google.Chrome", title: "Tab 1")
        let win2 = makeWindow(id: 102, pid: 501, bundleId: "com.google.Chrome", title: "Tab 2")
        let win3 = makeWindow(id: 103, pid: 501, bundleId: "com.google.Chrome", title: "Tab 3")
        
        wm.registry.register(window: win1)
        wm.registry.register(window: win2)
        wm.registry.register(window: win3)
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        var col = WindowColumn(windowIds: [win1.id, win2.id, win3.id], presentationMode: .tabbed)
        col.selectWindow(win1.id)
        ws.columns = [col]
        ws.focusedColumnIndex = 0
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Select tab position 2 (win2)
        wm.selectTabByPosition(2)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == win2.id)
        
        // Select last tab (win3)
        wm.selectLastTab()
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == win3.id)
        
        // Select tab position 1 (win1)
        wm.selectTabByPosition(1)
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == win1.id)
    }

    @Test("WorkspaceManager reorders active tab left and right")
    @MainActor
    func testWorkspaceManagerReorderActiveTab() {
        let wm = WorkspaceManager()
        let disp = makeDisplay()
        
        let win1 = makeWindow(id: 101, pid: 501, bundleId: "com.google.Chrome", title: "Tab 1")
        let win2 = makeWindow(id: 102, pid: 501, bundleId: "com.google.Chrome", title: "Tab 2")
        let win3 = makeWindow(id: 103, pid: 501, bundleId: "com.google.Chrome", title: "Tab 3")
        
        wm.registry.register(window: win1)
        wm.registry.register(window: win2)
        wm.registry.register(window: win3)
        
        var ws = DisplayWorkspace(displayGeometry: disp)
        var col = WindowColumn(windowIds: [win1.id, win2.id, win3.id], presentationMode: .tabbed)
        col.selectWindow(win2.id) // Active is win2 at index 1
        ws.columns = [col]
        ws.focusedColumnIndex = 0
        wm.setWorkspace(ws, for: disp.id)
        wm.setActiveDisplayId(disp.id)
        
        // Reorder right: win2 moves from index 1 to index 2
        wm.reorderActiveTabInFocusedColumn(direction: 1)
        #expect(wm.workspaces[disp.id]!.columns[0].windowIds == [win1.id, win3.id, win2.id])
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == win2.id)
        
        // Reorder left: win2 moves from index 2 to index 1
        wm.reorderActiveTabInFocusedColumn(direction: -1)
        #expect(wm.workspaces[disp.id]!.columns[0].windowIds == [win1.id, win2.id, win3.id])
        #expect(wm.workspaces[disp.id]!.columns[0].activeWindowId == win2.id)
    }
}
