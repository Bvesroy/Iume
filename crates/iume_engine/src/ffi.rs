//! Stable C ABI for the Swift core.
//!
//! Design rules:
//! * No allocation on the hot path. Column views are assembled in a fixed
//!   stack array; frames are written into a thread-local fixed buffer.
//! * No panics across the boundary. Every index and slice is bounds-checked
//!   before use; `panic = "abort"` is set in release so unwinding can never
//!   reach Swift.
//! * Results that contain pointers are only valid until the next call on the
//!   same thread. Swift copies them out synchronously.

use std::cell::RefCell;

use crate::layout;
use crate::magnetic;
use crate::spring;
use crate::types::{
    CenterMode, ColumnPresentation, EdgeMargins, EngineConfig, FrameBuffer, LayoutMode, Rect,
    StackedEntry, WindowColumn, WindowId, WindowRecord,
};

/// ABI version. Bumped whenever a struct layout changes.
pub const ABI_VERSION: u32 = 1;

// MARK: - C mirror structs

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeWindowId {
    pub pid: i32,
    pub raw_id: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeWindowFlags {
    pub is_floating: u8,
    pub is_minimized: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeWindowRecord {
    pub id: IumeWindowId,
    pub flags: IumeWindowFlags,
    pub frame: IumeRect,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeColumn {
    pub id_start: u32,
    pub id_count: u32,
    pub entry_start: u32,
    pub entry_count: u32,
    pub width: f64,
    pub presentation: u32,
    pub active_window_index: u32,
    pub is_full_width: u8,
    pub saved_pre_full_width_ratio: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeStackedEntry {
    pub id: IumeWindowId,
    pub height_ratio: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeConfig {
    pub window_gap: f64,
    pub margin_top: f64,
    pub margin_bottom: f64,
    pub margin_left: f64,
    pub margin_right: f64,
    pub default_column_width_ratio: f64,
    pub default_minimum_column_width: f64,
    pub off_screen_peek_sliver_width: f64,
    pub center_mode: u32,
    pub layout_mode: u32,
    pub smart_window_margins: u8,
    pub disable_padding_on_builtin: u8,
    pub is_builtin_display: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeFrameOut {
    pub id: IumeWindowId,
    pub frame: IumeRect,
    pub is_parked: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct IumeLayoutResult {
    pub frames: *const IumeFrameOut,
    pub frame_count: u32,
    pub total_strip_width: f64,
    pub target_viewport_offset: f64,
}

impl Default for IumeLayoutResult {
    fn default() -> Self {
        Self {
            frames: std::ptr::null(),
            frame_count: 0,
            total_strip_width: 0.0,
            target_viewport_offset: 0.0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeSnapTarget {
    pub target_offset: f64,
    pub focused_column_index: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeMagneticSnap {
    pub has_value: u8,
    pub snapped_frame: IumeRect,
    pub candidate: IumeWindowId,
    pub has_candidate: u8,
    pub candidate_frame: IumeRect,
    pub edge: u32,
    pub distance: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IumeChainedFrame {
    pub id: IumeWindowId,
    pub frame: IumeRect,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct IumeSpringState {
    pub position: f64,
    pub velocity: f64,
    pub target: f64,
    pub response: f64,
    pub damping_ratio: f64,
}

impl Default for IumeSpringState {
    fn default() -> Self {
        Self {
            position: 0.0,
            velocity: 0.0,
            target: 0.0,
            response: 0.22,
            damping_ratio: 0.92,
        }
    }
}

// MARK: - Conversions

#[inline]
fn wid_from_c(v: IumeWindowId) -> WindowId {
    WindowId::new(v.pid, v.raw_id)
}

#[inline]
fn wid_to_c(v: WindowId) -> IumeWindowId {
    IumeWindowId {
        pid: v.pid,
        raw_id: v.raw_id,
    }
}

#[inline]
fn rect_from_c(v: IumeRect) -> Rect {
    Rect::new(v.x, v.y, v.width, v.height)
}

#[inline]
fn rect_to_c(v: Rect) -> IumeRect {
    IumeRect {
        x: v.x,
        y: v.y,
        width: v.width,
        height: v.height,
    }
}

#[inline]
fn config_from_c(c: &IumeConfig) -> EngineConfig {
    EngineConfig {
        window_gap: c.window_gap,
        margins: EdgeMargins {
            top: c.margin_top,
            bottom: c.margin_bottom,
            left: c.margin_left,
            right: c.margin_right,
        },
        default_column_width_ratio: c.default_column_width_ratio,
        default_minimum_column_width: c.default_minimum_column_width,
        off_screen_peek_sliver_width: c.off_screen_peek_sliver_width,
        center_mode: CenterMode::from_u32(c.center_mode),
        layout_mode: LayoutMode::from_u32(c.layout_mode),
        smart_window_margins: c.smart_window_margins != 0,
        disable_padding_on_builtin: c.disable_padding_on_builtin != 0,
        is_builtin_display: c.is_builtin_display != 0,
    }
}

// MARK: - Thread-local output

thread_local! {
    static FRAMES: RefCell<FrameBuffer> = RefCell::new(FrameBuffer::default());
}

/// Build stack-allocated column views from the flat FFI arrays.
///
/// Returns the number of columns written. Callers must ensure `ids`, `entries`
/// and `columns` are valid for the lifetime of the returned views.
macro_rules! with_column_views {
    ($columns:expr, $count:expr, $ids:expr, $id_count:expr, $entries:expr, $entry_count:expr, $views:ident, $body:block) => {{
        let count = $count as usize;
        if count == 0 || $columns.is_null() {
            return Default::default();
        }

        let ids_len = $id_count as usize;
        let entries_len = $entry_count as usize;

        let cols = unsafe { std::slice::from_raw_parts($columns, count) };
        let ids: &[WindowId] = if ids_len == 0 {
            &[]
        } else if $ids.is_null() {
            return Default::default();
        } else {
            unsafe { std::slice::from_raw_parts($ids as *const WindowId, ids_len) }
        };
        let entries: &[StackedEntry] = if entries_len == 0 {
            &[]
        } else if $entries.is_null() {
            return Default::default();
        } else {
            unsafe { std::slice::from_raw_parts($entries as *const StackedEntry, entries_len) }
        };

        // Fast path: stack array keeps this allocation-free up to 96 columns.
        const STACK_COLUMNS: usize = 96;
        if count <= STACK_COLUMNS {
            let mut $views: [layout::ColumnView<'_>; STACK_COLUMNS] = [layout::ColumnView {
                ids: &[],
                width: 0.0,
                presentation: 0,
                active_window_index: 0,
                entries: &[],
                is_full_width: false,
                saved_pre_full_width_ratio: 0.5,
            }; STACK_COLUMNS];

            for (i, c) in cols.iter().enumerate() {
                let id_start = c.id_start as usize;
                let id_count = c.id_count as usize;
                let entry_start = c.entry_start as usize;
                let entry_count = c.entry_count as usize;
                if id_start + id_count > ids.len() || entry_start + entry_count > entries.len() {
                    return Default::default();
                }
                $views[i] = layout::ColumnView {
                    ids: &ids[id_start..id_start + id_count],
                    width: c.width,
                    presentation: c.presentation,
                    active_window_index: c.active_window_index as usize,
                    entries: &entries[entry_start..entry_start + entry_count],
                    is_full_width: c.is_full_width != 0,
                    saved_pre_full_width_ratio: c.saved_pre_full_width_ratio,
                };
            }

            let $views = &$views[..count];
            $body
        } else {
            let $views: Vec<layout::ColumnView<'_>> = cols
                .iter()
                .map(|c| {
                    let id_start = c.id_start as usize;
                    let id_count = c.id_count as usize;
                    let entry_start = c.entry_start as usize;
                    let entry_count = c.entry_count as usize;
                    layout::ColumnView {
                        ids: &ids[id_start..id_start + id_count],
                        width: c.width,
                        presentation: c.presentation,
                        active_window_index: c.active_window_index as usize,
                        entries: &entries[entry_start..entry_start + entry_count],
                        is_full_width: c.is_full_width != 0,
                        saved_pre_full_width_ratio: c.saved_pre_full_width_ratio,
                    }
                })
                .collect();
            let $views = $views.as_slice();
            $body
        }
    }};
}

macro_rules! with_window_records {
    ($windows:expr, $count:expr, $records:ident, $body:block) => {{
        let count = $count as usize;
        let c_windows: &[IumeWindowRecord] = if count == 0 {
            &[]
        } else if $windows.is_null() {
            return Default::default();
        } else {
            unsafe { std::slice::from_raw_parts($windows, count) }
        };
        const STACK_WINDOWS: usize = 256;
        if count <= STACK_WINDOWS {
            let mut $records: [WindowRecord; STACK_WINDOWS] = [WindowRecord {
                id: WindowId::default(),
                flags: crate::types::WindowFlags::tiled(),
                frame: Rect::default(),
            }; STACK_WINDOWS];
            for (i, w) in c_windows.iter().enumerate() {
                $records[i] = WindowRecord {
                    id: wid_from_c(w.id),
                    flags: crate::types::WindowFlags {
                        is_floating: w.flags.is_floating != 0,
                        is_minimized: w.flags.is_minimized != 0,
                    },
                    frame: rect_from_c(w.frame),
                };
            }
            let $records = &$records[..count];
            $body
        } else {
            let $records: Vec<WindowRecord> = c_windows
                .iter()
                .map(|w| WindowRecord {
                    id: wid_from_c(w.id),
                    flags: crate::types::WindowFlags {
                        is_floating: w.flags.is_floating != 0,
                        is_minimized: w.flags.is_minimized != 0,
                    },
                    frame: rect_from_c(w.frame),
                })
                .collect();
            let $records = $records.as_slice();
            $body
        }
    }};
}

// MARK: - Exported API

#[no_mangle]
pub extern "C" fn iume_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn iume_total_strip_width(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    gap: f64,
) -> f64 {
    if column_count == 0 {
        return 0.0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        { layout::total_strip_width_views(views, gap) }
    )
}

#[no_mangle]
pub extern "C" fn iume_column_offsets(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    gap: f64,
    out: *mut f64,
    out_capacity: u32,
) -> u32 {
    if column_count == 0 || out.is_null() {
        return 0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            let cap = out_capacity as usize;
            let out_slice = unsafe { std::slice::from_raw_parts_mut(out, cap) };
            layout::column_strip_offsets_views(views, gap, out_slice) as u32
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_max_scroll_offset(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    visible_width: f64,
    center_mode: u32,
    gap: f64,
) -> f64 {
    if column_count == 0 {
        return 0.0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            layout::max_scroll_offset_views(
                views,
                visible_width,
                CenterMode::from_u32(center_mode),
                gap,
            )
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_compute_viewport_offset(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    focused_column: i32,
    current_offset: f64,
    visible_width: f64,
    layout_mode: u32,
    center_mode: u32,
    gap: f64,
) -> f64 {
    if column_count == 0 {
        return 0.0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            let focused = if focused_column < 0 {
                None
            } else {
                Some(focused_column as usize)
            };
            layout::compute_viewport_offset_views(
                views,
                focused,
                current_offset,
                visible_width,
                LayoutMode::from_u32(layout_mode),
                CenterMode::from_u32(center_mode),
                gap,
            )
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_compute_layout(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    windows: *const IumeWindowRecord,
    window_count: u32,
    focused_column: i32,
    visible_frame: IumeRect,
    viewport_offset: f64,
    config: *const IumeConfig,
) -> IumeLayoutResult {
    if columns.is_null() || config.is_null() {
        return IumeLayoutResult::default();
    }
    let cfg = unsafe { config_from_c(&*config) };

    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            with_window_records!(windows, window_count, records, {
                let focused = if focused_column < 0 {
                    None
                } else {
                    Some(focused_column as usize)
                };

                FRAMES.with(|cell| {
                    let mut buf = cell.borrow_mut();
                    layout::compute_layout_views(
                        views,
                        records,
                        focused,
                        rect_from_c(visible_frame),
                        viewport_offset,
                        &cfg,
                        &mut buf,
                    );

                    let frames_ptr = buf.frames.as_ptr() as *const IumeFrameOut;
                    IumeLayoutResult {
                        frames: frames_ptr,
                        frame_count: buf.len as u32,
                        total_strip_width: buf.total_strip_width,
                        target_viewport_offset: buf.target_viewport_offset,
                    }
                })
            })
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_compute_snap_target(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    projected_offset: f64,
    velocity: f64,
    visible_width: f64,
    center_mode: u32,
    gap: f64,
) -> IumeSnapTarget {
    if column_count == 0 {
        return IumeSnapTarget::default();
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            // Materialise owned columns only for the snap call; it is a
            // settle-time path, not a per-frame one.
            let owned: Vec<WindowColumn> = views
                .iter()
                .map(|v| {
                    let mut col = WindowColumn::new(v.ids.to_vec(), v.width);
                    col.presentation = match v.presentation {
                        1 => ColumnPresentation::Tabbed,
                        _ => ColumnPresentation::Stacked,
                    };
                    col.active_window_index = v.active_window_index;
                    col.entries = v.entries.to_vec();
                    col.is_full_width = v.is_full_width;
                    col.saved_pre_full_width_ratio = v.saved_pre_full_width_ratio;
                    col
                })
                .collect();

            let target = layout::compute_snap_target(
                projected_offset,
                velocity,
                &owned,
                visible_width,
                CenterMode::from_u32(center_mode),
                gap,
            );
            IumeSnapTarget {
                target_offset: target.target_offset,
                focused_column_index: target.focused_column_index as u32,
            }
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_find_closest_column(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    viewport_offset: f64,
    visible_width: f64,
    gap: f64,
) -> u32 {
    if column_count == 0 {
        return 0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            let owned: Vec<WindowColumn> = views
                .iter()
                .map(|v| WindowColumn::new(v.ids.to_vec(), v.width))
                .collect();
            layout::find_closest_column_index(viewport_offset, &owned, visible_width, gap) as u32
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_center_column_offset(
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    column_index: u32,
    visible_width: f64,
    gap: f64,
) -> f64 {
    if column_count == 0 {
        return 0.0;
    }
    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            let owned: Vec<WindowColumn> = views
                .iter()
                .map(|v| WindowColumn::new(v.ids.to_vec(), v.width))
                .collect();
            layout::center_column_offset(column_index as usize, &owned, visible_width, gap)
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_snap_seam_ratio(combined_width: f64, target_width: f64, snap_radius: f64) -> f64 {
    magnetic::snap_seam_ratio(combined_width, target_width, snap_radius)
}

#[no_mangle]
pub extern "C" fn iume_evaluate_magnetic_snap(
    dragged_id: IumeWindowId,
    dragged_frame: IumeRect,
    candidates: *const IumeWindowRecord,
    candidate_count: u32,
    gap: f64,
    visible_frame: *const IumeRect,
    snap_radius: f64,
) -> IumeMagneticSnap {
    let count = candidate_count as usize;
    let candidates_slice = if count == 0 || candidates.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(candidates, count) }
    };

    let mut records: Vec<WindowRecord> = Vec::with_capacity(count.min(256));
    for c in candidates_slice.iter().take(256) {
        records.push(WindowRecord {
            id: wid_from_c(c.id),
            flags: crate::types::WindowFlags {
                is_floating: c.flags.is_floating != 0,
                is_minimized: c.flags.is_minimized != 0,
            },
            frame: rect_from_c(c.frame),
        });
    }

    let visible = if visible_frame.is_null() {
        None
    } else {
        Some(rect_from_c(unsafe { *visible_frame }))
    };

    let snap = magnetic::evaluate_magnetic_snap(
        wid_from_c(dragged_id),
        rect_from_c(dragged_frame),
        &records,
        gap,
        visible,
        snap_radius,
    );

    IumeMagneticSnap {
        has_value: if snap.has_value { 1 } else { 0 },
        snapped_frame: rect_to_c(snap.snapped_frame),
        candidate: wid_to_c(snap.candidate),
        has_candidate: if snap.has_candidate { 1 } else { 0 },
        candidate_frame: rect_to_c(snap.candidate_frame),
        edge: snap.edge,
        distance: snap.distance,
    }
}

#[no_mangle]
pub extern "C" fn iume_compute_chained_frames(
    dragged_id: IumeWindowId,
    dragged_frame: IumeRect,
    columns: *const IumeColumn,
    column_count: u32,
    ids: *const IumeWindowId,
    id_count: u32,
    entries: *const IumeStackedEntry,
    entry_count: u32,
    windows: *const IumeWindowRecord,
    window_count: u32,
    gap: f64,
    breakaway_threshold: f64,
    out: *mut IumeChainedFrame,
    out_capacity: u32,
) -> u32 {
    if out.is_null() || out_capacity == 0 {
        return 0;
    }

    with_column_views!(
        columns,
        column_count,
        ids,
        id_count,
        entries,
        entry_count,
        views,
        {
            with_window_records!(windows, window_count, records, {
                let owned: Vec<WindowColumn> = views
                    .iter()
                    .map(|v| {
                        let mut col = WindowColumn::new(v.ids.to_vec(), v.width);
                        col.presentation = match v.presentation {
                            1 => ColumnPresentation::Tabbed,
                            _ => ColumnPresentation::Stacked,
                        };
                        col.active_window_index = v.active_window_index;
                        col.entries = v.entries.to_vec();
                        col
                    })
                    .collect();

                let capacity = out_capacity as usize;
                let mut scratch = vec![
                    magnetic::ChainedFrame {
                        id: WindowId::default(),
                        frame: Rect::default(),
                    };
                    capacity
                ];
                let n = magnetic::compute_chained_neighbor_frames(
                    wid_from_c(dragged_id),
                    rect_from_c(dragged_frame),
                    &owned,
                    records,
                    gap,
                    breakaway_threshold,
                    &mut scratch,
                );

                let out_slice =
                    unsafe { std::slice::from_raw_parts_mut(out, capacity) };
                for i in 0..n.min(capacity) {
                    out_slice[i] = IumeChainedFrame {
                        id: wid_to_c(scratch[i].id),
                        frame: rect_to_c(scratch[i].frame),
                    };
                }
                n as u32
            })
        }
    )
}

#[no_mangle]
pub extern "C" fn iume_spring_step(state: *mut IumeSpringState, dt: f64) {
    if state.is_null() {
        return;
    }
    let s = unsafe { &mut *state };
    let mut spring = spring::SpringState {
        position: s.position,
        velocity: s.velocity,
        target: s.target,
        response: s.response,
        damping_ratio: s.damping_ratio,
    };
    spring.step(dt);
    s.position = spring.position;
    s.velocity = spring.velocity;
}

#[no_mangle]
pub extern "C" fn iume_spring_is_at_rest(state: *const IumeSpringState) -> u8 {
    if state.is_null() {
        return 1;
    }
    let s = unsafe { &*state };
    let spring = spring::SpringState {
        position: s.position,
        velocity: s.velocity,
        target: s.target,
        response: s.response,
        damping_ratio: s.damping_ratio,
    };
    if spring.is_at_rest() {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn iume_smoothing_factor(smoothness: f64, dt: f64) -> f64 {
    spring::smoothing_factor(smoothness, dt)
}

#[no_mangle]
pub extern "C" fn iume_rubber_band(delta: f64, overshoot: f64, limit: f64) -> f64 {
    spring::rubber_band(delta, overshoot, limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c_wid(pid: i32, raw: u64) -> IumeWindowId {
        IumeWindowId { pid, raw_id: raw }
    }

    fn c_rect(x: f64, y: f64, w: f64, h: f64) -> IumeRect {
        IumeRect {
            x,
            y,
            width: w,
            height: h,
        }
    }

    #[test]
    fn layout_ffi_roundtrip() {
        let ids = [c_wid(1, 1), c_wid(1, 2)];
        let entries = [
            IumeStackedEntry {
                id: c_wid(1, 1),
                height_ratio: 0.5,
            },
            IumeStackedEntry {
                id: c_wid(1, 2),
                height_ratio: 0.5,
            },
        ];
        let columns = [IumeColumn {
            id_start: 0,
            id_count: 2,
            entry_start: 0,
            entry_count: 2,
            width: 500.0,
            presentation: 0,
            active_window_index: 0,
            is_full_width: 0,
            saved_pre_full_width_ratio: 0.5,
        }];
        let windows = [IumeWindowRecord {
            id: c_wid(1, 1),
            flags: IumeWindowFlags::default(),
            frame: c_rect(0.0, 0.0, 100.0, 100.0),
        }, IumeWindowRecord {
            id: c_wid(1, 2),
            flags: IumeWindowFlags::default(),
            frame: c_rect(0.0, 0.0, 100.0, 100.0),
        }];
        let config = IumeConfig {
            window_gap: 10.0,
            margin_top: 0.0,
            margin_bottom: 0.0,
            margin_left: 0.0,
            margin_right: 0.0,
            default_column_width_ratio: 0.5,
            default_minimum_column_width: 380.0,
            off_screen_peek_sliver_width: 12.0,
            center_mode: 0,
            layout_mode: 0,
            smart_window_margins: 0,
            disable_padding_on_builtin: 0,
            is_builtin_display: 0,
        };
        let result = iume_compute_layout(
            columns.as_ptr(),
            1,
            ids.as_ptr(),
            2,
            entries.as_ptr(),
            2,
            windows.as_ptr(),
            2,
            0,
            c_rect(0.0, 0.0, 1000.0, 800.0),
            0.0,
            &config,
        );
        assert_eq!(result.frame_count, 2);
        assert_eq!(result.total_strip_width, 500.0);
        assert!(!result.frames.is_null());
        let frames = unsafe { std::slice::from_raw_parts(result.frames, 2) };
        assert_eq!(frames[0].frame.height, 395.0);
        assert_eq!(frames[1].frame.y, 405.0);
    }

    #[test]
    fn spring_ffi_converges() {
        let mut state = IumeSpringState {
            position: 0.0,
            velocity: 0.0,
            target: 500.0,
            response: 0.22,
            damping_ratio: 0.92,
        };
        for _ in 0..200 {
            iume_spring_step(&mut state, 1.0 / 120.0);
        }
        assert_eq!(iume_spring_is_at_rest(&state), 1);
        assert_eq!(state.position, 500.0);
    }

    #[test]
    fn seam_ffi() {
        assert_eq!(iume_snap_seam_ratio(1000.0, 495.0, 18.0), 500.0);
    }
}
