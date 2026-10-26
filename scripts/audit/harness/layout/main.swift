import Foundation
import CoreGraphics

// Standalone layout/geometry harness.
//
// Compiles the real production geometry sources (`CoreModels.swift`,
// `ManagedWindow.swift`, `BoxTilingEngine.swift`, `LayoutEngine.swift`) and
// exercises the single shared scroll-bounds authority without SwiftUI.
//
// This is the executable counterpart of the D03 / D08 / D16 / D18 regression
// tests, which cannot run through SwiftPM on a Command Line Tools-only machine.

private var failures = 0
private var checks = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor
func checkClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat, _ message: String) {
    check(
        abs(actual - expected) <= tolerance,
        "\(message) (actual \(String(format: "%.3f", Double(actual))), expected \(String(format: "%.3f", Double(expected))) ± \(tolerance))"
    )
}

func windowId(_ n: Int) -> WindowId {
    WindowId(pid: 1, rawId: UInt64(n + 1))
}

func columns(widths: [CGFloat]) -> [WindowColumn] {
    widths.enumerated().map { index, width in
        WindowColumn(windowIds: [windowId(index)], width: width)
    }
}

func windows(for columns: [WindowColumn], visibleFrame: CGRect) -> [WindowId: ManagedWindow] {
    var result: [WindowId: ManagedWindow] = [:]
    for column in columns {
        for id in column.windowIds {
            let frame = CGRect(x: 0, y: 0, width: column.width, height: visibleFrame.height)
            result[id] = ManagedWindow(
                id: id,
                pid: 1,
                bundleIdentifier: "test",
                appName: "Test",
                title: "Test",
                frame: frame
            )
        }
    }
    return result
}

let engine = LayoutEngine(windowGap: 20.0)
let gap: CGFloat = 20.0

// MARK: - D16: a single column still has a valid scroll range

@MainActor
func d16SingleColumnGeometry() {
    // One wide column: the old `guard columns.count > 1` returned 0, making the
    // column's right half unreachable.
    let wide = columns(widths: [1400])
    checkClose(
        engine.maxScrollOffset(columns: wide, visibleWidth: 1000, centerMode: .never, gap: gap),
        400,
        tolerance: 0.001,
        "D16 single wide column exposes width minus viewport"
    )

    let fits = columns(widths: [600])
    checkClose(
        engine.maxScrollOffset(columns: fits, visibleWidth: 1000, centerMode: .never, gap: gap),
        0,
        tolerance: 0.001,
        "D16 single column that fits has no scroll range"
    )

    checkClose(
        engine.maxScrollOffset(columns: [], visibleWidth: 1000, centerMode: .never, gap: gap),
        0,
        tolerance: 0.001,
        "D16 empty workspace has no scroll range"
    )

    // Centered single wide column: the center target (200) is smaller than the
    // strip-end range (400), so max() keeps 400.
    checkClose(
        engine.maxScrollOffset(columns: wide, visibleWidth: 1000, centerMode: .always, gap: gap),
        400,
        tolerance: 0.001,
        "D16 centered single wide column max offset"
    )

    // Snap must not pull a single column's own scroll range back to zero (D18).
    let wideSnap = engine.computeSnapTarget(
        for: 250,
        columns: wide,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap
    )
    checkClose(
        wideSnap.targetOffset,
        250,
        tolerance: 0.001,
        "D18 single wide column snap preserves an in-range offset"
    )
    check(wideSnap.focusedColumnIndex == 0, "D18 single wide column snap keeps focus on column 0")

    let wideSnapOvershoot = engine.computeSnapTarget(
        for: 900,
        columns: wide,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap
    )
    checkClose(
        wideSnapOvershoot.targetOffset,
        400,
        tolerance: 0.001,
        "D18 single wide column snap clamps to the valid range"
    )

    let fitsSnap = engine.computeSnapTarget(
        for: 75,
        columns: fits,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap
    )
    checkClose(
        fitsSnap.targetOffset,
        0,
        tolerance: 0.001,
        "D18 single column that fits snaps to zero"
    )

    let infiniteSnap = engine.computeSnapTarget(
        for: .infinity,
        columns: wide,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap
    )
    checkClose(
        infiniteSnap.targetOffset,
        400,
        tolerance: 0.001,
        "D18 single wide column clamps an infinite projection like the linear path"
    )

    let nanSnap = engine.computeSnapTarget(
        for: .nan,
        columns: wide,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap
    )
    checkClose(
        nanSnap.targetOffset,
        0,
        tolerance: 0.001,
        "D18 single wide column treats a NaN projection as the strip start"
    )
}

