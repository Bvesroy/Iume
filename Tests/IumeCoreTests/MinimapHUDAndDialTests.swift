import Testing
import Foundation
import CoreGraphics
import AppKit
import SwiftUI
@testable import IumeCore

/// The suite drives shared singletons (the HUD controller and the workspace manager), so it
/// runs serially to keep the tests from stepping on each other.
@Suite("Minimap HUD & Dial Geometry Tests", .serialized)
struct MinimapHUDAndDialTests {

    // MARK: - DialGeometry Tests

    @Test("DialGeometry angles and ratios map accurately across 270 degree sweep")
    func testAngleRatioMapping() {
        // Strip ratio 0 is startAngleDegrees (135°)
        let startAngle = DialGeometry.angle(forStripRatio: 0.0)
        #expect(abs(startAngle - 135.0) < 0.001)

        // Strip ratio 1 is startAngleDegrees + 270° = 405° (= 45°)
        let endAngle = DialGeometry.angle(forStripRatio: 1.0)
        #expect(abs(endAngle - 405.0) < 0.001)

        // Midpoint ratio 0.5 is 135 + 135 = 270° (top / 12 o'clock)
        let midAngle = DialGeometry.angle(forStripRatio: 0.5)
        #expect(abs(midAngle - 270.0) < 0.001)

        // Inverse mapping
        #expect(abs(DialGeometry.stripRatio(forAngleDegrees: 135.0) - 0.0) < 0.001)
        #expect(abs(DialGeometry.stripRatio(forAngleDegrees: 270.0) - 0.5) < 0.001)
        #expect(abs(DialGeometry.stripRatio(forAngleDegrees: 45.0) - 1.0) < 0.001)
        #expect(abs(DialGeometry.stripRatio(forAngleDegrees: 405.0) - 1.0) < 0.001)
    }

    @Test("DialGeometry gap resolution snaps to closest end of the strip")
    func testGapResolution() {
        // The bottom gap is between 45° and 135° (center is 90° / 6 o'clock)
        // 50° is closer to 45° (ratio 1.0)
        let ratioNearEnd = DialGeometry.stripRatio(forAngleDegrees: 50.0)
        #expect(ratioNearEnd == 1.0)

        // 130° is closer to 135° (ratio 0.0)
        let ratioNearStart = DialGeometry.stripRatio(forAngleDegrees: 130.0)
        #expect(ratioNearStart == 0.0)
    }

    @Test("DialGeometry column geometries calculate proportional arcs without absorbing gaps")
    func testColumnGeometries() {
        let widths: [CGFloat] = [200, 200]
        let gap: CGFloat = 40
        // Total = 200 + 40 + 200 = 440
        let geos = DialGeometry.columnGeometries(widths: widths, gap: gap)
        #expect(geos.count == 2)

        // First column: starts at 0, ends at 200/440
        #expect(abs(geos[0].startRatio - 0.0) < 0.001)
        #expect(abs(geos[0].endRatio - Double(200.0 / 440.0)) < 0.001)
        #expect(abs(geos[0].centerRatio - Double(100.0 / 440.0)) < 0.001)

        // Second column: starts at 240/440, ends at 440/440 = 1.0
        #expect(abs(geos[1].startRatio - Double(240.0 / 440.0)) < 0.001)
        #expect(abs(geos[1].endRatio - 1.0) < 0.001)
        #expect(abs(geos[1].centerRatio - Double(340.0 / 440.0)) < 0.001)

        // Hit testing for column index
        #expect(DialGeometry.columnIndex(atStripRatio: 0.1, geometries: geos) == 0)
        #expect(DialGeometry.columnIndex(atStripRatio: 0.9, geometries: geos) == 1)
    }

    @Test("DialGeometry insertion index correctly determines drop slot during drag")
    func testInsertionIndex() {
        let widths: [CGFloat] = [100, 100, 100]
        let gap: CGFloat = 0

        // Dragging column 0 (which was at slot 0) towards the end
        // Ratio 0.1 -> still at slot 0
        let slot0 = DialGeometry.insertionIndex(atStripRatio: 0.1, widths: widths, gap: gap, draggingIndex: 0)
        #expect(slot0 == 0)

        // Ratio 0.5 -> middle slot 1
        let slot1 = DialGeometry.insertionIndex(atStripRatio: 0.5, widths: widths, gap: gap, draggingIndex: 0)
        #expect(slot1 == 1)

        // Ratio 0.9 -> end slot 2
        let slot2 = DialGeometry.insertionIndex(atStripRatio: 0.9, widths: widths, gap: gap, draggingIndex: 0)
        #expect(slot2 == 2)

        // Dragging column 2 towards the beginning
        let slotFromEnd = DialGeometry.insertionIndex(atStripRatio: 0.1, widths: widths, gap: gap, draggingIndex: 2)
        #expect(slotFromEnd == 0)
    }

