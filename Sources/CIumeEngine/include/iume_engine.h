/*
 * iume_engine.h — stable C ABI for the Iume Rust layout/spring engine.
 *
 * Rules:
 *  - All structs are `#[repr(C)]` on the Rust side; do not reorder fields.
 *  - `iume_compute_layout` returns a pointer into a thread-local buffer that is
 *    valid until the next engine call on the same thread. Copy it out before
 *    calling again.
 *  - Every function is thread-safe; there is no shared mutable engine state.
 */

#ifndef IUME_ENGINE_H
#define IUME_ENGINE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IUME_ABI_VERSION 1

typedef struct {
    int32_t pid;
    uint64_t raw_id;
} IumeWindowId;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} IumeRect;

typedef struct {
    uint8_t is_floating;
    uint8_t is_minimized;
} IumeWindowFlags;

typedef struct {
    IumeWindowId id;
    IumeWindowFlags flags;
    IumeRect frame;
} IumeWindowRecord;

typedef struct {
    uint32_t id_start;
    uint32_t id_count;
    uint32_t entry_start;
    uint32_t entry_count;
    double width;
    uint32_t presentation; /* 0 = stacked, 1 = tabbed */
    uint32_t active_window_index;
    uint8_t is_full_width;
    double saved_pre_full_width_ratio;
} IumeColumn;

typedef struct {
    IumeWindowId id;
    double height_ratio;
} IumeStackedEntry;

typedef struct {
    double window_gap;
    double margin_top;
    double margin_bottom;
    double margin_left;
    double margin_right;
    double default_column_width_ratio;
    double default_minimum_column_width;
    double off_screen_peek_sliver_width;
    uint32_t center_mode;  /* 0 = never, 1 = onOverflow, 2 = always */
    uint32_t layout_mode;  /* 0 = scrollStrip, 1 = focusColumn, 2 = centeredFocus, 3 = manual */
    uint8_t smart_window_margins;
    uint8_t disable_padding_on_builtin;
    uint8_t is_builtin_display;
} IumeConfig;

typedef struct {
    IumeWindowId id;
    IumeRect frame;
    uint8_t is_parked;
} IumeFrameOut;

typedef struct {
    const IumeFrameOut *frames;
    uint32_t frame_count;
    double total_strip_width;
    double target_viewport_offset;
} IumeLayoutResult;

typedef struct {
    double target_offset;
    uint32_t focused_column_index;
} IumeSnapTarget;

typedef struct {
    uint8_t has_value;
    IumeRect snapped_frame;
    IumeWindowId candidate;
    uint8_t has_candidate;
    IumeRect candidate_frame;
    uint32_t edge; /* 0 = leftOfCandidate, 1 = rightOfCandidate, 2 = screenLeft, 3 = screenRight */
    double distance;
} IumeMagneticSnap;

typedef struct {
    IumeWindowId id;
    IumeRect frame;
} IumeChainedFrame;

typedef struct {
    double position;
    double velocity;
    double target;
    double response;
    double damping_ratio;
} IumeSpringState;

uint32_t iume_abi_version(void);

double iume_total_strip_width(const IumeColumn *columns, uint32_t column_count,
                              const IumeWindowId *ids, uint32_t id_count,
                              const IumeStackedEntry *entries, uint32_t entry_count,
                              double gap);

uint32_t iume_column_offsets(const IumeColumn *columns, uint32_t column_count,
                             const IumeWindowId *ids, uint32_t id_count,
                             const IumeStackedEntry *entries, uint32_t entry_count,
                             double gap, double *out, uint32_t out_capacity);

double iume_max_scroll_offset(const IumeColumn *columns, uint32_t column_count,
                              const IumeWindowId *ids, uint32_t id_count,
                              const IumeStackedEntry *entries, uint32_t entry_count,
                              double visible_width, uint32_t center_mode, double gap);

double iume_compute_viewport_offset(const IumeColumn *columns, uint32_t column_count,
                                    const IumeWindowId *ids, uint32_t id_count,
                                    const IumeStackedEntry *entries, uint32_t entry_count,
                                    int32_t focused_column, double current_offset,
                                    double visible_width, uint32_t layout_mode,
                                    uint32_t center_mode, double gap);

IumeLayoutResult iume_compute_layout(const IumeColumn *columns, uint32_t column_count,
                                     const IumeWindowId *ids, uint32_t id_count,
                                     const IumeStackedEntry *entries, uint32_t entry_count,
                                     const IumeWindowRecord *windows, uint32_t window_count,
                                     int32_t focused_column, IumeRect visible_frame,
                                     double viewport_offset, const IumeConfig *config);

IumeSnapTarget iume_compute_snap_target(const IumeColumn *columns, uint32_t column_count,
                                        const IumeWindowId *ids, uint32_t id_count,
                                        const IumeStackedEntry *entries, uint32_t entry_count,
                                        double projected_offset, double velocity,
                                        double visible_width, uint32_t center_mode, double gap);

uint32_t iume_find_closest_column(const IumeColumn *columns, uint32_t column_count,
                                  const IumeWindowId *ids, uint32_t id_count,
                                  const IumeStackedEntry *entries, uint32_t entry_count,
                                  double viewport_offset, double visible_width, double gap);

double iume_center_column_offset(const IumeColumn *columns, uint32_t column_count,
                                 const IumeWindowId *ids, uint32_t id_count,
                                 const IumeStackedEntry *entries, uint32_t entry_count,
                                 uint32_t column_index, double visible_width, double gap);

double iume_snap_seam_ratio(double combined_width, double target_width, double snap_radius);

IumeMagneticSnap iume_evaluate_magnetic_snap(IumeWindowId dragged_id, IumeRect dragged_frame,
                                             const IumeWindowRecord *candidates,
                                             uint32_t candidate_count, double gap,
                                             const IumeRect *visible_frame, double snap_radius);

uint32_t iume_compute_chained_frames(IumeWindowId dragged_id, IumeRect dragged_frame,
                                     const IumeColumn *columns, uint32_t column_count,
                                     const IumeWindowId *ids, uint32_t id_count,
                                     const IumeStackedEntry *entries, uint32_t entry_count,
                                     const IumeWindowRecord *windows, uint32_t window_count,
                                     double gap, double breakaway_threshold,
                                     IumeChainedFrame *out, uint32_t out_capacity);

void iume_spring_step(IumeSpringState *state, double dt);
uint8_t iume_spring_is_at_rest(const IumeSpringState *state);
double iume_smoothing_factor(double smoothness, double dt);
double iume_rubber_band(double delta, double overshoot, double limit);

#ifdef __cplusplus
}
#endif

#endif /* IUME_ENGINE_H */
