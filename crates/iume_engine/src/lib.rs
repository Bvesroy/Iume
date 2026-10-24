//! Iume engine — deterministic layout, viewport, magnetic and spring math.
//!
//! The crate is intentionally dependency-free so the static library stays tiny
//! and the build stays hermetic. `ffi` exposes a stable C ABI consumed by
//! `Sources/IumeCore/RustEngine`.
//!
//! # Guarantees
//! * **No allocation on the hot path.** `compute_layout` borrows its inputs and
//!   writes into a caller-owned fixed buffer.
//! * **Deterministic.** All math is `f64`, rounding matches Swift's `round()`.
//! * **Panic-free ABI.** Every exported function validates pointers and bounds.

#![deny(clippy::undocumented_unsafe_blocks)]
#![allow(clippy::missing_safety_doc)]

pub mod ffi;
pub mod layout;
pub mod magnetic;
pub mod spring;
pub mod types;

pub use types::{
    CenterMode, ColumnPresentation, DisplayGeometry, EdgeMargins, EngineConfig, FrameBuffer,
    FrameOut, InsertionPolicy, LayoutMode, MagneticSnap, Rect, SnapTarget, StackedEntry,
    WindowColumn, WindowFlags, WindowId, WindowRecord, MAX_FRAMES,
};

/// Crate version, surfaced in diagnostics.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
