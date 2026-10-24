import Testing
import Foundation
import CoreGraphics
import AppKit
import SwiftUI
@testable import IumeCore

/// Layout maths for the flat HUD instruments (timeline, spectrum, edge rail, tape).
///
/// Each style draws from the same helpers its hit-testing uses, so these tests pin the contract
/// that what you see is what you can grab.
@Suite("HUD Instrument Layout Tests", .serialized)
struct HUDInstrumentLayoutTests {

    private let widths: [CGFloat] = [180, 320, 140, 220]

    // MARK: - Timeline

    @Test("Timeline segments are proportional to column width and never overlap")
    func timelineSegmentsAreProportional() {
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: 8)
        let frames = MinimapTimelineView.segmentFrames(for: geometries)

        #expect(frames.count == widths.count)
        // 320 must be wider than 140.
        #expect(frames[1].width > frames[3].width)
        #expect(frames[3].width > frames[2].width)

        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minX >= left.maxX - 0.5)
        }

        let trackLeft = MinimapTimelineView.insetX
        let trackRight = trackLeft + MinimapTimelineView.trackWidth
        #expect(frames.first!.minX >= trackLeft - 0.5)
        #expect(frames.last!.maxX <= trackRight + 0.5)
    }

    @Test("Timeline x positions round-trip the strip ratio")
    func timelineRatioRoundTrip() {
        for step in 0...20 {
            let ratio = Double(step) / 20.0
            let x = MinimapTimelineView.x(forRatio: ratio)
            let recovered = Double((x - MinimapTimelineView.insetX) / MinimapTimelineView.trackWidth)
            #expect(abs(recovered - ratio) < 0.0001)
        }
    }

    // MARK: - Spectrum

    @Test("Spectrum bars are evenly spaced and centred in the panel")
    func spectrumBarsAreCentred() {
        let frames = MinimapSpectrumView.barFrames(count: 5)

        #expect(frames.count == 5)
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minX > left.minX)
        }

        let leftMargin = frames.first!.minX
        let rightMargin = MinimapSpectrumView.panelWidth - frames.last!.maxX
        #expect(abs(leftMargin - rightMargin) < 0.5)
    }

    @Test("Spectrum ratio mapping lands on bar centres and round-trips")
    func spectrumRatioMapping() {
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: 8)
        let frames = MinimapSpectrumView.barFrames(count: geometries.count)

        for (index, geo) in geometries.enumerated() {
            let x = MinimapSpectrumView.x(
                forRatio: geo.centerRatio,
                geometries: geometries,
                frames: frames
            )
            #expect(abs(x - frames[index].midX) < 0.01)

            let recovered = MinimapSpectrumView.ratio(
                forX: x,
                geometries: geometries,
                frames: frames
            )
            #expect(abs(recovered - geo.centerRatio) < 0.0001)
        }
    }

    @Test("Spectrum bar height encodes width and fits above the baseline")
    func spectrumBarHeight() {
        let tallest = MinimapSpectrumView.barHeight(for: 600, maxWidth: 600)
        let shortest = MinimapSpectrumView.barHeight(for: 100, maxWidth: 600)

        #expect(tallest > shortest)
        #expect(tallest <= MinimapSpectrumView.baselineY - MinimapSpectrumView.barsTop)
        #expect(shortest > 0)
    }

    // MARK: - Edge rail

    @Test("Edge rail height follows the window count and rows stay inside it")
    func railHugsItsRows() {
        let few = MinimapEdgeRailView.panelHeight(for: 3)
        let many = MinimapEdgeRailView.panelHeight(for: 18)
        #expect(few < many)
        #expect(few >= 132)
        #expect(many <= MinimapEdgeRailView.maxPanelHeight)

        let frames = MinimapEdgeRailView.rowFrames(count: 6)
        #expect(frames.count == 6)
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minY >= left.maxY - 0.5)
        }
        #expect(frames.first!.minY >= MinimapEdgeRailView.headerHeight - 0.5)
        #expect(frames.last!.maxY <= MinimapEdgeRailView.panelHeight(for: 6) + 0.5)
    }

    @Test("Edge rail ratio mapping is monotonic and round-trips every row")
    func railRatioMapping() {
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: 8)
        let frames = MinimapEdgeRailView.rowFrames(count: geometries.count)

        var previousY = -CGFloat.greatestFiniteMagnitude
        for step in 0...20 {
            let ratio = Double(step) / 20.0
            let y = MinimapEdgeRailView.y(forRatio: ratio, geometries: geometries, frames: frames)
            #expect(y >= previousY)
            previousY = y
        }

        for (index, geo) in geometries.enumerated() {
            let y = MinimapEdgeRailView.y(forRatio: geo.centerRatio, geometries: geometries, frames: frames)
            #expect(abs(y - frames[index].midY) < 0.01)

            let recovered = MinimapEdgeRailView.ratio(forY: y, geometries: geometries, frames: frames)
            #expect(abs(recovered - geo.centerRatio) < 0.0001)
        }
    }

    // MARK: - Tape

    @Test("Short tapes fit the whole strip; long tapes keep a seven-column zoom")
    func tapeScale() {
        #expect(MinimapTapeView.visibleSpan(columnCount: 4) == 1.0)
        #expect(abs(MinimapTapeView.visibleSpan(columnCount: 14) - 0.5) < 0.0001)
        #expect(abs(MinimapTapeView.visibleSpan(columnCount: 35) - 0.2) < 0.0001)

        let short = MinimapTapeView.layout(columnCount: 4, viewportCentreRatio: 0.5)
        // The strip spans the inset-to-inset width, not the raw panel.
        #expect(abs(short.x(forRatio: 0) - MinimapTapeView.edgeInset) < 0.01)
        #expect(abs(short.x(forRatio: 1) - (MinimapTapeView.panelWidth - MinimapTapeView.edgeInset)) < 0.5)
        // Playhead sits on the viewport centre.
        #expect(abs(short.reticleX - short.x(forRatio: 0.5)) < 0.01)

        let long = MinimapTapeView.layout(columnCount: 20, viewportCentreRatio: 0.4)
        #expect(abs(long.reticleX - MinimapTapeView.panelWidth / 2) < 0.01)
        #expect(abs(long.x(forRatio: 0.4) - MinimapTapeView.panelWidth / 2) < 0.01)
    }

    @Test("Tape icons sit on their strip ratios and near the playhead when focused")
    func tapeIconPlacement() {
        let geometries = DialGeometry.columnGeometries(widths: widths, gap: 8)
        let frames = MinimapTapeView.iconFrames(geometries: geometries, viewportCentreRatio: 0.5)
        let layout = MinimapTapeView.layout(columnCount: geometries.count, viewportCentreRatio: 0.5)

        #expect(frames.count == geometries.count)
        for (index, geo) in geometries.enumerated() {
            #expect(abs(frames[index].midX - layout.x(forRatio: geo.centerRatio)) < 0.01)
            #expect(abs(frames[index].midY - MinimapTapeView.iconY) < 0.01)
        }
    }

    // MARK: - Hit-testing

    @Test("Every new style hit-tests the column drawn under the pointer")
    @MainActor
    func newStylesHitTheirColumns() {
        let settings = SettingsStore.shared
        let priorShow = settings.showMinimapHUD
        let priorStyle = settings.hudStyle
        defer {
            settings.showMinimapHUD = priorShow
            settings.hudStyle = priorStyle
        }
        settings.showMinimapHUD = true

        let columns = widths.enumerated().map { index, width in
            DialColumnInfo(
                id: UUID(),
                width: width,
                windowCount: 1,
                title: "Win \(index)",
                appName: "App \(index)",
                bundleIdentifier: "com.test.app\(index)"
            )
        }
        let controller = MinimapHUDController.shared
        controller.update(
            columns: columns,
            totalStripWidth: widths.reduce(0, +) + 8 * CGFloat(widths.count - 1),
            viewportOffset: 0,
            visibleWidth: 900,
            focusedIndex: 1,
            activeTitle: "Win 1",
            screen: nil,
            gap: 8,
            isSettling: true
        )

        let geometries = controller.state.columnGeometries
        #expect(geometries.count == widths.count)

        for style in [MinimapHUDStyle.timeline, .spectrum, .edgeRail, .tape] {
            settings.hudStyle = style
            let size = controller.panelSize(for: style)
            let view = HUDHostingView(rootView: AnyView(EmptyView()))
            view.frame = NSRect(origin: .zero, size: size)
            view.controller = controller

            let frames: [CGRect]
            switch style {
            case .timeline:
                frames = MinimapTimelineView.segmentFrames(for: geometries)
            case .spectrum:
                frames = MinimapSpectrumView.barFrames(count: geometries.count)
            case .edgeRail:
                frames = MinimapEdgeRailView.rowFrames(count: geometries.count)
            case .tape:
                frames = MinimapTapeView.iconFrames(
                    geometries: geometries,
                    viewportCentreRatio: MinimapTapeView.viewportCentreRatio(of: controller.state)
                )
            default:
                frames = []
            }

            #expect(frames.count == geometries.count)
            for (index, frame) in frames.enumerated() {
                // Spectrum bar frames carry the bar's x only; its y comes from the bar band.
                let viewY: CGFloat = style == .spectrum
                    ? (MinimapSpectrumView.barsTop + MinimapSpectrumView.baselineY) / 2
                    : frame.midY
                // View space is y-down; AppKit is y-up.
                let point = CGPoint(x: frame.midX, y: size.height - viewY)
                #expect(
                    view.columnTickHit(at: point) == index,
                    "\(style.rawValue) missed column \(index)"
                )
            }
        }
    }
}
