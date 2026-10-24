import SwiftUI

/// Shared dark-glass surface for the flat HUD instruments (timeline, spectrum, edge rail and
/// tape), so every style reads as the same product as the circular dial.
struct HUDGlassSurface: View {
    var cornerRadius: CGFloat = 20

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // Cool near-black tint with the light collecting at the top, so white content stays
            // legible over any wallpaper.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.86), location: 0.00),
                        .init(color: Color(red: 0.04, green: 0.04, blue: 0.06).opacity(0.93), location: 0.55),
                        .init(color: Color(red: 0.01, green: 0.01, blue: 0.02).opacity(0.96), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.36), location: 0.00),
                        .init(color: .white.opacity(0.04), location: 0.45),
                        .init(color: .white.opacity(0.10), location: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.50), radius: 20, x: 0, y: 8)
    }
}

/// Tracked uppercase micro-label used by the flat instruments.
struct HUDMicroLabel: View {
    var text: String
    var opacity: Double = 0.42
    var size: CGFloat = 7

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(opacity))
    }
}

/// `03 / 05` readout shared by the flat instruments.
struct HUDCounter: View {    var index: Int
    var count: Int
    var accented: Bool = false
    var size: CGFloat = 13

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(String(format: "%02d", max(1, index + 1)))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(accented ? Color.accentColor : Color.white.opacity(0.92))
            Text("/")
                .font(.system(size: size * 0.72, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.24))
            Text(String(format: "%02d", max(1, count)))
                .font(.system(size: size * 0.78, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
        }
        .monospacedDigit()
    }
}

/// Strip ratio of the boundary a dragged column would drop into.
///
/// Matches `DialGeometry.insertionBoundaryRatio`: the dragged column is removed first, so the
/// marker sits after the previous remaining window rather than at the target's leading edge.
func hudInsertionRatio(
    for insertion: Int,
    draggingIndex: Int,
    geometries: [DialColumnGeometry]
) -> Double {
    guard !geometries.isEmpty else { return 0 }
    let remaining = geometries.indices.filter { $0 != draggingIndex }
    guard insertion > 0, !remaining.isEmpty else { return 0 }
    let slot = min(insertion, remaining.count) - 1
    return geometries[remaining[slot]].endRatio
}
