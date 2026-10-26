# Iume sliding-engine measurement — baseline-before

- Timestamp (UTC): 20261025T172854Z
- Commit: 9992c8054f58f24e83e8a342f131d6719254c898
- Working-tree fingerprint: 81b51e7873106dbe1d879228d3a6407fde64aa4c
- macOS: 27.0.1
- CPU: Apple M4
- Rust: rustc 1.99.1 (58cf8f9c3 2026-10-13)
- Swift: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)

## Rust unit tests
```
running 30 tests
test ffi::tests::seam_ffi ... ok
test layout::tests::cycle_width_matches_swift ... ok
test ffi::tests::layout_ffi_roundtrip ... ok
test layout::tests::centered_focus_matches_swift ... ok
test layout::tests::removal_matches_swift ... ok
test layout::tests::right_edge_parking_matches_swift ... ok
test layout::tests::offsets_match_swift ... ok
test layout::tests::snap_target_matches_swift ... ok
test ffi::tests::spring_ffi_converges ... ok
test layout::tests::insertion_after_focused_matches_swift ... ok
test layout::tests::stacked_frames_match_swift ... ok
test layout::tests::total_width_matches_swift ... ok
test layout::tests::left_sliver_clamp_matches_swift ... ok
test layout::tests::tabbed_column_reserves_tab_bar ... ok
test layout::tests::viewport_scroll_strip_matches_swift ... ok
test layout::tests::zero_gap_edge_margins_flush ... ok
test magnetic::tests::chained_right_neighbor_moves ... ok
test magnetic::tests::no_snap_beyond_radius ... ok
test magnetic::tests::seam_snaps_to_half ... ok
test magnetic::tests::snaps_left_to_right ... ok
test magnetic::tests::snaps_right_to_left ... ok
test spring::tests::converges_to_target ... ok
test spring::tests::critically_damped_settles ... ok
test spring::tests::large_dt_is_clamped ... ok
test spring::tests::no_overshoot_beyond_reasonable_bounds ... ok
test spring::tests::smoothing_factor_monotonic ... ok
test spring::tests::stable_at_240hz_and_80hz ... ok
test types::tests::column_entries_sync_with_ids ... ok
test types::tests::frame_buffer_capacity ... ok
test types::tests::rect_helpers ... ok

test result: ok. 30 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests iume_engine

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

```

Rust test status: 0

## Spring benchmark (real crate sources)
| case | 60 Hz | 80 Hz | 120 Hz | 240 Hz |
|---|---:|---:|---:|---:|
| settle 100 pt | 333 ms / 0.00 pt / 20f | 312 ms / 0.00 pt / 25f | 292 ms / 0.00 pt / 35f | 271 ms / 0.00 pt / 65f |
| settle 500 pt | 367 ms / 0.00 pt / 22f | 350 ms / 0.05 pt / 28f | 325 ms / 0.10 pt / 39f | 296 ms / 0.17 pt / 71f |
| settle 2000 pt | 400 ms / 0.22 pt / 24f | 363 ms / 0.30 pt / 29f | 433 ms / 0.52 pt / 52f | 421 ms / 0.79 pt / 101f |
| settle 20000 pt | 583 ms / 2.39 pt / 35f | 562 ms / 3.45 pt / 45f | 542 ms / 5.16 pt / 65f | 512 ms / 7.92 pt / 123f |

| elapsed | 60 Hz | 80 Hz | 120 Hz | 240 Hz | spread |
|---|---:|---:|---:|---:|---:|
| 50 ms | 202.78 | 206.35 | 210.15 | 214.22 | 11.44 pt |
| 100 ms | 373.23 | 380.88 | 389.13 | 398.11 | 24.88 pt |
| 200 ms | 486.28 | 489.17 | 491.92 | 494.48 | 8.20 pt |
| 350 ms | 499.98 | 500.00 | 500.00 | 500.00 | 0.02 pt |

Retarget continuity: position 800.000000 -> 800.000000 (Δ0.00e0), velocity 0.000000 -> 0.000000 (Δ0.00e0); settles in 333 ms, peak 800.00 pt.

Reversal at 120 Hz: max single-frame displacement 165.50 pt (velocity at retarget 0.0 pt/s).

Rapid retarget @ 8 ms: max single-frame displacement 21.27 pt, final 6.40 pt.
Rapid retarget @ 16 ms: max single-frame displacement 61.13 pt, final -21.27 pt.

10 s stall: spring position 245.21 pt (max 1000.0); momentum-velocity state position 27.33 pt.

```json
{"rates":[60,80,120,240],"consistency":[{"seconds":0.05,"positions":[202.784239,206.354522,210.154856,214.221619],"spread":11.437380},{"seconds":0.1,"positions":[373.233209,380.876963,389.134911,398.108233],"spread":24.875024},{"seconds":0.2,"positions":[486.281611,489.169465,491.916830,494.480069],"spread":8.198458},{"seconds":0.35,"positions":[499.984612,500.000000,500.000000,500.000000],"spread":0.015388}],"retarget":{"pos_before":800.000000,"pos_after":800.000000,"vel_before":0.000000,"vel_after":0.000000,"settle_ms":333.333,"peak":800.000000},"reversal_max_frame_step":165.497017,"stall_step_10s":245.212738}
```

## Swift tests
Swift test status: 1 (blocked or failed)
```
error: SwiftCompile normal arm64 failed with a nonzero exit code. Command line:     cd /Users/bves/projects
/Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapLoopCarouselView.swift:179:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
    [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapLoopCarouselView.swift:179:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
    [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:569:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:570:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:571:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:572:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:573:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:574:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:575:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
     [0;36m|[0;0m                        `- [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
/Users/bves/projects/Iume/Sources/IumeCore/UI/Overlays.swift:576:24: [1;31merror: [1;39mexternal macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found[0;0m
```

## Standalone Swift physics harness
Physics harness not present yet.

## Environment note
SwiftPM failures caused by a missing Xcode SwiftUI macro plugin are
environment limitations, not product regressions. Rust and the
standalone physics harness still exercise the shipped physics source.
