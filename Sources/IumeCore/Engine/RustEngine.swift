import Foundation
import CoreGraphics
import CIumeEngine

/// Swift facade over the Rust strip engine.
///
/// The Rust static library owns every hot-path calculation: strip geometry,
/// viewport projection, snapping, spring integration and magnetic adhesion.
/// Inputs are marshalled into flat C arrays; the engine writes frames into a
/// thread-local buffer which is copied out before returning.
///
/// All entry points are pure and thread-safe. They return `nil` only when the
/// engine rejects malformed input, letting callers fall back to the Swift
/// reference implementation (used by the parity tests).
public enum RustEngine {

    /// ABI version compiled into the linked static library.
    public static let abiVersion: UInt32 = iume_abi_version()

    /// Always true: the static library is linked into the executable.
    public static var isAvailable: Bool { abiVersion == 1 }

    public static var versionDescription: String {
        "iume_engine ABI \(abiVersion)"
    }

    // MARK: - Marshalling

    /// Flat buffers matching the C ABI. Columns reference slices of `ids` and
    /// `entries` by offset, so no pointers are stored across array mutations.
    struct Payload {
        var columns: [IumeColumn] = []
        var ids: [IumeWindowId] = []
        var entries: [IumeStackedEntry] = []
        var windows: [IumeWindowRecord] = []
    }

