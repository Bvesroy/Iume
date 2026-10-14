# macOS Permissions & Security Guide

## 1. Principles

Iume is designed with **Privacy First** and **Minimum Permissions**:
- **No Root Privileges**: Never runs as root or requires sudo.
- **No SIP Disabling**: Fully compatible with System Integrity Protection enabled.
- **No Screen Recording Permission**: Does not capture screens, pixels, or video buffers.
- **No Network / Telemetry**: Operates 100% offline. Zero analytics, zero crash telemetry, zero cloud accounts.
- **No Input Monitoring Permission Required for Core Shortcuts**: Global keyboard shortcuts are registered via standard macOS Carbon APIs (`RegisterEventHotKey`).

---

## 2. Required Permission: Accessibility

### Why is Accessibility required?
Under macOS security architecture, applications cannot inspect, reposition, or resize windows belonging to other applications without user-granted **Accessibility permissions**.

Iume specifically uses Accessibility to:
1. Enumerate top-level application windows (`AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)`).
2. Read window geometry (`kAXPositionAttribute`, `kAXSizeAttribute`).
3. Set window position and size to arrange columns on the horizontal strip.
4. Focus and raise windows when you navigate (`kAXMainAttribute`, `kAXRaiseAction`).
5. Receive notifications when new windows are created or closed (`AXObserver`).

---

## 3. How to Grant Accessibility Permission

### Step 1: Launch Iume
Upon first launch, Iume will detect whether Accessibility permission is granted. If not, a native macOS prompt will appear:

```
"Iume" would like to control this computer using accessibility features.
```

### Step 2: Enable in System Settings
1. Open **System Settings** on your Mac.
2. Navigate to **Privacy & Security** in the sidebar.
3. Select **Accessibility** in the list.
4. Locate **Iume** and toggle the switch to **ON**.
5. If prompted, enter your administrator password or use Touch ID.

---

## 4. Troubleshooting & Revoking

### If Iume is not moving windows after granting permission:
In rare cases following a rebuild or Xcode clean build, macOS may retain a stale code-signature hash for the binary:
1. In **System Settings > Privacy & Security > Accessibility**, select **Iume** and click the **"-"** (minus) button to remove it.
2. Re-launch Iume or run `./scripts/build.sh`.
3. Add Iume back when prompted.

### How to Revoke Permission:
Simply open **System Settings > Privacy & Security > Accessibility**, find **Iume**, and toggle the switch to **OFF** or click the **"-"** button. Iume will immediately cease window-management operations without crashing.
