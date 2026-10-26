# Module 05: Scrolling Physics & Trackpad Interaction

## 1. Overview: The 5 Pillars of Iume Scrolling

Iume's trackpad scrolling engine ([`ScrollController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/ScrollController.swift)) is calibrated to deliver verified, fluid physics across **5 fundamental motion behaviors**:

1. **Inertial Scrolling**: Natural continuation of strip motion after fingers break contact with the trackpad glass.
2. **Momentum Scrolling**: Release velocity dynamically dictates the projection distance of the kinetic coast.
3. **Deceleration & Friction**: Continuous exponential and aerodynamic drag that arrests motion smoothly without abrupt stops.
4. **Kinetic Scrolling Profiles**: Four distinct physical models (`.natural`, `.viscous`, `.highInertia`, `.snappy`) tailoring deceleration curves to user preference.
5. **Smooth Scrolling**: Sub-frame low-pass interpolation turning bursty trackpad event packets into smooth 120Hz continuous motion.

```
+-----------------------------------------------------------------------------------------+
|                                    TRACKPAD HARDWARE                                    |
+-----------------------------------------------------------------------------------------+
                                           │
                        ┌──────────────────┴──────────────────┐
                        │ 2-Finger Scroll Gestures            │ 3/4-Finger Multitouch
                        ▼                                     ▼
        +──────────────────────────────+      +──────────────────────────────+
        |   CGEventTap (Head Insert)   |      |  MultitouchSupport Framework |
        |   Intercepts kCGEventScroll  |      |  Centroid tracking callback  |
        +──────────────────────────────+      +──────────────────────────────+
                        │                                     │
                        └──────────────────┬──────────────────┘
                                           ▼
+-----------------------------------------------------------------------------------------+
|                                  ScrollController                                       |
|  Direct Touch Resampling · CADisplayLink (120Hz) · Spring & Deceleration Integrator     |
+-----------------------------------------------------------------------------------------+
        │                                                     │
        │ Direct Physical Contact (Phase 1/2)                 │ Finger Lift (Phase 4)
        ▼                                                     ▼
+──────────────────────────────+              +──────────────────────────────+
|    stepTracking (Direct 1:1) |              |   stepDeceleration (Kinetic) |
|    Zero lag; input paces     |              |   4 Profiles: Natural,       |
|    the motion                |              |   Viscous, HighInertia,      |
+──────────────────────────────+              |   Snappy                     |
                                              +──────────────────────────────+
```

---

## 2. Low-Level Event Interception

### 2.1 CGEventTap (2-Finger Scrolling)
Iume registers a high-priority session event tap (`CGEvent.tapCreate`) at `kCGHeadInsertEventTap` listening for `kCGEventScrollWheel`.
- **Ownership Decision (`shouldInterceptScroll`)**:
  - Checks if user is holding required modifiers (`None`, `⌥ Option`, `⌃ Control`, or `Always`).
  - Distinguishes continuous trackpad scrolls (`event.isContinuous`) from discrete notched mouse wheel clicks.
  - Consumes the event by returning `nil` to prevent target applications underneath from scrolling their own internal text panes while the strip is navigating.

### 2.2 MultitouchSupport (3 & 4-Finger Panning)
For users who prefer dedicated 3 or 4-finger gestures, Iume dynamically loads private symbols from `/System/Library/PrivateFrameworks/MultitouchSupport.framework`:
- `MTRegisterContactFrameCallback`: Receives raw multi-touch contact frames on an independent hardware thread.
- Centroid Calculation: Computes the mean geometric center $(\bar{X}, \bar{Y})$ of active touch points and dispatches deltas directly to `ScrollController`.

---

## 3. Direct Touch Resampling & Smooth Scrolling (`stepTracking`)

Trackpad events arrive in irregular packet bursts (0, 1, or 2 samples per 120Hz display tick). A naive accumulation causes noticeable motion micro-stutter.

```swift
// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepTracking]
private func stepTracking(now: CFTimeInterval, dt: CGFloat, from frameStart: CGFloat) -> Bool {
    ...
    let isDirectTouch = (lastPhase == 1 || lastPhase == 2)
        && lastMomentumPhase == 0
        && (now - lastInputTimestamp) <= 0.12
    let isMacOSMomentum = (lastMomentumPhase == 1 || lastMomentumPhase == 2)
    let smoothness = SettingsStore.shared.scrollSmoothness
    let smoothEnabled = SettingsStore.shared.smoothScrollingEnabled

    if isDirectTouch || isMacOSMomentum || !smoothEnabled || smoothness <= 0.05 {
        // Direct 1:1 manipulation during physical touch or native momentum stream.
        // Zero filter lag; input timestamp paces motion.
        if currentOffset != smoothTargetOffset {
            currentOffset = smoothTargetOffset
        }
    } else {
        // Continuous low-pass interpolation filter:
        let lambda = max(28.0, 35.0 + CGFloat(1.0 - smoothness) * 80.0)
        let factor = 1.0 - exp(-lambda * dt)
        let distance = smoothTargetOffset - currentOffset
        let step = distance * factor
        currentOffset += step
        let frameVelocity = step / max(0.001, dt)
        let alpha = min(0.85, max(0.40, 0.45 + CGFloat(smoothness) * 0.35))
        if dt > 0, frameVelocity.isFinite {
            currentVelocity = (currentVelocity == 0)
                ? frameVelocity
                : (currentVelocity * alpha + frameVelocity * (1.0 - alpha))
        }
        if abs(smoothTargetOffset - currentOffset) < 0.05 {
            currentOffset = smoothTargetOffset
        }
    }
    ...
}
```