    static func makePayload(
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow]? = nil
    ) -> Payload {
        var payload = Payload()
        payload.columns.reserveCapacity(columns.count)

        let totalIDs = columns.reduce(0) { $0 + $1.windowIds.count }
        let totalEntries = columns.reduce(0) { $0 + $1.windowEntries.count }
        payload.ids.reserveCapacity(totalIDs)
        payload.entries.reserveCapacity(totalEntries)
        if let windows { payload.windows.reserveCapacity(min(totalIDs, windows.count)) }

        for column in columns {
            let idStart = UInt32(payload.ids.count)
            for id in column.windowIds {
                payload.ids.append(IumeWindowId(pid: id.pid, raw_id: id.rawId))
                if let windows, let window = windows[id] {
                    payload.windows.append(
                        IumeWindowRecord(
                            id: IumeWindowId(pid: id.pid, raw_id: id.rawId),
                            flags: IumeWindowFlags(
                                is_floating: window.isFloating ? 1 : 0,
                                is_minimized: window.isMinimized ? 1 : 0
                            ),
                            frame: IumeRect(
                                x: Double(window.frame.origin.x),
                                y: Double(window.frame.origin.y),
                                width: Double(window.frame.width),
                                height: Double(window.frame.height)
                            )
                        )
                    )
                }
            }
            let idCount = UInt32(payload.ids.count) - idStart

            let entryStart = UInt32(payload.entries.count)
            for entry in column.windowEntries {
                payload.entries.append(
                    IumeStackedEntry(
                        id: IumeWindowId(pid: entry.id.pid, raw_id: entry.id.rawId),
                        height_ratio: Double(entry.heightRatio)
                    )
                )
            }
            let entryCount = UInt32(payload.entries.count) - entryStart

            payload.columns.append(
                IumeColumn(
                    id_start: idStart,
                    id_count: idCount,
                    entry_start: entryStart,
                    entry_count: entryCount,
                    width: Double(column.width),
                    presentation: column.presentationMode == .tabbed ? 1 : 0,
                    active_window_index: UInt32(max(0, column.activeWindowIndex)),
                    is_full_width: column.isFullWidth ? 1 : 0,
                    saved_pre_full_width_ratio: Double(column.savedPreFullWidthRatio)
                )
            )
        }
        return payload
    }

    @inline(__always)
    static func withPayload<R>(
        _ payload: Payload,
        _ body: (
            UnsafeBufferPointer<IumeColumn>,
            UnsafeBufferPointer<IumeWindowId>,
            UnsafeBufferPointer<IumeStackedEntry>
        ) -> R
    ) -> R {
        payload.columns.withUnsafeBufferPointer { cols in
            payload.ids.withUnsafeBufferPointer { ids in
                payload.entries.withUnsafeBufferPointer { entries in
                    body(cols, ids, entries)
                }
            }
        }
    }

    @inline(__always)
    static func withPayloadAndWindows<R>(
        _ payload: Payload,
        _ body: (
            UnsafeBufferPointer<IumeColumn>,
            UnsafeBufferPointer<IumeWindowId>,
            UnsafeBufferPointer<IumeStackedEntry>,
            UnsafeBufferPointer<IumeWindowRecord>
        ) -> R
    ) -> R {
        withPayload(payload) { cols, ids, entries in
            payload.windows.withUnsafeBufferPointer { windows in
                body(cols, ids, entries, windows)
            }
        }
    }

    @inline(__always)
    static func u32(_ value: Int) -> UInt32 {
        UInt32(clamping: value)
    }

    // MARK: - Strip geometry

    public static func totalStripWidth(columns: [WindowColumn], gap: CGFloat) -> CGFloat? {
        guard !columns.isEmpty else { return 0 }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            let width = iume_total_strip_width(
                cols.baseAddress, u32(cols.count),
                ids.baseAddress, u32(ids.count),
                entries.baseAddress, u32(entries.count),
                Double(gap)
            )
            return CGFloat(width)
        }
    }

    public static func columnStripOffsets(columns: [WindowColumn], gap: CGFloat) -> [CGFloat]? {
        guard !columns.isEmpty else { return [] }
        let payload = makePayload(columns: columns)
        var output = [Double](repeating: 0, count: columns.count)
        let written = withPayload(payload) { cols, ids, entries in
            output.withUnsafeMutableBufferPointer { buffer in
                iume_column_offsets(
                    cols.baseAddress, u32(cols.count),
                    ids.baseAddress, u32(ids.count),
                    entries.baseAddress, u32(entries.count),
                    Double(gap),
                    buffer.baseAddress, u32(buffer.count)
                )
            }
        }
        guard Int(written) == columns.count else { return nil }
        return output.map { CGFloat($0) }
    }

    public static func maxScrollOffset(
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        centerMode: CenterMode,
        gap: CGFloat
    ) -> CGFloat? {
        guard !columns.isEmpty else { return 0 }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            let value = iume_max_scroll_offset(
                cols.baseAddress, u32(cols.count),
                ids.baseAddress, u32(ids.count),
                entries.baseAddress, u32(entries.count),
                Double(visibleWidth), centerMode.rustValue, Double(gap)
            )
            return CGFloat(value)
        }
    }

    public static func computeViewportOffset(
        columns: [WindowColumn],
        focusedColumnIndex: Int?,
        currentViewportOffset: CGFloat,
        visibleWidth: CGFloat,
        layoutMode: LayoutMode,
        centerMode: CenterMode,
        gap: CGFloat
    ) -> CGFloat? {
        guard !columns.isEmpty else { return 0 }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            let value = iume_compute_viewport_offset(
                cols.baseAddress, u32(cols.count),
                ids.baseAddress, u32(ids.count),
                entries.baseAddress, u32(entries.count),
                Int32(clamping: focusedColumnIndex ?? -1),
                Double(currentViewportOffset),
                Double(visibleWidth),
                layoutMode.rustValue,
                centerMode.rustValue,
                Double(gap)
            )
            return CGFloat(value)
        }
    }

    public static func findClosestColumnIndex(
        viewportOffset: CGFloat,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        gap: CGFloat
    ) -> Int? {
        guard !columns.isEmpty else { return 0 }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            Int(
                iume_find_closest_column(
                    cols.baseAddress, u32(cols.count),
                    ids.baseAddress, u32(ids.count),
                    entries.baseAddress, u32(entries.count),
                    Double(viewportOffset), Double(visibleWidth), Double(gap)
                )
            )
        }
    }

    public static func centerColumnOffset(
        index: Int,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        guard index >= 0, index < columns.count else { return nil }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            CGFloat(
                iume_center_column_offset(
                    cols.baseAddress, u32(cols.count),
                    ids.baseAddress, u32(ids.count),
                    entries.baseAddress, u32(entries.count),
                    u32(index), Double(visibleWidth), Double(gap)
                )
            )
        }
    }

    public static func computeSnapTarget(
        projectedOffset: CGFloat,
        velocity: CGFloat,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        centerMode: CenterMode,
        gap: CGFloat
    ) -> LayoutEngine.SnapTarget? {
        guard !columns.isEmpty else {
            return LayoutEngine.SnapTarget(targetOffset: 0, focusedColumnIndex: 0)
        }
        let payload = makePayload(columns: columns)
        return withPayload(payload) { cols, ids, entries in
            let target = iume_compute_snap_target(
                cols.baseAddress, u32(cols.count),
                ids.baseAddress, u32(ids.count),
                entries.baseAddress, u32(entries.count),
                Double(projectedOffset), Double(velocity),
                Double(visibleWidth), centerMode.rustValue, Double(gap)
            )
            return LayoutEngine.SnapTarget(
                targetOffset: CGFloat(target.target_offset),
                focusedColumnIndex: Int(target.focused_column_index)
            )
        }
    }

    // MARK: - Layout

    public static func computeLayout(
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        focusedColumnIndex: Int?,
        visibleFrame: CGRect,
        viewportOffset: CGFloat,
        windowGap: CGFloat,
        edgeMargins: EdgeMargins,
        defaultColumnWidthRatio: CGFloat,
        defaultMinimumColumnWidth: CGFloat,
        offScreenPeekSliverWidth: CGFloat,
        layoutMode: LayoutMode,
        centerMode: CenterMode,
        isBuiltinDisplay: Bool,
        disablePaddingOnBuiltinDisplay: Bool,
        smartWindowMargins: Bool
    ) -> LayoutComputation? {
        guard !columns.isEmpty else {
            return LayoutComputation(targetFrames: [:], totalStripWidth: 0, targetViewportOffset: 0)
        }

        let payload = makePayload(columns: columns, windows: windows)
        return withPayloadAndWindows(payload) { cols, ids, entries, windowBuffer in
            var config = IumeConfig(
                window_gap: Double(windowGap),
                margin_top: Double(edgeMargins.top),
                margin_bottom: Double(edgeMargins.bottom),
                margin_left: Double(edgeMargins.left),
                margin_right: Double(edgeMargins.right),
                default_column_width_ratio: Double(defaultColumnWidthRatio),
                default_minimum_column_width: Double(defaultMinimumColumnWidth),
                off_screen_peek_sliver_width: Double(offScreenPeekSliverWidth),
                center_mode: centerMode.rustValue,
                layout_mode: layoutMode.rustValue,
                smart_window_margins: smartWindowMargins ? 1 : 0,
                disable_padding_on_builtin: disablePaddingOnBuiltinDisplay ? 1 : 0,
                is_builtin_display: isBuiltinDisplay ? 1 : 0
            )

            let result = iume_compute_layout(
                cols.baseAddress, u32(cols.count),
                ids.baseAddress, u32(ids.count),
                entries.baseAddress, u32(entries.count),
                windowBuffer.baseAddress, u32(windowBuffer.count),
                Int32(clamping: focusedColumnIndex ?? -1),
                IumeRect(
                    x: Double(visibleFrame.origin.x),
                    y: Double(visibleFrame.origin.y),
                    width: Double(visibleFrame.width),
                    height: Double(visibleFrame.height)
                ),
                Double(viewportOffset),
                &config
            )

            let frameCount = Int(result.frame_count)
            if frameCount > 0 && result.frames == nil { return nil }

            var targetFrames: [WindowId: CGRect] = [:]
            targetFrames.reserveCapacity(frameCount)
            var parked: Set<WindowId> = []
            parked.reserveCapacity(frameCount)

            if let base = result.frames, frameCount > 0 {
                let frames = UnsafeBufferPointer(start: base, count: frameCount)
                for frame in frames {
                    let id = WindowId(pid: frame.id.pid, rawId: frame.id.raw_id)
                    targetFrames[id] = CGRect(
                        x: frame.frame.x,
                        y: frame.frame.y,
                        width: frame.frame.width,
                        height: frame.frame.height
                    )
                    if frame.is_parked != 0 {
                        parked.insert(id)
                    }
                }
            }

            return LayoutComputation(
                targetFrames: targetFrames,
                totalStripWidth: CGFloat(result.total_strip_width),
                targetViewportOffset: CGFloat(result.target_viewport_offset),
                parkedWindowIds: parked
            )
        }
    }

    // MARK: - Spring

    @inline(__always)
    public static func step(spring state: inout SpringState, dt: CGFloat) {
        var cState = IumeSpringState(
            position: Double(state.position),
            velocity: Double(state.velocity),
            target: Double(state.target),
            response: Double(state.response),
            damping_ratio: Double(state.dampingRatio)
        )
        iume_spring_step(&cState, Double(dt))
        state.position = CGFloat(cState.position)
        state.velocity = CGFloat(cState.velocity)
    }

    @inline(__always)
    public static func springIsAtRest(_ state: SpringState) -> Bool {
        var cState = IumeSpringState(
            position: Double(state.position),
            velocity: Double(state.velocity),
            target: Double(state.target),
            response: Double(state.response),
            damping_ratio: Double(state.dampingRatio)
        )
        return iume_spring_is_at_rest(&cState) != 0
    }

    // MARK: - Magnetic

    public static func snapSeamRatio(
        combinedWidth: CGFloat,
        targetWidth: CGFloat,
        snapRadius: CGFloat
    ) -> CGFloat {
        CGFloat(
            iume_snap_seam_ratio(
                Double(combinedWidth),
                Double(targetWidth),
                Double(snapRadius)
            )
        )
    }

    public static func evaluateMagneticSnap(
        draggedId: WindowId,
        draggedFrame: CGRect,
        candidateWindows: [(id: WindowId, frame: CGRect)],
        gap: CGFloat,
        visibleFrame: CGRect?,
        snapRadius: CGFloat
    ) -> MagneticWindowEngine.SnapResult? {
        var records: [IumeWindowRecord] = []
        records.reserveCapacity(candidateWindows.count)
        for candidate in candidateWindows {
            records.append(
                IumeWindowRecord(
                    id: IumeWindowId(pid: candidate.id.pid, raw_id: candidate.id.rawId),
                    flags: IumeWindowFlags(is_floating: 0, is_minimized: 0),
                    frame: IumeRect(
                        x: Double(candidate.frame.origin.x),
                        y: Double(candidate.frame.origin.y),
                        width: Double(candidate.frame.width),
                        height: Double(candidate.frame.height)
                    )
                )
            )
        }

        let dragged = IumeWindowId(pid: draggedId.pid, raw_id: draggedId.rawId)
        let draggedRect = IumeRect(
            x: Double(draggedFrame.origin.x),
            y: Double(draggedFrame.origin.y),
            width: Double(draggedFrame.width),
            height: Double(draggedFrame.height)
        )

        let snap: IumeMagneticSnap
        if let visible = visibleFrame {
            var visibleRect = IumeRect(
                x: Double(visible.origin.x),
                y: Double(visible.origin.y),
                width: Double(visible.width),
                height: Double(visible.height)
            )
            snap = withUnsafePointer(to: &visibleRect) { pointer in
                records.withUnsafeBufferPointer { buffer in
                    iume_evaluate_magnetic_snap(
                        dragged, draggedRect,
                        buffer.baseAddress, u32(buffer.count),
                        Double(gap), pointer, Double(snapRadius)
                    )
                }
            }
        } else {
            snap = records.withUnsafeBufferPointer { buffer in
                iume_evaluate_magnetic_snap(
                    dragged, draggedRect,
                    buffer.baseAddress, u32(buffer.count),
                    Double(gap), nil, Double(snapRadius)
                )
            }
        }

        guard snap.has_value != 0 else { return nil }

        let edge: MagneticWindowEngine.SnapResult.Edge
        switch snap.edge {
        case 0: edge = .leftOfCandidate
        case 1: edge = .rightOfCandidate
        case 2: edge = .screenLeftEdge
        default: edge = .screenRightEdge
        }

        let candidateId = snap.has_candidate != 0
            ? WindowId(pid: snap.candidate.pid, rawId: snap.candidate.raw_id)
            : nil
        let candidateFrame = snap.has_candidate != 0
            ? CGRect(
                x: snap.candidate_frame.x,
                y: snap.candidate_frame.y,
                width: snap.candidate_frame.width,
                height: snap.candidate_frame.height
            )
            : nil

        return MagneticWindowEngine.SnapResult(
            snappedFrame: CGRect(
                x: snap.snapped_frame.x,
                y: snap.snapped_frame.y,
                width: snap.snapped_frame.width,
                height: snap.snapped_frame.height
            ),
            candidateWindowId: candidateId,
            candidateFrame: candidateFrame,
            edge: edge,
            distance: CGFloat(snap.distance)
        )
    }

    public static func computeChainedFrames(
        draggedId: WindowId,
        draggedFrame: CGRect,
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        gap: CGFloat,
        breakawayThreshold: CGFloat,
        capacity: Int
    ) -> [(id: WindowId, frame: CGRect)]? {
        guard capacity > 0 else { return [] }
        let payload = makePayload(columns: columns, windows: windows)
        var output = [IumeChainedFrame](
            repeating: IumeChainedFrame(
                id: IumeWindowId(pid: 0, raw_id: 0),
                frame: IumeRect(x: 0, y: 0, width: 0, height: 0)
            ),
            count: capacity
        )

        let written = withPayloadAndWindows(payload) { cols, ids, entries, windowBuffer in
            output.withUnsafeMutableBufferPointer { buffer in
                iume_compute_chained_frames(
                    IumeWindowId(pid: draggedId.pid, raw_id: draggedId.rawId),
                    IumeRect(
                        x: Double(draggedFrame.origin.x),
                        y: Double(draggedFrame.origin.y),
                        width: Double(draggedFrame.width),
                        height: Double(draggedFrame.height)
                    ),
                    cols.baseAddress, u32(cols.count),
                    ids.baseAddress, u32(ids.count),
                    entries.baseAddress, u32(entries.count),
                    windowBuffer.baseAddress, u32(windowBuffer.count),
                    Double(gap), Double(breakawayThreshold),
                    buffer.baseAddress, u32(buffer.count)
                )
            }
        }

        let count = min(Int(written), capacity)
        return output.prefix(count).map { frame in
            (
                id: WindowId(pid: frame.id.pid, rawId: frame.id.raw_id),
                frame: CGRect(
                    x: frame.frame.x,
                    y: frame.frame.y,
                    width: frame.frame.width,
                    height: frame.frame.height
                )
            )
        }
    }
}

// MARK: - Enum bridges

extension CenterMode {
    @inline(__always)
    var rustValue: UInt32 {
        switch self {
        case .never: return 0
        case .onOverflow: return 1
        case .always: return 2
        }
    }
}

extension LayoutMode {
    @inline(__always)
    var rustValue: UInt32 {
        switch self {
        case .scrollStrip: return 0
        case .focusColumn: return 1
        case .centeredFocus: return 2
        case .manualLayout: return 3
        default: return 0
        }
    }
}
