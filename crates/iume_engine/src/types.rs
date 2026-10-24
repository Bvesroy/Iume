//! Core value types shared by every Iume engine module.
//!
//! These mirror the Swift `WindowId`, `WindowColumn`, `EdgeMargins` and
//! `DisplayGeometry` types one-for-one so the FFI layer can translate without
//! lossy conversions.

/// Stable identifier for a managed window (`pid` + raw `CGWindowID`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct WindowId {
    pub pid: i32,
    pub raw_id: u64,
}

impl WindowId {
    #[inline]
    pub const fn new(pid: i32, raw_id: u64) -> Self {
        Self { pid, raw_id }
    }
}

/// Vertical weight of one window inside a stacked column.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct StackedEntry {
    pub id: WindowId,
    pub height_ratio: f64,
}

/// Presentation mode for a column.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum ColumnPresentation {
    Stacked = 0,
    Tabbed = 1,
}

/// One column on the horizontal strip.
#[derive(Clone, Debug, PartialEq)]
pub struct WindowColumn {
    pub ids: Vec<WindowId>,
    pub width: f64,
    pub presentation: ColumnPresentation,
    pub active_window_index: usize,
    pub entries: Vec<StackedEntry>,
    pub is_full_width: bool,
    pub saved_pre_full_width_ratio: f64,
}

impl WindowColumn {
    pub fn new(ids: Vec<WindowId>, width: f64) -> Self {
        let entries = ids
            .iter()
            .map(|id| StackedEntry {
                id: *id,
                height_ratio: 0.5,
            })
            .collect();
        Self {
            ids,
            width,
            presentation: ColumnPresentation::Stacked,
            active_window_index: 0,
            entries,
            is_full_width: false,
            saved_pre_full_width_ratio: 0.5,
        }
    }

    #[inline]
    pub fn height_ratio_for(&self, id: WindowId) -> f64 {
        self.entries
            .iter()
            .find(|e| e.id == id)
            .map(|e| e.height_ratio)
            .unwrap_or(0.5)
    }
}

/// Outer margins around the strip. Mirrors `EdgeMargins`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct EdgeMargins {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

impl EdgeMargins {
    pub const ZERO: Self = Self {
        top: 0.0,
        bottom: 0.0,
        left: 0.0,
        right: 0.0,
    };
}

/// Rectangle in screen coordinates (origin bottom-left, like `CGRect`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    #[inline]
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    #[inline]
    pub fn min_x(&self) -> f64 {
        self.x
    }
    #[inline]
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    #[inline]
    pub fn min_y(&self) -> f64 {
        self.y
    }
    #[inline]
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    #[inline]
    pub fn mid_y(&self) -> f64 {
        self.y + self.height * 0.5
    }
    #[inline]
    pub fn intersects(&self, other: &Rect) -> bool {
        self.min_x() < other.max_x()
            && other.min_x() < self.max_x()
            && self.min_y() < other.max_y()
            && other.min_y() < self.max_y()
    }
}

/// Visibility state of a managed window, needed to skip floating/minimized ones.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct WindowFlags {
    pub is_floating: bool,
    pub is_minimized: bool,
}

impl WindowFlags {
    #[inline]
    pub const fn tiled() -> Self {
        Self {
            is_floating: false,
            is_minimized: false,
        }
    }
    #[inline]
    pub fn is_tiled(&self) -> bool {
        !self.is_floating && !self.is_minimized
    }
}

/// Window record consumed by the layout engine. Only fields the math needs.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct WindowRecord {
    pub id: WindowId,
    pub flags: WindowFlags,
    pub frame: Rect,
}

/// Physical display geometry.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct DisplayGeometry {
    pub id: u32,
    pub frame: Rect,
    pub visible_frame: Rect,
    pub is_primary: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum CenterMode {
    Never = 0,
    OnOverflow = 1,
    Always = 2,
}

