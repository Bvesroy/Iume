# Iume sliding-engine measurement — baseline-before

- Timestamp (UTC): 20261025T172727Z
- Commit: 9992c8054f58f24e83e8a342f131d6719254c898
- Working-tree fingerprint: 1409b8a7289b8744b2d15350c3df5d86b313a8f1
- macOS: 27.0.1
- CPU: Apple M4
- Rust: rustc 1.99.1 (58cf8f9c3 2026-10-13)
- Swift: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)

## Rust unit tests
```
running 30 tests
test ffi::tests::seam_ffi ... ok
test ffi::tests::spring_ffi_converges ... ok
test ffi::tests::layout_ffi_roundtrip ... ok
test layout::tests::cycle_width_matches_swift ... ok
test layout::tests::left_sliver_clamp_matches_swift ... ok
test layout::tests::centered_focus_matches_swift ... ok
test layout::tests::insertion_after_focused_matches_swift ... ok
test layout::tests::offsets_match_swift ... ok
test layout::tests::removal_matches_swift ... ok
test layout::tests::snap_target_matches_swift ... ok
test layout::tests::right_edge_parking_matches_swift ... ok
test layout::tests::stacked_frames_match_swift ... ok
test layout::tests::tabbed_column_reserves_tab_bar ... ok
test layout::tests::total_width_matches_swift ... ok
test layout::tests::viewport_scroll_strip_matches_swift ... ok
test layout::tests::zero_gap_edge_margins_flush ... ok
test magnetic::tests::no_snap_beyond_radius ... ok
test magnetic::tests::chained_right_neighbor_moves ... ok
test magnetic::tests::seam_snaps_to_half ... ok
test magnetic::tests::snaps_left_to_right ... ok
test magnetic::tests::snaps_right_to_left ... ok
test spring::tests::converges_to_target ... ok
test spring::tests::critically_damped_settles ... ok
test spring::tests::large_dt_is_clamped ... ok
test spring::tests::no_overshoot_beyond_reasonable_bounds ... ok
test spring::tests::smoothing_factor_monotonic ... ok
test types::tests::column_entries_sync_with_ids ... ok
test spring::tests::stable_at_240hz_and_80hz ... ok
test types::tests::frame_buffer_capacity ... ok
test types::tests::rect_helpers ... ok

test result: ok. 30 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests iume_engine

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

```

Rust test status: 0

## Spring benchmark (real crate sources)
engine build failed (status 1):
```
error: environment variable `CARGO_PKG_VERSION` not defined at compile time
  --> /Users/bves/projects/Iume/crates/iume_engine/src/lib.rs:29:27
   |
29 | pub const VERSION: &str = env!("CARGO_PKG_VERSION");
   |                           ^^^^^^^^^^^^^^^^^^^^^^^^^
   |
   = help: `CARGO_PKG_VERSION` may not be available for the current Cargo target
   = help: Cargo sets build script variables at run time. Use `std::env::var("CARGO_PKG_VERSION")` instead

error: aborting due to 1 previous error

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
