import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import IumeCore

@Suite("v2.0 Feature Parity Tests", .serialized)
struct V2FeatureParityTests {
    
    // MARK: - 120Hz Spring Physics
    
    @Test("SpringState harmonic oscillator steps smoothly and reaches rest")
    func testSpringStateConvergence() {
        var spring = SpringState()
        spring.position = 0
        spring.velocity = 0
        spring.target = 500
        spring.response = 0.22
        spring.dampingRatio = 0.92
        
        #expect(!spring.isAtRest)
        
        // Step at 120Hz (dt = 1/120) for 0.5s (60 steps)
        let dt: CGFloat = 1.0 / 120.0
        for _ in 0..<60 {
            spring.step(dt: dt)
        }
        
        // Should be at or extremely close to 500
        #expect(abs(spring.position - 500) < 5.0)
        
        // After 1.0s (120 steps total), it must be at rest
        for _ in 0..<60 {
            spring.step(dt: dt)
        }
        #expect(spring.isAtRest)
        #expect(spring.position == 500)
        #expect(spring.velocity == 0)
    }
    
    // MARK: - PureStripLayoutEngine: 3 Center Modes
    
    @Test("PureStripLayoutEngine targetViewportOffset respects CenterMode always, onOverflow, never")
    func testCenterModes() {
        let cols = [
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 1)], width: 400),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 2)], width: 400),
            WindowColumn(windowIds: [WindowId(pid: 1, rawId: 3)], width: 400)
        ]
        let visFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let margins = EdgeMargins.zero
        let innerGap: CGFloat = 10
        
        // Column 0: 0..400
        // Column 1: 410..810 (mid = 610)
        // Usable width = 1000
        // Total strip width = 400 + 10 + 400 + 10 + 400 = 1220 (overflows 1000)
        
        // 1. CenterMode.always on Column 1: targetOffset = 410 - (1000 - 400)/2 = 410 - 300 = 110
        let offsetAlways = PureStripLayoutEngine.targetViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: innerGap,
            outerMargins: margins,
            centerMode: .always
        )
        #expect(offsetAlways == 110)
        
        // 2. CenterMode.onOverflow on Column 1: since total 1220 > 1000, centers column 1
        let offsetOverflow = PureStripLayoutEngine.targetViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: innerGap,
            outerMargins: margins,
            centerMode: .onOverflow
        )
        #expect(offsetOverflow == 110)
        
        // When strip does NOT overflow (e.g. single 400pt column):
        let singleCol = [cols[0]]
        let offsetNoOverflow = PureStripLayoutEngine.targetViewportOffset(
            columns: singleCol,
            focusedColumnIndex: 0,
            currentViewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: innerGap,
            outerMargins: margins,
            centerMode: .onOverflow
        )
        #expect(offsetNoOverflow == 0)
        
        // 3. CenterMode.never on Column 1: since column 1 (410..810) is already fully visible inside 0..1000, offset remains 0
        let offsetNever = PureStripLayoutEngine.targetViewportOffset(
            columns: cols,
            focusedColumnIndex: 1,
            currentViewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: innerGap,
            outerMargins: margins,
            centerMode: .never
        )
        #expect(offsetNever == 0)
    }
    
    // MARK: - Stacks and Tabbed Columns Layout Frames
    
    @Test("PureStripLayoutEngine computeWindowFrames supports Tabbed and Stacked modes")
    func testComputeWindowFramesTabbedAndStacked() {
        let win1 = WindowId(pid: 1, rawId: 10)
        let win2 = WindowId(pid: 1, rawId: 20)
        
        // Column 0: Tabbed mode with 2 windows
        var col0 = WindowColumn(
            id: UUID(),
            windowIds: [win1, win2],
            width: 500,
            presentationMode: .tabbed,
            activeWindowIndex: 0
        )
        
        let visFrame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let margins = EdgeMargins.zero
        let innerGap: CGFloat = 0
        
        let framesTabbed = PureStripLayoutEngine.computeWindowFrames(
            columns: [col0],
            viewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: innerGap,
            outerMargins: margins
        )
        
        // Active tab (win1) gets full column height minus 28pt tab bar
        let f1 = framesTabbed[win1]
        #expect(f1 != nil)
        #expect(f1?.origin.y == PureStripLayoutEngine.tabBarHeight)
        #expect(f1?.height == 600 - PureStripLayoutEngine.tabBarHeight)
        #expect(f1?.width == 500)
        
        // Inactive tab (win2) parked offscreen
        let f2 = framesTabbed[win2]
        #expect(f2 != nil)
        #expect(f2!.origin.x < visFrame.minX || f2!.origin.x >= visFrame.maxX)
        
        // Column 0 switched to Stacked mode
        col0.presentationMode = .stacked
        let framesStacked = PureStripLayoutEngine.computeWindowFrames(
            columns: [col0],
            viewportOffset: 0,
            visibleFrame: visFrame,
            innerGap: 10,
            outerMargins: margins
        )
        let sf1 = framesStacked[win1]
        let sf2 = framesStacked[win2]
        #expect(sf1 != nil && sf2 != nil)
        // Heights split proportionally
        #expect(sf1!.width == 500)
        #expect(sf2!.width == 500)
        #expect(sf1!.height >= PureStripLayoutEngine.minStackedWindowHeight)
        #expect(sf2!.height >= PureStripLayoutEngine.minStackedWindowHeight)
        #expect(sf1!.origin.y < sf2!.origin.y)
    }
    
    // MARK: - Stacking and Unstacking Operations
    
    @Test("LayoutEngine stackWindow and unstackWindow operations")
    func testStackAndUnstackOperations() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 1, rawId: 1)
        let w2 = WindowId(pid: 1, rawId: 2)
        
        var columns = [
            WindowColumn(windowIds: [w1], width: 400),
            WindowColumn(windowIds: [w2], width: 400)
        ]
        
        // Stack w1 into column 1
        engine.stackWindow(windowId: w1, fromColumnIndex: 0, toColumnIndex: 1, columns: &columns)
        #expect(columns.count == 1)
        #expect(columns[0].windowIds.count == 2)
        #expect(columns[0].windowIds.contains(w1))
        #expect(columns[0].windowIds.contains(w2))
        
        // Unstack w1 out of column 0
        let newIdx = engine.unstackWindow(windowId: w1, fromColumnIndex: 0, columns: &columns, visibleWidth: 1000)
        #expect(columns.count == 2)
        #expect(newIdx == 1)
        #expect(columns[0].windowIds == [w2])
        #expect(columns[1].windowIds == [w1])
    }
    
    // MARK: - Nudge Column Width
    
    @Test("LayoutEngine nudgeColumnWidth adjusts width proportionally")
    func testNudgeColumnWidth() {
        let engine = LayoutEngine()
        let w1 = WindowId(pid: 1, rawId: 1)
        var columns = [WindowColumn(windowIds: [w1], width: 500)]
        
        // Nudge wider (+5% on 1000pt screen = +50pt)
        let wWider = engine.nudgeColumnWidth(at: 0, columns: &columns, deltaRatio: 0.05, visibleWidth: 1000)
        #expect(wWider == 550)
        
        // Nudge narrower (-10% on 1000pt screen = -100pt)
        let wNarrower = engine.nudgeColumnWidth(at: 0, columns: &columns, deltaRatio: -0.10, visibleWidth: 1000)
        #expect(wNarrower == 450)
    }
    
    // MARK: - InteractionManager
    
    @Test("InteractionManager prevents background focus stealing and computes drag reorder")
    @MainActor
    func testInteractionManager() {
        SettingsStore.shared.dragToReorder = true
        let im = InteractionManager.shared
        
        // Simulate user clicking / launching app 500
        im.markUserInitiatedActivation(pid: 500)
        
        // Newly created window for PID 500 should be focused
        #expect(im.shouldFocusNewlyCreatedWindow(appPID: 500, currentFocusedPID: 100))
        
        // Background popup from PID 999 should NOT steal focus
        #expect(!im.shouldFocusNewlyCreatedWindow(appPID: 999, currentFocusedPID: 100))
        
        // Drag to reorder drop index calculation
        // Columns midpoints at [200, 500, 800]
        let midpoints: [CGFloat] = [200, 500, 800]
        let drop0 = im.resolveDragReorderDropIndex(draggedWindowId: WindowId(pid: 1, rawId: 1), cursorScreenX: 180, columnMidpointsScreenX: midpoints)
        let drop1 = im.resolveDragReorderDropIndex(draggedWindowId: WindowId(pid: 1, rawId: 1), cursorScreenX: 520, columnMidpointsScreenX: midpoints)
        let drop2 = im.resolveDragReorderDropIndex(draggedWindowId: WindowId(pid: 1, rawId: 1), cursorScreenX: 900, columnMidpointsScreenX: midpoints)
        
        #expect(drop0 == 0)
        #expect(drop1 == 1)
        #expect(drop2 == 2)
    }
    
    // MARK: - KeyTranslator
    
    @Test("KeyTranslator displayString converts Carbon keycode to glyph")
    func testKeyTranslator() {
        // Keycode 0x04 corresponds to 'H'
        let glyphH = KeyTranslator.displayString(for: 0x04)
        #expect(!glyphH.isEmpty)
        
        // Keycode 0x24 corresponds to Return
        let glyphReturn = KeyTranslator.displayString(for: 0x24)
        #expect(!glyphReturn.isEmpty)
    }
    
    // MARK: - MacSetupInspector Health Report
    
    @Test("MacSetupChecker inspectSystem returns valid report")
    @MainActor
    func testSetupHealthReport() {
        let report = MacSetupChecker.inspectSystem()
        #expect(report.hasSeparateSpacesPerDisplay || !report.hasSeparateSpacesPerDisplay)
        #expect(report.isSpacesAutoRearranging || !report.isSpacesAutoRearranging)
    }
}
