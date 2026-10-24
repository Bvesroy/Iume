import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import IumeCore

/// The strip re-computes placements on every display-link frame. The stacking order only
/// changes when the window set, its order, or the focused window changes — so an identical
/// repeat must not reach WindowServer at all.
///
/// These tests use window IDs that cannot exist, so the `CGSOrderWindow` calls on the
/// "issued" paths are harmless no-ops.
@Suite("Strip z-order signature cache")
struct ZOrderSignatureTests {

    private func placement(_ cgWindowID: UInt32) -> WindowPlacement {
        WindowPlacement(
            windowId: WindowId(pid: 1, rawId: UInt64(cgWindowID)),
            axElement: AXUIElementCreateSystemWide(),
            cgWindowID: cgWindowID,
            targetFrame: .zero
        )
    }

    /// Returns a live WindowServer connection, or nil when there is no graphical session
    /// (headless CI), in which case `enforceStripZOrder` cannot issue anything.
    private var connection: UInt32? {
        guard let cid = WindowController.cgsDefaultConnection?(), cid != 0 else { return nil }
        return cid
    }

    @Test("An unchanged strip issues one batch and then reuses it")
    func identicalBatchIsSkipped() throws {
        guard let cid = connection else { return }
        let controller = WindowController()
        let visible = [placement(900_001), placement(900_002), placement(900_003)]
        let focused = visible[1].windowId

        #expect(controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: focused))
        #expect(!controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: focused))
        #expect(!controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: focused))
    }

    @Test("A frame change alone does not disturb the cache")
    func frameChangeKeepsCache() throws {
        guard let cid = connection else { return }
        let controller = WindowController()
        let focusedId = WindowId(pid: 1, rawId: 900_002)
        let original = [placement(900_001), placement(900_002)]

        #expect(controller.enforceStripZOrder(cid: cid, visible: original, parked: [], focusedId: focusedId))

        // Same windows, scrolled: different frames, identical stacking.
        let scrolled = [
            WindowPlacement(windowId: focusedId, axElement: AXUIElementCreateSystemWide(), cgWindowID: 900_002, targetFrame: CGRect(x: -480, y: 0, width: 400, height: 600)),
            WindowPlacement(windowId: WindowId(pid: 1, rawId: 900_001), axElement: AXUIElementCreateSystemWide(), cgWindowID: 900_001, targetFrame: CGRect(x: -880, y: 0, width: 400, height: 600)),
        ]
        // Note: reordered set — the strip order genuinely changed here, so this must re-issue.
        #expect(controller.enforceStripZOrder(cid: cid, visible: scrolled, parked: [], focusedId: focusedId))

        // Same order, only frames differ.
        let sameOrderDifferentFrames = [
            WindowPlacement(windowId: WindowId(pid: 1, rawId: 900_001), axElement: AXUIElementCreateSystemWide(), cgWindowID: 900_001, targetFrame: CGRect(x: 40, y: 0, width: 400, height: 600)),
            WindowPlacement(windowId: focusedId, axElement: AXUIElementCreateSystemWide(), cgWindowID: 900_002, targetFrame: CGRect(x: 440, y: 0, width: 400, height: 600)),
        ]
        #expect(controller.enforceStripZOrder(cid: cid, visible: sameOrderDifferentFrames, parked: [], focusedId: focusedId))
        // ...and then it settles again.
        #expect(!controller.enforceStripZOrder(cid: cid, visible: sameOrderDifferentFrames, parked: [], focusedId: focusedId))
    }

    @Test("Focus change re-issues the batch")
    func focusChangeReissues() throws {
        guard let cid = connection else { return }
        let controller = WindowController()
        let visible = [placement(900_011), placement(900_012)]

        #expect(controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: visible[0].windowId))
        #expect(controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: visible[1].windowId))
    }

    @Test("A window becoming parked re-issues the batch")
    func parkingChangeReissues() throws {
        guard let cid = connection else { return }
        let controller = WindowController()
        let stayVisible = [placement(900_021), placement(900_022)]
        let leftBehind = placement(900_023)

        #expect(controller.enforceStripZOrder(cid: cid, visible: stayVisible, parked: [], focusedId: nil))
        #expect(controller.enforceStripZOrder(cid: cid, visible: stayVisible, parked: [leftBehind], focusedId: nil))
        #expect(!controller.enforceStripZOrder(cid: cid, visible: stayVisible, parked: [leftBehind], focusedId: nil))
    }

    @Test("Clearing the frame cache forces the next batch")
    func clearingCacheInvalidates() throws {
        guard let cid = connection else { return }
        let controller = WindowController()
        let visible = [placement(900_031), placement(900_032)]

        #expect(controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: nil))
        #expect(!controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: nil))

        controller.clearFrameCache()

        #expect(controller.enforceStripZOrder(cid: cid, visible: visible, parked: [], focusedId: nil))
    }

    @Test("Without a WindowServer connection nothing is issued")
    func noConnectionIssuesNothing() {
        let controller = WindowController()
        let visible = [placement(900_041)]

        #expect(!controller.enforceStripZOrder(cid: 0, visible: visible, parked: [], focusedId: nil))
        #expect(!controller.enforceStripZOrder(cid: 0, visible: visible, parked: [], focusedId: nil))
    }
}
