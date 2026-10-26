//! Deterministic strip layout math.
//!
//! This is a line-for-line port of `Sources/IumeCore/LayoutEngine/LayoutEngine.swift`.
//! Every branch, rounding rule and clamp matches the Swift implementation so the
//! engine can be swapped in without any visible change. The difference is that
//! this version borrows its inputs and writes into a caller-owned buffer, so a
//! 120 Hz layout pass performs no heap allocation.

use crate::types::{
    CenterMode, EdgeMargins, FrameBuffer, InsertionPolicy, LayoutMode, Rect, SnapTarget,
    StackedEntry, WindowColumn, WindowId, WindowRecord,
};

/// Borrowed, read-only view of a column. Lets the FFI hand over Swift memory
/// without copying.
#[derive(Clone, Copy, Debug)]
pub struct ColumnView<'a> {
    pub ids: &'a [WindowId],
    pub width: f64,
    pub presentation: u32,
    pub active_window_index: usize,
    pub entries: &'a [StackedEntry],
    pub is_full_width: bool,
    pub saved_pre_full_width_ratio: f64,
}

impl<'a> ColumnView<'a> {
    pub fn from_column(col: &'a WindowColumn) -> Self {
        Self {
            ids: &col.ids,
            width: col.width,
            presentation: col.presentation as u32,
            active_window_index: col.active_window_index,
            entries: &col.entries,
            is_full_width: col.is_full_width,
            saved_pre_full_width_ratio: col.saved_pre_full_width_ratio,
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

/// Column strip offsets: X of each column on the infinite strip.
#[inline]
pub fn column_strip_offsets_views(columns: &[ColumnView<'_>], gap: f64, out: &mut [f64]) -> usize {
    let mut cursor = 0.0;
    let n = columns.len().min(out.len());
    for i in 0..n {
        out[i] = cursor;
        cursor += columns[i].width + gap;
    }
    n
}

/// Total strip width including inter-column gaps.
#[inline]
pub fn total_strip_width_views(columns: &[ColumnView<'_>], gap: f64) -> f64 {
    if columns.is_empty() {
        return 0.0;
    }
    let sum: f64 = columns.iter().map(|c| c.width).sum();
    sum + (columns.len() - 1) as f64 * gap
}

/// Total strip width for owned columns (used by tests and mutation helpers).
#[inline]
pub fn total_strip_width(columns: &[WindowColumn], gap: f64) -> f64 {
    if columns.is_empty() {
        return 0.0;
    }
    let sum: f64 = columns.iter().map(|c| c.width).sum();
    sum + (columns.len() - 1) as f64 * gap
}

/// Column strip offsets for owned columns.
pub fn column_strip_offsets(columns: &[WindowColumn], gap: f64) -> Vec<f64> {
    let mut out = vec![0.0; columns.len()];
    let mut cursor = 0.0;
    for (i, col) in columns.iter().enumerate() {
        out[i] = cursor;
        cursor += col.width + gap;
    }
    out
}

/// Maximum allowed viewport offset, including full centering for `.always`.
pub fn max_scroll_offset_views(
    columns: &[ColumnView<'_>],
    visible_width: f64,
    center_mode: CenterMode,
    gap: f64,
) -> f64 {
    if columns.is_empty() {
        return 0.0;
    }
    let total_width = total_strip_width_views(columns, gap);
    let base_max = (total_width - visible_width).max(0.0);
    match center_mode {
        CenterMode::Always => {
            let mut cursor = 0.0;
            let mut last_offset = 0.0;
            let mut last_width = 0.0;
            for col in columns {
                last_offset = cursor;
                last_width = col.width;
                cursor += col.width + gap;
            }
            let last_center = last_offset + last_width / 2.0 - visible_width / 2.0;
            base_max.max(last_center.max(0.0))
        }
        CenterMode::OnOverflow => {
            if total_width > visible_width {
                let mut cursor = 0.0;
                let mut last_offset = 0.0;
                let mut last_width = 0.0;
                for col in columns {
                    last_offset = cursor;
                    last_width = col.width;
                    cursor += col.width + gap;
                }
                let last_center = last_offset + last_width / 2.0 - visible_width / 2.0;
                base_max.max(last_center.max(0.0))
            } else {
                base_max
            }
        }
        _ => base_max,
    }
}

/// Maximum scroll offset for owned columns.
pub fn max_scroll_offset(
    columns: &[WindowColumn],
    visible_width: f64,
    center_mode: CenterMode,
    gap: f64,
) -> f64 {
    if columns.is_empty() {
        return 0.0;
    }
    let total_width = total_strip_width(columns, gap);
    let base_max = (total_width - visible_width).max(0.0);
    match center_mode {
        CenterMode::Always => {
            let offsets = column_strip_offsets(columns, gap);
            if let (Some(last_col), Some(last_offset)) = (columns.last(), offsets.last()) {
                let last_center = *last_offset + last_col.width / 2.0 - visible_width / 2.0;
                return base_max.max(last_center.max(0.0));
            }
            base_max
        }
        CenterMode::OnOverflow => {
            if total_width > visible_width {
                let offsets = column_strip_offsets(columns, gap);
                if let (Some(last_col), Some(last_offset)) = (columns.last(), offsets.last()) {
                    let last_center = *last_offset + last_col.width / 2.0 - visible_width / 2.0;
                    return base_max.max(last_center.max(0.0));
                }
            }
            base_max
        }
        _ => base_max,
    }
}

/// Ideal viewport offset for the focused column under a layout and center mode.
pub fn compute_viewport_offset_views(
    columns: &[ColumnView<'_>],
    focused_column_index: Option<usize>,
    current_viewport_offset: f64,
    visible_width: f64,
    layout_mode: LayoutMode,
    center_mode: CenterMode,
    gap: f64,
) -> f64 {
    if columns.is_empty() {
        return 0.0;
    }
    let max_allowed = max_scroll_offset_views(columns, visible_width, center_mode, gap);

    let focused_idx = match focused_column_index {
        Some(i) if i < columns.len() => i,
        _ => return current_viewport_offset.max(0.0).min(max_allowed),
    };

    let mut cursor = 0.0;
    for col in columns.iter().take(focused_idx) {
        cursor += col.width + gap;
    }
    let col_left = cursor;
    let col_width = columns[focused_idx].width;
    let col_right = col_left + col_width;

    match layout_mode {
        LayoutMode::ScrollStrip => match center_mode {
            CenterMode::Always => {
                let center_target = col_left + col_width / 2.0 - visible_width / 2.0;
                center_target.max(0.0).min(max_allowed)
            }
            CenterMode::OnOverflow => {
                let total_width = total_strip_width_views(columns, gap);
                if total_width <= visible_width {
                    0.0
                } else {
                    let center_target = col_left + col_width / 2.0 - visible_width / 2.0;
                    center_target.max(0.0).min(max_allowed)
                }
            }
            CenterMode::Never => {
                let mut offset = current_viewport_offset;
                if col_left < current_viewport_offset {
                    offset = col_left;
                } else if col_right > current_viewport_offset + visible_width {
                    offset = col_right - visible_width;
                }
                offset.max(0.0).min(max_allowed)
            }
        },
        LayoutMode::FocusColumn => col_left.max(0.0).min(max_allowed),
        LayoutMode::CenteredFocus => {
            let center_target = col_left + col_width / 2.0 - visible_width / 2.0;
            center_target.max(0.0).min(max_allowed)
        }
        LayoutMode::ManualLayout => current_viewport_offset.max(0.0).min(max_allowed),
    }
}

/// Compute every window frame and write it into `out`.
///
/// `windows` is a flat, contiguous array; lookups are linear scans which beat
/// hash maps at the window counts a desktop actually has.
pub fn compute_layout_views(
    columns: &[ColumnView<'_>],
    windows: &[WindowRecord],
    focused_column_index: Option<usize>,
    visible_frame: Rect,
    viewport_offset: f64,
    config: &crate::types::EngineConfig,
    out: &mut FrameBuffer,
) {
    out.clear();
    if columns.is_empty() {
        return;
    }

    let total_managed: usize = columns.iter().map(|c| c.ids.len()).sum();

    let collapse_margins = (config.smart_window_margins && total_managed <= 1)
        || (config.disable_padding_on_builtin && config.is_builtin_display);
    let margins = if collapse_margins {
        EdgeMargins::ZERO
    } else {
        config.margins
    };
    let effective_gap = if config.smart_window_margins && total_managed <= 1 {
        0.0
    } else {
        config.window_gap
    };

    let usable_width = (visible_frame.width - margins.left - margins.right).max(200.0);
    let usable_height = (visible_frame.height - margins.top - margins.bottom).max(100.0);

    let total_width = total_strip_width_views(columns, effective_gap);
    let ideal_viewport = compute_viewport_offset_views(
        columns,
        focused_column_index,
        viewport_offset,
        usable_width,
        config.layout_mode,
        config.center_mode,
        effective_gap,
    );

    let min_visible_x = visible_frame.x + margins.left;
    let max_visible_x = min_visible_x + usable_width;
    let base_origin_y = visible_frame.y + margins.top;

    let sliver = config.off_screen_peek_sliver_width.max(1.0);

    let mut active_strip_x = 0.0;

    for column in columns {
        // Collect the tiled ids of this column, preserving order.
        let mut count = 0usize;
        for id in column.ids {
            if windows
                .iter()
                .any(|w| w.id == *id && w.flags.is_tiled())
            {
                count += 1;
            }
        }
        if count == 0 {
            continue;
        }

        let col_strip_x = active_strip_x;
        let col_width = column.width;
        active_strip_x += col_width + effective_gap;

        let col_screen_x = min_visible_x + col_strip_x - viewport_offset;

        let mut final_screen_x = col_screen_x;
        let mut is_parked = false;

        if col_screen_x + col_width <= min_visible_x + sliver {
            final_screen_x = min_visible_x - col_width + sliver;
            is_parked = true;
        } else if col_screen_x >= max_visible_x - sliver {
            final_screen_x = max_visible_x - sliver;
            is_parked = true;
        }

        if column.presentation == 1 {
            // Tabbed: reserve a 28pt tab bar, park inactive tabs left.
            let tab_bar_height = 28.0;
            let tab_content_y = base_origin_y + tab_bar_height;
            let tab_content_height = (usable_height - tab_bar_height).max(100.0);

            let mut tiled_idx = 0usize;
            for id in column.ids {
                let is_tiled = windows
                    .iter()
                    .any(|w| w.id == *id && w.flags.is_tiled());
                if !is_tiled {
                    continue;
                }
                let is_current_tab = tiled_idx == column.active_window_index;
                let screen_x = if is_current_tab {
                    round_half_away(final_screen_x)
                } else {
                    min_visible_x - col_width + sliver
                };
                let frame = Rect::new(
                    screen_x,
                    round_half_away(tab_content_y),
                    round_half_away(col_width),
                    round_half_away(tab_content_height),
                );
                out.push(*id, frame, is_parked || !is_current_tab);
                tiled_idx += 1;
            }
        } else {
            // Stacked: distribute usable height by ratio.
            let total_vertical_gaps = (count.saturating_sub(1)) as f64 * config.window_gap;
            let available_height = (usable_height - total_vertical_gaps).max(100.0);

            let mut sum_ratios = 0.0;
            for id in column.ids {
                if windows
                    .iter()
                    .any(|w| w.id == *id && w.flags.is_tiled())
                {
                    sum_ratios += column.height_ratio_for(*id);
                }
            }
            let sum_ratios = sum_ratios.max(0.01);

            let mut current_y = base_origin_y;
            let mut row_index = 0usize;
            for id in column.ids {
                let is_tiled = windows
                    .iter()
                    .any(|w| w.id == *id && w.flags.is_tiled());
                if !is_tiled {
                    continue;
                }
                let entry_ratio = column
                    .entries
                    .iter()
                    .find(|e| e.id == *id)
                    .map(|e| e.height_ratio)
                    .unwrap_or(1.0 / count as f64);
                let proportional_height = (available_height * (entry_ratio / sum_ratios)).floor();
                let h = if row_index == count - 1 {
                    ((base_origin_y + usable_height) - current_y).max(100.0)
                } else {
                    proportional_height.max(100.0)
                };
                let frame = Rect::new(
                    round_half_away(final_screen_x),
                    round_half_away(current_y),
                    round_half_away(col_width),
                    round_half_away(h),
                );
                out.push(*id, frame, is_parked);
                current_y += h + config.window_gap;
                row_index += 1;
            }
        }
    }

    out.total_strip_width = total_width;
    out.target_viewport_offset = ideal_viewport;
}

/// Round half away from zero, matching Swift's `round(_:)`.
#[inline]
pub fn round_half_away(v: f64) -> f64 {
    v.round()
}

/// Insert a window into the strip according to the policy. Returns new index.
pub fn insert_window(
    window_id: WindowId,
    columns: &mut Vec<WindowColumn>,
    focused_column_index: Option<usize>,
    policy: InsertionPolicy,
    preferred_width: Option<f64>,
    visible_width: f64,
    margins: EdgeMargins,
    gap: f64,
    default_column_width_ratio: f64,
    default_minimum_column_width: f64,
) -> usize {
    let usable_w = (visible_width - margins.left - margins.right).max(200.0);
    let half_screen_width = ((usable_w - gap) * default_column_width_ratio).floor();
    let width = preferred_width.unwrap_or(default_minimum_column_width.max(half_screen_width));

    match policy {
        InsertionPolicy::AfterFocused => match focused_column_index {
            Some(idx) if idx < columns.len() => {
                columns.insert(idx + 1, WindowColumn::new(vec![window_id], width));
                idx + 1
            }
            _ => {
                columns.push(WindowColumn::new(vec![window_id], width));
                columns.len() - 1
            }
        },
        InsertionPolicy::AtEnd => {
            columns.push(WindowColumn::new(vec![window_id], width));
            columns.len() - 1
        }
        InsertionPolicy::InCurrentColumn => match focused_column_index {
            Some(idx) if idx < columns.len() => {
                columns[idx].ids.push(window_id);
                columns[idx].entries.push(StackedEntry {
                    id: window_id,
                    height_ratio: 0.5,
                });
                idx
            }
            _ => {
                columns.push(WindowColumn::new(vec![window_id], width));
                columns.len() - 1
            }
        },
    }
}

/// Remove a window, pruning empty columns. Returns the new focused index.
pub fn remove_window(
    window_id: WindowId,
    columns: &mut Vec<WindowColumn>,
    current_focused_index: Option<usize>,
) -> Option<usize> {
    let mut target_col_index: Option<usize> = None;
    for (idx, col) in columns.iter_mut().enumerate() {
        if let Some(win_idx) = col.ids.iter().position(|id| *id == window_id) {
            col.ids.remove(win_idx);
            col.entries.retain(|e| e.id != window_id);
            if col.active_window_index >= col.ids.len() && !col.ids.is_empty() {
                col.active_window_index = col.ids.len() - 1;
            }
            target_col_index = Some(idx);
            break;
        }
    }

    columns.retain(|c| !c.ids.is_empty());

    if columns.is_empty() {
        return None;
    }

    if let Some(focused) = current_focused_index {
        if focused >= columns.len() {
            return Some(columns.len() - 1);
        }
        return Some(focused);
    }
    if let Some(target) = target_col_index {
        return Some(target.min(columns.len() - 1));
    }
    Some(0)
}

/// Move a column left or right. Returns its new index.
pub fn move_column(index: usize, direction: i32, columns: &mut Vec<WindowColumn>) -> usize {
    if index >= columns.len() {
        return index;
    }
    let new_index = index as i64 + direction as i64;
    if new_index < 0 || new_index >= columns.len() as i64 {
        return index;
    }
    let col = columns.remove(index);
    columns.insert(new_index as usize, col);
    new_index as usize
}

/// Index of the column whose center is closest to the viewport center.
pub fn find_closest_column_index(
    viewport_offset: f64,
    columns: &[WindowColumn],
    visible_width: f64,
    gap: f64,
) -> usize {
    if columns.is_empty() {
        return 0;
    }
    let offsets = column_strip_offsets(columns, gap);
    let viewport_center = viewport_offset + visible_width / 2.0;
    let mut best_index = 0usize;
    let mut best_distance = f64::INFINITY;
    for (i, col_left) in offsets.iter().enumerate() {
        let col_center = col_left + columns[i].width / 2.0;
        let dist = (col_center - viewport_center).abs();
        if dist < best_distance {
            best_distance = dist;
            best_index = i;
        }
    }
    best_index
}

/// Snap target for a projected offset, honouring flick direction.
pub fn compute_snap_target(
    projected_offset: f64,
    velocity: f64,
    columns: &[WindowColumn],
    visible_width: f64,
    center_mode: CenterMode,
    gap: f64,
) -> SnapTarget {
    if columns.is_empty() {
        return SnapTarget {
            target_offset: 0.0,
            focused_column_index: 0,
        };
    }

    let total_width = total_strip_width(columns, gap);
    let max_allowed = max_scroll_offset(columns, visible_width, center_mode, gap);

    if total_width <= visible_width && center_mode != CenterMode::Always {
        return SnapTarget {
            target_offset: 0.0,
            focused_column_index: 0,
        };
    }

    let offsets = column_strip_offsets(columns, gap);
    let mut candidates: Vec<f64> = vec![0.0, max_allowed];

    match center_mode {
        CenterMode::Always => {
            for (i, col) in columns.iter().enumerate() {
                let center_target = offsets[i] + col.width / 2.0 - visible_width / 2.0;
                candidates.push(center_target.max(0.0).min(max_allowed));
            }
        }
        CenterMode::OnOverflow => {
            if total_width <= visible_width {
                return SnapTarget {
                    target_offset: 0.0,
                    focused_column_index: 0,
                };
            }
            for (i, col) in columns.iter().enumerate() {
                let center_target = offsets[i] + col.width / 2.0 - visible_width / 2.0;
                candidates.push(center_target.max(0.0).min(max_allowed));
            }
        }
        CenterMode::Never => {
            for (i, col) in columns.iter().enumerate() {
                candidates.push(offsets[i].max(0.0).min(max_allowed));
                if col.width > visible_width {
                    let right_snap = offsets[i] + col.width - visible_width;
                    candidates.push(right_snap.max(0.0).min(max_allowed));
                }
            }
        }
    }

    // Deduplicate at half-point precision, then sort.
    for c in candidates.iter_mut() {
        *c = (*c * 2.0).round() / 2.0;
    }
    candidates.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    candidates.dedup_by(|a, b| (*a - *b).abs() < f64::EPSILON);

    let clamped = projected_offset.max(0.0).min(max_allowed);
    let mut chosen = clamped;

    if velocity > 100.0 {
        let forward: Vec<f64> = candidates
            .iter()
            .copied()
            .filter(|c| *c > clamped - 20.0)
            .collect();
        if let Some(best) = forward.iter().copied().find(|c| *c > clamped) {
            chosen = best;
        } else if let Some(first) = forward.first() {
            chosen = *first;
        } else {
            chosen = candidates.last().copied().unwrap_or(max_allowed);
        }
    } else if velocity < -100.0 {
        let backward: Vec<f64> = candidates
            .iter()
            .copied()
            .filter(|c| *c < clamped + 20.0)
            .collect();
        if let Some(best) = backward.iter().rev().copied().find(|c| *c < clamped) {
            chosen = best;
        } else if let Some(last) = backward.last() {
            chosen = *last;
        } else {
            chosen = candidates.first().copied().unwrap_or(0.0);
        }
    } else {
        let mut best_distance = f64::INFINITY;
        for c in &candidates {
            let d = (*c - clamped).abs();
            if d < best_distance {
                best_distance = d;
                chosen = *c;
            }
        }
    }

    // Prominent column = largest visible overlap at the chosen offset.
    let mut best_col_idx = 0usize;
    let mut max_visible_width = -1.0;
    for (i, col) in columns.iter().enumerate() {
        let col_left = offsets[i];
        let col_right = col_left + col.width;
        let vis_left = col_left.max(chosen);
        let vis_right = col_right.min(chosen + visible_width);
        let vis_w = (vis_right - vis_left).max(0.0);
        if vis_w > max_visible_width {
            max_visible_width = vis_w;
            best_col_idx = i;
        }
    }

    SnapTarget {
        target_offset: chosen,
        focused_column_index: best_col_idx,
    }
}

/// Cycle through preset width ratios. Returns the new width.
pub fn cycle_preset_width(
    index: usize,
    columns: &mut [WindowColumn],
    visible_width: f64,
    ratios: &[f64],
    backward: bool,
    default_minimum_column_width: f64,
) -> f64 {
    if index >= columns.len() {
        return 0.0;
    }
    let presets: &[f64] = if ratios.is_empty() {
        &[0.25, 0.333, 0.50, 0.667, 0.75, 1.0]
    } else {
        ratios
    };

    let current_width = columns[index].width;
    let current_ratio = current_width / visible_width.max(1.0);

    let mut next_ratio = presets[0];
    if backward {
        next_ratio = *presets.last().unwrap_or(&0.75);
        for r in presets.iter().rev() {
            if *r < current_ratio - 0.04 {
                next_ratio = *r;
                break;
            }
        }
    } else {
        for r in presets.iter() {
            if *r > current_ratio + 0.04 {
                next_ratio = *r;
                break;
            }
        }
    }

    let new_width = default_minimum_column_width.max((visible_width * next_ratio).round());
    columns[index].width = new_width;
    columns[index].is_full_width = false;
    new_width
}

/// Nudge a column width by a ratio delta. Returns the new width.
pub fn nudge_column_width(
    index: usize,
    columns: &mut [WindowColumn],
    delta_ratio: f64,
    visible_width: f64,
    default_minimum_column_width: f64,
) -> f64 {
    if index >= columns.len() {
        return 0.0;
    }
    let current_ratio = columns[index].width / visible_width.max(1.0);
    let new_ratio = (current_ratio + delta_ratio).clamp(0.15, 1.0);
    let new_width = default_minimum_column_width.max((visible_width * new_ratio).round());
    columns[index].width = new_width;
    columns[index].is_full_width = new_ratio >= 0.99;
    new_width
}

/// Toggle full-width for a column. Returns the new width.
pub fn toggle_full_width(
    index: usize,
    columns: &mut [WindowColumn],
    visible_width: f64,
    default_minimum_column_width: f64,
) -> f64 {
    if index >= columns.len() {
        return 0.0;
    }
    if columns[index].is_full_width {
        let restored = default_minimum_column_width
            .max((visible_width * columns[index].saved_pre_full_width_ratio).round());
        columns[index].width = restored;
        columns[index].is_full_width = false;
        restored
    } else {
        columns[index].saved_pre_full_width_ratio = columns[index].width / visible_width.max(1.0);
        columns[index].width = visible_width;
        columns[index].is_full_width = true;
        visible_width
    }
}

/// Center a column in the viewport. Returns the offset.
pub fn center_column_offset(
    index: usize,
    columns: &[WindowColumn],
    visible_width: f64,
    gap: f64,
) -> f64 {
    if index >= columns.len() {
        return 0.0;
    }
    let offsets = column_strip_offsets(columns, gap);
    let col_left = offsets[index];
    let col_width = columns[index].width;
    let total_width = total_strip_width(columns, gap);
    let max_allowed = (total_width - visible_width).max(0.0);
    let center_target = col_left + col_width / 2.0 - visible_width / 2.0;
    center_target.max(0.0).min(max_allowed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ColumnPresentation, EngineConfig, FrameBuffer, WindowFlags};

    fn cfg(gap: f64) -> EngineConfig {
        EngineConfig {
            window_gap: gap,
            margins: EdgeMargins::ZERO,
            default_column_width_ratio: 0.5,
            default_minimum_column_width: 400.0,
            off_screen_peek_sliver_width: 12.0,
            center_mode: CenterMode::Never,
            layout_mode: LayoutMode::ScrollStrip,
            smart_window_margins: false,
            disable_padding_on_builtin: false,
            is_builtin_display: false,
        }
    }

    fn wid(i: u64) -> WindowId {
        WindowId::new(1, i)
    }

    fn rec(i: u64) -> WindowRecord {
        WindowRecord {
            id: wid(i),
            flags: WindowFlags::tiled(),
            frame: Rect::default(),
        }
    }

    fn owned_views<'a>(cols: &'a [WindowColumn], views: &mut Vec<ColumnView<'a>>) {
        views.clear();
        for c in cols {
            views.push(ColumnView::from_column(c));
        }
    }

    #[test]
    fn total_width_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 400.0),
            WindowColumn::new(vec![wid(2)], 500.0),
            WindowColumn::new(vec![wid(3)], 600.0),
        ];
        assert_eq!(total_strip_width(&cols, 10.0), 1520.0);
    }

    #[test]
    fn offsets_match_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 300.0),
            WindowColumn::new(vec![wid(2)], 400.0),
            WindowColumn::new(vec![wid(3)], 500.0),
        ];
        assert_eq!(column_strip_offsets(&cols, 10.0), vec![0.0, 310.0, 720.0]);
    }

    #[test]
    fn viewport_scroll_strip_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 500.0),
            WindowColumn::new(vec![wid(2)], 500.0),
            WindowColumn::new(vec![wid(3)], 500.0),
        ];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        assert_eq!(
            compute_viewport_offset_views(&views, Some(0), 0.0, 1000.0, LayoutMode::ScrollStrip, CenterMode::Never, 10.0),
            0.0
        );
        assert_eq!(
            compute_viewport_offset_views(&views, Some(2), 0.0, 1000.0, LayoutMode::ScrollStrip, CenterMode::Never, 10.0),
            520.0
        );
        assert_eq!(
            compute_viewport_offset_views(&views, Some(0), 520.0, 1000.0, LayoutMode::ScrollStrip, CenterMode::Never, 10.0),
            0.0
        );
    }

    #[test]
    fn centered_focus_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 400.0),
            WindowColumn::new(vec![wid(2)], 400.0),
            WindowColumn::new(vec![wid(3)], 400.0),
        ];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        assert_eq!(
            compute_viewport_offset_views(&views, Some(1), 0.0, 1000.0, LayoutMode::CenteredFocus, CenterMode::Never, 10.0),
            110.0
        );
    }

    #[test]
    fn stacked_frames_match_swift() {
        let cols = vec![WindowColumn::new(vec![wid(1), wid(2)], 500.0)];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        let windows = vec![rec(1), rec(2)];
        let mut buf = FrameBuffer::default();
        compute_layout_views(
            &views,
            &windows,
            Some(0),
            Rect::new(0.0, 0.0, 1000.0, 800.0),
            0.0,
            &cfg(10.0),
            &mut buf,
        );
        assert_eq!(buf.len, 2);
        let f1 = buf.frames[0].frame;
        let f2 = buf.frames[1].frame;
        assert_eq!(f1.width, 500.0);
        assert_eq!(f1.height, 395.0);
        assert_eq!(f2.height, 395.0);
        assert_eq!(f1.y, 0.0);
        assert_eq!(f2.y, 405.0);
    }

    #[test]
    fn right_edge_parking_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 400.0),
            WindowColumn::new(vec![wid(2)], 400.0),
            WindowColumn::new(vec![wid(3)], 400.0),
        ];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        let windows = vec![rec(1), rec(2), rec(3)];
        let mut buf = FrameBuffer::default();
        let mut c = cfg(10.0);
        c.layout_mode = LayoutMode::ManualLayout;
        compute_layout_views(
            &views,
            &windows,
            Some(0),
            Rect::new(0.0, 0.0, 500.0, 800.0),
            0.0,
            &c,
            &mut buf,
        );
        let f3 = buf
            .as_slice()
            .iter()
            .find(|f| f.id == wid(3))
            .expect("win3");
        assert_eq!(f3.frame.x, 488.0);
    }

    #[test]
    fn left_sliver_clamp_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 800.0),
            WindowColumn::new(vec![wid(2)], 800.0),
            WindowColumn::new(vec![wid(3)], 800.0),
        ];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        let windows = vec![rec(1), rec(2), rec(3)];
        let mut buf = FrameBuffer::default();
        compute_layout_views(
            &views,
            &windows,
            Some(2),
            Rect::new(0.0, 0.0, 1440.0, 900.0),
            1600.0,
            &cfg(0.0),
            &mut buf,
        );
        let f1 = buf
            .as_slice()
            .iter()
            .find(|f| f.id == wid(1))
            .expect("win1");
        assert_eq!(f1.frame.x, -788.0);
        assert_eq!(f1.is_parked, 1);
        assert_eq!(f1.frame.max_x(), 12.0);
    }

    #[test]
    fn insertion_after_focused_matches_swift() {
        let mut cols = vec![
            WindowColumn::new(vec![wid(1)], 400.0),
            WindowColumn::new(vec![wid(2)], 400.0),
        ];
        let idx = insert_window(
            wid(3),
            &mut cols,
            Some(0),
            InsertionPolicy::AfterFocused,
            None,
            1000.0,
            EdgeMargins::ZERO,
            10.0,
            0.5,
            400.0,
        );
        assert_eq!(idx, 1);
        assert_eq!(cols.len(), 3);
        assert_eq!(cols[1].ids, vec![wid(3)]);
    }

    #[test]
    fn removal_matches_swift() {
        let mut cols = vec![
            WindowColumn::new(vec![wid(1)], 400.0),
            WindowColumn::new(vec![wid(2)], 400.0),
        ];
        let focused = remove_window(wid(1), &mut cols, Some(0));
        assert_eq!(cols.len(), 1);
        assert_eq!(cols[0].ids, vec![wid(2)]);
        assert_eq!(focused, Some(0));
    }

    #[test]
    fn cycle_width_matches_swift() {
        let mut cols = vec![WindowColumn::new(vec![wid(1)], 500.0)];
        assert_eq!(cycle_preset_width(0, &mut cols, 1000.0, &[], false, 400.0), 667.0);
        assert_eq!(cycle_preset_width(0, &mut cols, 1000.0, &[], false, 400.0), 750.0);
        assert_eq!(cycle_preset_width(0, &mut cols, 1000.0, &[], false, 400.0), 1000.0);
        assert_eq!(cycle_preset_width(0, &mut cols, 1000.0, &[], false, 400.0), 400.0);
    }

    #[test]
    fn snap_target_matches_swift() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 600.0),
            WindowColumn::new(vec![wid(2)], 600.0),
            WindowColumn::new(vec![wid(3)], 600.0),
        ];
        let t0 = compute_snap_target(50.0, 0.0, &cols, 1200.0, CenterMode::Never, 0.0);
        assert_eq!(t0.target_offset, 0.0);
        assert_eq!(t0.focused_column_index, 0);

        let tf = compute_snap_target(150.0, 120.0, &cols, 1200.0, CenterMode::Never, 0.0);
        assert_eq!(tf.target_offset, 600.0);
        assert_eq!(tf.focused_column_index, 1);

        let tb = compute_snap_target(450.0, -120.0, &cols, 1200.0, CenterMode::Never, 0.0);
        assert_eq!(tb.target_offset, 0.0);
        assert_eq!(tb.focused_column_index, 0);
    }

    #[test]
    fn tabbed_column_reserves_tab_bar() {
        let mut col = WindowColumn::new(vec![wid(1), wid(2)], 500.0);
        col.presentation = ColumnPresentation::Tabbed;
        let cols = vec![col];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        let windows = vec![rec(1), rec(2)];
        let mut buf = FrameBuffer::default();
        compute_layout_views(
            &views,
            &windows,
            Some(0),
            Rect::new(0.0, 0.0, 1000.0, 800.0),
            0.0,
            &cfg(0.0),
            &mut buf,
        );
        let active = buf.as_slice().iter().find(|f| f.id == wid(1)).unwrap();
        assert_eq!(active.frame.y, 28.0);
        assert_eq!(active.frame.height, 772.0);
    }

    #[test]
    fn zero_gap_edge_margins_flush() {
        let cols = vec![
            WindowColumn::new(vec![wid(1)], 485.0),
            WindowColumn::new(vec![wid(2)], 485.0),
        ];
        let mut views = Vec::new();
        owned_views(&cols, &mut views);
        let windows = vec![rec(1), rec(2)];
        let mut buf = FrameBuffer::default();
        let mut c = cfg(0.0);
        c.margins = EdgeMargins {
            top: 10.0,
            bottom: 10.0,
            left: 15.0,
            right: 15.0,
        };
        compute_layout_views(
            &views,
            &windows,
            Some(0),
            Rect::new(0.0, 0.0, 1000.0, 600.0),
            0.0,
            &c,
            &mut buf,
        );
        let f1 = buf.as_slice().iter().find(|f| f.id == wid(1)).unwrap().frame;
        let f2 = buf.as_slice().iter().find(|f| f.id == wid(2)).unwrap().frame;
        assert_eq!(f1.x, 15.0);
        assert_eq!(f1.y, 10.0);
        assert_eq!(f1.height, 580.0);
        assert_eq!(f2.x, 500.0);
        assert_eq!(f2.max_x(), 985.0);
        assert_eq!(f1.max_x(), f2.min_x());
    }
}
