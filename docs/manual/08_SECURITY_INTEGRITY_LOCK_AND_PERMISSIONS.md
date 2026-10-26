# Module 08: Security, Integrity Lock & Permissions

## 1. The Scroll Lock Cryptographic Integrity Engine

To ensure that the verified "perfect scrolling" physics engine is permanently protected against accidental regression, unauthorized modification, or automated AI refactoring, Iume incorporates a custom cryptographic integrity guard ([`tools/scroll_lock.py`](file:///Users/bves/projects/Iume/tools/scroll_lock.py)).

```
+─────────────────────────────────────────────────────────────────────────────────────────+
|                             SCROLL LOCK SECURITY ARCHITECTURE                           |
+─────────────────────────────────────────────────────────────────────────────────────────+
        │                                  │                                  │
        ▼                                  ▼                                  ▼
+──────────────────────────+   +──────────────────────────+   +──────────────────────────+
|   Source Code Anchors    |   |  Cryptographic Ledger    |   |  Enforcement Gates       |
|   11 Tagged Code Blocks  |   |  • PBKDF2-HMAC-SHA256    |   |  • Git Pre-Commit Hook   |
|   in 7 Primary Files     |   |  • 200,000 Iterations    |   |  • .agentrules Directives|
|   Standard Comment Bounds|   |  • SHA-256 Section Hashes|   |  • Time-Limited Token    |
+──────────────────────────+   +──────────────────────────+   +──────────────────────────+
```

---

## 2. Inventory of Locked Code Sections

Every locked region is demarcated with standardized boundary comments:
```swift
// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:<id>]
... protected code ...
// [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:<id>]
```

The 11 locked sections span the complete vertical slice of the scrolling engine:

| # | File Path | Section ID | Protected Functionality |
| :-: | :--- | :--- | :--- |
| **1** | [`ScrollController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/ScrollController.swift#L771-L850) | `stepTracking` | 1:1 direct touch bypass, trackpad event smoothing filter, and velocity blending. |
| **2** | [`ScrollController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/ScrollController.swift#L877-L969) | `stepDeceleration` | Closed-form exponential and aerodynamic drag formulas across the 4 kinetic profiles. |
| **3** | [`ScrollController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Controller/ScrollController.swift#L1572-L1595) | `onScrollPhysicalLift` | Phase 4 touch lift sample flush, velocity multiplier scaling, and inertia dispatch. |
| **4** | [`CoreModels.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Models/CoreModels.swift#L729-L766) | `KineticScrollingProfile` | Enumeration defining `.natural`, `.viscous`, `.highInertia`, and `.snappy`. |
| **5** | [`SettingsStore.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Settings/SettingsStore.swift#L223-L268) | `PhysicsSettingsProperties` | `@Published` variables for deceleration, inertia, momentum multiplier, and smoothness. |
| **6** | [`SettingsMemoryManager.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Persistence/SettingsMemoryManager.swift#L38-L49) | `DefaultPhysicsSnapshotValues` | Durable file snapshot defaults enforcing active inertia on initial app startup. |
| **7** | [`WorkspaceManager.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/Workspace/WorkspaceManager.swift#L251-L258) | `KickstartPhysicsActivation` | Guarantees kickstart explicitly arms inertia, momentum, and smooth scrolling. |
| **8** | [`LaunchHUDController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/LaunchHUDController.swift#L86-L94) | `HUDKickstartPhysicsActivation` | LaunchHUD kickstart trigger ensuring all 5 scrolling physics dimensions are engaged. |
| **9** | [`LaunchHUDController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/LaunchHUDController.swift#L328-L476) | `HUDScrollingDynamicsCard` | LaunchHUD control card with live sliders, friction presets, and profile picker. |
| **10** | [`StatusBarController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/StatusBarController.swift#L248-L288) | `StatusBarKineticSubmenu` | Menu bar `🌊 Kinetic & Inertial Scrolling` menu and profile selectors. |
| **11** | [`StatusBarController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/StatusBarController.swift#L427-L457) | `StatusBarKineticActions` | Menu bar handlers toggling inertia, momentum, smooth scrolling, and profiles. |

---

## 3. Cryptographic Hashing & Token Verification

### 3.1 Password Authentication
- **Algorithm**: PBKDF2-HMAC-SHA256.
- **Rounds**: 200,000 iterations.
- **Salt**: 128-bit cryptographically secure pseudorandom salt (`secrets.token_bytes(16)`), serialized to [`.scroll_lock.json`](file:///Users/bves/projects/Iume/.scroll_lock.json).
- **Default Master Password**: `iume-perfect-scrolling-vault`.

### 3.2 Time-Limited Unlock Tokens (`.scroll_lock.token`)
When the correct password is provided via `python3 tools/scroll_lock.py unlock`, the tool issues a temporary session token file valid for **15 minutes** (900 seconds):
- **Structure**:
  ```json
  {
    "issued_at": 1730000000.0,
    "expires_at": 1730000900.0,
    "nonce": "4a7b9c...",
    "signature": "hmac_sha256_signature..."
  }
  ```
- **HMAC Signature**: Signed with a persistent `token_secret` stored in `.scroll_lock.json`.
- **Git Ignored**: `.scroll_lock.token` is listed in [`.gitignore`](file:///Users/bves/projects/Iume/.gitignore) to ensure credentials and active bypass sessions are never committed to version control.

### 3.3 Git Pre-Commit Hook Enforcement
The pre-commit hook ([`.git/hooks/pre-commit`](file:///Users/bves/projects/Iume/.git/hooks/pre-commit)) executes `python3 tools/scroll_lock.py verify` before every git commit:
- If all 11 locked sections match their recorded SHA-256 hashes OR if an unexpired `.scroll_lock.token` exists, the commit proceeds.
- If any section was modified without authorization, the commit is aborted immediately with an explicit error detailing which section was tampered with.

---

## 4. macOS TCC Security & Accessibility Permissions

### 4.1 Required Entitlements & Permissions
macOS Transparency, Consent, and Control (TCC) strictly regulates application access to external windows:
1. **Accessibility (`kTCCServiceAccessibility`)**: Required for `AXUIElementSetAttributeValue` (repositioning windows) and `AXObserver` (event tap).
2. **No Input Monitoring Required**: Because Iume registers global shortcuts via Carbon `RegisterEventHotKey`, it does **not** require the invasive `kTCCServiceListenEvent` permission.

### 4.2 The Code-Signing Trap & Persistent Identity
A frequent flaw in macOS window manager development is **Ad-Hoc Signing (`codesign -s -`)**:
- An ad-hoc signed binary computes a new `cdhash` on every single build.
- macOS TCC identifies authorized applications by their `(Bundle ID + cdhash / designated requirement)`.
- Rebuilding an ad-hoc signed app causes TCC to treat each build as an unknown new app, prompting the user repeatedly for Accessibility permissions on every launch.

#### Iume's Solution:
1. Builds are signed with a persistent local code-signing identity: **`Iume Local Signer`** (or a Developer ID Application certificate).
2. The designated requirement matches the persistent certificate subject, preserving TCC grants permanently across local debug and release builds.
3. Hardened runtime entitlements ([`Resources/Iume.entitlements`](file:///Users/bves/projects/Iume/Resources/Iume.entitlements)):
   - `com.apple.security.cs.allow-jit`: Enables high-speed Swift closure execution.
   - `com.apple.security.cs.allow-unsigned-executable-memory`: Required by Swift concurrency runtimes on Apple Silicon.
   - `com.apple.security.cs.disable-library-validation`: Permits dynamic loading of private SkyLight and Multitouch frameworks.

### 4.3 Single-Prompt Onboarding Policy
In strict compliance with macOS HIG, Iume never displays unprompted system permission popups on launch. Instead:
- If Accessibility is missing, a non-activating onboarding card is shown.
- The system authorization prompt is triggered **only** when the user explicitly clicks the "Grant Permission" or "Kickstart" button.
