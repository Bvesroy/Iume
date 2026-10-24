//! Magnetic snapping and chained-neighbour adhesion.
//!
//! Port of `MagneticWindowEngine.swift`. The chained-neighbour computation is
//! the one that used to allocate a dictionary of every neighbour frame; here it
//! writes straight into a caller-owned buffer.

use crate::types::{MagneticSnap, Rect, StackedEntry, WindowColumn, WindowId, WindowRecord};

pub const EDGE_LEFT_OF_CANDIDATE: u32 = 0;
pub const EDGE_RIGHT_OF_CANDIDATE: u32 = 1;
pub const EDGE_SCREEN_LEFT: u32 = 2;
pub const EDGE_SCREEN_RIGHT: u32 = 3;

/// Snap a seam width to a standard ratio split when within `snap_radius`.
#[inline]
pub fn snap_seam_ratio(combined_width: f64, target_width: f64, snap_radius: f64) -> f64 {
    const RATIOS: [f64; 5] = [0.25, 0.3333, 0.50, 0.6667, 0.75];
    let mut best_width = target_width;
    let mut min_diff = snap_radius + 1.0;
    for ratio in RATIOS {
        let candidate = (combined_width * ratio).round();
        let diff = (target_width - candidate).abs();
        if diff <= snap_radius && diff < min_diff {
            min_diff = diff;
            best_width = candidate;
        }
    }
    best_width
}

/// Evaluate a magnetic snap between a dragged window and every candidate.
pub fn evaluate_magnetic_snap(
    dragged_id: WindowId,
    dragged_frame: Rect,
    candidates: &[WindowRecord],
    gap: f64,
    visible_frame: Option<Rect>,
    snap_radius: f64,
) -> MagneticSnap {
    let mut result = MagneticSnap {
        has_value: false,
        ..Default::default()
    };
    let mut min_distance = snap_radius + 1.0;

    for candidate in candidates {
        if candidate.id == dragged_id || !candidate.flags.is_tiled() {
            continue;
        }
        let c = candidate.frame;

        let vertical_overlap = (dragged_frame.max_y().min(c.max_y())
            - dragged_frame.min_y().max(c.min_y()))
        .max(0.0);
        let vertical_distance = (dragged_frame.min_y() - c.min_y()).abs();
        if vertical_overlap <= 0.0 && vertical_distance > snap_radius * 1.5 {
            continue;
        }

        // Dragged window to the LEFT of candidate: dragged.maxX + gap == candidate.minX
        let target_max_x = c.min_x() - gap;
        let dist_left = (dragged_frame.max_x() - target_max_x).abs();
        if dist_left <= snap_radius && dist_left < min_distance {
            let snapped = Rect::new(
                (target_max_x - dragged_frame.width).round(),
                c.y.round(),
                dragged_frame.width.round(),
                c.height.round(),
            );
            min_distance = dist_left;
            result = MagneticSnap {
                has_value: true,
                snapped_frame: snapped,
                candidate: candidate.id,
                has_candidate: true,
                candidate_frame: c,
                edge: EDGE_LEFT_OF_CANDIDATE,
                distance: dist_left,
            };
        }

        // Dragged window to the RIGHT of candidate: dragged.minX == candidate.maxX + gap
        let target_min_x = c.max_x() + gap;
        let dist_right = (dragged_frame.min_x() - target_min_x).abs();
        if dist_right <= snap_radius && dist_right < min_distance {
            let snapped = Rect::new(
                target_min_x.round(),
                c.y.round(),
                dragged_frame.width.round(),
                c.height.round(),
            );
            min_distance = dist_right;
            result = MagneticSnap {
                has_value: true,
                snapped_frame: snapped,
                candidate: candidate.id,
                has_candidate: true,
                candidate_frame: c,
                edge: EDGE_RIGHT_OF_CANDIDATE,
                distance: dist_right,
            };
        }
    }

    if let Some(vis) = visible_frame {
        let dist_left = (dragged_frame.min_x() - vis.min_x()).abs();
        if dist_left <= snap_radius && dist_left < min_distance {
            let snapped = Rect::new(
                vis.min_x().round(),
                dragged_frame.min_y().round(),
                dragged_frame.width.round(),
                dragged_frame.height.round(),
            );
            min_distance = dist_left;
            result = MagneticSnap {
                has_value: true,
                snapped_frame: snapped,
                candidate: WindowId::default(),
                has_candidate: false,
                candidate_frame: Rect::default(),
                edge: EDGE_SCREEN_LEFT,
                distance: dist_left,
            };
        }

        let dist_right = (dragged_frame.max_x() - vis.max_x()).abs();
        if dist_right <= snap_radius && dist_right < min_distance {
            let snapped = Rect::new(
                (vis.max_x() - dragged_frame.width).round(),
                dragged_frame.min_y().round(),
                dragged_frame.width.round(),
                dragged_frame.height.round(),
            );
            result = MagneticSnap {
                has_value: true,
                snapped_frame: snapped,
                candidate: WindowId::default(),
                has_candidate: false,
                candidate_frame: Rect::default(),
                edge: EDGE_SCREEN_RIGHT,
                distance: dist_right,
            };
        }
    }

    result
}