impl CenterMode {
    pub fn from_u32(v: u32) -> Self {
        match v {
            2 => CenterMode::Always,
            1 => CenterMode::OnOverflow,
            _ => CenterMode::Never,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum LayoutMode {
    ScrollStrip = 0,
    FocusColumn = 1,
    CenteredFocus = 2,
    ManualLayout = 3,
}

impl LayoutMode {
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => LayoutMode::FocusColumn,
            2 => LayoutMode::CenteredFocus,
            3 => LayoutMode::ManualLayout,
            _ => LayoutMode::ScrollStrip,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum InsertionPolicy {
    AfterFocused = 0,
    AtEnd = 1,
    InCurrentColumn = 2,
}

impl InsertionPolicy {
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => InsertionPolicy::AtEnd,
            2 => InsertionPolicy::InCurrentColumn,
            _ => InsertionPolicy::AfterFocused,
        }
    }
}

/// Engine configuration mirroring the tunables on Swift `LayoutEngine`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct EngineConfig {
    pub window_gap: f64,
    pub margins: EdgeMargins,
    pub default_column_width_ratio: f64,
    pub default_minimum_column_width: f64,
    pub off_screen_peek_sliver_width: f64,
    pub center_mode: CenterMode,
    pub layout_mode: LayoutMode,
    /// Collapse outer margins when a single window is on the strip.
    pub smart_window_margins: bool,
    /// Collapse outer margins on the built-in display.
    pub disable_padding_on_builtin: bool,
    /// True when the target display is the built-in panel.
    pub is_builtin_display: bool,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            window_gap: 0.0,
            margins: EdgeMargins::ZERO,
            default_column_width_ratio: 0.5,
            default_minimum_column_width: 380.0,
            off_screen_peek_sliver_width: 12.0,
            center_mode: CenterMode::Never,
            layout_mode: LayoutMode::ScrollStrip,
            smart_window_margins: false,
            disable_padding_on_builtin: false,
            is_builtin_display: false,
        }
    }
}

/// One computed window frame. Flat output keeps the hot loop allocation-free.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct FrameOut {
    pub id: WindowId,
    pub frame: Rect,
    pub is_parked: u8,
}

/// Maximum number of frames the FFI buffer accepts in one call.
pub const MAX_FRAMES: usize = 512;

/// Fixed-capacity frame buffer used across the C ABI. No heap allocation.
#[derive(Clone, Copy, Debug)]
pub struct FrameBuffer {
    pub frames: [FrameOut; MAX_FRAMES],
    pub len: usize,
    pub total_strip_width: f64,
    pub target_viewport_offset: f64,
    pub overflowed: bool,
}

impl Default for FrameBuffer {
    fn default() -> Self {
        Self {
            frames: [FrameOut {
                id: WindowId::default(),
                frame: Rect::default(),
                is_parked: 0,
            }; MAX_FRAMES],
            len: 0,
            total_strip_width: 0.0,
            target_viewport_offset: 0.0,
            overflowed: false,
        }
    }
}

impl FrameBuffer {
    #[inline]
    pub fn push(&mut self, id: WindowId, frame: Rect, is_parked: bool) {
        if self.len < MAX_FRAMES {
            self.frames[self.len] = FrameOut {
                id,
                frame,
                is_parked: if is_parked { 1 } else { 0 },
            };
            self.len += 1;
        } else {
            self.overflowed = true;
        }
    }

    #[inline]
    pub fn as_slice(&self) -> &[FrameOut] {
        &self.frames[..self.len]
    }

    #[inline]
    pub fn clear(&mut self) {
        self.len = 0;
        self.total_strip_width = 0.0;
        self.target_viewport_offset = 0.0;
        self.overflowed = false;
    }
}

/// Snap target returned by the viewport module.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct SnapTarget {
    pub target_offset: f64,
    pub focused_column_index: usize,
}

/// Magnetic snap result. `has_value == false` means no snap.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct MagneticSnap {
    pub has_value: bool,
    pub snapped_frame: Rect,
    pub candidate: WindowId,
    pub has_candidate: bool,
    pub candidate_frame: Rect,
    pub edge: u32,
    pub distance: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn column_entries_sync_with_ids() {
        let a = WindowId::new(1, 1);
        let b = WindowId::new(1, 2);
        let col = WindowColumn::new(vec![a, b], 500.0);
        assert_eq!(col.entries.len(), 2);
        assert_eq!(col.height_ratio_for(a), 0.5);
    }

    #[test]
    fn rect_helpers() {
        let r = Rect::new(10.0, 20.0, 100.0, 50.0);
        assert_eq!(r.max_x(), 110.0);
        assert_eq!(r.max_y(), 70.0);
        assert_eq!(r.mid_y(), 45.0);
    }

    #[test]
    fn frame_buffer_capacity() {
        let mut buf = FrameBuffer::default();
        for i in 0..MAX_FRAMES {
            buf.push(WindowId::new(1, i as u64), Rect::default(), false);
        }
        assert!(!buf.overflowed);
        buf.push(WindowId::new(1, 9999), Rect::default(), false);
        assert!(buf.overflowed);
        assert_eq!(buf.as_slice().len(), MAX_FRAMES);
    }
}
