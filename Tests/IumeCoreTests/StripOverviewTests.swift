import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import IumeCore

@Suite("Strip Overview & Panoramic Preview Tests")
struct StripOverviewTests {
    
    @Test("WindowPreviewCapturer generates valid preview data and clamps aspect ratio")
    @MainActor
    func testWindowPreviewCapturer() {
        let winId = WindowId(pid: 1234, rawId: 5678)
        let window = ManagedWindow(
            id: winId,
            pid: 1234,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "GitHub — Iume",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        
        let colId = UUID()
        let preview = WindowPreviewCapturer.capturePreview(
            for: window,
            cgWindowId: nil,
            columnId: colId,
            stackedCount: 2
        )
        
        #expect(preview.id == winId)
        #expect(preview.columnId == colId)
        #expect(preview.title == "GitHub — Iume")
        #expect(preview.stackedCount == 2)
        #expect(abs(preview.aspectRatio - 1.5) < 0.01)
    }
    
    @Test("StripOverviewController reorders columns locally and updates focus index")
    @MainActor
    func testStripOverviewControllerLocalReorder() {
        let controller = StripOverviewController.shared
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        
        controller.columns = [
            OverviewColumnData(id: id1, columnWidth: 500, windowCount: 1),
            OverviewColumnData(id: id2, columnWidth: 600, windowCount: 1),
            OverviewColumnData(id: id3, columnWidth: 700, windowCount: 1)
        ]
        controller.focusedColumnIndex = 0
        
        // Move column 0 to index 2
        controller.reorderColumnLocally(from: 0, to: 2)
        
        #expect(controller.columns.count == 3)
        #expect(controller.columns[0].id == id2)
        #expect(controller.columns[1].id == id3)
        #expect(controller.columns[2].id == id1)
        #expect(controller.focusedColumnIndex == 2)
    }
    
    @Test("WorkspaceManager reorderColumns updates workspace columns order")
    @MainActor
    func testWorkspaceManagerReorderColumns() {
        let wm = WorkspaceManager.shared
        let dispId: CGDirectDisplayID = 1
        wm.setActiveDisplayId(dispId)
        
        let col1 = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 100, rawId: 1)], width: 400)
        let col2 = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 200, rawId: 2)], width: 500)
        
        let display = DisplayGeometry(
            id: dispId,
            name: "Main Display",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            isPrimary: true
        )
        wm.setWorkspace(
            DisplayWorkspace(
                displayGeometry: display,
                columns: [col1, col2],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: dispId
        )
        
        // Reorder columns
        wm.reorderColumns(newColumns: [col2, col1])
        
        let updatedWs = wm.workspaces[dispId]
        #expect(updatedWs?.columns.count == 2)
        #expect(updatedWs?.columns[0].id == col2.id)
        #expect(updatedWs?.columns[1].id == col1.id)
    }
    
    @Test("ShortcutAction enum contains toggleOverview")
    func testShortcutActionContainsToggleOverview() {
        let actions = ShortcutAction.allCases
        #expect(actions.contains(.toggleOverview))
        #expect(ShortcutAction.toggleOverview.rawValue == "Toggle Strip Overview")
    }
}
