import Testing
import CoreGraphics
import Foundation
@testable import IumeCore

@Suite("Window Registry Tests")
struct WindowRegistryTests {
    @Test("Register and retrieve managed window")
    func testRegisterAndRetrieve() {
        let registry = WindowRegistry()
        let winId = WindowId(pid: 1234, rawId: 5678)
        let window = ManagedWindow(
            id: winId,
            pid: 1234,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Apple News",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        registry.register(window: window)
        #expect(registry.get(windowId: winId) != nil)
        #expect(registry.get(windowId: winId)?.title == "Apple News")
        #expect(registry.windows(forPid: 1234).count == 1)
        
        // Mutate
        registry.update(windowId: winId) { win in
            win.title = "Updated Title"
        }
        #expect(registry.get(windowId: winId)?.title == "Updated Title")
        
        // Unregister
        registry.unregister(windowId: winId)
        #expect(registry.get(windowId: winId) == nil)
        #expect(registry.windows(forPid: 1234).isEmpty)
    }
    
    @Test("Focus tracking updates isFocused property")
    func testFocusTracking() {
        let registry = WindowRegistry()
        let id1 = WindowId(pid: 1, rawId: 1)
        let id2 = WindowId(pid: 1, rawId: 2)
        
        let win1 = ManagedWindow(id: id1, pid: 1, bundleIdentifier: "app", appName: "App", title: "W1", frame: .zero)
        let win2 = ManagedWindow(id: id2, pid: 1, bundleIdentifier: "app", appName: "App", title: "W2", frame: .zero)
        
        registry.register(window: win1)
        registry.register(window: win2)
        
        registry.focusedId = id1
        #expect(registry.get(windowId: id1)?.isFocused == true)
        #expect(registry.get(windowId: id2)?.isFocused == false)
        
        registry.focusedId = id2
        #expect(registry.get(windowId: id1)?.isFocused == false)
        #expect(registry.get(windowId: id2)?.isFocused == true)
    }
}

@Suite("Focus Manager Tests")
@MainActor
struct FocusManagerTests {
    @Test("Directional horizontal navigation")
    func testHorizontalFocusNavigation() {
        let focusManager = FocusManager()
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let win3 = WindowId(pid: 1, rawId: 3)
        let cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 400),
            WindowColumn(windowIds: [win3], width: 400)
        ]
        
        var selectedWin: WindowId?
        var selectedCol: Int?
        focusManager.onFocusRequested = { winId, colIdx in
            selectedWin = winId
            selectedCol = colIdx
        }
        
        // From column 0, focus right -> column 1
        focusManager.focusRight(columns: cols, currentColumnIndex: 0)
        #expect(selectedWin == win2)
        #expect(selectedCol == 1)
        
        // From column 2, focus right -> stays at column 2
        focusManager.focusRight(columns: cols, currentColumnIndex: 2)
        #expect(selectedWin == win3)
        #expect(selectedCol == 2)
        
        // From column 1, focus left -> column 0
        focusManager.focusLeft(columns: cols, currentColumnIndex: 1)
        #expect(selectedWin == win1)
        #expect(selectedCol == 0)
        
        // Jump to last
        focusManager.focusLast(columns: cols)
        #expect(selectedWin == win3)
        #expect(selectedCol == 2)
        
        // Jump to first
        focusManager.focusFirst(columns: cols)
        #expect(selectedWin == win1)
        #expect(selectedCol == 0)
    }
    
    @Test("Cycle windows forward and backward")
    func testCycleWindows() {
        let focusManager = FocusManager()
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1], width: 400),
            WindowColumn(windowIds: [win2], width: 400)
        ]
        
        var targetWin: WindowId?
        focusManager.onFocusRequested = { win, _ in targetWin = win }
        
        focusManager.cycleWindows(columns: cols, currentWindowId: win1, forward: true)
        #expect(targetWin == win2)
        
        focusManager.cycleWindows(columns: cols, currentWindowId: win2, forward: true)
        #expect(targetWin == win1) // wraps around
        
        focusManager.cycleWindows(columns: cols, currentWindowId: win1, forward: false)
        #expect(targetWin == win2) // backwards wrap
    }
}

@Suite("Diagnostics Tests")
struct DiagnosticsTests {
    @Test("Logging and report generation")
    func testDiagnostics() {
        let diag = Diagnostics()
        diag.log(level: "INFO", category: "Test", message: "Starting integration test")
        diag.recordNotification()
        diag.updateMetrics(windows: 5, columns: 4)
        
        let report = diag.exportDiagnosticReport()
        #expect(report.contains("Managed Windows: 5"))
        #expect(report.contains("Active Columns: 4"))
        #expect(report.contains("Total Notifications Handled: 1"))
        #expect(report.contains("Starting integration test"))
    }
}