    @Test("DialGeometry viewport range correctly maps strip offset to 0...1 ratios")
    func testViewportRange() {
        let totalWidth: CGFloat = 1000
        let visibleWidth: CGFloat = 400
        // Max offset = 600

        // At start (offset 0)
        let vp0 = DialGeometry.viewportRange(offset: 0, visibleWidth: visibleWidth, totalStripWidth: totalWidth)
        #expect(abs(vp0.start - 0.0) < 0.001)
        #expect(abs(vp0.end - 0.4) < 0.001)

        // At end (offset 600)
        let vpEnd = DialGeometry.viewportRange(offset: 600, visibleWidth: visibleWidth, totalStripWidth: totalWidth)
        #expect(abs(vpEnd.start - 0.6) < 0.001)
        #expect(abs(vpEnd.end - 1.0) < 0.001)
    }

    // MARK: - Regression Tests

    @Test("Viewport range stays in strip space midway through the scroll")
    func testViewportRangeUsesStripSpace() {
        let totalWidth: CGFloat = 1000
        let visibleWidth: CGFloat = 400
        // Halfway through the scrollable range. The old implementation mapped the *scroll
        // range* onto the dial, which only agreed with strip space at the two extremes.
        let vp = DialGeometry.viewportRange(offset: 300, visibleWidth: visibleWidth, totalStripWidth: totalWidth)
        #expect(abs(vp.start - 0.3) < 0.001)
        #expect(abs(vp.end - 0.7) < 0.001)
    }

    @Test("Column arcs and the viewport share one strip space")
    func testColumnArcsAndViewportShareSpace() {
        let widths: [CGFloat] = [300, 300, 300]
        let gap: CGFloat = 20
        // Strip = 3 * 300 + 2 * 20 = 940
        let total = DialGeometry.totalStripWidth(widths: widths, gap: gap)
        #expect(total == 940)

        let geos = DialGeometry.columnGeometries(widths: widths, gap: gap)
        // The second column starts at strip point 320 (300 + 20).
        #expect(abs(geos[1].startRatio - Double(320.0 / total)) < 0.001)

        // Scrolled so the viewport covers strip points 320...640, it has to begin exactly on
        // the second column's arc and end exactly on the third column's arc.
        let vp = DialGeometry.viewportRange(offset: 320, visibleWidth: 320, totalStripWidth: total)
        #expect(abs(vp.start - geos[1].startRatio) < 0.001)
        #expect(abs(vp.end - geos[2].startRatio) < 0.001)
    }

    @Test("Column arcs are laid out in the same gap-aware space as the strip total")
    func testColumnArcsUseTheStripGap() {
        let widths: [CGFloat] = [200, 200, 200]
        let gap: CGFloat = 20
        // Strip = 3 * 200 + 2 * 20 = 640
        let total = DialGeometry.totalStripWidth(widths: widths, gap: gap)
        #expect(total == 640)

        // The arcs have to sit at the same strip points the layout engine uses, otherwise the
        // viewport arc and the column arcs are drawn in two different spaces and can never
        // line up.
        let geos = DialGeometry.columnGeometries(widths: widths, gap: gap)
        #expect(abs(geos[1].startRatio - Double(220.0 / total)) < 0.001)
        #expect(abs(geos.last!.endRatio - 1.0) < 0.001)

        // A mismatched (zero) gap puts the arcs at the wrong strip points.
        let mismatched = DialGeometry.columnGeometries(widths: widths, gap: 0)
        #expect(abs(mismatched[1].startRatio - Double(200.0 / 600.0)) < 0.001)
        #expect(abs(mismatched[1].startRatio - geos[1].startRatio) > 0.001)
    }

    @Test("A nudge inside the dragged column's own footprint does not teleport it")
    func testInsertionIndexIgnoresNudgeInsideDraggedColumn() {
        let widths: [CGFloat] = [100, 100, 100]
        let gap: CGFloat = 0
        let total = DialGeometry.totalStripWidth(widths: widths, gap: gap)

        // Dragging the middle column. A pointer one point past its start used to shift the
        // insertion slot to 0, moving the column to the front on a 1pt nudge.
        let justInside = DialGeometry.insertionIndex(
            atStripRatio: 101.0 / Double(total),
            widths: widths,
            gap: gap,
            draggingIndex: 1
        )
        #expect(justInside == 1)

        // Anywhere inside its own footprint keeps the same slot.
        for point in stride(from: 100.0, through: 200.0, by: 10.0) {
            let slot = DialGeometry.insertionIndex(
                atStripRatio: point / Double(total),
                widths: widths,
                gap: gap,
                draggingIndex: 1
            )
            #expect(slot == 1)
        }
    }

