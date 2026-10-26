import Foundation
import CoreGraphics
import ApplicationServices

// Standalone WindowController and WindowWriter reliability test harness (D05, WP 1 & WP 2).
// Exercises AXTransport injection, error detection, bounded retry policies, latest-wins
// coalescing, and settle verification with read-back and repair without real apps.

private var failures = 0
private var checks = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor
func checkClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 1.0, _ message: String) {
    check(
        abs(actual - expected) <= tolerance,
        "\(message) (actual \(String(format: "%.3f", Double(actual))), expected \(String(format: "%.3f", Double(expected))) ± \(tolerance))"
    )
}

final class MockAXTransport: AXTransport, @unchecked Sendable {
    private let lock = NSLock()
    var setAttributeHandler: ((AXUIElement, CFString, CFTypeRef) -> AXError)?
    var copyAttributeHandler: ((AXUIElement, CFString, inout AnyObject?) -> AXError)?
    var setMessagingTimeoutHandler: ((AXUIElement, Float) -> AXError)?

    var setAttributeCalls: [(element: AXUIElement, attribute: String, value: CFTypeRef)] = []
    var copyAttributeCalls: [(element: AXUIElement, attribute: String)] = []

    func setAttributeValue(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError {
        lock.lock()
        setAttributeCalls.append((element: element, attribute: attribute as String, value: value))
        let handler = setAttributeHandler
        lock.unlock()
        return handler?(element, attribute, value) ?? .success
    }

    func copyAttributeValue(_ element: AXUIElement, attribute: CFString, value: inout AnyObject?) -> AXError {
        lock.lock()
        copyAttributeCalls.append((element: element, attribute: attribute as String))
        let handler = copyAttributeHandler
        lock.unlock()
        return handler?(element, attribute, &value) ?? .success
    }

    func setMessagingTimeout(_ element: AXUIElement, timeoutInSeconds: Float) -> AXError {
        lock.lock()
        let handler = setMessagingTimeoutHandler
        lock.unlock()
        return handler?(element, timeoutInSeconds) ?? .success
    }

    func resetCalls() {
        lock.lock()
        defer { lock.unlock() }
        setAttributeCalls.removeAll()
        copyAttributeCalls.removeAll()
    }
}

@MainActor
func runAllTests() {
    print("Running Window Application Pipeline & AX Reliability Tests (D05)...")

    let dummyElement = AXUIElementCreateApplication(getpid())
    let winId1 = WindowId(pid: 1001, rawId: 1)
    let winId2 = WindowId(pid: 1002, rawId: 2)

    // MARK: - Test 1: Successful Position Write & Verified Cache
    do {
        print("Test 1: Successful position write and verified cache...")
        let mock = MockAXTransport()
        let controller = WindowController(transport: mock)

        let targetPos = CGPoint(x: 200, y: 150)
        controller.setPositionAsync(element: dummyElement, position: targetPos, size: CGSize(width: 800, height: 600), windowId: winId1)

        controller.syncQueue(for: 1001)

        let state = controller.frameState(for: winId1)
        check(state != nil, "State exists for winId1")
        check(state?.desiredFrame?.origin.x == 200, "Desired frame updated")
        check(state?.verifiedFrame?.origin.x == 200, "Verified frame updated on success")
        check(state?.lastWriteResult == .success, "Last write result is success")
        check(state?.consecutiveFailures == 0, "Consecutive failures is 0")
        check(controller.lastAppliedFrame(for: winId1)?.origin.x == 200, "Last applied frame returns verified frame")
    }

    // MARK: - Test 2: Failed Write Invalidates Cache and Does Not Mark Verified
    do {
        print("Test 2: Failed write invalidates cache and avoids false verified state...")
        let mock = MockAXTransport()
        mock.setAttributeHandler = { _, attr, _ in
            if attr == (kAXPositionAttribute as CFString) {
                return .cannotComplete // simulate timeout / failure
            }
            return .success
        }
        let controller = WindowController(transport: mock)

        let targetPos = CGPoint(x: 300, y: 200)
        controller.setPositionAsync(element: dummyElement, position: targetPos, size: CGSize(width: 800, height: 600), windowId: winId1)

        controller.syncQueue(for: 1001)

        let state = controller.frameState(for: winId1)
        check(state != nil, "State exists")
        check(state?.desiredFrame?.origin.x == 300, "Desired frame recorded")
        check(state?.verifiedFrame == nil, "Verified frame NOT set on failure")
        check(state?.lastWriteResult == .cannotComplete, "Last write result is cannotComplete")
        check(state?.consecutiveFailures == 1, "Consecutive failures incremented to 1")
        check(controller.lastAppliedFrame(for: winId1) == nil, "lastAppliedFrame is nil after failure")

        // Now next write for same position should NOT be suppressed as duplicate because previous failed!
        mock.resetCalls()
        mock.setAttributeHandler = { _, _, _ in .success } // now it succeeds

        controller.setPositionAsync(element: dummyElement, position: targetPos, size: CGSize(width: 800, height: 600), windowId: winId1)

        controller.syncQueue(for: 1001)

        let retryState = controller.frameState(for: winId1)
        check(retryState?.verifiedFrame?.origin.x == 300, "Retry succeeded and verified frame updated")
        check(retryState?.lastWriteResult == .success, "Retry marked success")
        check(retryState?.consecutiveFailures == 0, "Consecutive failures reset to 0")
    }

    // MARK: - Test 3: Bounded Retry Policy (Cap at 3 Failures During Motion, Unconditional Settle)
    do {
        print("Test 3: Bounded retry policy (cap at 3 consecutive failures)...")
        let mock = MockAXTransport()
        mock.setAttributeHandler = { _, _, _ in .cannotComplete }
        let controller = WindowController(transport: mock)

        // Attempt 1
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 10, y: 10), windowId: winId1)
        controller.syncQueue(for: 1001)
        check(controller.getConsecutiveFailures(for: winId1) == 1, "Failure count is 1")

