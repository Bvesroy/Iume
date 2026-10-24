import CoreGraphics
import Foundation

/// A single column's footprint along the horizontal strip, expressed as a 0...1 ratio.
///
/// The circular HUD dial draws the strip as a 270° arc, so every position in the
/// endless layout collapses into a normalised ratio that maps directly onto an angle.
public struct DialColumnGeometry: Equatable, Sendable {
    public var index: Int
    public var startRatio: Double
    public var endRatio: Double
    public var centerRatio: Double

    public init(index: Int, startRatio: Double, endRatio: Double, centerRatio: Double) {
        self.index = index
        self.startRatio = startRatio
        self.endRatio = endRatio
        self.centerRatio = centerRatio
    }
}

/// Pure, AppKit-free mathematics mapping the horizontal window strip onto the circular HUD dial.
///
/// The strip is linear but the dial is a gauge: it opens at 135° (lower left), sweeps 270°
/// clockwise and closes at 45° (lower right), leaving a gap along the bottom so the control
/// reads as an instrument rather than an ambiguous closed loop.
///
/// Keeping this free of UI types means the mapping can be unit tested directly.
public enum DialGeometry {
    /// Angle (degrees) at which strip ratio 0 begins. 0° = 3 o'clock, increasing clockwise.
    public static let startAngleDegrees: Double = 135
    /// Total angular extent of the dial track.
    public static let sweepAngleDegrees: Double = 270

    // MARK: - Angle ⇄ Ratio

    /// Normalises an arbitrary angle into 0..<360.
    public static func normalizeAngle(_ angle: Double) -> Double {
        var n = angle.truncatingRemainder(dividingBy: 360)
        if n < 0 { n += 360 }
        return n
    }

    /// Maps a 0...1 strip ratio to its dial angle in degrees.
    public static func angle(forStripRatio ratio: Double) -> Double {
        startAngleDegrees + clamp01(ratio) * sweepAngleDegrees
    }

    /// Inverse of ``angle(forStripRatio:)``.
    ///
    /// Angles landing inside the bottom gap are ambiguous (the strip has two distinct ends there),
    /// so they snap to whichever end of the strip is angularly closer.
    public static func stripRatio(forAngleDegrees angle: Double) -> Double {
        let normalized = normalizeAngle(angle - startAngleDegrees)
        guard normalized >= sweepAngleDegrees else {
            return normalized / sweepAngleDegrees
        }
        // Inside the bottom gap: nearest end wins.
        return (normalized - sweepAngleDegrees) < (360 - normalized) ? 1 : 0
    }

    // MARK: - Column Layout