/// A chained neighbour frame written into a caller-owned buffer.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct ChainedFrame {
    pub id: WindowId,
    pub frame: Rect,
}

/// Compute chained neighbour frames so a dragged window carries its strip with it.
///
/// `windows` provides the `is_floating` / `is_minimized` flags and original
/// frame (for the vertical breakaway check). `out` is filled and its length
/// returned.
pub fn compute_chained_neighbor_frames(
    dragged_id: WindowId,
    dragged_frame: Rect,
    columns: &[WindowColumn],
    windows: &[WindowRecord],
    gap: f64,
    breakaway_threshold: f64,
    out: &mut [ChainedFrame],
) -> usize {
    let col_idx = match columns.iter().position(|c| c.ids.contains(&dragged_id)) {
        Some(i) => i,
        None => return 0,
    };

    // Vertical rip-away decouples the chain.
    if let Some(orig) = windows.iter().find(|w| w.id == dragged_id) {
        if (dragged_frame.min_y() - orig.frame.min_y()).abs() > breakaway_threshold {
            return 0;
        }
    }

    let usable_y = dragged_frame.y;
    let usable_height = dragged_frame.height;
    let mut len = 0usize;

    // Right neighbours.
    let mut running_right_x = dragged_frame.max_x() + gap;
    if col_idx + 1 < columns.len() {
        for col in &columns[col_idx + 1..] {
            let count = col
                .ids
                .iter()
                .filter(|id| {
                    windows
                        .iter()
                        .any(|w| w.id == **id && w.flags.is_tiled())
                })
                .count();
            if count == 0 {
                break;
            }
            let single_height =
                (usable_height - (count.saturating_sub(1)) as f64 * gap) / count as f64;
            let mut stack_idx = 0usize;
            for id in &col.ids {
                let Some(win) = windows
                    .iter()
                    .find(|w| w.id == *id && w.flags.is_tiled())
                else {
                    continue;
                };
                let win_y = usable_y + stack_idx as f64 * (single_height + gap);
                let frame = Rect::new(
                    running_right_x.round(),
                    win_y.round(),
                    col.width.round(),
                    single_height.round(),
                );
                if len < out.len() {
                    out[len] = ChainedFrame {
                        id: win.id,
                        frame,
                    };
                    len += 1;
                }
                stack_idx += 1;
            }
            running_right_x += col.width + gap;
        }
    }

    // Left neighbours.
    let mut running_left_edge_x = dragged_frame.min_x() - gap;
    if col_idx > 0 {
        for left_idx in (0..col_idx).rev() {
            let col = &columns[left_idx];
            let count = col
                .ids
                .iter()
                .filter(|id| {
                    windows
                        .iter()
                        .any(|w| w.id == **id && w.flags.is_tiled())
                })
                .count();
            if count == 0 {
                break;
            }
            let col_origin_x = running_left_edge_x - col.width;
            let single_height =
                (usable_height - (count.saturating_sub(1)) as f64 * gap) / count as f64;
            let mut stack_idx = 0usize;
            for id in &col.ids {
                let Some(win) = windows
                    .iter()
                    .find(|w| w.id == *id && w.flags.is_tiled())
                else {
                    continue;
                };
                let win_y = usable_y + stack_idx as f64 * (single_height + gap);
                let frame = Rect::new(
                    col_origin_x.round(),
                    win_y.round(),
                    col.width.round(),
                    single_height.round(),
                );
                if len < out.len() {
                    out[len] = ChainedFrame {
                        id: win.id,
                        frame,
                    };
                    len += 1;
                }
                stack_idx += 1;
            }
            running_left_edge_x = col_origin_x - gap;
        }
    }

    len
}