@Suite("SettingsStore Tests")
@MainActor
struct SettingsStoreTests {
    @Test("Defaults reset and serialization")
    func testSettingsDefaults() {
        let store = SettingsStore()
        store.windowGap = 35.0
        store.layoutMode = .centeredFocus
        
        #expect(store.windowGap == 35.0)
        #expect(store.layoutMode == .centeredFocus)
        
        store.resetToDefaults()
        #expect(store.windowGap == 12.0)
        #expect(store.layoutMode == .scrollStrip)
        #expect(store.isEnabled == true)
    }
}

@Suite("Observer & Reconciliation Tests")
@MainActor
struct ObserverAndReconciliationTests {
    @Test("Intent suppression distinguishes self-originated frame updates from user moves")
    func testIntentSuppression() {
        let observer = WindowObserver()
        let winId = WindowId(pid: 999, rawId: 100)
        let targetFrame = CGRect(x: 100, y: 50, width: 800, height: 600)
        
        observer.recordExpectedFrame(targetFrame, for: winId, duration: 1.0)
        
        // Exact match
        #expect(observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: targetFrame))
        
        // Within 2 pt tolerance
        let slightDrift = CGRect(x: 101, y: 51, width: 800, height: 600)
        #expect(observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: slightDrift))
        
        // Manual user drag (e.g. 80 pt difference)
        let userMoved = CGRect(x: 250, y: 50, width: 800, height: 600)
        #expect(!observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: userMoved))
    }
    
    @Test("Manual window resize reconciliation updates column width and preserves it")
    func testManualResizeReconciliation() {
        let workspaceManager = WorkspaceManager()
        let winId = WindowId(pid: 42, rawId: 1)
        let initialFrame = CGRect(x: 0, y: 0, width: 600, height: 700)
        let window = ManagedWindow(
            id: winId,
            pid: 42,
            bundleIdentifier: "com.test.app",
            appName: "TestApp",
            title: "Test Window",
            frame: initialFrame
        )
        
        workspaceManager.registry.register(window: window)
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
                columns: [WindowColumn(windowIds: [winId], width: 600)],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: 1
        )
        workspaceManager.setActiveDisplayId(1)
        
        // User manually dragged right window border expanding width to 950 pt
        let resizedFrame = CGRect(x: 0, y: 25, width: 950, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: winId, newFrame: resizedFrame)
        
        #expect(workspaceManager.registry.get(windowId: winId)?.preferredWidth == 950)
        #expect(workspaceManager.workspaces[1]?.columns.first?.width == 950)
    }
}

@Suite("Scroll Controller & 2-Finger Gestures Tests")
@MainActor
struct ScrollControllerTests {
    @Test("Seamless 2-finger horizontal scroll detection")
    func testHorizontalIntentDetection() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        settings.scrollTriggerMode = .seamlessHorizontal
        
        // Horizontal swipe (two fingers left/right) -> should intercept and consume
        let horizontal = scrollController.shouldInterceptScroll(dx: -28.0, dy: 4.0, flags: [])
        #expect(horizontal == true)
        
        // Vertical swipe (scrolling document inside app) -> should NOT intercept, pass through
        let vertical = scrollController.shouldInterceptScroll(dx: 3.0, dy: -45.0, flags: [])
        #expect(vertical == false)
        
        // Vertical swipe WITH Option key held -> should intercept
        let optVertical = scrollController.shouldInterceptScroll(dx: 0.0, dy: -20.0, flags: [.maskAlternate])
        #expect(optVertical == true)
    }
    
    @Test("Option modifier mode respects user configuration")
    func testOptionModifierMode() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        settings.scrollTriggerMode = .withOption
        
        // Plain swipe without Option -> false
        let plain = scrollController.shouldInterceptScroll(dx: -50.0, dy: 0.0, flags: [])
        #expect(plain == false)
        
        // With Option -> true
        let withOpt = scrollController.shouldInterceptScroll(dx: -50.0, dy: 0.0, flags: [.maskAlternate])
        #expect(withOpt == true)
        
        // Restore default
        settings.scrollTriggerMode = .seamlessHorizontal
    }
    
    @Test("Direct and continuous offset clamping")
    func testOffsetClamping() {
        let scrollController = ScrollController()
        scrollController.setOffset(500, maxOffset: 1200)
        #expect(scrollController.currentOffset == 500)
        
        // Exceeding maxOffset clamped in direct setOffset
        scrollController.setOffset(1500, maxOffset: 1200)
        #expect(scrollController.currentOffset == 1200)
        
        // Negative offset clamped to 0
        scrollController.setOffset(-200, maxOffset: 1200)
        #expect(scrollController.currentOffset == 0)
    }
}