    /// Total strip width including inter-column gaps.
    public static func totalStripWidth(widths: [CGFloat], gap: CGFloat) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
    }

    /// Start offset (in points) of each column along the strip.
    public static func startOffsets(widths: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(widths.count)
        var cursor: CGFloat = 0
        for w in widths {
            offsets.append(cursor)
            cursor += max(0, w) + gap
        }
        return offsets
    }

    /// Converts raw column widths into their ratio-space footprints on the dial.
    public static func columnGeometries(widths: [CGFloat], gap: CGFloat = 0) -> [DialColumnGeometry] {
        guard !widths.isEmpty else { return [] }
        let total = totalStripWidth(widths: widths, gap: gap)
        guard total > 0 else { return [] }

        var result: [DialColumnGeometry] = []
        result.reserveCapacity(widths.count)
        var cursor: CGFloat = 0
        for (idx, w) in widths.enumerated() {
            let colWidth = max(0, w)
            let start = Double(cursor / total)
            let colEnd = Double((cursor + colWidth) / total)
            cursor += colWidth + gap
            let end = min(1.0, colEnd)
            result.append(
                DialColumnGeometry(
                    index: idx,
                    startRatio: start,
                    endRatio: max(start, end),
                    centerRatio: (start + max(start, end)) / 2
                )
            )
        }
        return result
    }

    // MARK: - Hit Resolution

    /// Index of the column containing `ratio`, or the nearest one if the ratio lands in a gap.
    /// Returns `nil` for an empty strip.
    public static func columnIndex(atStripRatio ratio: Double, geometries: [DialColumnGeometry]) -> Int? {
        guard !geometries.isEmpty else { return nil }
        let r = clamp01(ratio)
        var best = geometries[0].index
        var bestDistance = Double.greatestFiniteMagnitude
        for geo in geometries {
            let d = distance(from: r, to: geo)
            if d < bestDistance {
                bestDistance = d
                best = geo.index
            }
        }
        return best
    }

    /// Where a dragged column would land if dropped at `ratio`.
    ///
    /// The result is an index into the *final* array, so it already accounts for the dragged
    /// column being lifted out and every later column shifting one slot to the left.
    public static func insertionIndex(atStripRatio ratio: Double, widths: [CGFloat], gap: CGFloat, draggingIndex: Int) -> Int {
        guard widths.count > 1, widths.indices.contains(draggingIndex) else { return 0 }
        let total = totalStripWidth(widths: widths, gap: gap)
        guard total > 0 else { return 0 }

        let offsets = startOffsets(widths: widths, gap: gap)
        let point = clamp01(ratio) * total
        let draggedWidth = max(0, widths[draggingIndex])
        // Lifting a column out of the strip also removes the gap that joined it to its neighbour.
        let removedRun = draggedWidth + gap

        // Express the pointer in the *reduced* strip (the dragged column lifted out).
        //
        // The pointer landing inside the dragged column's own footprint is the delicate case:
        // subtracting the removed run there would shift it left of the slot it came from and
        // teleport the column across the strip on a 4pt nudge. Inside its own footprint the
        // pointer therefore resolves to the vacated slot instead.
        let reducedPoint: CGFloat
        if point <= offsets[draggingIndex] {
            reducedPoint = point
        } else if point >= offsets[draggingIndex] + draggedWidth {
            reducedPoint = point - removedRun
        } else {
            reducedPoint = offsets[draggingIndex]
        }

        var remainingCenters: [CGFloat] = []
        remainingCenters.reserveCapacity(widths.count - 1)
        var cursor: CGFloat = 0
        for (idx, w) in widths.enumerated() where idx != draggingIndex {
            remainingCenters.append(cursor + max(0, w) / 2)
            cursor += max(0, w) + gap
        }

        var insertion = 0
        for center in remainingCenters where reducedPoint >= center {
            insertion += 1
        }
        return min(insertion, widths.count - 1)
    }

    /// The ratio of the boundary a drop at `insertion` lands on, expressed in the **original**
    /// strip space so it lines up with the column arcs drawn on the dial.
    ///
    /// `insertion` is an index into the array *after* the dragged column has been lifted out, so
    /// the boundary sits just past the last column that precedes the drop slot.
    public static func insertionBoundaryRatio(
        insertion: Int,
        widths: [CGFloat],
        gap: CGFloat,
        draggingIndex: Int
    ) -> Double {
        let geometries = columnGeometries(widths: widths, gap: gap)
        guard !geometries.isEmpty else { return 0 }
        let remainingIndices = widths.indices.filter { $0 != draggingIndex }
        guard insertion > 0, !remainingIndices.isEmpty else { return 0 }
        let slot = min(insertion, remainingIndices.count) - 1
        return geometries[remainingIndices[slot]].endRatio
    }

    // MARK: - Viewport
    /// The slice of the strip currently on screen, as a 0...1 ratio range.
    ///
    /// The dial uses *strip space* rather than *track space* so the viewport gates line up exactly
    /// with the column arcs underneath them — you can read which columns are on screen directly.
    public static func viewportRange(offset: CGFloat, visibleWidth: CGFloat, totalStripWidth: CGFloat) -> (start: Double, end: Double) {
        guard totalStripWidth > 0 else { return (0, 1) }
        let visibleRatio = min(1.0, max(0, Double(visibleWidth / totalStripWidth)))
        let startRatio = min(max(0, Double(offset / totalStripWidth)), 1 - visibleRatio)
        return (startRatio, startRatio + visibleRatio)
    }

    // MARK: - Helpers

    private static func distance(from ratio: Double, to geo: DialColumnGeometry) -> Double {
        if ratio >= geo.startRatio && ratio <= geo.endRatio { return 0 }
        return min(abs(ratio - geo.startRatio), abs(ratio - geo.endRatio))
    }

    private static func clamp01(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1, max(0, v))
    }
}