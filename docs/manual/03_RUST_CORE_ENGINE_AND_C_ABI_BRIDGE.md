# Module 03: Rust Core Engine & C ABI Bridge

## 1. Overview & Architectural Role

The Rust engine ([`crates/iume_engine`](file:///Users/bves/projects/Iume/crates/iume_engine/)) is a pure, zero-dependency, allocation-free static library (`libiume_engine.a`) linked into [`IumeCore`](file:///Users/bves/projects/Iume/Sources/IumeCore/). It provides deterministic mathematical solutions for:
1. **Strip Geometry & Layout**: Column coordinate projection, centering modes, viewport bounds clamping.
2. **Harmonic Spring Physics**: Analytical integration of the damped harmonic oscillator differential equation at variable frame deltas.
3. **Magnetic Snapping**: Edge attraction, candidate bounding box hit testing, and seam-ratio split quantization.

```
+-----------------------------------------------------------------------------------------+
|                                    SWIFT (IumeCore)                                     |
|    RustEngine.swift facade · Flat buffer marshalling · Copied output frames             |
+-----------------------------------------------------------------------------------------+
                                           │
                                           │ C ABI Call (Zero overhead, direct pointer pass)
                                           ▼
+-----------------------------------------------------------------------------------------+
|                                C BRIDGE (CIumeEngine)                                   |
|    include/iume_engine.h · #[repr(C)] struct declarations · Stable ABI v1               |
+-----------------------------------------------------------------------------------------+
                                           │
                                           │ Native symbol linkage
                                           ▼
+-----------------------------------------------------------------------------------------+
|                               RUST CORE (iume_engine)                                   |
|    layout.rs · spring.rs · magnetic.rs · types.rs · ffi.rs                              |
|    • Thread-local static FrameBuffer (MAX_FRAMES = 256)                                 |
|    • Zero heap allocation (no malloc, no Vec realloc on hot path)                       |
|    • Compile profile: opt-level=3, lto="fat", panic="abort", strip="debuginfo"          |
+-----------------------------------------------------------------------------------------+
```

---

## 2. Memory Layout & C ABI Contracts (`types.rs` & `iume_engine.h`)

All data structures traversing the FFI boundary use the standard C ABI memory layout (`#[repr(C)]`). Field order is invariant.

### 2.1 Fundamental Data Structures

#### `IumeWindowId`
```c
typedef struct {
    int32_t pid;       /* Process ID owning the window */
    uint64_t raw_id;   /* Low-level CGWindowID / AXUIElement identifier */
} IumeWindowId;
```

#### `IumeRect`
```c
typedef struct {
    double x;
    double y;
    double width;
    double height;
} IumeRect;
```

#### `IumeColumn`
Represents an aggregated strip column containing one or more stacked/tabbed windows:
```c
typedef struct {
    uint32_t id_start;                 /* Index into flat IumeWindowId array */
    uint32_t id_count;                 /* Number of windows in this column */
    uint32_t entry_start;              /* Index into flat IumeStackedEntry array */
    uint32_t entry_count;              /* Number of stacked height entries */
    double width;                      /* Column width in points */
    uint32_t presentation;             /* 0 = stacked, 1 = tabbed */
    uint32_t active_window_index;      /* Active tab index if tabbed */
    uint8_t is_full_width;             /* 1 if expanded to full screen width */
    double saved_pre_full_width_ratio; /* Restorable ratio prior to full-width */
} IumeColumn;
```

#### `IumeConfig`
Engine-wide layout and geometric configuration parameters:
```c
typedef struct {
    double window_gap;
    double margin_top;
    double margin_bottom;
    double margin_left;
    double margin_right;
    double default_column_width_ratio;
    double default_minimum_column_width;
    double off_screen_peek_sliver_width;
    uint32_t center_mode;              /* 0 = never, 1 = onOverflow, 2 = always */
    uint32_t layout_mode;              /* 0 = scrollStrip, 1 = focusColumn, 2 = centeredFocus, 3 = manual */
    uint8_t smart_window_margins;      /* 1 = collapse outer margins when single column */
    uint8_t disable_padding_on_builtin;
    uint8_t is_builtin_display;
} IumeConfig;
```

---

## 3. Analytical Spring Physics Solver (`spring.rs`)

The motion of windows and the viewport in Iume is governed by an exact closed-form analytical solution of the second-order linear ordinary differential equation for a damped harmonic oscillator:

$$m \frac{d^2x}{dt^2} + c \frac{dx}{dt} + k (x - x_{\text{target}}) = 0$$

Normalizing by mass ($m = 1$), the equation is parameterized by natural angular frequency $\omega$ and damping ratio $\zeta$:

$$\frac{d^2x}{dt^2} + 2\zeta\omega \frac{dx}{dt} + \omega^2 (x - x_{\text{target}}) = 0$$

Where:
- $\omega = \frac{2\pi}{\max(\text{response}, 0.05)}$ (perceptual response time in seconds, default $\approx 0.22\text{s}$).
- $\zeta = \text{damping\_ratio}$ (default $\approx 0.92$ for snappy glide with zero oscillation).
- $d_0 = x(0) - x_{\text{target}}$ (initial displacement from target).
- $v_0 = v(0)$ (initial velocity).

### 3.1 Closed-Form Integration Branches

#### Case 1: Underdamped ($\zeta < 1.0 - 10^{-4}$)
When $\zeta < 1$, the system oscillates with damped frequency $\omega_d = \omega \sqrt{1 - \zeta^2}$:

$$d(t) = e^{-\zeta\omega t} \left[ d_0 \cos(\omega_d t) + \left(\frac{v_0 + \zeta\omega d_0}{\omega_d}\right) \sin(\omega_d t) \right]$$

$$v(t) = e^{-\zeta\omega t} \left[ v_0 \cos(\omega_d t) - \left(\frac{\omega^2 d_0 + \zeta\omega v_0}{\omega_d}\right) \sin(\omega_d t) \right]$$

#### Case 2: Critically Damped ($|\zeta - 1.0| \le 10^{-4}$)
When $\zeta = 1$, the motion returns to equilibrium as fast as possible without oscillating:

$$d(t) = e^{-\omega t} \left[ d_0 + (v_0 + \omega d_0) t \right]$$

$$v(t) = e^{-\omega t} \left[ v_0 - \omega (v_0 + \omega d_0) t \right]$$

#### Case 3: Overdamped ($\zeta > 1.0 + 10^{-4}$)
When $\zeta > 1$, the motion exhibits two real negative exponential decay roots $r_1, r_2 = -\zeta\omega \pm \omega \sqrt{\zeta^2 - 1}$:

$$c_2 = \frac{v_0 - r_1 d_0}{r_2 - r_1}, \quad c_1 = d_0 - c_2$$

$$d(t) = c_1 e^{r_1 t} + c_2 e^{r_2 t}$$

$$v(t) = c_1 r_1 e^{r_1 t} + c_2 r_2 e^{r_2 t}$$

### 3.2 Robustness & Stability Guarantees
- **Frame-Delta Clamping**: Integration step $h = \min(dt, \frac{1}{30.0})$ prevents explosion or tunneling during display lag.
- **Non-Finite Repair**: If position, velocity, or target becomes `NaN` or `Inf`, the state is repaired instantly to $x = x_{\text{target}}, v = 0.0$.
- **Settle Thresholds**: Settles when $|x - x_{\text{target}}| < 0.40\text{ pt}$ and $|v| < 3.5\text{ pt/s}$.

---

## 4. Strip Layout Mathematics (`layout.rs`)

### 4.1 Column Strip Offsets
Calculates the starting X coordinate of every column along the linear strip:
```rust
pub fn column_strip_offsets_views(columns: &[ColumnView<'_>], gap: f64, out: &mut [f64]) -> usize {
    let mut cursor = 0.0;
    let n = columns.len().min(out.len());
    for i in 0..n {
        out[i] = cursor;
        cursor += columns[i].width + gap;
    }
    n
}
```

### 4.2 Centering Modes
- **`.never`**: Strips anchor at $X = 0$.
- **`.onOverflow`**: If $\text{TotalStripWidth} \le \text{VisibleWidth}$, the entire strip is centered on screen:
  $$\text{Offset} = -\frac{\text{VisibleWidth} - \text{TotalStripWidth}}{2}$$
- **`.always`**: Individual focused columns are dynamically centered:
  $$\text{Offset} = \text{ColumnStripX}_i - \frac{\text{VisibleWidth} - \text{ColumnWidth}_i}{2}$$

---

## 5. Magnetic Snapping & Edge Adhesion (`magnetic.rs`)

When windows are manually dragged, `evaluate_magnetic_snap` checks nearby candidate edges within `snap_radius` (default: 32 points).

### 5.1 Seam Ratio Quantization (`snap_seam_ratio`)
When resizing the boundary between two adjacent columns, Iume quantizes the partition ratio to standard aesthetic proportions:

$$\text{Ratios} \in \{ 0.25, 0.3333, 0.50, 0.6667, 0.75 \}$$

If $|\text{TargetWidth} - \text{CombinedWidth} \times \text{Ratio}| \le \text{SnapRadius}$, the seam snaps magnetically to the exact ratio boundary.

---

## 6. FFI Safe Export Layer (`ffi.rs`)

To eliminate allocation overhead on 120Hz display ticks, Rust maintains a thread-local static output frame buffer:

```rust
pub const MAX_FRAMES: usize = 256;

#[repr(C)]
pub struct FrameBuffer {
    pub frames: [FrameOut; MAX_FRAMES],
    pub count: usize,
    pub total_strip_width: f64,
    pub target_viewport_offset: f64,
}

thread_local! {
    static FRAME_BUFFER: std::cell::RefCell<FrameBuffer> = std::cell::RefCell::new(FrameBuffer::new());
}
```

### Pointer Safety & Invariants
1. `iume_compute_layout` validates that all column arrays, entry pointers, and configuration structs are non-null and correctly bounded.
2. The returned `IumeLayoutResult` points directly into the calling thread's `FRAME_BUFFER`. Swift copies out the computed frames immediately before yielding control, guaranteeing zero memory leaks and zero heap fragmentation.
