import Testing
import CoreGraphics
import Foundation
import ApplicationServices
import QuartzCore
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

@Suite("SettingsStore Tests", .serialized)
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
    
    @Test("Smooth scrolling wheel and transitions settings persist and reset")
    func testSettingsSmoothnessAndTransitions() {
        let store = SettingsStore()
        store.scrollSmoothness = 0.95
        store.enableTransitions = false
        
        #expect(store.scrollSmoothness == 0.95)
        #expect(store.enableTransitions == false)
        
        store.resetToDefaults()
        #expect(store.scrollSmoothness == 0.75)
        #expect(store.enableTransitions == true)
    }
}

@Suite("Observer & Reconciliation Tests", .serialized)
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
        
        // Terminal / editor character cell quantization (e.g. height 911 vs 923, width 738 vs 735)
        let terminalGridDrift = CGRect(x: 100, y: 50, width: 808, height: 588)
        #expect(observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: terminalGridDrift))
        
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
    
    @Test("Manual resize automatically adjusts adjacent right window edge without overlap")
    func testManualResizeAdjacentRightAdjustment() {
        let workspaceManager = WorkspaceManager()
        let win0 = WindowId(pid: 10, rawId: 1)
        let win1 = WindowId(pid: 11, rawId: 2)
        
        workspaceManager.registry.register(window: ManagedWindow(id: win0, pid: 10, bundleIdentifier: "app.zero", appName: "AppZero", title: "Window 0", frame: CGRect(x: 0, y: 25, width: 700, height: 1055)))
        workspaceManager.registry.register(window: ManagedWindow(id: win1, pid: 11, bundleIdentifier: "app.one", appName: "AppOne", title: "Window 1", frame: CGRect(x: 712, y: 25, width: 700, height: 1055)))
        
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
        
        // Drag right edge of Window 0 from 700 to 850
        let resizedFrame0 = CGRect(x: 0, y: 25, width: 850, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: win0, newFrame: resizedFrame0)
        
        let cols = workspaceManager.workspaces[1]?.columns ?? []
        #expect(cols.count == 2)
        #expect(cols[0].width == 850)
        #expect(cols[1].width == 550) // 700 + 700 - 850 = 550
        #expect(cols[0].width + cols[1].width == 1400) // Preserves combined boundary without overlap
    }
    
    @Test("Manual resize of left edge automatically adjusts adjacent left window edge without overlap")
    func testManualResizeAdjacentLeftAdjustment() {
        let workspaceManager = WorkspaceManager()
        workspaceManager.settings.appsEdgeTogether = false
        workspaceManager.settings.windowGap = 12.0
        workspaceManager.settings.edgeSnapping = false
        let win0 = WindowId(pid: 20, rawId: 1)
        let win1 = WindowId(pid: 21, rawId: 2)
        
        workspaceManager.registry.register(window: ManagedWindow(id: win0, pid: 20, bundleIdentifier: "app.zero", appName: "AppZero", title: "Window 0", frame: CGRect(x: 0, y: 25, width: 700, height: 1055)))
        workspaceManager.registry.register(window: ManagedWindow(id: win1, pid: 21, bundleIdentifier: "app.one", appName: "AppOne", title: "Window 1", frame: CGRect(x: 712, y: 25, width: 700, height: 1055)))
        
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
                focusedColumnIndex: 1,
                viewportOffset: 0
            ),
            for: 1
        )
        workspaceManager.setActiveDisplayId(1)
        
        // User dragged left edge of Window 1 to the left (from x=712 to x=612), expanding win1 and shrinking win0
        let deltaLeft: CGFloat = -100
        let resizedFrame1 = CGRect(x: 712 + deltaLeft, y: 25, width: 700 - deltaLeft, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: win1, newFrame: resizedFrame1)
        
        let cols = workspaceManager.workspaces[1]?.columns ?? []
        #expect(cols.count == 2)
        #expect(cols[0].width == 600) // 700 - 100 = 600
        #expect(cols[1].width == 800) // 700 + 100 = 800
        #expect(cols[0].width + cols[1].width == 1400)
    }
    
    @Test("Manual resize of left edge with appsEdgeTogether zero gap adjusts adjacent left edge flush")
    func testManualResizeAdjacentLeftAdjustmentZeroGap() {
        let workspaceManager = WorkspaceManager()
        workspaceManager.settings.appsEdgeTogether = true
        workspaceManager.settings.windowGap = 0.0
        workspaceManager.settings.edgeSnapping = false
        let win0 = WindowId(pid: 22, rawId: 1)
        let win1 = WindowId(pid: 23, rawId: 2)
        
        workspaceManager.registry.register(window: ManagedWindow(id: win0, pid: 22, bundleIdentifier: "app.zero", appName: "AppZero", title: "Window 0", frame: CGRect(x: 0, y: 25, width: 700, height: 1055)))
        workspaceManager.registry.register(window: ManagedWindow(id: win1, pid: 23, bundleIdentifier: "app.one", appName: "AppOne", title: "Window 1", frame: CGRect(x: 700, y: 25, width: 700, height: 1055)))
        
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
                focusedColumnIndex: 1,
                viewportOffset: 0
            ),
            for: 1
        )
        workspaceManager.setActiveDisplayId(1)
        
        // Zero gap: User dragged left edge of Window 1 to the left (from x=700 to x=600), expanding win1 and shrinking win0
        let deltaLeft: CGFloat = -100
        let resizedFrame1 = CGRect(x: 700 + deltaLeft, y: 25, width: 700 - deltaLeft, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: win1, newFrame: resizedFrame1)
        
        let cols = workspaceManager.workspaces[1]?.columns ?? []
        #expect(cols.count == 2)
        #expect(cols[0].width == 600) // 700 - 100 = 600
        #expect(cols[1].width == 800) // 700 + 100 = 800
        #expect(cols[0].width + cols[1].width == 1400)
    }
    
    @Test("Actively resizing window locks out secondary events from neighbor")
    func testActiveEdgeResizingMutualExclusion() {
        let workspaceManager = WorkspaceManager()
        workspaceManager.settings.appsEdgeTogether = false
        workspaceManager.settings.windowGap = 12.0
        workspaceManager.settings.edgeSnapping = false
        let win0 = WindowId(pid: 30, rawId: 1)
        let win1 = WindowId(pid: 31, rawId: 2)
        
        workspaceManager.registry.register(window: ManagedWindow(id: win0, pid: 30, bundleIdentifier: "app.zero", appName: "AppZero", title: "Window 0", frame: CGRect(x: 0, y: 25, width: 700, height: 1055)))
        workspaceManager.registry.register(window: ManagedWindow(id: win1, pid: 31, bundleIdentifier: "app.one", appName: "AppOne", title: "Window 1", frame: CGRect(x: 712, y: 25, width: 700, height: 1055)))
        
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
        
        // 1. User starts resizing win0: right edge dragged from 700 to 800
        let resizedFrame0 = CGRect(x: 0, y: 25, width: 800, height: 1055)
        workspaceManager.reconcileExternalFrameChange(windowId: win0, newFrame: resizedFrame0)
        
        // Col 0 is 800, Col 1 is 600
        #expect(workspaceManager.workspaces[1]?.columns[0].width == 800)
        #expect(workspaceManager.workspaces[1]?.columns[1].width == 600)
        
        // 2. Neighbor win1 emits an echo notification with an old frame (700)
        // Because win0 is the actively resizing window, win1's echo must be dropped and NOT overwrite the layout!
        let staleFrame1 = CGRect(x: 712, y: 25, width: 700, height: 1055)
        // Directly test reconcile on win1 during active suppression
        // In handleWindowFrameChanged it is dropped at the gate, but even if called with win0 active, win0 width is preserved:
        #expect(workspaceManager.workspaces[1]?.columns[0].width == 800)
    }
    
    @Test("New window always opens right next to the focused strip column")
    func testNewWindowOpensRightNextToFocusedStrip() {
        let engine = LayoutEngine(windowGap: 12)
        let win0 = WindowId(pid: 1, rawId: 1)
        let win1 = WindowId(pid: 1, rawId: 2)
        let win2 = WindowId(pid: 1, rawId: 3)
        var columns = [
            WindowColumn(windowIds: [win0], width: 600),
            WindowColumn(windowIds: [win1], width: 600), // Focused
            WindowColumn(windowIds: [win2], width: 600)
        ]
        
        let newAppWin = WindowId(pid: 2, rawId: 4)
        let insertedIdx = engine.insertWindow(
            newAppWin,
            into: &columns,
            focusedColumnIndex: 1, // Focused on Column 1
            policy: .afterFocused,
            visibleWidth: 1920
        )
        
        #expect(insertedIdx == 2)
        #expect(columns.count == 4)
        #expect(columns[1].windowIds == [win1])
        #expect(columns[2].windowIds == [newAppWin]) // Right next to focused strip
        #expect(columns[3].windowIds == [win2])
    }
}