### Key Principles:
1. **Direct Touch 1:1 Bypass**: While fingers physically touch the trackpad glass (`lastPhase == 1 || 2`), the smoothing filter is bypassed. The strip follows fingers with zero latency.
2. **Exponential Low-Pass Smoothing**: For discrete wheel events or when smooth scrolling is enabled, motion smoothly interpolates toward `smoothTargetOffset` using factor $1.0 - e^{-\lambda \cdot dt}$.

---

## 4. Kinetic Profiles & Closed-Form Deceleration (`stepDeceleration`)

When fingers lift from the trackpad glass (Phase 4: `Ended`), the engine engages `stepDeceleration` across **4 selectable kinetic profiles**:

```swift
// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepDeceleration]
private func stepDeceleration(dt: CGFloat, from frameStart: CGFloat) -> Bool {
    guard dt > 0 else { return false }
    let settings = SettingsStore.shared
    let rawFriction = CGFloat(settings.scrollDeceleration)
    let baseDecel = min(max(rawFriction, 0.85), 0.995)

    switch settings.kineticScrollingProfile {
    case .natural:
        // Exact exponential decay: v(t) = v0 · k^t, x(t) = x0 + v0 · (k^t − 1) / ln k.
        let perSecond = pow(baseDecel, 60.0)
        decay = pow(perSecond, dt)
        let logDecay = log(perSecond)
        displacement = currentVelocity * (decay - 1.0) / logDecay
        currentVelocity *= decay

    case .viscous:
        // Aerodynamic fluid resistance: dv/dt = -(alpha * v + beta * v * |v|)
        let speed = abs(currentVelocity)
        let linearAlpha = (1.0 - baseDecel) * 60.0
        let quadBeta: CGFloat = 0.00040
        let totalDrag = linearAlpha + quadBeta * speed
        decay = max(0.0, 1.0 - totalDrag * dt)
        displacement = currentVelocity * dt * (1.0 + decay) * 0.5
        currentVelocity *= decay

    case .highInertia:
        // Low friction kinetic glide: extended momentum conservation for sweeping moves
        let effectiveDecel = min(0.996, baseDecel + 0.015)
        let perSecond = pow(effectiveDecel, 60.0)
        decay = pow(perSecond, dt)
        let logDecay = log(perSecond)
        displacement = currentVelocity * (decay - 1.0) / logDecay
        currentVelocity *= decay

    case .snappy:
        // Fast kinetic braking: slightly higher friction with linear arrest below 250 pt/s
        let effectiveDecel = max(0.85, baseDecel - 0.035)
        let perSecond = pow(effectiveDecel, 60.0)
        var snappyDecay = pow(perSecond, dt)
        if abs(currentVelocity) < 250.0 {
            snappyDecay *= max(0.2, 1.0 - 0.35 * (dt * 60.0))
        }
        decay = snappyDecay
        displacement = currentVelocity * dt
        currentVelocity *= decay
    }
    ...
}
```

### Detailed Mathematical Formulations:

#### 1. `.natural` (macOS Native Parity)
Integrates exact closed-form exponential decay independent of frame rate:
$$v(t) = v_0 \cdot k^t$$
$$\Delta x(t) = \int_0^t v_0 k^\tau d\tau = v_0 \frac{k^t - 1}{\ln k}$$
Where $k = \text{baseDecel}^{60}$. Distance covered during a flick remains identical whether rendered at 60 Hz, 120 Hz, or 240 Hz.

#### 2. `.viscous` (Aerodynamic Fluid Resistance)
Employs combined linear and quadratic aerodynamic drag:
$$\frac{dv}{dt} = -(\alpha v + \beta v |v|)$$
Where $\alpha = (1.0 - \text{baseDecel}) \times 60.0$ and $\beta = 0.00040$. High flick speeds encounter aggressive quadratic resistance, arresting violent gestures smoothly before transitioning into soft, viscous low-speed coasting.

#### 3. `.highInertia` (Effortless Multi-Monitor Glide)
Increases decay factor to $k_{\text{eff}} = \min(0.996, \text{baseDecel} + 0.015)$, conserving kinetic energy over long distances for effortless navigation across ultra-wide monitors.

#### 4. `.snappy` (Immediate Linear Braking)
Increases friction and enforces an aggressive linear arrest below $250\text{ pt/s}$, snapping the viewport to a dead stop with zero lingering drift.

---

## 5. Finger Lift Handover & Momentum Multiplier

When the user lifts their fingers from the trackpad:

```swift
// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:onScrollPhysicalLift]
if phase == 4 && momentumPhase == 0 {
    let seamStart = currentOffset
    flushDirectTouch(publish: true, frameStart: seamStart)
    
    let allowInertia = settings.inertialScrolling && settings.momentumScrolling && !settings.freezeOnRelease
    if allowInertia && abs(currentVelocity) > 25 {
        let multiplier = CGFloat(max(0.2, min(3.0, settings.momentumMultiplier)))
        currentVelocity *= multiplier
        beginDeceleration()
    } else if allowInertia {
        // Adaptive grace period (90ms) for macOS trackpad momentum stream to engage
        scheduleMomentumGrace(generation: gestureGeneration, delay: 0.090)
    } else {
        requestSettle()
    }
    return
}
```

1. **Contact Flush**: Flushes the final contact sample so no input distance is discarded.
2. **Velocity Scaling**: Multiplies release velocity by `momentumMultiplier` ($0.5\times$ to $2.5\times$).
3. **Adaptive Momentum Grace Period**: If release velocity is low ($< 25\text{ pt/s}$), grants a 90ms grace period for macOS's native momentum stream to engage before triggering spring settlement.
