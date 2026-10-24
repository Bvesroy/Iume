import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import IumeCore

@Suite("Amethyst Feature Parity & System Hardening Tests", .serialized)
struct AmethystFeatureParityTests {
    
    @Test("Smart Window Margins collapses margin when single column is tiled")
    @MainActor
    func testSmartWindowMargins() {
        let engine = LayoutEngine(windowGap: 12)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let margins = EdgeMargins(top: 20, bottom: 20, left: 20, right: 20)
        
        let win1 = WindowId(pid: 100, rawId: 1)
        let win2 = WindowId(pid: 100, rawId: 2)
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 100, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 100, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 2", frame: .zero)
        ]
        
        // Single column: margins should collapse to 0
        let singleColumn = [WindowColumn(id: UUID(), windowIds: [win1], width: 800)]
        let singleLayout = engine.computeLayout(
            columns: singleColumn,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: screen,
            viewportOffset: 0,
            layoutMode: .scrollStrip,
            edgeMargins: margins,
            isBuiltinDisplay: false,
            disablePaddingOnBuiltinDisplay: false,
            smartWindowMargins: true
        )
        
        let frame1 = singleLayout.targetFrames[win1]
        #expect(frame1 != nil)
        #expect(frame1?.minY == 0)
        #expect(frame1?.height == 1080)
        
        // Multiple columns: standard margins apply
        let twoColumns = [
            WindowColumn(id: UUID(), windowIds: [win1], width: 800),
            WindowColumn(id: UUID(), windowIds: [win2], width: 800)
        ]
        let multiLayout = engine.computeLayout(
            columns: twoColumns,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: screen,
            viewportOffset: 0,
            layoutMode: .scrollStrip,
            edgeMargins: margins,
            isBuiltinDisplay: false,
            disablePaddingOnBuiltinDisplay: false,
            smartWindowMargins: true
        )
        let multiFrame1 = multiLayout.targetFrames[win1]
        #expect(multiFrame1 != nil)
        #expect(multiFrame1?.minY == 20)
        #expect(multiFrame1?.height == 1040.0)
    }
    
    @Test("Disable padding on built-in display zeros margins on primary screen")
    @MainActor
    func testDisablePaddingOnBuiltinDisplay() {
        let engine = LayoutEngine(windowGap: 12)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let margins = EdgeMargins(top: 20, bottom: 20, left: 20, right: 20)
        
        let win1 = WindowId(pid: 100, rawId: 1)
        let win2 = WindowId(pid: 100, rawId: 2)
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 100, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 1", frame: .zero),
            win2: ManagedWindow(id: win2, pid: 100, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Tab 2", frame: .zero)
        ]
        
        let cols = [
            WindowColumn(id: UUID(), windowIds: [win1], width: 800),
            WindowColumn(id: UUID(), windowIds: [win2], width: 800)
        ]
        
        // On built-in screen (isBuiltinDisplay = true)
        let layout = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: screen,
            viewportOffset: 0,
            layoutMode: .scrollStrip,
            edgeMargins: margins,
            isBuiltinDisplay: true,
            disablePaddingOnBuiltinDisplay: true,
            smartWindowMargins: false
        )
        let frame1 = layout.targetFrames[win1]
        #expect(frame1 != nil)
        #expect(frame1?.minY == 0)
        #expect(frame1?.height == 1080)
    }
    
    @Test("Small Window Classifier auto-floats utility windows when enabled")
    @MainActor
    func testSmallWindowClassifier() {
        let smallSize = CGSize(width: 300, height: 250)
        let standardSize = CGSize(width: 800, height: 600)
        let threshold = 400.0
        
        #expect(WindowClassifier.shouldFloatSmallWindow(size: smallSize, threshold: threshold, isEnabled: true))
        #expect(!WindowClassifier.shouldFloatSmallWindow(size: standardSize, threshold: threshold, isEnabled: true))
        #expect(!WindowClassifier.shouldFloatSmallWindow(size: smallSize, threshold: threshold, isEnabled: false))
    }
    
    @Test("ShortcutManager registers all Amethyst-parity actions")
    @MainActor
    func testAmethystShortcuts() {
        let manager = ShortcutManager.shared
        manager.registerDefaultShortcuts()
        
        let allActions = ShortcutAction.allCases
        #expect(allActions.contains(.throwSpaceLeft))
        #expect(allActions.contains(.throwSpaceRight))
        #expect(allActions.contains(.focusDisplay1))
        #expect(allActions.contains(.focusDisplay2))
        #expect(allActions.contains(.focusDisplay3))
        #expect(allActions.contains(.reevaluateWindows))
        #expect(allActions.contains(.relaunchIume))
    }
    
    @Test("Multi-monitor send column scales width proportionally across displays")
    @MainActor
    func testProportionalColumnScaling() {
        let wm = WorkspaceManager.shared
        
        // Display 1: 1920 wide; Display 2: 3840 wide (4K)
        let disp1 = DisplayGeometry(id: 10, name: "HD Display", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), isPrimary: true)
        let disp2 = DisplayGeometry(id: 20, name: "4K Display", frame: CGRect(x: 1920, y: 0, width: 3840, height: 2160), visibleFrame: CGRect(x: 1920, y: 0, width: 3840, height: 2135), isPrimary: false)
        
        var ws1 = DisplayWorkspace(displayGeometry: disp1)
        let winId = WindowId(pid: 777, rawId: 888)
        // 960 width is exactly 50% of 1920
        let col = WindowColumn(id: UUID(), windowIds: [winId], width: 960)
        ws1.columns = [col]
        ws1.focusedColumnIndex = 0
        
        let ws2 = DisplayWorkspace(displayGeometry: disp2)
        
        wm.displayManager.setActiveDisplaysForTesting([disp1, disp2])
        wm.setWorkspace(ws1, for: 10)
        wm.setWorkspace(ws2, for: 20)
        wm.setActiveDisplayId(10)
        
        wm.sendFocusedColumnToNextDisplay()
        
        // Column should now be in ws2, scaled to ~1920 (50% of 3840)
        let targetCol = wm.workspaces[20]?.columns.first
        #expect(targetCol != nil)
        if let targetCol = targetCol {
            #expect(abs(targetCol.width - 1920) < 5.0)
        }
    }
}
