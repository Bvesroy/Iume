# Scroll Lock Policy: Perfect Scrolling Engine Integrity

## 1. Overview
The scrolling physics in Iume have been calibrated and verified by the user to provide "perfect scrolling" across all 5 key physical dimensions:
1. **Inertial Scrolling**: Natural continuation after trackpad finger lift.
2. **Momentum Scrolling**: Release-velocity-driven kinetic gliding.
3. **Deceleration / Friction**: Calibrated exponential and fluid resistance without jarring stops.
4. **Kinetic Scrolling Profiles**: Four distinct deceleration models (`natural`, `viscous`, `highInertia`, `snappy`).
5. **Smooth Scrolling**: Sub-frame interpolation and direct 1:1 touch resampling with zero input lag.

To protect this verified configuration against regressions, unintended changes, or automated external refactoring, all underlying code sections have been cryptographically locked and require password authorization before any modifications can occur.

---

## 2. Locked Sections & Code Map

The following 11 sections across 7 files are locked:

| File | Section ID | Description |
| :--- | :--- | :--- |
| `Sources/IumeCore/Controller/ScrollController.swift` | `stepTracking` | Real-time trackpad event tracking, 1:1 direct touch bypass, and continuous smoothness filter |
| `Sources/IumeCore/Controller/ScrollController.swift` | `stepDeceleration` | Closed-form exponential and aerodynamic drag deceleration physics across the 4 kinetic profiles |
| `Sources/IumeCore/Controller/ScrollController.swift` | `onScrollPhysicalLift` | Trackpad lift phase 4 handling, momentum velocity multiplication, and inertia dispatch |
| `Sources/IumeCore/Models/CoreModels.swift` | `KineticScrollingProfile` | `KineticScrollingProfile` enumeration defining the 4 physics deceleration curves |
| `Sources/IumeCore/Settings/SettingsStore.swift` | `PhysicsSettingsProperties` | SettingsStore physics properties governing deceleration, inertia, momentum multiplier, profiles, and smoothness |
| `Sources/IumeCore/Persistence/SettingsMemoryManager.swift` | `DefaultPhysicsSnapshotValues` | Default durable snapshot parameters for kinetic, inertial, momentum, and smooth scrolling |
| `Sources/IumeCore/Workspace/WorkspaceManager.swift` | `KickstartPhysicsActivation` | Guarantees kickstart activates full inertial, momentum, and smooth scrolling engine |
| `Sources/IumeCore/UI/LaunchHUDController.swift` | `HUDKickstartPhysicsActivation` | LaunchHUD kickstart trigger guaranteeing all 5 scrolling physics dimensions are engaged |
| `Sources/IumeCore/UI/LaunchHUDController.swift` | `HUDScrollingDynamicsCard` | LaunchHUD control card for Inertial, Momentum, Friction, Kinetic Profiles, and Smooth Scrolling |
| `Sources/IumeCore/UI/StatusBarController.swift` | `StatusBarKineticSubmenu` | Menu bar items for Kinetic, Inertial, Momentum, Smooth Scrolling, and Profiles |
| `Sources/IumeCore/UI/StatusBarController.swift` | `StatusBarKineticActions` | Menu bar handlers for toggling Inertial, Momentum, Smooth Scrolling, and switching Kinetic Profiles |

---

## 3. Enforcement Mechanisms

1. **Source Code Markers**:
   Every locked section is demarcated with:
   ```swift
   // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:<id>]
   ...
   // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:<id>]
   ```

2. **Cryptographic Integrity Hash (`.scroll_lock.json`)**:
   Tracks the SHA-256 hash of each enclosed section alongside a PBKDF2-HMAC-SHA256 password hash (200,000 rounds).

3. **Git Pre-Commit Hook (`.git/hooks/pre-commit`)**:
   Runs `python3 tools/scroll_lock.py verify` before any git commit. If an unauthorized edit touches any locked section, the commit is blocked.

4. **Contributor Governance (`.agentrules`)**:
   Instructs all automated tools and contributors to never touch locked sections without prompting the user for the authorization password.

---

## 4. Usage Instructions

### Verify Status
To verify the integrity of all locked sections:
```bash
python3 tools/scroll_lock.py status
python3 tools/scroll_lock.py verify -v
```

### Unlocking to Make Changes
When intentional changes need to be made to scrolling physics:
```bash
python3 tools/scroll_lock.py unlock
# (Prompts for password; grants a 15-minute temporary edit token)
```

### Relocking After Changes
After modifications are complete and verified with the test suite (`bash scripts/audit/run-all-tests.sh`):
```bash
python3 tools/scroll_lock.py relock
```

### Changing the Lock Password
To update or change the lock password:
```bash
python3 tools/scroll_lock.py set-password
```
