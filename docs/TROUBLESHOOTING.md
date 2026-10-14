# Troubleshooting & Diagnostics Guide

## 1. Quick Diagnostic Checklist

If windows are not being managed or shortcuts do not respond:

1. **Verify Accessibility Permission:**
   - Look at the Iume menu bar icon. If a yellow warning appears, open **Settings > Advanced** and check if Accessibility permission is active.
   - If granted but inactive, remove and re-add Iume in **System Settings > Privacy & Security > Accessibility**.

2. **Verify That Management is Enabled:**
   - Check the menu bar item. Ensure it shows **"Iume: Active"**. If disabled, click **"Enable Management"**.

3. **Check Excluded Applications:**
   - Open **Settings > Windows**. If an application's bundle identifier is in the exclusion list, it will float freely and will not be tiled into the strip.

---

## 2. Common Scenarios

### A window is stuck or not resizing
Some legacy or non-standard macOS applications enforce fixed aspect ratios or strict minimum window dimensions (e.g., System Settings, Calculator, or certain third-party utilities). Iume detects the application's minimum allowable size and respects it, ensuring adjacent columns do not overlap.

### An external monitor was disconnected
When an external monitor is disconnected, Iume automatically catches the `didChangeScreenParametersNotification`, migrates all active columns from the disconnected display to your primary display, and re-aligns the strip. No windows are permanently lost off-screen.

### Resetting Preferences
If you ever want to return to default behavior:
1. Open **Settings > Advanced**.
2. Click **"Reset Preferences to Defaults"**.
3. All gaps, column widths, and policies will reset to factory defaults.

### Exporting Diagnostic Reports
When filing an issue or debugging behavior:
1. Open **Settings > Advanced**.
2. Click **"Export Report"**.
3. The complete diagnostic report (including window counts, columns, recent events, and error counts) is automatically copied to your macOS clipboard.