// MARK: - D03: one loop-eligibility predicate

@MainActor
func d03SingleColumnNeverLoops() {
    let wide = columns(widths: [1400])
    check(
        !engine.isLoopEligible(columns: wide, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap),
        "D03 a single column is never loop-eligible"
    )

    let looped = engine.computeViewportOffset(
        columns: wide,
        focusedColumnIndex: 0,
        currentViewportOffset: 5000,
        visibleWidth: 1000,
        layoutMode: .scrollStrip,
        centerMode: .never,
        gap: gap,
        loopMode: true
    )
    let linear = engine.computeViewportOffset(
        columns: wide,
        focusedColumnIndex: 0,
        currentViewportOffset: 5000,
        visibleWidth: 1000,
        layoutMode: .scrollStrip,
        centerMode: .never,
        gap: gap,
        loopMode: false
    )
    checkClose(looped, 0, tolerance: 0.001, "D03 focusing the only column aligns it at zero")
    checkClose(looped, linear, tolerance: 0.001, "D03 single-column loop flag has no effect")

    // With no focused column the current offset is clamped to the single-column range.
    let clamped = engine.computeViewportOffset(
        columns: wide,
        focusedColumnIndex: nil,
        currentViewportOffset: 5000,
        visibleWidth: 1000,
        layoutMode: .scrollStrip,
        centerMode: .never,
        gap: gap,
        loopMode: true
    )
    checkClose(clamped, 400, tolerance: 0.001, "D03 single-column idle offset is clamped to the valid range")
}

@MainActor
func d03ShortStripNeverLoops() {
    let short = columns(widths: [300, 300])
    checkClose(
        engine.cyclicStripPeriod(columns: short, gap: gap),
        640,
        tolerance: 0.001,
        "D03 short strip period includes the closing gap"
    )
    check(
        !engine.isLoopEligible(columns: short, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap),
        "D03 a strip shorter than the viewport is not loop-eligible"
    )

    let looped = engine.computeViewportOffset(
        columns: short,
        focusedColumnIndex: 1,
        currentViewportOffset: 5000,
        visibleWidth: 1000,
        layoutMode: .scrollStrip,
        centerMode: .always,
        gap: gap,
        loopMode: true
    )
    let linear = engine.computeViewportOffset(
        columns: short,
        focusedColumnIndex: 1,
        currentViewportOffset: 5000,
        visibleWidth: 1000,
        layoutMode: .scrollStrip,
        centerMode: .always,
        gap: gap,
        loopMode: false
    )
    checkClose(looped, linear, tolerance: 0.001, "D03 short-strip looped viewport equals linear")
    checkClose(looped, 0, tolerance: 0.001, "D03 short-strip viewport is clamped to zero")

    let loopedSnap = engine.computeSnapTarget(
        for: 5000,
        columns: short,
        visibleWidth: 1000,
        centerMode: .always,
        gap: gap,
        loopMode: true,
        layoutMode: .scrollStrip
    )
    let linearSnap = engine.computeSnapTarget(
        for: 5000,
        columns: short,
        visibleWidth: 1000,
        centerMode: .always,
        gap: gap,
        loopMode: false,
        layoutMode: .scrollStrip
    )
    checkClose(loopedSnap.targetOffset, linearSnap.targetOffset, tolerance: 0.001, "D03 short-strip snap ignores loop")
    checkClose(loopedSnap.targetOffset, 0, tolerance: 0.001, "D03 short-strip snap target is zero")
}

@MainActor
func d03NonStripModesNeverLoop() {
    let wide = columns(widths: [1100, 1100, 1100, 1100])
    for mode in [LayoutMode.manualLayout, .grid, .tall, .wide, .bsp, .row, .column] {
        check(
            !engine.isLoopEligible(columns: wide, visibleWidth: 1000, layoutMode: mode, gap: gap),
            "D03 \(mode.rawValue) is not loop-eligible"
        )
        let snap = engine.computeSnapTarget(
            for: 4470,
            columns: wide,
            visibleWidth: 1000,
            centerMode: .never,
            gap: gap,
            loopMode: true,
            layoutMode: mode
        )
        let maxOffset = engine.maxScrollOffset(columns: wide, visibleWidth: 1000, centerMode: .never, gap: gap)
        check(
            snap.targetOffset >= -0.001 && snap.targetOffset <= maxOffset + 0.001,
            "D03 \(mode.rawValue) snap ignores loop and stays in bounds (target \(snap.targetOffset))"
        )
    }
}