        // Attempt 2
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 20, y: 10), windowId: winId1)
        controller.syncQueue(for: 1001)
        check(controller.getConsecutiveFailures(for: winId1) == 2, "Failure count is 2")

        // Attempt 3
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 30, y: 10), windowId: winId1)
        controller.syncQueue(for: 1001)
        check(controller.getConsecutiveFailures(for: winId1) == 3, "Failure count is 3 (max bounded)")

        // Attempt 4 during motion: should be throttled/backed off!
        mock.resetCalls()
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 40, y: 10), windowId: winId1)
        controller.syncQueue(for: 1001)
        check(mock.setAttributeCalls.isEmpty, "Motion write backed off at 3 failures")

        // Settle pass: MUST execute unconditionally despite 3 failures!
        mock.resetCalls()
        mock.setAttributeHandler = { _, _, _ in .success }
        mock.copyAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString) {
                var p = CGPoint(x: 50, y: 10)
                val = AXValueCreate(.cgPoint, &p)
                return .success
            }
            if attr == (kAXSizeAttribute as CFString) {
                var s = CGSize(width: 800, height: 600)
                val = AXValueCreate(.cgSize, &s)
                return .success
            }
            return .success
        }

        controller.settleFrameAsync(element: dummyElement, frame: CGRect(x: 50, y: 10, width: 800, height: 600), windowId: winId1)
        controller.syncQueue(for: 1001)

        check(!mock.setAttributeCalls.isEmpty, "Settle executed unconditionally")
        check(controller.getConsecutiveFailures(for: winId1) == 0, "Consecutive failures reset on settle success")
        check(controller.lastAppliedFrame(for: winId1)?.origin.x == 50, "Verified frame set on settle success")
    }

    // MARK: - Test 4: Latest-Wins Coalescing
    do {
        print("Test 4: Latest-wins coalescing drops intermediate updates...")
        let mock = MockAXTransport()
        let controller = WindowController(transport: mock)

        var writtenOrigins: [CGFloat] = []
        let lock = NSLock()
        mock.setAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString), let axVal = val as! AXValue? {
                var pt = CGPoint.zero
                if AXValueGetValue(axVal, .cgPoint, &pt) {
                    lock.lock()
                    writtenOrigins.append(pt.x)
                    lock.unlock()
                }
            }
            return .success
        }

        // Initialize queue and block it momentarily
        controller.ensureEnhancedUIDisabled(for: 1001)
        let blockSem = DispatchSemaphore(value: 0)

        // Queue a blocking block first
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 10, y: 0), windowId: winId1)
        mock.setAttributeHandler = { _, _, _ in
            _ = blockSem.wait(timeout: .now() + 0.1)
            return .success
        }

        // Rapid succession of updates while queue is processing
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 100, y: 0), windowId: winId1)
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 200, y: 0), windowId: winId1)
        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 300, y: 0), windowId: winId1)

        mock.setAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString), let axVal = val as! AXValue? {
                var pt = CGPoint.zero
                if AXValueGetValue(axVal, .cgPoint, &pt) {
                    lock.lock()
                    writtenOrigins.append(pt.x)
                    lock.unlock()
                }
            }
            return .success
        }

        blockSem.signal()
        controller.syncQueue(for: 1001)

        lock.lock()
        let origins = writtenOrigins
        lock.unlock()

        check(origins.last == 300, "Latest target (300) was applied")
        // Intermediate 200 should have been superseded
        check(!origins.contains(200), "Intermediate frame 200 was skipped by latest-wins")
    }

    // MARK: - Test 5: Destroyed Window Detection
    do {
        print("Test 5: Destroyed window detection invalidates writer and clears cache...")
        let mock = MockAXTransport()
        mock.setAttributeHandler = { _, _, _ in .invalidUIElement }
        let controller = WindowController(transport: mock)

        controller.setPositionAsync(element: dummyElement, position: CGPoint(x: 100, y: 0), windowId: winId1)
        controller.syncQueue(for: 1001)

        // Window should be removed from cache safely
        check(controller.frameState(for: winId1) == nil, "Writer cache cleared on .invalidUIElement")
        check(controller.lastAppliedFrame(for: winId1) == nil, "Last applied frame cleared")
    }

    // MARK: - Test 6: Settle Verification Discrepancy & Bounded Single Repair
    do {
        print("Test 6: Settle verification detects discrepancy and repairs once...")
        let mock = MockAXTransport()
        var readAttempts = 0
        var writeCount = 0

        mock.setAttributeHandler = { _, attr, _ in
            if attr == (kAXPositionAttribute as CFString) {
                writeCount += 1
            }
            return .success
        }

        mock.copyAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString) {
                readAttempts += 1
                // First read has discrepancy: 105 instead of 100 (> 1.0 pt)
                var p = (readAttempts == 1) ? CGPoint(x: 105, y: 0) : CGPoint(x: 100, y: 0)
                val = AXValueCreate(.cgPoint, &p)
                return .success
            }
            if attr == (kAXSizeAttribute as CFString) {
                var s = CGSize(width: 800, height: 600)
                val = AXValueCreate(.cgSize, &s)
                return .success
            }
            return .success
        }

        let controller = WindowController(transport: mock)
        controller.settleFrameAsync(element: dummyElement, frame: CGRect(x: 100, y: 0, width: 800, height: 600), windowId: winId1)
        controller.syncQueue(for: 1001)

        check(readAttempts >= 2, "Read back occurred twice (initial + repaired verification)")
        check(writeCount >= 2, "Repair write occurred upon discrepancy")
        let st = controller.frameState(for: winId1)
        check(st?.verifiedFrame?.origin.x == 100, "Repaired frame verified at 100")
        check(st?.consecutiveFailures == 0, "Consecutive failures is 0 after repair")
        check(IumeSignpost.metrics.snapshot().repairs >= 1, "Signpost metrics tracked repair")
    }

    // MARK: - Test 7: Settle Verification Unresolved Mismatch
    do {
        print("Test 7: Settle verification handles unresolved mismatch (bounded: no infinite repair)...")
        let mock = MockAXTransport()
        var writeCount = 0

        mock.setAttributeHandler = { _, attr, _ in
            if attr == (kAXPositionAttribute as CFString) {
                writeCount += 1
            }
            return .success
        }

        // App rejects position, stays stubbornly at 250
        mock.copyAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString) {
                var p = CGPoint(x: 250, y: 0)
                val = AXValueCreate(.cgPoint, &p)
                return .success
            }
            if attr == (kAXSizeAttribute as CFString) {
                var s = CGSize(width: 800, height: 600)
                val = AXValueCreate(.cgSize, &s)
                return .success
            }
            return .success
        }

        let controller = WindowController(transport: mock)
        controller.settleFrameAsync(element: dummyElement, frame: CGRect(x: 100, y: 0, width: 800, height: 600), windowId: winId1)
        controller.syncQueue(for: 1001)

        let st = controller.frameState(for: winId1)
        check(st?.verifiedFrame == nil, "Verified frame NOT claimed when discrepancy persists")
        check(st?.unverifiedObservedFrame?.origin.x == 250, "Unverified observed frame captures physical state (250)")
        check(st?.lastWriteResult == .failure, "Last write result records failure")
        check(st?.consecutiveFailures == 1, "Consecutive failures incremented")
        check(IumeSignpost.metrics.snapshot().persistentMismatches >= 1, "Signpost metrics tracked persistent mismatch")
    }

    // MARK: - Test 8: Parked Offscreen Windows Settle Alignment
    do {
        print("Test 8: Parked offscreen windows settle alignment...")
        let mock = MockAXTransport()
        mock.copyAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString) {
                var p = CGPoint(x: -200, y: 0)
                val = AXValueCreate(.cgPoint, &p)
                return .success
            }
            if attr == (kAXSizeAttribute as CFString) {
                var s = CGSize(width: 100, height: 600)
                val = AXValueCreate(.cgSize, &s)
                return .success
            }
            return .success
        }

        let controller = WindowController(transport: mock)
        let placement = WindowPlacement(
            windowId: winId2,
            axElement: dummyElement,
            cgWindowID: 2,
            targetFrame: CGRect(x: -200, y: 0, width: 100, height: 600)
        )

        // Pass 1: Settle when window is not yet parked/verified -> should write & verify
        controller.applyStripFrames(
            placements: [placement],
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            focusedWindowId: nil,
            isMoving: false
        )
        controller.syncQueue(for: 1002)

        check(controller.frameState(for: winId2)?.verifiedFrame?.origin.x == -200, "Parked window settled and verified")

        // Pass 2: Settle again with stationary parked window -> 0 redundant IPC calls!
        mock.resetCalls()
        controller.applyStripFrames(
            placements: [placement],
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            focusedWindowId: nil,
            isMoving: false
        )
        controller.syncQueue(for: 1002)

        check(mock.setAttributeCalls.isEmpty, "0 IPC calls for already verified stationary parked window")
    }

    // MARK: - Test 9: Per-PID Queue Isolation
    do {
        print("Test 9: Per-PID queue isolation prevents slow app from blocking another app...")
        let mock = MockAXTransport()
        let controller = WindowController(transport: mock)

        // Pre-create contexts
        controller.ensureEnhancedUIDisabled(for: 1001)
        controller.ensureEnhancedUIDisabled(for: 1002)

        let slowBlocked = DispatchSemaphore(value: 0)

        // Delay PID 1001 in transport
        mock.setAttributeHandler = { el, _, _ in
            var pid: pid_t = 0
            if AXUIElementGetPid(el, &pid) == .success && pid == 1001 {
                _ = slowBlocked.wait(timeout: .now() + 1.0)
            }
            return .success
        }

        // Win1 (PID 1001) is queued and waiting on slowBlocked
        let dummy1001 = AXUIElementCreateApplication(1001)
        let dummy1002 = AXUIElementCreateApplication(1002)

        controller.setPositionAsync(element: dummy1001, position: CGPoint(x: 10, y: 0), windowId: winId1)

        // Win2 (PID 1002) should execute immediately on its own queue!
        final class FastCompletedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _val = false
            func mark() { lock.lock(); _val = true; lock.unlock() }
            var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return _val }
        }
        let box = FastCompletedBox()

        controller.setPositionAsync(element: dummy1002, position: CGPoint(x: 20, y: 0), windowId: winId2)

        let fastThread = Thread {
            controller.syncQueue(for: 1002)
            box.mark()
        }
        fastThread.start()
        Thread.sleep(forTimeInterval: 0.05)

        check(box.isMarked, "PID 1002 completed independently without blocking on PID 1001")
        slowBlocked.signal()
        controller.syncQueue(for: 1001)
    }

    // MARK: - Test 10: Settle Verification for App-Quantized Sizing (e.g. Terminal character cell grid)
    do {
        print("Test 10: Settle verification handles app-quantized sizing (Terminal character grid)...")
        let mock = MockAXTransport()
        final class VerifiedBox: @unchecked Sendable {
            var frame: CGRect?
        }
        let box = VerifiedBox()

        mock.setAttributeHandler = { _, _, _ in .success }
        // Terminal accepts position at 100, but quantizes size to character grid (692x995 instead of 700x1000)
        mock.copyAttributeHandler = { _, attr, val in
            if attr == (kAXPositionAttribute as CFString) {
                var p = CGPoint(x: 100, y: 0)
                val = AXValueCreate(.cgPoint, &p)
                return .success
            }
            if attr == (kAXSizeAttribute as CFString) {
                var s = CGSize(width: 692, height: 995)
                val = AXValueCreate(.cgSize, &s)
                return .success
            }
            return .success
        }

        let controller = WindowController(transport: mock)
        controller.onWindowFrameVerified = { _, frame in
            box.frame = frame
        }

        controller.settleFrameAsync(element: dummyElement, frame: CGRect(x: 100, y: 0, width: 700, height: 1000), windowId: winId1)
        controller.syncQueue(for: 1001)

        let st = controller.frameState(for: winId1)
        check(st?.lastWriteResult == .success, "Last write result is success for quantized window")
        check(st?.consecutiveFailures == 0, "Consecutive failures is 0 for quantized window")
        check(st?.verifiedFrame?.origin.x == 100, "Verified frame origin is 100")
        check(st?.verifiedFrame?.size.width == 692, "Verified frame width captured quantized width (692)")
        check(box.frame?.size.width == 692, "onWindowFrameVerified notified with true quantized frame")
    }

    print("\nSummary: \(checks) checks, \(failures) failures.")
    if failures == 0 {
        print("\nALL D05 WINDOW PIPELINE CHECKS PASSED!\n")
    } else {
        print("\nSOME CHECKS FAILED!\n")
        exit(1)
    }
}

runAllTests()
