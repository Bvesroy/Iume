#!/usr/bin/env python3
"""analyze.py - stdlib-only analysis of window_sampler.swift CSV output.

Reads the window CSV (and the trailer the sampler appends) and reports:
  * sampling floor (explicit, in ms and Hz)
  * sample interval p50/p95/max
  * motion episodes
  * per-window frame-to-frame delta stats
  * direction reversals (oscillation / dither)
  * gaps and overlaps between horizontally adjacent on-screen windows of one pid
  * total path length

Usage:
  analyze.py samples.csv
  analyze.py samples.csv --pid 1234 --eps 0.5 --min-size 50
  analyze.py samples.csv --json > report.json

Exit codes: 0 ok, 1 no usable rows, 2 bad args / unreadable input.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from collections import Counter, defaultdict

FIELDS = ["t", "wn", "pid", "owner", "x", "y", "w", "h", "layer"]


# ---------------------------------------------------------------- percentiles

def pct(values, p):
    """Linear-interpolated percentile of an unsorted list."""
    if not values:
        return 0.0
    s = sorted(values)
    if len(s) == 1:
        return float(s[0])
    rank = p / 100.0 * (len(s) - 1)
    lo, hi = int(math.floor(rank)), int(math.ceil(rank))
    if lo == hi:
        return float(s[lo])
    frac = rank - lo
    return float(s[lo]) * (1 - frac) + float(s[hi]) * frac


def fmt(x, nd=2):
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:.{nd}f}"
    return str(x)


# -------------------------------------------------------------------- parsing

def parse_csv(path):
    """Return (meta: dict, rows: list[dict]). '#' lines are comments/metadata."""
    meta = {}
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            if line.lstrip().startswith("#"):
                for k, v in re.findall(r"([A-Za-z_][\w]*)=([^\s]*)", line):
                    meta.setdefault(k, v)
                continue
            try:
                parts = next(csv.reader([line]))
            except (csv.Error, StopIteration):
                continue
            if len(parts) < len(FIELDS):
                continue
            try:
                row = {
                    "t": float(parts[0]),
                    "wn": int(float(parts[1])),
                    "pid": int(float(parts[2])),
                    "owner": parts[3],
                    "x": float(parts[4]),
                    "y": float(parts[5]),
                    "w": float(parts[6]),
                    "h": float(parts[7]),
                    "layer": int(float(parts[8])),
                }
            except ValueError:
                continue
            rows.append(row)
    return meta, rows


# ------------------------------------------------------------------- analysis

def build_frames(rows, pid_filter=None):
    """Group rows into frames keyed by sample time. Also return per-window series."""
    frames = defaultdict(list)
    series = defaultdict(list)
    for r in rows:
        if pid_filter is not None and r["pid"] != pid_filter:
            continue
        frames[round(r["t"], 6)].append(r)
        series[r["wn"]].append(r)
    for wn in series:
        series[wn].sort(key=lambda r: r["t"])
        # de-duplicate identical timestamps (defensive)
        dedup = []
        for r in series[wn]:
            if not dedup or abs(r["t"] - dedup[-1]["t"]) > 1e-9:
                dedup.append(r)
        series[wn] = dedup
    times = sorted(frames)
    return frames, series, times


def motion_stats(series, eps, base_dt, max_episode_gap):
    """Per-window geometry motion, episodes, reversals, path length, resize count."""
    out = {}
    for wn, pts in series.items():
        if len(pts) < 2:
            out[wn] = {
                "samples": len(pts), "moved_pairs": 0, "episodes": [], "path_px": 0.0,
                "span_s": 0.0, "dx": [], "dy": [], "dl2": [], "rev_x": 0, "rev_y": 0,
                "resizes": 0, "max_step": 0.0, "owner": pts[0]["owner"] if pts else "",
                "layer": pts[0]["layer"] if pts else 0,
            }
            continue
        dxs, dys, dl2 = [], [], []
        moved = []
        episodes = []
        cur_start = None
        rev_x = rev_y = 0
        last_sx = last_sy = 0
        resizes = 0
        max_step = 0.0
        for a, b in zip(pts, pts[1:]):
            dt = b["t"] - a["t"]
            dx, dy = b["x"] - a["x"], b["y"] - a["y"]
            dw, dh = b["w"] - a["w"], b["h"] - a["h"]
            step = math.hypot(dx, dy)
            moved_here = max(abs(dx), abs(dy), abs(dw), abs(dh)) > eps and dt <= max_episode_gap
            moved.append(moved_here)
            if moved_here:
                dxs.append(abs(dx))
                dys.append(abs(dy))
                dl2.append(step)
                max_step = max(max_step, step)
                if abs(dw) > eps or abs(dh) > eps:
                    resizes += 1
                sx = 0 if abs(dx) <= eps else (1 if dx > 0 else -1)
                sy = 0 if abs(dy) <= eps else (1 if dy > 0 else -1)
                if sx and last_sx and sx != last_sx:
                    rev_x += 1
                if sy and last_sy and sy != last_sy:
                    rev_y += 1
                if sx:
                    last_sx = sx
                if sy:
                    last_sy = sy
            # episode bookkeeping: contiguous run of moving pairs
            if moved_here:
                if cur_start is None:
                    cur_start = a["t"]
                cur_end = b["t"]
            else:
                if cur_start is not None:
                    episodes.append((cur_start, cur_end))
                    cur_start = None
        if cur_start is not None:
            episodes.append((cur_start, cur_end))

        out[wn] = {
            "samples": len(pts),
            "moved_pairs": sum(1 for m in moved if m),
            "episodes": episodes,
            "path_px": sum(dl2),
            "span_s": pts[-1]["t"] - pts[0]["t"],
            "dx": dxs, "dy": dys, "dl2": dl2,
            "rev_x": rev_x, "rev_y": rev_y,
            "resizes": resizes,
            "max_step": max_step,
            "owner": pts[0]["owner"], "layer": pts[0]["layer"],
        }
    return out


def adjacency(frames, eps, min_size, max_pair_distance):
    """Horizontal neighbours (same pid, same layer) and their gap/overlap over time."""
    pairs = defaultdict(list)
    for t, wins in frames.items():
        usable = [w for w in wins if w["w"] >= min_size and w["h"] >= min_size]
        usable.sort(key=lambda w: (w["layer"], w["x"]))
        for a in usable:
            best = None
            for b in usable:
                if b is a or b["layer"] != a["layer"]:
                    continue
                if b["x"] <= a["x"] + 1.0:            # must be to the right
                    continue
                if b["x"] - (a["x"] + a["w"]) > max_pair_distance:
                    continue
                # vertical overlap must be meaningful
                ov = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
                if ov < 0.5 * min(a["h"], b["h"]):
                    continue
                if best is None or b["x"] < best["x"]:
                    best = b
            if best is None:
                continue
            gap = best["x"] - (a["x"] + a["w"])
            pairs[(a["wn"], a["owner"], best["wn"], best["owner"], a["layer"])].append((t, gap))
    result = []
    for key, vals in pairs.items():
        gaps = [g for _, g in vals]
        result.append({
            "a_wn": key[0], "a_owner": key[1], "b_wn": key[2], "b_owner": key[3],
            "layer": key[4], "frames": len(gaps),
            "median": pct(gaps, 50), "min": min(gaps), "max": max(gaps),
            "p05": pct(gaps, 5), "p95": pct(gaps, 95),
            "gap_frames": sum(1 for g in gaps if g > 0.5),
            "overlap_frames": sum(1 for g in gaps if g < -0.5),
        })
    result.sort(key=lambda d: -d["frames"])
    return result


# ---------------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description="Analyze window_sampler.swift CSV output.")
    ap.add_argument("csv", help="window CSV produced by window_sampler")
    ap.add_argument("--pid", type=int, default=None, help="restrict to this pid (default: header target_pid, else all)")
    ap.add_argument("--eps", type=float, default=0.5, help="motion threshold in points (default 0.5)")
    ap.add_argument("--min-size", type=float, default=50.0, help="ignore windows smaller than this many points (default 50)")
    ap.add_argument("--max-pair-distance", type=float, default=4000.0,
                    help="max horizontal distance to consider two windows neighbours (default 4000 pt)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    try:
        meta, rows = parse_csv(args.csv)
    except OSError as exc:
        print(f"cannot read {args.csv}: {exc}", file=sys.stderr)
        return 2
    if not rows:
        print(f"no usable rows in {args.csv}", file=sys.stderr)
        return 1

    target_pid = args.pid
    if target_pid is None:
        try:
            target_pid = int(meta.get("target_pid", "0"))
        except ValueError:
            target_pid = 0
        if target_pid <= 0:
            target_pid = None

    frames, series, times = build_frames(rows, target_pid)
    if not times:
        print("no rows matched the requested pid", file=sys.stderr)
        return 1

    intervals = [b - a for a, b in zip(times, times[1:])]
    base_dt = pct(intervals, 50) or 0.0
    max_episode_gap = max(4 * base_dt, 0.2) if base_dt else 1.0

    stats = motion_stats(series, args.eps, base_dt, max_episode_gap)
    pairs = adjacency(frames, args.eps, args.min_size, args.max_pair_distance)

    # ---- sampling floor ----
    hz = float(meta.get("sampling_hz", "0") or 0) or (1.0 / base_dt if base_dt else 0.0)
    cost_p50 = float(meta.get("sample_call_cost_ms_p50", "0") or 0)
    cost_p95 = float(meta.get("sample_call_cost_ms_p95", "0") or 0)
    try:
        display_hz = float(meta.get("nsscreen_max_fps", "0") or 0)
    except ValueError:
        display_hz = 0.0
    try:
        mode_hz = float(meta.get("mode_refresh_hz", "0") or 0)
    except ValueError:
        mode_hz = 0.0
    effective_display_hz = display_hz if display_hz > 0 else mode_hz
    request_ms = 1000.0 / hz if hz else 0.0
    display_ms = 1000.0 / effective_display_hz if effective_display_hz else 0.0
    floor_ms = max(request_ms, cost_p50)
    floor_hz = 1000.0 / floor_ms if floor_ms else 0.0

    total_path = sum(s["path_px"] for s in stats.values())
    span = times[-1] - times[0]
    owner = meta.get("target_owner", "")
    pid_label = target_pid if target_pid is not None else "any"

    if args.json:
        payload = {
            "input": args.csv,
            "target_pid": target_pid,
            "target_owner": owner,
            "samples": len(times),
            "span_s": span,
            "eps": args.eps,
            "sampling_floor": {
                "requested_hz": hz,
                "achieved_interval_ms_p50": base_dt * 1000,
                "call_cost_ms_p50": cost_p50,
                "call_cost_ms_p95": cost_p95,
                "display_hz": effective_display_hz,
                "floor_ms": floor_ms,
                "floor_hz": floor_hz,
            },
            "intervals_ms": {
                "p50": pct(intervals, 50) * 1000,
                "p95": pct(intervals, 95) * 1000,
                "max": max(intervals) * 1000 if intervals else 0.0,
            },
            "windows": {
                str(wn): {
                    "owner": s["owner"], "layer": s["layer"], "samples": s["samples"],
                    "moved_pairs": s["moved_pairs"], "episodes": len(s["episodes"]),
                    "path_px": s["path_px"], "rev_x": s["rev_x"], "rev_y": s["rev_y"],
                    "resizes": s["resizes"], "max_step_px": s["max_step"],
                    "delta_px_p50": pct(s["dl2"], 50), "delta_px_max": max(s["dl2"]) if s["dl2"] else 0.0,
                }
                for wn, s in stats.items()
            },
            "adjacency": pairs,
            "total_path_px": total_path,
        }
        print(json.dumps(payload, indent=2))
        return 0

    # ---- text report ----
    print("IUME WINDOW MOTION AUDIT")
    print("=" * 78)
    print(f"input .................... {args.csv}")
    print(f"target ................... pid {pid_label} {owner}".rstrip())
    print(f"recorded ................. {span:.3f} s, {len(times)} frames, {len(stats)} distinct windows")
    print(f"motion threshold (eps) ... {args.eps} pt")
    print()

    print("SAMPLING FLOOR  (read this before trusting any number below)")
    print("-" * 78)
    print(f"requested rate ........... {hz:.1f} Hz -> {request_ms:.2f} ms period")
    print(f"achieved interval p50 .... {base_dt * 1000:.2f} ms"
          f"  (p95 {pct(intervals, 95) * 1000:.2f} ms, max {(max(intervals) * 1000 if intervals else 0):.2f} ms)")
    print(f"CGWindowList call cost ... p50 {cost_p50:.3f} ms, p95 {cost_p95:.3f} ms"
          f"  ({meta.get('deadline_overruns', '?')} deadline overruns)")
    if effective_display_hz:
        print(f"display refresh .......... {effective_display_hz:.1f} Hz -> {display_ms:.2f} ms per commit")
    else:
        print("display refresh .......... unknown (header had no refresh value)")
    print(f"=> resolution floor ...... {floor_ms:.2f} ms (~{floor_hz:.1f} Hz) ="
          f" max(sample period {request_ms:.2f} ms, call cost {cost_p50:.2f} ms)")
    print("   Nothing faster than this floor is observable. Frame-to-frame deltas are")
    print("   further quantized to the display commit period, so a 120 Hz app sampled at")
    print("   20 Hz shows ~6 refresh commits merged into one delta. Reversal counts are")
    print("   LOWER bounds: an oscillation faster than the floor aliases into noise or")
    print("   into a slower apparent oscillation (Nyquist).")
    print()

    print("SAMPLE INTERVAL")
    print("-" * 78)
    print(f"p50 {pct(intervals, 50) * 1000:8.2f} ms   p95 {pct(intervals, 95) * 1000:8.2f} ms"
          f"   max {(max(intervals) * 1000 if intervals else 0):8.2f} ms   n={len(intervals)}")
    stalls = [d for d in intervals if d > max(3 * base_dt, 0.1)]
    print(f"stalled intervals (>3x p50): {len(stalls)}"
          + (f", worst {max(stalls) * 1000:.1f} ms" if stalls else ""))
    print()

    print("MOTION EPISODES  (contiguous runs of changed geometry)")
    print("-" * 78)
    if not stats:
        print("no windows")
    header = f"{'win':>8}  {'owner':<22} {'lyr':>3} {'frm':>5} {'mv':>5} {'ep':>3} " \
             f"{'longest':>8} {'displacement':>12} {'path px':>9} {'revX':>4} {'revY':>4}"
    print(header)
    any_motion = False
    for wn, s in sorted(stats.items(), key=lambda kv: -kv[1]["path_px"]):
        if s["moved_pairs"] == 0:
            continue
        any_motion = True
        longest = max((b - a for a, b in s["episodes"]), default=0.0)
        print(f"{wn:>8}  {s['owner'][:22]:<22} {s['layer']:>3} {s['samples']:>5} "
              f"{s['moved_pairs']:>5} {len(s['episodes']):>3} {longest:>7.2f}s "
              f"{s['max_step']:>11.1f} {s['path_px']:>9.1f} {s['rev_x']:>4} {s['rev_y']:>4}")
    if not any_motion:
        print("(no window moved during the recording)")
    print()

    print("PER-WINDOW DELTA STATS (per sample pair, position change in points)")
    print("-" * 78)
    print(f"{'win':>8}  {'|dx| p50':>9} {'|dx| p95':>9} {'|dy| p50':>9} {'|dy| p95':>9} "
          f"{'step max':>9} {'resizes':>7}  {'moved/s':>8}")
    for wn, s in sorted(stats.items(), key=lambda kv: -kv[1]["path_px"]):
        if not s["dl2"]:
            continue
        rate = s["moved_pairs"] / s["span_s"] if s["span_s"] > 0 else 0.0
        print(f"{wn:>8}  {pct(s['dx'], 50):>9.2f} {pct(s['dx'], 95):>9.2f} "
              f"{pct(s['dy'], 50):>9.2f} {pct(s['dy'], 95):>9.2f} "
              f"{s['max_step']:>9.2f} {s['resizes']:>7}  {rate:>8.2f}")
    print()

    print("DIRECTION REVERSALS (oscillation / dither detector)")
    print("-" * 78)
    print(f"{'win':>8}  {'revX':>5} {'revY':>5} {'ratioX':>7} {'ratioY':>7} {'Hz est':>6}  verdict")
    for wn, s in sorted(stats.items(), key=lambda kv: -(kv[1]["rev_x"] + kv[1]["rev_y"])):
        # reversals per moving step
        denom = max(1, s["moved_pairs"] - 1)
        rx, ry = s["rev_x"] / denom, s["rev_y"] / denom
        total_rev = s["rev_x"] + s["rev_y"]
        hz_est = total_rev / (2.0 * s["span_s"]) if s["span_s"] > 0 else 0.0
        verdict = "oscillating" if max(rx, ry) > 0.4 else ("mixed" if max(rx, ry) > 0.15 else "monotonic")
        print(f"{wn:>8}  {s['rev_x']:>5} {s['rev_y']:>5} {rx:>7.2f} {ry:>7.2f} {hz_est:>6.2f}  {verdict}")
    print("   ratio near 1.0 = direction flips on almost every moving sample (dither/")
    print("   rubber-banding); near 0 = one-way travel. Hz est = reversals / 2 / span and")
    print("   is only meaningful while the true period stays above the sampling floor.")
    print()

    print("HORIZONTAL NEIGHBOURS  (gaps and overlaps, same pid + layer)")
    print("-" * 78)
    if not pairs:
        print("(no horizontally adjacent window pair observed)")
    else:
        print(f"{'A-win':>7} {'B-win':>7} {'lyr':>3} {'frames':>6} {'gap p50':>8} {'gap min':>8} "
              f"{'gap max':>8} {'gap-frm':>7} {'ovl-frm':>7}")
        for p in pairs[:12]:
            print(f"{p['a_wn']:>7} {p['b_wn']:>7} {p['layer']:>3} {p['frames']:>6} "
                  f"{p['median']:>8.1f} {p['min']:>8.1f} {p['max']:>8.1f} "
                  f"{p['gap_frames']:>7} {p['overlap_frames']:>7}")
        print("   gap > 0 = visible seam between windows; gap < 0 = overlapping frames.")
        print("   A median near 0 with large min/max spread is the signature of windows")
        print("   that are meant to tile but are repositioned asynchronously.")
    print()

    print("PATH LENGTH")
    print("-" * 78)
    print(f"total .................... {total_path:.1f} pt over {span:.2f} s"
          f"  ({total_path / span if span else 0:.1f} pt/s)")
    for wn, s in sorted(stats.items(), key=lambda kv: -kv[1]["path_px"])[:5]:
        if s["path_px"] <= 0:
            continue
        print(f"  win {wn:>7} {s['owner'][:20]:<20} {s['path_px']:>9.1f} pt"
              f"  ({s['path_px'] / s['span_s'] if s['span_s'] else 0:.1f} pt/s)")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