// MARK: - D08: loop-aware snap target

let loopColumns = columns(widths: [1100, 1100, 1100, 1100])
let loopPeriod: CGFloat = 4480

@MainActor
func d08LoopSnapTarget() {
    checkClose(
        engine.cyclicStripPeriod(columns: loopColumns, gap: gap),
        loopPeriod,
        tolerance: 0.001,
        "D08 fixture period"
    )
    check(
        engine.isLoopEligible(columns: loopColumns, visibleWidth: 1000, layoutMode: .scrollStrip, gap: gap),
        "D08 fixture is loop-eligible"
    )

    // Just before one full cycle: the nearest snap is column 0's copy at +period.
    let forward = engine.computeSnapTarget(
        for: 4470,
        columns: loopColumns,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap,
        loopMode: true,
        layoutMode: .scrollStrip
    )
    checkClose(forward.targetOffset, loopPeriod, tolerance: 0.001, "D08 forward snap wraps to the next cycle")
    check(forward.focusedColumnIndex == 0, "D08 forward snap focuses column 0")

    // Just below zero: the nearest snap is column 3's copy one cycle back.
    let backward = engine.computeSnapTarget(
        for: -30,
        velocity: -120,
        columns: loopColumns,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap,
        loopMode: true,
        layoutMode: .scrollStrip
    )
    checkClose(backward.targetOffset, -1120, tolerance: 0.001, "D08 backward snap wraps to the previous cycle")
    check(backward.focusedColumnIndex == 3, "D08 backward snap focuses the last column")

    // The same call in a non-looping mode must clamp inside the strip.
    let linear = engine.computeSnapTarget(
        for: 4470,
        velocity: 120,
        columns: loopColumns,
        visibleWidth: 1000,
        centerMode: .never,
        gap: gap,
        loopMode: true,
        layoutMode: .grid
    )
    let maxOffset = engine.maxScrollOffset(columns: loopColumns, visibleWidth: 1000, centerMode: .never, gap: gap)
    check(linear.targetOffset <= maxOffset + 0.001, "D08 non-loop snap stays inside the strip")
    check(linear.targetOffset != loopPeriod, "D08 non-loop snap does not return a cyclic target")
}

// MARK: - D18: one authoritative bounds value

@MainActor
func d18ScrollBounds() {
    let pair = columns(widths: [600, 600])
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let bounds = engine.scrollBounds(
        columns: pair,
        visibleFrame: frame,
        edgeMargins: EdgeMargins(top: 8, bottom: 8, left: 10, right: 10),
        totalWindowCount: 2,
        smartWindowMargins: false,
        disablePaddingOnBuiltinDisplay: false,
        isBuiltinDisplay: false,
        centerMode: .never,
        windowGap: gap,
        layoutMode: .scrollStrip,
        loopMode: true
    )
    checkClose(bounds.usableWidth, 1180, tolerance: 0.001, "D18 usable width subtracts margins once")
    checkClose(bounds.gap, 20, tolerance: 0.001, "D18 gap is the resolved gap")
    checkClose(bounds.maxOffset, 40, tolerance: 0.001, "D18 max offset derives from usable width and resolved gap")
    check(bounds.loopEligible, "D18 period 1220 covers the 1180 viewport")
    checkClose(
        engine.maxScrollOffset(columns: pair, visibleWidth: bounds.usableWidth, centerMode: .never, gap: bounds.gap),
        bounds.maxOffset,
        tolerance: 0.001,
        "D18 bounds max offset is self-consistent"
    )
    check(
        engine.isLoopEligible(columns: pair, visibleWidth: bounds.usableWidth, layoutMode: .scrollStrip, gap: bounds.gap) == bounds.loopEligible,
        "D18 bounds loop flag is self-consistent"
    )

    // Single-window smart margins collapse margins and gap in the same place.
    let single = columns(widths: [1200])
    let collapsed = engine.scrollBounds(
        columns: single,
        visibleFrame: frame,
        edgeMargins: EdgeMargins(top: 8, bottom: 8, left: 10, right: 10),
        totalWindowCount: 1,
        smartWindowMargins: true,
        disablePaddingOnBuiltinDisplay: false,
        isBuiltinDisplay: false,
        centerMode: .never,
        windowGap: gap,
        layoutMode: .scrollStrip,
        loopMode: true
    )
    checkClose(collapsed.usableWidth, 1200, tolerance: 0.001, "D18 smart single window drops margins")
    checkClose(collapsed.gap, 0, tolerance: 0.001, "D18 smart single window drops gap")
    checkClose(collapsed.maxOffset, 0, tolerance: 0.001, "D18 smart single window has no range")
    check(!collapsed.loopEligible, "D18 smart single window does not loop")
}