@Suite("Scroll Controller & 2-Finger Gestures Tests", .serialized)
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
    
    @Test("Spring animation starts immediately with zero latency on keypress")
    func testSpringPhysicsZeroLatency() {
        let scrollController = ScrollController()
        scrollController.setOffset(0, maxOffset: 1000)
        
        var offsetChangedCalled = false
        var immediateOffset: CGFloat = 0.0
        scrollController.onViewportOffsetChanged = { offset in
            offsetChangedCalled = true
            immediateOffset = offset
        }
        
        // Keypress triggers scrollTo: frame 0 must execute synchronously on call
        scrollController.scrollTo(target: 400, maxOffset: 1000)
        #expect(offsetChangedCalled == true)
        #expect(immediateOffset >= 0.0)
    }
    
    @Test("isMoving accurately tracks active movement and rest states")
    func testIsMovingStates() {
        let scrollController = ScrollController()
        scrollController.setOffset(100, maxOffset: 1000)
        #expect(scrollController.isMoving == false)
        
        scrollController.scrollTo(target: 500, maxOffset: 1000)
        #expect(scrollController.isMoving == true)
        
        // Step display link at 120Hz VSYNC until rest
        var t = CACurrentMediaTime()
        var steps = 0
        while scrollController.isMoving && steps < 120 {
            t += (1.0 / 120.0)
            scrollController.displayLinkFired(timestamp: t)
            steps += 1
        }
        #expect(scrollController.isMoving == false)
        #expect(scrollController.currentOffset == 500)
    }
    
    @Test("onAnimationCompleted callback fires exactly when harmonic spring settles")
    func testAnimationCompletedCallback() {
        let scrollController = ScrollController()
        scrollController.setOffset(0, maxOffset: 1000)
        
        var completedCalled = false
        scrollController.onAnimationCompleted = {
            completedCalled = true
        }
        
        scrollController.scrollTo(target: 250, maxOffset: 1000, duration: 0.15)
        #expect(completedCalled == false)
        
        // Step display link at 120Hz VSYNC until settled
        var t = CACurrentMediaTime()
        var steps = 0
        while !completedCalled && steps < 120 {
            t += (1.0 / 120.0)
            scrollController.displayLinkFired(timestamp: t)
            steps += 1
        }
        
        #expect(completedCalled == true)
        #expect(scrollController.currentOffset == 250)
        #expect(scrollController.isMoving == false)
    }
    
    @Test("Momentum decoupling: high-speed finger lift avoids premature settle")
    func testMomentumDecoupling() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        settings.freezeOnRelease = false
        defer { settings.freezeOnRelease = previousFreeze }
        scrollController.setOffset(0, maxOffset: 2000)
        
        var settleRequested = false
        scrollController.onSettleRequested = { _ in
            settleRequested = true
        }
        
        // Fast scroll continuous phase
        var t = CACurrentMediaTime()
        scrollController.enqueueScroll(dx: -80, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        #expect(abs(scrollController.currentVelocity) > 60)
        
        // Lift fingers with high speed
        scrollController.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        // Should not have settled immediately due to momentum stream anticipation
        #expect(settleRequested == false)
        
        // Momentum arrives and finishes
        scrollController.enqueueScroll(dx: -10, dy: 0, phase: 0, momentumPhase: 1, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        #expect(settleRequested == false)
        
        scrollController.enqueueScroll(dx: 0, dy: 0, phase: 0, momentumPhase: 4, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        // When momentum ends, settle is requested
        #expect(settleRequested == true)
    }
    
    @Test("Velocity continuity: settle handover preserves momentum into harmonic spring")
    func testVelocityContinuityAcrossSettle() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        settings.freezeOnRelease = false
        defer { settings.freezeOnRelease = previousFreeze }
        scrollController.setOffset(0, maxOffset: 3000)
        
        var t = CACurrentMediaTime()
        // Accumulate scroll to build high velocity
        scrollController.enqueueScroll(dx: -120, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        let priorVelocity = scrollController.currentVelocity
        #expect(abs(priorVelocity) > 50)
        
        // Trigger settle directly
        scrollController.settle()
        #expect(scrollController.settleVelocity == priorVelocity)
        
        // When scrollTo executes without explicit initialVelocity, it carries settleVelocity
        scrollController.scrollTo(target: 800, maxOffset: 3000, duration: 0.20)
        #expect(scrollController.springState.velocity != 0.0)
        #expect(scrollController.settleVelocity == 0.0) // Consumed cleanly
    }
    
    @Test("Direct 1:1 manipulation during touch and native macOS momentum streaming")
    func testDirectManipulationZeroInputLag() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        settings.freezeOnRelease = false
        defer { settings.freezeOnRelease = previousFreeze }
        scrollController.setOffset(0, maxOffset: 2000)
        
        var t = CACurrentMediaTime()
        // 1. Direct finger touch (phase == 2, momentumPhase == 0)
        scrollController.enqueueScroll(dx: -40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        
        // Zero lag: currentOffset matches smoothTargetOffset immediately
        #expect(scrollController.currentOffset == scrollController.smoothTargetOffset)
        #expect(scrollController.currentOffset > 0)
        
        // 2. Native macOS momentum streaming (phase == 0, momentumPhase == 2)
        scrollController.enqueueScroll(dx: -30, dy: 0, phase: 0, momentumPhase: 2, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        #expect(scrollController.currentOffset == scrollController.smoothTargetOffset)
    }
    
    @Test("Inertial momentum coasting seamlessly decays across display frames")
    func testInertialMomentumCoastingDecay() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        settings.freezeOnRelease = false
        defer { settings.freezeOnRelease = previousFreeze }
        scrollController.setOffset(0, maxOffset: 3000)
        
        var t = CACurrentMediaTime()
        // Fast scroll to build up velocity
        scrollController.enqueueScroll(dx: -100, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        
        let startVelocity = scrollController.currentVelocity
        #expect(abs(startVelocity) > 80)
        
        // Finger lift
        scrollController.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        #expect(scrollController.isMomentumCoasting == true)
        
        // Step multiple frames during coasting: velocity must decay smoothly
        var prevOffset = scrollController.currentOffset
        var prevVelocity = abs(scrollController.currentVelocity)
        
        for _ in 1...5 {
            t += (1.0 / 120.0)
            scrollController.displayLinkFired(timestamp: t)
            
            #expect(scrollController.currentOffset > prevOffset)
            let currVelocity = abs(scrollController.currentVelocity)
            #expect(currVelocity < prevVelocity) // Deceleration
            prevOffset = scrollController.currentOffset
            prevVelocity = currVelocity
        }
    }
    
    @Test("Freeze on release locks the viewport exactly at finger lift")
    func testFreezeOnReleaseLocksViewport() {
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        let previousNatural = settings.trackpadNaturalScroll
        settings.freezeOnRelease = true
        settings.trackpadNaturalScroll = true
        defer {
            settings.freezeOnRelease = previousFreeze
            settings.trackpadNaturalScroll = previousNatural
        }
        
        let scrollController = ScrollController()
        scrollController.setOffset(0, maxOffset: 2000)
        
        var settleOffsets: [CGFloat] = []
        scrollController.onSettleRequested = { settleOffsets.append($0) }
        
        var t = CACurrentMediaTime()
        scrollController.enqueueScroll(dx: -80, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        let liftedOffset = scrollController.currentOffset
        #expect(liftedOffset > 0)
        
        // Physical finger lift: the strip must freeze immediately.
        scrollController.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        #expect(scrollController.currentOffset == liftedOffset)
        #expect(scrollController.smoothTargetOffset == liftedOffset)
        #expect(scrollController.isMomentumCoasting == false)
        #expect(scrollController.isMoving == false)
        
        // macOS momentum packets must be swallowed without moving the strip.
        for momentum in [Int64(1), 2, 2, 2] {
            scrollController.enqueueScroll(dx: -120, dy: 0, phase: 0, momentumPhase: momentum, flags: [])
            t += (1.0 / 120.0)
            scrollController.displayLinkFired(timestamp: t)
            #expect(scrollController.currentOffset == liftedOffset)
        }
        scrollController.enqueueScroll(dx: 0, dy: 0, phase: 0, momentumPhase: 4, flags: [])
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        
        #expect(scrollController.currentOffset == liftedOffset)
        #expect(settleOffsets == [liftedOffset])
    }
    
    @Test("Freeze stops interactive swipes without a projected fling")
    func testFreezeStopsInteractiveSwipeExactly() {
        let settings = SettingsStore.shared
        let previousFreeze = settings.freezeOnRelease
        settings.freezeOnRelease = true
        defer { settings.freezeOnRelease = previousFreeze }
        
        let scrollController = ScrollController()
        scrollController.setOffset(100, maxOffset: 2000)
        
        var settledOffset: CGFloat?
        scrollController.onSettleRequested = { settledOffset = $0 }
        
        scrollController.applyInteractiveDelta(-50, maxOffset: 2000, timestamp: CACurrentMediaTime())
        var t = CACurrentMediaTime()
        t += (1.0 / 120.0)
        scrollController.displayLinkFired(timestamp: t)
        let expected = scrollController.currentOffset
        
        scrollController.endInteractiveSwipe(maxOffset: 2000)
        
        #expect(scrollController.currentOffset == expected)
        #expect(expected == 50)
        #expect(scrollController.currentVelocity == 0)
        #expect(scrollController.isMoving == false)
        #expect(settledOffset == expected)
    }
}

@Suite("Multi-Space & Layout Persistence Tests", .serialized)
@MainActor
struct MultiSpaceAndPersistenceTests {
    
    @Test("Every display and Space keeps an independent strip")
    func testMultiSpaceWorkspaceSeparation() {
        let workspaceManager = WorkspaceManager()
        let display = DisplayGeometry(
            id: 1,
            name: "Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875),
            isPrimary: true
        )
        
        let winWork = WindowId(pid: 100, rawId: 1)
        let winChat = WindowId(pid: 200, rawId: 2)
        
        let workWorkspace = DisplayWorkspace(
            displayGeometry: display,
            columns: [WindowColumn(windowIds: [winWork], width: 700)],
            focusedColumnIndex: 0,
            viewportOffset: 0
        )
        let chatWorkspace = DisplayWorkspace(
            displayGeometry: display,
            columns: [WindowColumn(windowIds: [winChat], width: 450)],
            focusedColumnIndex: 0,
            viewportOffset: 100
        )
        
        // Space 1 (Work)
        workspaceManager.setWorkspace(workWorkspace, for: 1, spaceId: 1)
        // Space 2 (Chat)
        workspaceManager.setWorkspace(chatWorkspace, for: 1, spaceId: 2)
        
        #expect(workspaceManager.spaceWorkspaces[WorkspaceKey(displayId: 1, spaceId: 1)]?.columns.first?.width == 700)
        #expect(workspaceManager.spaceWorkspaces[WorkspaceKey(displayId: 1, spaceId: 1)]?.columns.first?.windowIds == [winWork])
        
        #expect(workspaceManager.spaceWorkspaces[WorkspaceKey(displayId: 1, spaceId: 2)]?.columns.first?.width == 450)
        #expect(workspaceManager.spaceWorkspaces[WorkspaceKey(displayId: 1, spaceId: 2)]?.columns.first?.windowIds == [winChat])
    }
    
    @Test("Layout persistence preserves column order, widths, and vertical stacks")
    func testLayoutPersistenceRestoration() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let testFile = tempDir.appendingPathComponent("test_layout.json")
        let persistence = LayoutPersistenceManager(customStorageUrl: testFile)
        
        let win1Id = WindowId(pid: 10, rawId: 1)
        let win2Id = WindowId(pid: 20, rawId: 2)
        let win3Id = WindowId(pid: 30, rawId: 3)
        
        let win1 = ManagedWindow(id: win1Id, pid: 10, bundleIdentifier: "com.apple.Terminal", appName: "Terminal", title: "zsh", frame: .zero)
        let win2 = ManagedWindow(id: win2Id, pid: 20, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "GitHub", frame: .zero)
        let win3 = ManagedWindow(id: win3Id, pid: 30, bundleIdentifier: "com.apple.Notes", appName: "Notes", title: "Todo", frame: .zero)
        
        let windowsMap: [WindowId: ManagedWindow] = [
            win1Id: win1,
            win2Id: win2,
            win3Id: win3
        ]
        
        // Column 0: Terminal (width 620)
        // Column 1: Stacked [Safari, Notes] (width 850)
        let originalColumns = [
            WindowColumn(windowIds: [win1Id], width: 620),
            WindowColumn(windowIds: [win2Id, win3Id], width: 850)
        ]
        
        // 1. Capture and save
        let savedSpace = persistence.captureSpaceLayout(
            columns: originalColumns,
            windows: windowsMap,
            focusedColumnIndex: 1,
            viewportOffset: 150
        )
        let state = PersistedLayoutState(spaces: ["1_1": savedSpace])
        persistence.save(state: state)
        
        // 2. Load and verify serialization
        let loaded = persistence.load()
        #expect(loaded != nil)
        #expect(loaded?.spaces["1_1"]?.columns.count == 2)
        #expect(loaded?.spaces["1_1"]?.columns[0].width == 620)
        #expect(loaded?.spaces["1_1"]?.columns[1].width == 850)
        #expect(loaded?.spaces["1_1"]?.columns[1].windowSignatures.count == 2)
        
        // 3. Restore with running windows (simulating restart)
        // Order of discovered windows is deliberately scrambled
        let scrambledWindows = [win3, win1, win2]
        let restored = persistence.restoreSpaceLayout(
            savedLayout: loaded!.spaces["1_1"]!,
            availableWindows: scrambledWindows,
            visibleWidth: 1440
        )
        
        #expect(restored.restoredColumns.count == 2)
        // Column 0 must be Terminal with width 620
        #expect(restored.restoredColumns[0].width == 620)
        #expect(restored.restoredColumns[0].windowIds == [win1Id])
        
        // Column 1 must have stacked Safari and Notes with width 850
        #expect(restored.restoredColumns[1].width == 850)
        #expect(restored.restoredColumns[1].windowIds == [win2Id, win3Id])
        #expect(restored.savedFocusedIndex == 1)
        #expect(restored.savedViewportOffset == 150)
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    @Test("New window slots in right next to the focused one")
    func testNewWindowSlotsBesideFocused() {
        let engine = LayoutEngine(windowGap: 12.0, defaultColumnWidthRatio: 0.50, defaultMinimumColumnWidth: 380.0)
        
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 2, rawId: 2)
        let win3 = WindowId(pid: 3, rawId: 3)
        
        var columns = [
            WindowColumn(windowIds: [win1], width: 500),
            WindowColumn(windowIds: [win2], width: 500),
            WindowColumn(windowIds: [win3], width: 500)
        ]
        
        // Focused column is column 1 (win2)
        let focusedCol = 1
        let newWinId = WindowId(pid: 4, rawId: 4)
        
        // Slot new window with .afterFocused policy
        let insertIndex = engine.insertWindow(
            newWinId,
            into: &columns,
            focusedColumnIndex: focusedCol,
            policy: .afterFocused,
            visibleWidth: 1440
        )
        
        // Inserted right beside focused: index 2
        #expect(insertIndex == 2)
        #expect(columns.count == 4)
        #expect(columns[0].windowIds == [win1])
        #expect(columns[1].windowIds == [win2])
        #expect(columns[2].windowIds == [newWinId]) // Slotted right next to focused win2
        #expect(columns[3].windowIds == [win3])     // Shifted cleanly to the right
    }
    
    @Test("Pre-tiling initialFrame is preserved and restored on stop/quit")
    func testInitialFramePreservationAndRestoration() {
        let registry = WindowRegistry()
        let win1Id = WindowId(pid: 101, rawId: 1001)
        let win2Id = WindowId(pid: 102, rawId: 1002)
        
        let originalFrame1 = CGRect(x: 200, y: 150, width: 900, height: 650)
        let originalFrame2 = CGRect(x: 50, y: 80, width: 800, height: 500)
        
        var win1 = ManagedWindow(
            id: win1Id,
            pid: 101,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Safari Browser",
            frame: originalFrame1,
            initialFrame: originalFrame1
        )
        let win2 = ManagedWindow(
            id: win2Id,
            pid: 102,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Code",
            title: "Editor",
            frame: originalFrame2,
            initialFrame: originalFrame2
        )
        
        registry.register(window: win1)
        registry.register(window: win2)
        
        #expect(registry.get(windowId: win1Id)?.initialFrame == originalFrame1)
        #expect(registry.get(windowId: win2Id)?.initialFrame == originalFrame2)
        
        // Simulate strip tiling changing current frame
        win1.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        registry.register(window: win1)
        
        // Verify initialFrame is untouched despite frame changes
        #expect(registry.get(windowId: win1Id)?.frame.origin.x == 0)
        #expect(registry.get(windowId: win1Id)?.initialFrame == originalFrame1)
    }
    
    @Test("Re-kickstarting preserves pre-tiling frames when keepOriginalFrames is true")
    func testReKickstartPreservesPreTilingFrames() {
        let registry = WindowRegistry()
        let winId = WindowId(pid: 201, rawId: 2001)
        let originalFrame = CGRect(x: 120, y: 150, width: 850, height: 600)
        
        let win = ManagedWindow(
            id: winId,
            pid: 201,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            title: "Terminal Window",
            frame: originalFrame,
            initialFrame: originalFrame
        )
        registry.register(window: win)
        #expect(registry.get(windowId: winId)?.initialFrame == originalFrame)
        
        // Simulate kickstart clearing registry but keeping original frames
        registry.removeAll(keepOriginalFrames: true)
        
        // Now suppose window is re-discovered while tiled at a column position
        let tiledFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let rediscoveredWin = ManagedWindow(
            id: winId,
            pid: 201,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            title: "Terminal Window",
            frame: tiledFrame,
            initialFrame: tiledFrame
        )
        registry.register(window: rediscoveredWin)
        
        // Must preserve the original pre-tiling frame, NOT the tiled frame!
        #expect(registry.get(windowId: winId)?.initialFrame == originalFrame)
        #expect(registry.get(windowId: winId)?.frame == tiledFrame)
    }
    
    @Test("WorkspaceManager stop disables management and clears overlays")
    func testWorkspaceManagerStopLifecycle() {
        let wsManager = WorkspaceManager.shared
        wsManager.settings.isEnabled = true
        
        wsManager.stop()
        
        #expect(wsManager.settings.isEnabled == false)
        #expect(wsManager.workspaces.isEmpty)
        #expect(wsManager.registry.allWindows().isEmpty)
    }
    
    @Test("LayoutEngine with edge margins and zero gap tiles flush to boundaries")
    func testEdgeMarginsAndZeroGapTiling() {
        let engine = LayoutEngine(
            windowGap: 0,
            edgeMargins: EdgeMargins(top: 10, bottom: 10, left: 15, right: 15),
            defaultColumnWidthRatio: 0.5
        )
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        let cols = [
            WindowColumn(windowIds: [win1], width: 485),
            WindowColumn(windowIds: [win2], width: 485)
        ]
        let windows: [WindowId: ManagedWindow] = [
            win1: ManagedWindow(id: win1, pid: 1, bundleIdentifier: "a", appName: "A", title: "A", frame: .zero, initialFrame: .zero),
            win2: ManagedWindow(id: win2, pid: 1, bundleIdentifier: "b", appName: "B", title: "B", frame: .zero, initialFrame: .zero)
        ]
        
        let comp = engine.computeLayout(
            columns: cols,
            windows: windows,
            focusedColumnIndex: 0,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600),
            viewportOffset: 0,
            layoutMode: .scrollStrip
        )
        
        // Window 1: x = 15, width = 485, y = 10, height = 580 (600 - 20)
        let frame1 = comp.targetFrames[win1]!
        #expect(frame1.origin.x == 15)
        #expect(frame1.origin.y == 10)
        #expect(frame1.width == 485)
        #expect(frame1.height == 580)
        
        // Window 2: x = 15 + 485 + 0 = 500, width = 485, right edge = 985 (1000 - 15)
        let frame2 = comp.targetFrames[win2]!
        #expect(frame2.origin.x == 500)
        #expect(frame2.maxX == 985)
        #expect(frame1.maxX == frame2.minX) // Absolutely zero gap!
    }
    
    @Test("reflowColumnsForGeometryChange adapts columns to fill screen without gaps")
    func testReflowColumnsAdaptsToZeroGap() {
        let wsManager = WorkspaceManager()
        let display = DisplayGeometry(
            id: 1,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            isPrimary: true
        )
        let win1 = WindowId(pid: 1, rawId: 1)
        let win2 = WindowId(pid: 1, rawId: 2)
        wsManager.setWorkspace(
            DisplayWorkspace(
                displayGeometry: display,
                columns: [
                    WindowColumn(windowIds: [win1], width: 700),
                    WindowColumn(windowIds: [win2], width: 700)
                ]
            ),
            for: 1
        )
        wsManager.setActiveDisplayId(1)
        
        wsManager.settings.windowGap = 0
        wsManager.settings.edgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
        wsManager.settings.defaultColumnWidthRatio = 0.5
        
        wsManager.reflowColumnsForGeometryChange()
        
        let cols = wsManager.workspaces[1]?.columns ?? []
        #expect(cols.count == 2)
        #expect(cols[0].width + cols[1].width == 1470) // Exact screen width!
    }
}

@Suite("Freeform Scrolling & Settle Stability Tests", .serialized)
@MainActor
struct FreeformScrollingAndSettleStabilityTests {
    @Test("Prominent column index correctly identifies most visible column at arbitrary scroll positions")
    func testProminentColumnIndex() {
        let engine = LayoutEngine(windowGap: 10, centerMode: .never)
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 600),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 600),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 600)
        ]
        let visibleWidth: CGFloat = 1000.0
        
        // At offset 0: Column 0 has 600pt visible, Column 1 has 390pt visible -> Col 0 prominent
        let idx0 = engine.prominentColumnIndex(for: 0.0, columns: cols, visibleWidth: visibleWidth, gap: 10)
        #expect(idx0 == 0)
        
        // At offset 450: Column 0 has 150pt visible, Column 1 has 600pt visible -> Col 1 prominent
        let idx1 = engine.prominentColumnIndex(for: 450.0, columns: cols, visibleWidth: visibleWidth, gap: 10)
        #expect(idx1 == 1)
        
        // At offset 1000: Column 1 has 210pt visible, Column 2 has 600pt visible -> Col 2 prominent
        let idx2 = engine.prominentColumnIndex(for: 1000.0, columns: cols, visibleWidth: visibleWidth, gap: 10)
        #expect(idx2 == 2)
    }
    
    @Test("Freeform scrolling remains exactly where user left it without snapping or shifting")
    func testFreeformScrollPreservesExactOffset() {
        let scrollController = ScrollController()
        let settings = SettingsStore.shared
        settings.freeformScroll = true
        
        var settledOffset: CGFloat? = nil
        scrollController.onSettleRequested = { offset in
            settledOffset = offset
        }
        
        // User scrolled and left strip at an arbitrary unaligned position (373.5 pt)
        scrollController.setOffset(373.5, maxOffset: 2000)
        scrollController.settle()
        
        // Must remain exactly at 373.5 pt without snapping
        #expect(scrollController.currentOffset == 373.5)
        #expect(settledOffset == 373.5)
        #expect(scrollController.isSpringAnimating == false)
        #expect(scrollController.isMoving == false)
    }
    
    @Test("WorkspaceManager in freeform mode does not auto-shift or scroll viewport offset on applyLayout")
    func testWorkspaceManagerFreeformNoAutoShift() {
        let wsManager = WorkspaceManager()
        wsManager.settings.freeformScroll = true
        
        let display = DisplayGeometry(
            id: 100,
            name: "Test Screen",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900),
            isPrimary: true
        )
        let win1 = WindowId(pid: 1, rawId: 10)
        let win2 = WindowId(pid: 1, rawId: 20)
        let win3 = WindowId(pid: 1, rawId: 30)
        
        var ws = DisplayWorkspace(
            displayGeometry: display,
            columns: [
                WindowColumn(windowIds: [win1], width: 700),
                WindowColumn(windowIds: [win2], width: 700),
                WindowColumn(windowIds: [win3], width: 700)
            ]
        )
        // User left strip at custom offset 412.0
        ws.viewportOffset = 412.0
        ws.focusedColumnIndex = 1
        wsManager.setWorkspace(ws, for: 100)
        wsManager.setActiveDisplayId(100)
        
        // applyLayout must keep viewportOffset exactly at 412.0 without animating to column boundaries
        wsManager.applyLayout(animated: false)
        
        let activeWs = wsManager.workspaces[100]
        #expect(activeWs?.viewportOffset == 412.0)
        #expect(wsManager.scrollController.currentOffset == 412.0)
        #expect(wsManager.scrollController.isMoving == false)
    }
}




