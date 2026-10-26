# Module 04: Window Management, Accessibility & AX Pipeline

## 1. Overview of macOS Accessibility Integration

macOS does not provide an open compositor surface API for third-party window managers. Every physical manipulation of a window on screen—querying its frame, repositioning it, changing its size, bringing it to front, or reading its title—must be transacted through the **macOS Accessibility (AX) C-API** (`ApplicationServices.framework`).

Because Accessibility IPC involves synchronous inter-process Remote Procedure Calls (XPC/Mach messages) between Iume and running target applications, naive window managers frequently suffer from stuttering, beachballs, and total lockups when an application is slow, unresponsive, or spinning.

```
+-----------------------------------------------------------------------------------------+
|                                    Iume WindowController                                |
|   WindowFrameState Ledger · Monotonic Generations · Latest-Wins Frame Coalescing        |
+-----------------------------------------------------------------------------------------+
                                           │
                        ┌──────────────────┴──────────────────┐
                        ▼                                     ▼
        +──────────────────────────────+      +──────────────────────────────+
        |   AppAXContext (PID 1420)    |      |   AppAXContext (PID 8931)    |
        |   Terminal.app (Serial Queue)|      |   Xcode.app (Serial Queue)   |
        +──────────────────────────────+      +──────────────────────────────+
                        │                                     │
                        │ AXUIElementSetAttributeValue        │ AXUIElementSetAttributeValue
                        ▼                                     ▼
        +──────────────────────────────+      +──────────────────────────────+
        |  Terminal Mach Message Port  |      |   Xcode Mach Message Port    |
        |  (Instant 0.2ms reply)       |      |   (Slow 45ms reply)          |
        +──────────────────────────────+      +──────────────────────────────+
```

---

## 2. Low-Level System SPI Bindings

[`WindowController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/WindowController.swift) directly binds to macOS private system entry points using Swift's `@_silgen_name`:

```swift
@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID") @discardableResult
public func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

public let kCPSUserGenerated: UInt32 = 0x200
```

### Purpose of Private SPI:
1. `_AXUIElementGetWindow`: Direct extraction of `CGWindowID` from an opaque `AXUIElement` reference. This is orders of magnitude faster than iterating window lists via `CGWindowListCopyWindowInfo`.
2. `GetProcessForPID` & `kCPSUserGenerated`: Enables programmatic process activation and window focusing without triggering macOS focus-stealing prevention alerts or window hopping glitches.

---

## 3. The AX Transport Seam (`AXTransport`)

To allow deterministic unit testing of slow, timing-out, or crashing applications without requiring real external GUI processes, Iume abstracts Accessibility operations behind the [`AXTransport`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/WindowController.swift#L24-L48) protocol:

```swift
public protocol AXTransport: Sendable {
    func setAttributeValue(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError
    func copyAttributeValue(_ element: AXUIElement, attribute: CFString, value: inout AnyObject?) -> AXError
    func setMessagingTimeout(_ element: AXUIElement, timeoutInSeconds: Float) -> AXError
}
```

- **Production**: Uses `SystemAXTransport.shared`, calling `AXUIElementSetAttributeValue` directly.
- **Audit Test Harness**: Injects mock transports to simulate slow apps, destroyed window errors (`kAXErrorInvalidUIElement`), and timed-out IPC channels.

---

## 4. Per-PID Serial Queue Isolation (`AppAXContext`)

Every managed application process identifier (`pid_t`) is allocated an independent, dedicated serial GCD queue:

```swift
public final class AppAXContext: @unchecked Sendable {
    public let pid: pid_t
    public let queue: DispatchQueue
    public let appElement: AXUIElement
    
    public init(pid: pid_t, transport: AXTransport = SystemAXTransport.shared) {
        self.pid = pid
        self.queue = DispatchQueue(label: "com.iume.window-controller.ax.\(pid)", qos: .userInteractive)
        self.appElement = AXUIElementCreateApplication(pid)
        _ = transport.setMessagingTimeout(self.appElement, timeoutInSeconds: 0.15)
    }
}
```

### Critical Resiliency Benefits:
- **Zero Head-of-Line Blocking**: If an Electron app or Java IDE stalls for 500ms handling an event, its serial queue blocks in isolation. Fast applications (Terminal, Safari, Notes) continue moving at 120Hz.
- **Strict Messaging Timeout**: Timeouts are capped at **150ms** via `AXUIElementSetMessagingTimeout`. Iume will never hang waiting for a hung process.

---

## 5. The Window Frame State Machine (`WindowFrameState`)

To coordinate high-speed continuous motion and avoid frame jitter, every window placement is tracked through an explicit state machine:

```swift
public struct WindowFrameState: Sendable, Equatable {
    public var desiredFrame: CGRect?            // Target computed by layout engine
    public var inFlightFrame: CGRect?           // Frame currently being written
    public var generation: UInt64               // Monotonically increasing order counter
    public var verifiedFrame: CGRect?           // Frame successfully acknowledged
    public var unverifiedObservedFrame: CGRect? // Actual frame read from OS
    public var lastWriteResult: AXError?        // Most recent AX status code
    public var consecutiveFailures: Int         // Failure counter (capped at 3)
}
```

### Lifecycle Progression:
1. **Desired**: The layout engine calculates a new position at timestamp $T$.
2. **Coalesced**: If a previous frame is still in-flight on the app's queue, the intermediate target is overwritten. Only the **latest frame** is dispatched to the physical window server.
3. **In-Flight**: The serial queue submits `AXUIElementSetAttributeValue(kAXPositionAttribute)`.
4. **Verified**: The write returns `.success`. The frame is recorded in `verifiedFrame`.
5. **Echo Filtered**: When `kAXWindowMovedNotification` arrives from macOS, Iume matches it against `verifiedFrame` and suppresses it, preventing recursive reflow loops.

---

## 6. Settle Verification & Repair Pipeline

When a dynamic scroll or spring retargeting completes and the strip comes to rest (`settle`), Iume initiates the **Settle Verification Pass**:

1. **Physical Read-Back**: Queries the actual physical window frame using `kAXPositionAttribute` and `kAXSizeAttribute`.
2. **Tolerance Comparison**: Evaluates $|X_{\text{actual}} - X_{\text{expected}}| \le \text{tolerance}$ (default: 1.0 point).
3. **Single Repair Pass**: If a discrepancy is detected, a single bounded repair write is dispatched.
4. **App-Quantized Dimension Awareness**: If the window's origin matches but its size differs (e.g., Terminal character-cell grid truncation), Iume accepts the dimension as verified and records the physical bounds without initiating an infinite repair loop.
5. **Bounded Retry Cap**: Consecutive failures are capped at **3**. After 3 failures, the window is marked stable at its observed frame to avoid thrashing CPU cycles.

---

## 7. Off-Screen Window Parking

Windows that are outside the current viewport are parked off-screen:
- **Desktop Coordinate Translation**: Windows are positioned at coordinates such as $X = -2000\text{ pt}$ or $X = \text{ScreenWidth} + 1500\text{ pt}$.
- **`is_parked` Flag**: Parked windows skip unnecessary redraws and sizing passes during high-speed continuous scrolling.
- **Window Server Order Retention**: Parked windows maintain their internal stacking order (`CGSOrderWindow`), ensuring that when scrolled back into view, they appear instantly without black flashes or rendering artifacts.