@MainActor
func d18AllPathsAgree() {
    let cols = columns(widths: [400, 500, 600, 700])
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let bounds = engine.scrollBounds(
        columns: cols,
        visibleFrame: frame,
        edgeMargins: .zero,
        totalWindowCount: 4,
        smartWindowMargins: false,
        disablePaddingOnBuiltinDisplay: false,
        isBuiltinDisplay: false,
        centerMode: .never,
        windowGap: 10,
        layoutMode: .scrollStrip,
        loopMode: false
    )
    checkClose(bounds.maxOffset, 1230, tolerance: 0.001, "D18 fixture max offset")
    check(!bounds.loopEligible, "D18 fixture does not loop")

    let winMap = windows(for: cols, visibleFrame: frame)
    for focused in cols.indices {
        let offset = engine.computeViewportOffset(
            columns: cols,
            focusedColumnIndex: focused,
            currentViewportOffset: 0,
            visibleWidth: bounds.usableWidth,
            layoutMode: .scrollStrip,
            centerMode: .never,
            gap: bounds.gap,
            loopMode: bounds.loopEligible
        )
        check(
            offset >= -0.001 && offset <= bounds.maxOffset + 0.001,
            "D18 viewport focus \(focused) stays in bounds (offset \(offset))"
        )

        let computation = engine.computeLayout(
            columns: cols,
            windows: winMap,
            focusedColumnIndex: focused,
            visibleFrame: frame,
            viewportOffset: 5000,
            layoutMode: .scrollStrip,
            centerMode: .never,
            edgeMargins: .zero,
            gap: bounds.gap,
            loopMode: bounds.loopEligible
        )
        check(
            computation.targetViewportOffset >= -0.001 && computation.targetViewportOffset <= bounds.maxOffset + 0.001,
            "D18 layout focus \(focused) stays in bounds (offset \(computation.targetViewportOffset))"
        )
    }

    for projected in stride(from: CGFloat(-500), through: 3000, by: 250) {
        let snap = engine.computeSnapTarget(
            for: projected,
            columns: cols,
            visibleWidth: bounds.usableWidth,
            centerMode: .never,
            gap: bounds.gap,
            loopMode: bounds.loopEligible,
            layoutMode: .scrollStrip
        )
        check(
            snap.targetOffset >= -0.001 && snap.targetOffset <= bounds.maxOffset + 0.001,
            "D18 snap at \(projected) stays in bounds (target \(snap.targetOffset))"
        )
    }
}

// Regression coverage for loop-mode frame ordering. Nearest-centre wrapping can
// otherwise select different cycle copies for adjacent columns and overlap them.
@MainActor
func d19LoopFramesRemainOrdered() {
    let loopCols = columns(widths: [380, 380, 380])
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let winMap = windows(for: loopCols, visibleFrame: frame)
    for offset in [CGFloat(0), 100, 300, 570, 900, 1100] {
        let computation = engine.computeLayout(
            columns: loopCols,
            windows: winMap,
            focusedColumnIndex: nil,
            visibleFrame: frame,
            viewportOffset: offset,
            layoutMode: .scrollStrip,
            centerMode: .never,
            edgeMargins: .zero,
            gap: 0,
            loopMode: true
        )
        let visible = loopCols.compactMap { column -> CGRect? in
            guard let id = column.windowIds.first,
                  !computation.parkedWindowIds.contains(id),
                  let rect = computation.targetFrames[id],
                  rect.maxX > frame.minX,
                  rect.minX < frame.maxX else { return nil }
            return rect
        }
        for leftIndex in visible.indices {
            for rightIndex in visible.indices where rightIndex > leftIndex {
                check(
                    !visible[leftIndex].intersects(visible[rightIndex]),
                    "D19 loop offset (offset) keeps visible columns non-overlapping"
                )
            }
        }
    }
}

// MARK: - Run

@MainActor
func run() {
    d16SingleColumnGeometry()
    d03SingleColumnNeverLoops()
    d03ShortStripNeverLoops()
    d03NonStripModesNeverLoop()
    d08LoopSnapTarget()
    d18ScrollBounds()
    d18AllPathsAgree()
    d19LoopFramesRemainOrdered()

    print("")
    if failures == 0 {
        print("PASS: \(checks) checks")
    } else {
        print("FAILED: \(failures) of \(checks) checks")
        exit(1)
    }
}

run()
