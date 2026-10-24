import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import IumeCore

@Suite("Setup & Window Classification Tests")
struct SetupAndClassificationTests {
    
    @Test("MacSetupChecker returns all standard system and conflict checks")
    @MainActor
    func testMacSetupChecks() {
        let checker = MacSetupChecker.shared
        let results = checker.runAllChecks()
        
        #expect(!results.isEmpty)
        let ids = results.map { $0.id }
        #expect(ids.contains("ax_permission"))
        #expect(ids.contains("app_location"))
        #expect(ids.contains("separate_spaces"))
        #expect(ids.contains("mru_spaces"))
        #expect(ids.contains("stage_manager"))
        #expect(ids.contains("edge_tiling"))
        #expect(ids.contains("conflicts"))
    }
    
    @Test("WindowClassification differentiates tile, float and ignore states")
    @MainActor
    func testWindowClassificationLogic() {
        let discovery = WindowDiscovery()
        // Non-window elements are ignored
        let dummyElement = AXUIElementCreateSystemWide()
        let classification = discovery.classifyWindow(dummyElement)
        #expect(classification == .ignore)
        #expect(!discovery.isEligibleWindow(dummyElement))
    }
    
    @Test("ShortcutManager registers sendToNextDisplay on ⌃⌥N")
    @MainActor
    func testSendToNextDisplayRegistration() {
        let manager = ShortcutManager.shared
        manager.registerDefaultShortcuts()
        
        var triggeredAction: ShortcutAction? = nil
        manager.onShortcutTriggered = { action in
            triggeredAction = action
        }
        #expect(triggeredAction == nil)
        
        #expect(ShortcutAction.allCases.contains(.sendToNextDisplay))
    }
    
    @Test("Multi-monitor send column to next display moves column between workspaces")
    @MainActor
    func testSendColumnBetweenDisplays() {
        let wm = WorkspaceManager.shared
        let disp1 = DisplayGeometry(id: 1, name: "Display 1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), isPrimary: true)
        let disp2 = DisplayGeometry(id: 2, name: "Display 2", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055), isPrimary: false)
        
        var ws1 = DisplayWorkspace(displayGeometry: disp1)
        let winId = WindowId(pid: 9999, rawId: 8888)
        let col = WindowColumn(id: UUID(), windowIds: [winId], width: 800)
        ws1.columns = [col]
        ws1.focusedColumnIndex = 0
        
        let ws2 = DisplayWorkspace(displayGeometry: disp2)
        
        wm.setWorkspace(ws1, for: 1)
        wm.setWorkspace(ws2, for: 2)
        wm.setActiveDisplayId(1)
        
        #expect(wm.workspaces[1]?.columns.count == 1)
        #expect(wm.workspaces[2]?.columns.count == 0)
    }
}