    @Test("Insertion index tracks the drop slot across the whole strip")
    func testInsertionIndexAcrossStrip() {
        let widths: [CGFloat] = [100, 100, 100]
        let gap: CGFloat = 0
        let total = DialGeometry.totalStripWidth(widths: widths, gap: gap)

        // Dragging the first column: past the second column's centre lands in slot 1,
        // past the third column's centre lands in slot 2.
        #expect(DialGeometry.insertionIndex(atStripRatio: 10.0 / Double(total), widths: widths, gap: gap, draggingIndex: 0) == 0)
        #expect(DialGeometry.insertionIndex(atStripRatio: 160.0 / Double(total), widths: widths, gap: gap, draggingIndex: 0) == 1)
        #expect(DialGeometry.insertionIndex(atStripRatio: 260.0 / Double(total), widths: widths, gap: gap, draggingIndex: 0) == 2)

        // Dragging the last column: the pointer is measured against the shortened strip, so
        // the second column's midpoint sits at 150 rather than 250.
        #expect(DialGeometry.insertionIndex(atStripRatio: 10.0 / Double(total), widths: widths, gap: gap, draggingIndex: 2) == 0)
        #expect(DialGeometry.insertionIndex(atStripRatio: 120.0 / Double(total), widths: widths, gap: gap, draggingIndex: 2) == 1)
        #expect(DialGeometry.insertionIndex(atStripRatio: 160.0 / Double(total), widths: widths, gap: gap, draggingIndex: 2) == 2)
    }

    @Test("Insertion boundary is expressed in the original strip space")
    func testInsertionBoundaryRatio() {
        let widths: [CGFloat] = [400, 400, 400]
        let gap: CGFloat = 0
        let geos = DialGeometry.columnGeometries(widths: widths, gap: gap)

        // Dragging the first column into slot 1 makes the final order [B, A, C] — the marker
        // belongs on the boundary between B and C in the *original* strip.
        #expect(abs(DialGeometry.insertionBoundaryRatio(insertion: 1, widths: widths, gap: gap, draggingIndex: 0) - geos[1].endRatio) < 0.001)

        // Dragging the middle column into slot 1 leaves the order unchanged, so the marker
        // belongs on the boundary between A and B.
        #expect(abs(DialGeometry.insertionBoundaryRatio(insertion: 1, widths: widths, gap: gap, draggingIndex: 1) - geos[0].endRatio) < 0.001)

        // Dragging the last column into slot 1 gives [A, C, B] — the marker belongs on the
        // boundary between A and B.
        #expect(abs(DialGeometry.insertionBoundaryRatio(insertion: 1, widths: widths, gap: gap, draggingIndex: 2) - geos[0].endRatio) < 0.001)

        // Dropping at the very front marks the start of the strip.
        #expect(DialGeometry.insertionBoundaryRatio(insertion: 0, widths: widths, gap: gap, draggingIndex: 1) == 0.0)

        // Dropping at the very end marks the end of the strip.
        #expect(abs(DialGeometry.insertionBoundaryRatio(insertion: 2, widths: widths, gap: gap, draggingIndex: 0) - 1.0) < 0.001)
    }

    @Test("Cancelling a drag clears the dial interaction state")
    @MainActor
    func testCancelDragClearsInteraction() {
        let controller = MinimapHUDController.shared
        controller.beginDrag(column: 0)
        #expect(controller.interaction == .dragging(column: 0, insertionIndex: 0))

        // A tap (press without movement) has to leave the dial idle, otherwise it stays
        // latched and never auto-hides again.
        controller.cancelDrag()
        #expect(controller.interaction == .idle)
    }

    @Test("HUD sound cues are short, quiet and free of clicks")
    @MainActor
    func testSoundCuesAreWellFormed() {
        let cues: [HudSoundEngine.Cue] = [.hover, .snap, .grab, .drop, .bump, .loopSeam]
        for cue in cues {
            guard let buffer = HudSoundEngine.shared.renderForTesting(cue),
                  let samples = buffer.floatChannelData?[0] else {
                Issue.record("could not render cue \(cue)")
                continue
            }
            let count = Int(buffer.frameLength)
            #expect(count > 0)

            let duration = Double(count) / 44_100.0
            // UI cues have to be over before they register as noise.
            #expect(duration < 0.2)

            var peak: Float = 0
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
            // Audible, but never clipping.
            #expect(peak > 0.05)
            #expect(peak <= 1.0)

            // Starting and ending on silence is what keeps the buffer from clicking.
            #expect(abs(samples[0]) < 0.02)
            #expect(abs(samples[count - 1]) < 0.02)
        }
    }