/// Compute stack height ratios for a column (helper used by settle paths).
pub fn equalize_ratios(entries: &mut [StackedEntry]) {
    let count = entries.len().max(1);
    let ratio = 1.0 / count as f64;
    for e in entries.iter_mut() {
        e.height_ratio = ratio;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::WindowFlags;

    fn wid(pid: i32, raw: u64) -> WindowId {
        WindowId::new(pid, raw)
    }

    fn rec(id: WindowId, frame: Rect) -> WindowRecord {
        WindowRecord {
            id,
            flags: WindowFlags::tiled(),
            frame,
        }
    }

    #[test]
    fn snaps_left_to_right() {
        let a = wid(100, 1);
        let b = wid(200, 2);
        let drag = Rect::new(180.0, 50.0, 600.0, 900.0);
        let cand = rec(b, Rect::new(800.0, 50.0, 600.0, 900.0));
        let snap = evaluate_magnetic_snap(a, drag, &[cand], 12.0, None, 32.0);
        assert!(snap.has_value);
        assert_eq!(snap.edge, EDGE_LEFT_OF_CANDIDATE);
        assert_eq!(snap.snapped_frame.x, 188.0);
        assert_eq!(snap.snapped_frame.max_x(), 788.0);
    }

    #[test]
    fn snaps_right_to_left() {
        let a = wid(102, 1);
        let b = wid(202, 2);
        let drag = Rect::new(725.0, 50.0, 500.0, 900.0);
        let cand = rec(b, Rect::new(100.0, 50.0, 600.0, 900.0));
        let snap = evaluate_magnetic_snap(a, drag, &[cand], 12.0, None, 32.0);
        assert!(snap.has_value);
        assert_eq!(snap.edge, EDGE_RIGHT_OF_CANDIDATE);
        assert_eq!(snap.snapped_frame.x, 712.0);
    }

    #[test]
    fn no_snap_beyond_radius() {
        let a = wid(103, 1);
        let b = wid(203, 2);
        let drag = Rect::new(100.0, 50.0, 600.0, 900.0);
        let cand = rec(b, Rect::new(800.0, 50.0, 600.0, 900.0));
        let snap = evaluate_magnetic_snap(a, drag, &[cand], 12.0, None, 32.0);
        assert!(!snap.has_value);
    }

    #[test]
    fn chained_right_neighbor_moves() {
        let a = wid(104, 1);
        let b = wid(204, 2);
        let cols = vec![
            WindowColumn::new(vec![a], 600.0),
            WindowColumn::new(vec![b], 600.0),
        ];
        let wins = vec![
            rec(a, Rect::new(0.0, 25.0, 600.0, 1000.0)),
            rec(b, Rect::new(612.0, 25.0, 600.0, 1000.0)),
        ];
        let mut out = [ChainedFrame {
            id: WindowId::default(),
            frame: Rect::default(),
        }; 16];
        let n = compute_chained_neighbor_frames(
            a,
            Rect::new(80.0, 25.0, 600.0, 1000.0),
            &cols,
            &wins,
            12.0,
            160.0,
            &mut out,
        );
        assert_eq!(n, 1);
        assert_eq!(out[0].id, b);
        assert_eq!(out[0].frame.x, 692.0);
    }

    #[test]
    fn seam_snaps_to_half() {
        assert_eq!(snap_seam_ratio(1000.0, 495.0, 18.0), 500.0);
        assert_eq!(snap_seam_ratio(1000.0, 520.0, 18.0), 520.0);
    }
}
