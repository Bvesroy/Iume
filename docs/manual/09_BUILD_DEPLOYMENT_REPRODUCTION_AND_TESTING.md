# Module 09: Build, Deployment, Reproduction & Testing

## 1. System Requirements & Toolchain Prerequisites

To build, test, package, and run Iume from source on a clean macOS workstation, the following prerequisites must be installed:

### Hardware & Operating System
- **Apple Silicon** (M1, M2, M3, M4) or **Intel x86_64** Mac.
- **macOS 14.0 Sonoma**, macOS 15.x Sequoia, or macOS 26.x.

### Software Toolchains
1. **Xcode Command Line Tools** (or full Xcode 15/16):
   ```bash
   xcode-select --install
   ```
2. **Swift 6.0+ Compiler**:
   Verify via terminal:
   ```bash
   swift --version  # swiftlang-6.0+ or Apple Swift version 6.0+
   ```
3. **Rust Toolchain (Cargo 1.75+)**:
   Install via official toolchain installer:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   source "$HOME/.cargo/env"
   cargo --version
   ```

---

## 2. Generating the Persistent Code-Signing Certificate

To prevent macOS TCC from resetting Accessibility permissions on every build, generate a persistent self-signed Code Signing certificate named **`Iume Local Signer`**:

```bash
# Automated certificate creation via terminal:
security create-certificate -a -c "Iume Local Signer" -t "Code Signing" -u -p codesigning
```

Alternatively, via macOS GUI:
1. Open **Keychain Access** (`/Applications/Utilities/Keychain Access.app`).
2. Go to menu: **Keychain Access > Certificate Assistant > Create a Certificate...**
3. Name: `Iume Local Signer`
4. Identity Type: **Self-Signed Root**
5. Certificate Type: **Code Signing**
6. Location: **login** keychain
7. Click **Create** and **Done**.

---

## 3. Step-by-Step Reproduction & Build Guide

### Step 1: Clone Repository
```bash
git clone https://github.com/bves/Iume.git /Users/bves/projects/Iume
cd /Users/bves/projects/Iume
```

### Step 2: Compile the Rust Core Engine (`build-rust.sh`)
The Rust engine must be compiled into a static library before building SwiftPM targets:
```bash
bash scripts/build-rust.sh
```
- Compiles `crates/iume_engine/` in release mode (`--release`).
- Emits static archive: `crates/iume_engine/target/release/libiume_engine.a`.

### Step 3: Build Debug Binary (`build.sh`)
```bash
bash scripts/build.sh
```
- Links `libiume_engine.a` via [`Package.swift`](file:///Users/bves/projects/Iume/Package.swift).
- Emits executable: `.build/debug/Iume`.

### Step 4: Build Release Binary (`build-release.sh`)
```bash
bash scripts/build-release.sh
```
- Emits optimized production binary: `.build/release/Iume`.

### Step 5: Package, Sign, and Install (`package.sh`)
```bash
bash scripts/package.sh
```
This automated pipeline:
1. Assembles the standalone `.app` bundle at `.build/bundle/Iume.app`.
2. Injects [`Resources/Info.plist`](file:///Users/bves/projects/Iume/Resources/Info.plist) and high-resolution [`Resources/AppIcon.icns`](file:///Users/bves/projects/Iume/Resources/AppIcon.icns).
3. Strips quarantine extended attributes (`xattr -cr`).
4. Signs the bundle with `Iume Local Signer` applying hardened runtime entitlements ([`Resources/Iume.entitlements`](file:///Users/bves/projects/Iume/Resources/Iume.entitlements)).
5. Copies cleanly to `/Applications/Iume.app`.
6. Registers the application with macOS LaunchServices (`lsregister -f`).
7. Creates distribution archives:
   - `dist/Iume-macOS.zip`
   - `dist/Iume-macOS.dmg` (with `/Applications` drag-and-drop symlink).

---

## 4. Deterministic Test Suite Gate (413/413 Checks)

Iume includes a unified audit test gate ([`scripts/audit/run-all-tests.sh`](file:///Users/bves/projects/Iume/scripts/audit/run-all-tests.sh)) that runs all verification suites without requiring full Xcode GUI tools:

```bash
bash scripts/audit/run-all-tests.sh
```

```
=================================================================
  Iume Unified Audit Test Gate (Phases 2-5)
  Repository: /Users/bves/projects/Iume
=================================================================

>>> [1/4] Running Layout Suite...
PASS: 95 checks
>>> [1/4] Layout Suite: PASSED

>>> [2/4] Running Physics & Scroll Resampling Suite...
[Test 1] Fuzzing Displacement Ledger Invariant (10,000 steps)...
[Test 2] Rapid Direction Reversals Stress...
[Test 3] Duplicate Lift / Phase 4 Events...
[Test 4] Cancelation (cancelAnimation) Edge Cases...
[Test 5] Gesture Interruption by Keyboard Retargeting & Finger Lift...
[Test 6] Epoch Timeout & Lost-Lift Recovery...
[Test 7] Sub-epsilon Delta Accumulation...
[Test 8] Deceleration / Friction & Momentum Dynamics...
[Test 9] Inertial Scrolling Toggle...
[Test 10] Momentum Velocity Multiplier Scaling...
[Test 11] Kinetic Scrolling Profiles...
[Test 12] Smooth Scrolling Toggle & Dynamics...
PASS: 238 checks
>>> [2/4] Physics Suite: PASSED

>>> [3/4] Running Window Pipeline & AX Reliability Suite...
Summary: 44 checks, 0 failures.
>>> [3/4] Window Pipeline Suite: PASSED

>>> [4/4] Running Rust Engine Parity Suite...
test result: ok. 36 passed; 0 failed; 0 ignored; finished in 0.00s
>>> [4/4] Rust Engine Suite: PASSED

=================================================================
  ALL AUDIT SUITES PASSED (413/413 CHECKS GREEN)!
=================================================================
```

---

## 5. First-Run Launch & Accessibility Authorization

1. Launch the installed application:
   ```bash
   open /Applications/Iume.app
   ```
2. The **Launch HUD** will appear floating on your desktop.
3. If Accessibility permissions have not been granted previously:
   - Click the **"⚠️ Accessibility Required"** button on the HUD.
   - macOS will open **System Settings > Privacy & Security > Accessibility**.
   - Toggle the switch next to **Iume** to **ON**.
4. Click **"Kickstart & Arrange Windows"**:
   - Iume will immediately discover all running open application windows and tile them into an interactive horizontal strip.