    @Test("Dragging a column on the dial reorders the strip end to end")
    @MainActor
    func testDialDragReordersStripEndToEnd() {
        let wm = WorkspaceManager.shared
        let hud = MinimapHUDController.shared
        let settings = SettingsStore.shared

        // Keep the test silent — the cues are synthesised for real.
        let soundWasEnabled = settings.hudSoundEnabled
        settings.hudSoundEnabled = false
        defer { settings.hudSoundEnabled = soundWasEnabled }

        settings.isEnabled = true
        wm.setupMinimapHUDCallbacks()

        let displayId: CGDirectDisplayID = 1
        let geom = DisplayGeometry(
            id: displayId,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isPrimary: true
        )
        let colA = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 10, rawId: 1)], width: 500)
        let colB = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 20, rawId: 2)], width: 500)
        let colC = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 30, rawId: 3)], width: 500)

        wm.setActiveDisplayId(displayId)
        wm.setWorkspace(
            DisplayWorkspace(
                displayGeometry: geom,
                columns: [colA, colB, colC],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: displayId
        )

        // Feed the dial the same three columns.
        let widths: [CGFloat] = [500, 500, 500]
        hud.update(
            columns: [
                DialColumnInfo(id: colA.id, width: 500, windowCount: 1, title: "A", appName: "A", bundleIdentifier: "com.test.a"),
                DialColumnInfo(id: colB.id, width: 500, windowCount: 1, title: "B", appName: "B", bundleIdentifier: "com.test.b"),
                DialColumnInfo(id: colC.id, width: 500, windowCount: 1, title: "C", appName: "C", bundleIdentifier: "com.test.c")
            ],
            totalStripWidth: 1500,
            viewportOffset: 0,
            visibleWidth: 1000,
            focusedIndex: 0,
            activeTitle: "A",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        // Grab the first column and drag it past the last column's centre.
        hud.beginDrag(column: 0)
        #expect(hud.interaction == .dragging(column: 0, insertionIndex: 0))

        let insertion = DialGeometry.insertionIndex(
            atStripRatio: 1400.0 / 1500.0,
            widths: widths,
            gap: 0,
            draggingIndex: 0
        )
        #expect(insertion == 2)

        hud.updateDrag(insertionIndex: insertion)
        #expect(hud.interaction == .dragging(column: 0, insertionIndex: 2))

        hud.endDrag(commit: true)
        #expect(hud.interaction == .idle)

        // The strip now reads B, C, A.
        let updated = wm.workspaces[displayId]?.columns ?? []
        #expect(updated.count == 3)
        #expect(updated[0].id == colB.id)
        #expect(updated[1].id == colC.id)
        #expect(updated[2].id == colA.id)
        #expect(wm.workspaces[displayId]?.focusedColumnIndex == 2)
    }

    @Test("Dropping a column back on its own slot leaves the strip untouched")
    @MainActor
    func testDialDragBackToOriginDoesNotReorder() {
        let wm = WorkspaceManager.shared
        let hud = MinimapHUDController.shared
        let settings = SettingsStore.shared

        let soundWasEnabled = settings.hudSoundEnabled
        settings.hudSoundEnabled = false
        defer { settings.hudSoundEnabled = soundWasEnabled }

        settings.isEnabled = true
        wm.setupMinimapHUDCallbacks()

        let displayId: CGDirectDisplayID = 1
        let geom = DisplayGeometry(
            id: displayId,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isPrimary: true
        )
        let colA = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 10, rawId: 1)], width: 500)
        let colB = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 20, rawId: 2)], width: 500)
        let colC = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 30, rawId: 3)], width: 500)

        wm.setActiveDisplayId(displayId)
        wm.setWorkspace(
            DisplayWorkspace(
                displayGeometry: geom,
                columns: [colA, colB, colC],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: displayId
        )

        let widths: [CGFloat] = [500, 500, 500]
        hud.update(
            columns: [
                DialColumnInfo(id: colA.id, width: 500, windowCount: 1, title: "A", appName: "A", bundleIdentifier: "com.test.a"),
                DialColumnInfo(id: colB.id, width: 500, windowCount: 1, title: "B", appName: "B", bundleIdentifier: "com.test.b"),
                DialColumnInfo(id: colC.id, width: 500, windowCount: 1, title: "C", appName: "C", bundleIdentifier: "com.test.c")
            ],
            totalStripWidth: 1500,
            viewportOffset: 0,
            visibleWidth: 1000,
            focusedIndex: 0,
            activeTitle: "A",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        // Pick up the middle column and drop it right back where it was.
        hud.beginDrag(column: 1)
        let insertion = DialGeometry.insertionIndex(
            atStripRatio: 750.0 / 1500.0,
            widths: widths,
            gap: 0,
            draggingIndex: 1
        )
        #expect(insertion == 1)
        hud.updateDrag(insertionIndex: insertion)
        hud.endDrag(commit: true)

        let updated = wm.workspaces[displayId]?.columns ?? []
        #expect(updated.count == 3)
        #expect(updated[0].id == colA.id)
        #expect(updated[1].id == colB.id)
        #expect(updated[2].id == colC.id)
    }

    // MARK: - Controller Interaction Tests

    @Test("MinimapHUDController handles drag state transitions and callbacks")
    @MainActor
    func testControllerDragAndMove() {
        let controller = MinimapHUDController.shared
        
        let cols = [
            DialColumnInfo(id: UUID(), width: 400, windowCount: 1, title: "Win 1", appName: "App 1", bundleIdentifier: "com.test.app1"),
            DialColumnInfo(id: UUID(), width: 400, windowCount: 1, title: "Win 2", appName: "App 2", bundleIdentifier: "com.test.app2"),
            DialColumnInfo(id: UUID(), width: 400, windowCount: 1, title: "Win 3", appName: "App 3", bundleIdentifier: "com.test.app3")
        ]
        
        controller.update(
            columns: cols,
            totalStripWidth: 1200,
            viewportOffset: 0,
            visibleWidth: 800,
            focusedIndex: 0,
            activeTitle: "Win 1",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        let oldOnMove = controller.onMoveColumn
        let oldOnSelect = controller.onSelectColumn
        defer {
            controller.onMoveColumn = oldOnMove
            controller.onSelectColumn = oldOnSelect
        }

        var movedFrom: Int?
        var movedTo: Int?
        controller.onMoveColumn = { from, to in
            movedFrom = from
            movedTo = to
        }

        var selectedIndex: Int?
        controller.onSelectColumn = { idx in
            selectedIndex = idx
        }

        // 1. Begin drag on column 0
        controller.beginDrag(column: 0)
        #expect(controller.interaction == .dragging(column: 0, insertionIndex: 0))

        // 2. Drag to slot 2
        controller.updateDrag(insertionIndex: 2)
        #expect(controller.interaction == .dragging(column: 0, insertionIndex: 2))

        // 3. Drop at slot 2 -> triggers onMoveColumn
        controller.endDrag(commit: true)
        #expect(controller.interaction == .idle)
        #expect(movedFrom == 0)
        #expect(movedTo == 2)

        // 4. Tap on column 1 without moving -> triggers selectColumn
        controller.beginDrag(column: 1)
        controller.endDrag(commit: true)
        #expect(selectedIndex == 1)
    }

    @Test("WorkspaceManager reorders columns when onMoveColumn fires")
    @MainActor
    func testWorkspaceColumnReordering() {
        let wm = WorkspaceManager.shared
        SettingsStore.shared.isEnabled = true
        wm.setupMinimapHUDCallbacks()
        let displayId: CGDirectDisplayID = 1
        let geom = DisplayGeometry(
            id: displayId,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isPrimary: true
        )
        
        let colA = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 10, rawId: 1)], width: 500)
        let colB = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 20, rawId: 2)], width: 500)
        let colC = WindowColumn(id: UUID(), windowIds: [WindowId(pid: 30, rawId: 3)], width: 500)
        
        wm.setActiveDisplayId(displayId)
        wm.setWorkspace(
            DisplayWorkspace(
                displayGeometry: geom,
                columns: [colA, colB, colC],
                focusedColumnIndex: 0,
                viewportOffset: 0
            ),
            for: displayId
        )

        // Trigger onMoveColumn from index 0 to index 2
        MinimapHUDController.shared.onMoveColumn?(0, 2)

        let updatedCols = wm.workspaces[displayId]?.columns ?? []
        #expect(updatedCols.count == 3)
        #expect(updatedCols[0].id == colB.id)
        #expect(updatedCols[1].id == colC.id)
        #expect(updatedCols[2].id == colA.id)
        #expect(wm.workspaces[displayId]?.focusedColumnIndex == 2)
    }

    // MARK: - HUD Style & Semicircle Geometry Tests

    @Test("MinimapHUDStyle settings expose all variants and default to the circular dial")
    @MainActor
    func testHUDStyleSettings() {
        #expect(MinimapHUDStyle.allCases.count >= 3)
        #expect(!MinimapHUDStyle.semicircle.displayName.isEmpty)
        #expect(!MinimapHUDStyle.circularDial.displayName.isEmpty)
        #expect(!MinimapHUDStyle.linearStrip.displayName.isEmpty)

        // A pristine store has to come up on the radial dial, visible by default, with sound
        // feedback on — the configuration the HUD was redesigned around. The fixture keeps the
        // test off the user's live preference domain and memory file.
        let fixture = IsolatedSettingsFixture()
        defer { fixture.cleanup() }
        let fresh = fixture.store
        #expect(fresh.hudStyle == .circularDial)
        #expect(fresh.hudSoundVolume > 0.0)
    }

    @Test("Horizon half-ellipse coordinate mapping accurately converts ratio to point and point to ratio")
    @MainActor
    func testSemicircleCoordinateMapping() {
        // Ratio 0.0 (left start)
        let ptStart = MinimapHorizonEllipseView.point(for: 0.0)
        #expect(ptStart.x < MinimapHorizonEllipseView.panelWidth / 2.0)
        let ratioStart = MinimapHorizonEllipseView.ratio(for: ptStart)
        #expect(abs(ratioStart - 0.0) < 0.01)

        // Ratio 0.5 (apex of the arch)
        let ptMid = MinimapHorizonEllipseView.point(for: 0.5)
        #expect(abs(ptMid.x - MinimapHorizonEllipseView.panelWidth / 2.0) < 0.01)
        #expect(ptMid.y < MinimapHorizonEllipseView.panelHeight)
        let ratioMid = MinimapHorizonEllipseView.ratio(for: ptMid)
        #expect(abs(ratioMid - 0.5) < 0.01)

        // Ratio 1.0 (right end)
        let ptEnd = MinimapHorizonEllipseView.point(for: 1.0)
        #expect(ptEnd.x > MinimapHorizonEllipseView.panelWidth / 2.0)
        let ratioEnd = MinimapHorizonEllipseView.ratio(for: ptEnd)
        #expect(abs(ratioEnd - 1.0) < 0.01)
    }

    @Test("MinimapHUDController reconfigures panel size across styles")
    @MainActor
    func testControllerReconfigureStyle() {
        let controller = MinimapHUDController.shared

        let semiSize = controller.panelSize(for: .semicircle)
        #expect(semiSize.width == MinimapHorizonEllipseView.panelWidth)
        #expect(semiSize.height == MinimapHorizonEllipseView.panelHeight)
        #expect(semiSize.width == 620)
        #expect(semiSize.height == 168)

        let dialSize = controller.panelSize(for: .circularDial)
        #expect(dialSize.width == 300)
        #expect(dialSize.height == 300)

        let linearSize = controller.panelSize(for: .linearStrip)
        #expect(linearSize.width == MinimapLinearView.panelWidth)
        #expect(linearSize.height == MinimapLinearView.panelHeight)

        controller.reconfigureStyle(.semicircle)
        // Reconfiguring the artwork must never overwrite the persisted preference: the style is
        // the user's choice, and writing it here would leak into the live preference domain.
        let persistedStyle = SettingsStore.shared.hudStyle
        controller.reconfigureStyle(.semicircle)
        #expect(SettingsStore.shared.hudStyle == persistedStyle)
    }

    @Test("Every MinimapHUDStyle design, MagneticSnapTransitionStyle, and WindowInsertionAnimationStyle works end-to-end")
    @MainActor
    func testNewStylesAndTransitions() {
        #expect(MinimapHUDStyle.allCases.count >= 5)
        let controller = MinimapHUDController.shared
        for style in MinimapHUDStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.subtitle.isEmpty)
            #expect(!style.symbol.isEmpty)
            let size = controller.panelSize(for: style)
            #expect(size.width > 0 && size.height > 0)
        }

        for cue in [HudSoundEngine.Cue.magnetLock, .partingInsert, .loopSeam] {
            guard let buf = HudSoundEngine.shared.renderForTesting(cue),
                  let samples = buf.floatChannelData?[0] else {
                Issue.record("Failed to render cue \(cue)")
                continue
            }
            let n = Int(buf.frameLength)
            #expect(n > 0)
            #expect(abs(samples[0]) < 0.02)
            #expect(abs(samples[n - 1]) < 0.02)
        }

        let src = CGRect(x: 100, y: 50, width: 600, height: 800)
        let dst = CGRect(x: 60, y: 50, width: 600, height: 800)
        for style in MagneticSnapTransitionStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.subtitle.isEmpty)
            let mid = MagneticWindowEngine.interpolateMagneticSnap(from: src, to: dst, progress: 0.5, style: style)
            #expect(mid.width == 600)
            let finalFrame = MagneticWindowEngine.interpolateMagneticSnap(from: src, to: dst, progress: 1.0, style: style)
            #expect(finalFrame == dst)
        }

        let w0 = WindowId(pid: 1, rawId: 1)
        let wNew = WindowId(pid: 1, rawId: 2)
        let w2 = WindowId(pid: 1, rawId: 3)
        let cols = [
            WindowColumn(windowIds: [w0], width: 500),
            WindowColumn(windowIds: [wNew], width: 500),
            WindowColumn(windowIds: [w2], width: 500)
        ]
        let targets: [WindowId: CGRect] = [
            w0: CGRect(x: 0, y: 30, width: 500, height: 800),
            wNew: CGRect(x: 500, y: 30, width: 500, height: 800),
            w2: CGRect(x: 1000, y: 30, width: 500, height: 800)
        ]

        for style in [WindowInsertionAnimationStyle.partingWave, .harmonicSlideIn, .bloomExpand] {
            let stepMid = PureStripLayoutEngine.computeInsertionAnimationFrames(
                targetFrames: targets,
                insertedWindowId: wNew,
                insertedColumnIndex: 1,
                columns: cols,
                progress: 0.25,
                style: style
            )
            #expect(stepMid[wNew]!.width < 500)
            #expect(stepMid[w2]!.minX < 1000)

            let stepEnd = PureStripLayoutEngine.computeInsertionAnimationFrames(
                targetFrames: targets,
                insertedWindowId: wNew,
                insertedColumnIndex: 1,
                columns: cols,
                progress: 1.0,
                style: style
            )
            #expect(stepEnd == targets)
        }
    }

    // MARK: - Dial Hit Testing

    @MainActor
    private func makeCrowdedController(columns count: Int) -> MinimapHUDController {
        let controller = MinimapHUDController.shared
        let cols = (0..<count).map { i in
            DialColumnInfo(
                id: UUID(),
                width: 200,
                windowCount: 1,
                title: "Win \(i)",
                appName: "App \(i)",
                bundleIdentifier: "com.test.app\(i)"
            )
        }
        controller.update(
            columns: cols,
            totalStripWidth: CGFloat(count) * 200,
            viewportOffset: 0,
            visibleWidth: 800,
            focusedIndex: 0,
            activeTitle: "Win 0",
            screen: nil,
            gap: 0,
            isSettling: true
        )
        return controller
    }

    @Test("Tick hit-testing snaps to the nearest column when columns are packed tight")
    @MainActor
    func testTickHitSnapsToNearestColumn() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true
        settings.hudStyle = .circularDial

        // Twelve columns put their centres 22.5 degrees apart, well inside the 14 degree
        // tolerance that used to make the first matching column win the hit test.
        let controller = makeCrowdedController(columns: 12)

        let view = HUDHostingView(rootView: AnyView(EmptyView()))
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: MinimapHUDController.panelSide,
            height: MinimapHUDController.panelSide
        )
        view.controller = controller

        for index in [0, 5, 9, 11] {
            let ratio = (Double(index) + 0.5) / 12.0
            let radians = DialGeometry.angle(forStripRatio: ratio) * .pi / 180
            let radius = MinimapHUDController.dialTrackRadius
            // AppKit's y axis points up; DialGeometry measures clockwise with y pointing down.
            let point = CGPoint(
                x: view.bounds.midX + cos(radians) * radius,
                y: view.bounds.midY - sin(radians) * radius
            )
            #expect(view.columnTickHit(at: point) == index)
        }
    }

    @Test("Tick hit-testing rejects the centre well and the space outside the track")
    @MainActor
    func testTickHitRejectsCoreAndRim() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true
        settings.hudStyle = .circularDial

        let controller = makeCrowdedController(columns: 6)
        let view = HUDHostingView(rootView: AnyView(EmptyView()))
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: MinimapHUDController.panelSide,
            height: MinimapHUDController.panelSide
        )
        view.controller = controller

        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        #expect(view.columnTickHit(at: centre) == nil)

        let beyond = CGPoint(x: centre.x, y: centre.y + MinimapHUDController.dialTrackRadius + 40)
        #expect(view.columnTickHit(at: beyond) == nil)

        // Directly on a column's orb is a drag target.
        let targetRadians = DialGeometry.angle(forStripRatio: (3.0 + 0.5) / 6.0) * .pi / 180
        let onOrb = CGPoint(
            x: centre.x + cos(targetRadians) * MinimapHUDController.dialTrackRadius,
            y: centre.y - sin(targetRadians) * MinimapHUDController.dialTrackRadius
        )
        #expect(view.columnTickHit(at: onOrb) == 3)

        // Halfway between two columns (45 degrees apart) is not: the press becomes a scrub,
        // which is what should happen when the pointer is not over any window.
        let between = CGPoint(x: centre.x, y: centre.y + MinimapHUDController.dialTrackRadius)
        #expect(view.columnTickHit(at: between) == nil)
    }

    @Test("A real pointer drag on the half-ellipse orb commits a reorder")
    @MainActor
    func testHorizonEllipsePointerDragReorders() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true
        settings.hudStyle = .semicircle

        let controller = MinimapHUDController.shared
        let columns = (0..<4).map { index in
            DialColumnInfo(
                id: UUID(),
                width: 200,
                windowCount: 1,
                title: "Win \(index)",
                appName: "App \(index)",
                bundleIdentifier: "com.test.drag\(index)"
            )
        }
        controller.update(
            columns: columns,
            totalStripWidth: 800,
            viewportOffset: 0,
            visibleWidth: 800,
            focusedIndex: 0,
            activeTitle: "Win 0",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        let size = NSSize(
            width: MinimapHorizonEllipseView.panelWidth,
            height: MinimapHorizonEllipseView.panelHeight
        )
        let view = HUDHostingView(rootView: AnyView(EmptyView()))
        view.frame = NSRect(origin: .zero, size: size)
        view.controller = controller

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view

        // SwiftUI points are y-down; the hosting view's mouse maths is AppKit y-up.
        func appKitPoint(forRatio ratio: Double) -> CGPoint {
            let p = MinimapHorizonEllipseView.point(for: ratio)
            return CGPoint(x: p.x, y: size.height - p.y)
        }

        let start = appKitPoint(forRatio: 0.125)
        let drop = appKitPoint(forRatio: 0.7)

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        let priorMove = controller.onMoveColumn
        defer { controller.onMoveColumn = priorMove }
        var movedFrom: Int?
        var movedTo: Int?
        controller.onMoveColumn = { from, to in
            movedFrom = from
            movedTo = to
        }

        view.mouseDown(with: event(.leftMouseDown, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, at: drop))
        view.mouseUp(with: event(.leftMouseUp, at: drop))

        #expect(movedFrom == 0)
        #expect(movedTo == 2)
        #expect(controller.interaction == .idle)
        #expect(controller.dragPointer == nil)
    }

    @Test("The half-ellipse readout is not a column or scrub target")
    @MainActor
    func testHorizonEllipseReadoutIsNotInteractive() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true
        settings.hudStyle = .semicircle

        let controller = MinimapHUDController.shared
        let columns = (0..<4).map { index in
            DialColumnInfo(
                id: UUID(),
                width: 200,
                windowCount: 1,
                title: "Win \(index)",
                appName: "App \(index)",
                bundleIdentifier: "com.test.readout\(index)"
            )
        }
        controller.update(
            columns: columns,
            totalStripWidth: 800,
            viewportOffset: 0,
            visibleWidth: 800,
            focusedIndex: 0,
            activeTitle: "Win 0",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        let view = HUDHostingView(rootView: AnyView(EmptyView()))
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: MinimapHorizonEllipseView.panelWidth,
            height: MinimapHorizonEllipseView.panelHeight
        )
        view.controller = controller

        // Centre of the readout capsule (SwiftUI y 142 -> AppKit y 26).
        let readout = CGPoint(x: MinimapHorizonEllipseView.panelWidth / 2.0, y: 26)
        #expect(view.columnTickHit(at: readout) == nil)
        #expect(!view.isTrackHit(at: readout))
    }

    @Test("A real pointer drag on the circular dial orb commits a reorder")
    @MainActor
    func testCircularDialPointerDragReorders() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true
        settings.hudStyle = .circularDial

        let controller = MinimapHUDController.shared
        let columns = (0..<4).map { index in
            DialColumnInfo(
                id: UUID(),
                width: 200,
                windowCount: 1,
                title: "Win \(index)",
                appName: "App \(index)",
                bundleIdentifier: "com.test.dialdrag\(index)"
            )
        }
        controller.update(
            columns: columns,
            totalStripWidth: 800,
            viewportOffset: 0,
            visibleWidth: 800,
            focusedIndex: 0,
            activeTitle: "Win 0",
            screen: nil,
            gap: 0,
            isSettling: true
        )

        let size = NSSize(width: MinimapHUDController.panelSide, height: MinimapHUDController.panelSide)
        let view = HUDHostingView(rootView: AnyView(EmptyView()))
        view.frame = NSRect(origin: .zero, size: size)
        view.controller = controller

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view

        func appKitPoint(forRatio ratio: Double) -> CGPoint {
            let radians = DialGeometry.angle(forStripRatio: ratio) * .pi / 180
            let radius = MinimapHUDController.dialTrackRadius
            return CGPoint(
                x: size.width / 2.0 + cos(radians) * radius,
                y: size.height / 2.0 - sin(radians) * radius
            )
        }

        let start = appKitPoint(forRatio: 0.125)
        let drop = appKitPoint(forRatio: 0.7)

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        let priorMove = controller.onMoveColumn
        defer { controller.onMoveColumn = priorMove }
        var movedFrom: Int?
        var movedTo: Int?
        controller.onMoveColumn = { from, to in
            movedFrom = from
            movedTo = to
        }

        // The real panel path starts with hit-testing. `mouseDown` alone bypasses the flipped
        // hosting-view conversion, which is exactly where the original drag bug lived.
        if let superview = view.superview {
            let superPoint = superview.convert(start, from: nil)
            #expect(view.hitTest(superPoint) === view)
        }

        view.mouseDown(with: event(.leftMouseDown, at: start))
        #expect(view.isFlipped)
        #expect(controller.state.columns.count == 4)
        #expect(view.columnTickHit(at: start) == 0)
        #expect(controller.interaction != .idle)
        view.mouseDragged(with: event(.leftMouseDragged, at: drop))
        #expect(controller.dragPointer != nil)
        #expect(controller.interaction == .dragging(column: 0, insertionIndex: 2))
        view.mouseUp(with: event(.leftMouseUp, at: drop))

        #expect(movedFrom == 0)
        #expect(movedTo == 2)
        #expect(controller.interaction == .idle)
    }

    @Test("Dial radii stay concentric and inside the panel")
    func testDialGeometryIsConcentric() {
        #expect(MinimapHUDController.dialCoreRadius < MinimapHUDController.dialTrackRadius)
        #expect(MinimapHUDController.dialTrackRadius + 16 < MinimapHUDController.dialDiameter / 2)
        #expect(MinimapHUDController.dialDiameter < MinimapHUDController.panelSide)
    }
}
