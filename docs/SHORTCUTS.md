# Keyboard Shortcuts & Navigation Guide

Iume is built for rapid, keyboard-centric navigation inspired by **PaperWM** and **niri**.

---

## 1. Default Keybindings

All shortcuts use the `Option` (`⌥`) modifier key to avoid conflicting with standard macOS application commands (`Command ⌘` / `Control ⌃`):

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| **`⌥ + H`** | **Focus Previous Window** | Moves focus to the column on the left and scrolls the viewport. |
| **`⌥ + L`** | **Focus Next Window** | Moves focus to the column on the right and scrolls the viewport. |
| **`⌥ + K`** | **Focus Window Above** | Navigates upward if multiple windows are vertically stacked in a column. |
| **`⌥ + J`** | **Focus Window Down** | Navigates downward if multiple windows are vertically stacked in a column. |
| **`⌥ + ⇧ + H`** | **Move Column Left** | Reorders the active column one position to the left. |
| **`⌥ + ⇧ + L`** | **Move Column Right** | Reorders the active column one position to the right. |
| **`⌥ + Return`** | **Toggle Zoom / Maximize** | Toggles zoom state of the currently active window. |
| **`⌥ + W`** | **Close Window** | Safely triggers the active window's close action. |
| **`⌥ + Tab`** | **Cycle Windows** | Cycles focus sequentially through all managed windows. |
| **`⌥ + ⇧ + Tab`** | **Cycle Windows Backward**| Cycles focus backwards through managed windows. |
| **`⌥ + ←`** | **Scroll Viewport Left** | Manually scrolls the horizontal viewport to the left. |
| **`⌥ + →`** | **Scroll Viewport Right**| Manually scrolls the horizontal viewport to the right. |

---

## 2. Trackpad and Mouse Navigation

- **Horizontal Trackpad Scroll:** Swipe horizontally with two fingers to pan smoothly across the infinite strip.
- **Natural Scrolling:** Can be configured in **Settings > Navigation** to match your preferred gesture direction.
- **Column Snapping:** When enabled, the viewport smoothly glides and snaps to the nearest column boundary when scrolling stops.

---

## 3. Customization & Conflict Prevention

Keyboard shortcuts in Iume are registered through macOS Carbon `RegisterEventHotKey`, ensuring:
- They trigger instantly even when Iume runs in the background.
- They do not conflict with or consume normal text input.
- They do not require dangerous Input Monitoring permissions.
