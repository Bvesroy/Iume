# Keyboard Shortcuts & Navigation Guide

Iume is built for rapid, keyboard-centric navigation inspired by **PaperWM** and **niri**.

---

## 1. Default Keybindings

All default shortcuts use `Control + Option` (`⌃⌥`) plus the listed key. Optional legacy `Option`-only fallbacks can be enabled in **Settings → Shortcuts**.

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| **`⌃⌥ + H`** / **`⌃⌥ + ←`** | **Focus Previous Window** | Moves focus to the column on the left and scrolls the viewport. |
| **`⌃⌥ + L`** / **`⌃⌥ + →`** | **Focus Next Window** | Moves focus to the column on the right and scrolls the viewport. |
| **`⌃⌥ + K`** / **`⌃⌥ + ↑`** | **Focus Window Above** | Navigates upward if multiple windows are vertically stacked in a column. |
| **`⌃⌥ + J`** / **`⌃⌥ + ↓`** | **Focus Window Down** | Navigates downward if multiple windows are vertically stacked in a column. |
| **`⌃⌥⇧ + H`** / **`⌃⌥⇧ + ←`** | **Move Column Left** | Reorders the active column one position to the left. |
| **`⌃⌥⇧ + L`** / **`⌃⌥⇧ + →`** | **Move Column Right** | Reorders the active column one position to the right. |
| **`⌃⌥ + Return`** / **`⌃⌥ + F`** | **Full Width Column** | Toggles the active column between its current width and full screen width. |
| **`⌃⌥ + W`** | **Close Window** | Safely triggers the active window's close action. |
| **`⌃⌥ + Tab`** | **Cycle Windows / Tabs** | Cycles focus through managed windows. Inside a tab group it switches tabs instead. |
| **`⌃⌥⇧ + Tab`** | **Cycle Backward** | Cycles focus backwards; switches tabs backwards inside a tab group. |
| **`⌃⌥⇧ + T`** | **Toggle Tab vs. Stack** | Toggles the active column between browser tab strip and vertical stack. |
| **`⌃⌥ + T`** | **Tab Same App Windows** | Combines open windows of the active app into a single Chrome-style tab group. |
| **`⌃⌥⌘ + T`** | **Tab All Same-App Windows** | Groups all windows across the workspace by application into tabs. |
| **`⌃⌥⌘ + ]`** / **`⌃⌥⌘ + [`** | **Next / Prev Tab** | Switches between tabs within the focused group. |
| **`⌃⌥⌘ + N`** | **New Tab in Group** | Spawns a new window for the current app and attaches it as a tab. |
| **`⌃⌥⇧ + W`** | **Close Active Tab** | Closes only the active tab's window, leaving the rest of the group alive (locked tabs protected). |
| **`⌃⌥⌘ + D`** | **Detach Active Tab** | Pops the active tab out into its own independent column/window. |
| **`⌃⌥⇧ + U`** | **Ungroup All Tabs** | Explodes the focused group into one independent column per tab. |
| **`⌃⌥⇧ + P`** | **Keep Tab Bar Visible** | Pins the tab bar open, including for single-window groups. |
| **`⌃⌥⌘ + 1–8`** | **Select Tab 1–8** | Activates the tab at position 1 through 8 directly. |
| **`⌃⌥⌘ + 9`** | **Select Last Tab** | Activates the rightmost tab in the active group. |
| **`⌃⌥⇧ + [`** / **`⌃⌥⇧ + ]`** | **Reorder Active Tab** | Moves the active tab left or right within the group strip. |
| **`⌃⌥ + O`** / **`⌥ + O`** | **Strip Overview & Drag-Adjust** | Opens panoramic preview of all apps on the strip with live drag-to-reorder. |

---

## 2. Trackpad and Mouse Navigation

- **Horizontal Trackpad Scroll:** Swipe horizontally with two fingers to pan smoothly across the infinite strip.
- **Chrome-Style Tab Strip:** In multi-window groups, a 28pt floating tab bar sits above the window:
  - **Click Tab:** Instantly switch to that window without losing application state, scroll position, or reloading.
  - **Live Titles & Status:** Browser-style titles update live; dirty indicator (`•`), notification count, and lock icon display status.
  - **Drag to Reorder:** Drag tabs horizontally to reorder with fluid animations.
  - **Drag Out to Detach:** Drag a tab vertically down or out beyond the tear-off threshold to pop it into an independent window.
  - **Drag Window to Group:** Drag any compatible application window over an existing window/column to see a luminous drop preview and combine them into tabs.
  - **Right-Click Context Menu:** Duplicate tab, rename tab, reset title, lock/unlock tab against accidental closure, move left/right, move to other group, detach, close others, close to right, or ungroup.
  - **Interactive Group Pill:** Click `[ Group Name ▾ ]` to rename the group, choose custom color presets, collapse/expand the group, or ungroup all tabs.
  - **Add Tab (+):** Click `+` to spawn a new window, or pick an existing same-app window from the menu.
  - **Close Tab (x):** Click `x` on any tab to close only that individual window. The group collapses cleanly when one tab remains.
  - **Double-Click Tab:** Instantly rename any tab inline with a custom title.
  - **Keep Bar Visible:** Pin a single-window group's bar from the `…` menu (or `⌃⌥⇧P`). Unpinned single-tab groups revert to a normal column.
- **Center Activity Capsule Click:** Click in the middle on the floating Minimap HUD to expand into a panoramic Strip Overview. Drag any app card horizontally to rearrange the strip layout.
- **Natural Scrolling:** Can be configured in **Settings > Navigation** to match your preferred gesture direction.
- **Column Snapping:** When enabled, the viewport smoothly glides and snaps to the nearest column boundary when scrolling stops.

---

## 3. Customization & Conflict Prevention

Keyboard shortcuts in Iume are registered through macOS Carbon `RegisterEventHotKey`, ensuring:
- They trigger instantly even when Iume runs in the background.
- They do not conflict with or consume normal text input.
- They do not require dangerous Input Monitoring permissions.
