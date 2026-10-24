#!/usr/bin/swift

// AppIconRenderer.swift
// Renders the Iume app icon as vector art at any pixel size.
//
// Design language (matches the in-app product):
//   * Iume lays every window side by side on one endless horizontal strip, so
//     the mark is the strip seen head-on: three columns, the focused one in
//     the middle — the same shape as the menu bar symbol `rectangle.split.3x1`
//     (Sources/IumeCore/UI/StatusBarController.swift).
//   * The focused column is filled with the macOS control-accent blue and
//     carries a soft glow, matching the in-app focus ring
//     (Sources/IumeCore/UI/FocusBorderOverlay.swift).
//   * The container is a macOS-style squircle with an indigo -> cyan -> violet
//     gradient and a liquid-glass sheen.
//
// Every pixel size is rendered from the vector source at its native size
// rather than resampled from one bitmap, so small sizes stay crisp.
//
// Output: PNGs written to the directory given as argv[1], named
// `icon_<size>x<size>.png`.
//
// Usage: swift scripts/AppIconRenderer.swift <output-dir> [size ...]

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

/// The macOS control accent, used for the focused column.
let accent = rgb(0x0A84FF)
let accentLight = rgb(0x5AB4FF)

let fillAll: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: locations
    )!
}

// MARK: - Path helpers

/// Apple's macOS app icons use a superellipse (squircle), not a circular-arc
/// rounded rectangle. `exponent` 6 approximates the system shape closely.
func squirclePath(in rect: CGRect, exponent: CGFloat = 6, samples: Int = 1024) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let p = 2.0 / exponent

    for i in 0...samples {
        let t = (CGFloat(i) / CGFloat(samples)) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), p), ct)
        let y = cy + b * copysign(pow(abs(st), p), st)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Geometry

struct IconStyle {
    let size: CGFloat

    /// Small sizes need harder contrast because fine detail disappears.
    var isTiny: Bool { size < 48 }

    /// Artboard proportions (relative to the canvas).
    var artInset: CGFloat { size * 0.086 }
    var artRect: CGRect {
        CGRect(
            x: artInset,
            y: artInset,
            width: size - artInset * 2,
            height: size - artInset * 2
        )
    }

    // The three columns of the strip.
    var columnWidth: CGFloat { size * (isTiny ? 0.158 : 0.152) }
    var columnGap: CGFloat { size * (isTiny ? 0.050 : 0.048) }
    var columnRadius: CGFloat { columnWidth * 0.26 }

    /// Focused (middle) column is taller than its neighbours.
    var focusHeight: CGFloat { size * (isTiny ? 0.430 : 0.420) }
    var sideHeight: CGFloat { size * (isTiny ? 0.295 : 0.285) }
}

// MARK: - Renderer

func drawIcon(size: CGFloat) -> CGImage? {
    let style = IconStyle(size: size)
    let S = size
    let space = CGColorSpaceCreateDeviceRGB()

    guard let ctx = CGContext(
        data: nil,
        width: Int(S),
        height: Int(S),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let art = style.artRect
    let squircle = squirclePath(in: art)

    // ---------------------------------------------------------------------
    // 1. Squircle body with depth shadow
    // ---------------------------------------------------------------------
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -S * 0.012),
        blur: S * 0.055,
        color: rgb(0x000000, 0.42)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0x0A1030))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Base diagonal gradient: electric indigo -> deep blue -> midnight violet.
    ctx.drawLinearGradient(
        gradient(
            [rgb(0x4A46E8), rgb(0x1A1F6B), rgb(0x090A28)],
            [0.0, 0.48, 1.0]
        ),
        start: CGPoint(x: art.minX, y: art.maxY),
        end: CGPoint(x: art.maxX, y: art.minY),
        options: fillAll
    )

    // Cyan aurora (top-left).
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    ctx.drawRadialGradient(
        gradient([rgb(0x2FD9F0, 0.42), rgb(0x000000, 0)], [0.0, 1.0]),
        startCenter: CGPoint(x: art.minX + art.width * 0.18, y: art.maxY - art.height * 0.14),
        startRadius: 0,
        endCenter: CGPoint(x: art.minX + art.width * 0.18, y: art.maxY - art.height * 0.14),
        endRadius: art.width * 0.72,
        options: CGGradientDrawingOptions([])
    )
    ctx.restoreGState()

    // Violet bloom (bottom-right) for depth.
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    ctx.drawRadialGradient(
        gradient([rgb(0x8B5CF6, 0.36), rgb(0x000000, 0)], [0.0, 1.0]),
        startCenter: CGPoint(x: art.maxX - art.width * 0.14, y: art.minY + art.height * 0.16),
        startRadius: 0,
        endCenter: CGPoint(x: art.maxX - art.width * 0.14, y: art.minY + art.height * 0.16),
        endRadius: art.width * 0.70,
        options: CGGradientDrawingOptions([])
    )
    ctx.restoreGState()

    // Liquid-glass sheen across the top.
    ctx.saveGState()
    ctx.drawRadialGradient(
        gradient([rgb(0xFFFFFF, 0.24), rgb(0x000000, 0)], [0.0, 1.0]),
        startCenter: CGPoint(x: art.minX + art.width * 0.32, y: art.maxY - art.height * 0.14),
        startRadius: 0,
        endCenter: CGPoint(x: art.minX + art.width * 0.32, y: art.maxY - art.height * 0.14),
        endRadius: art.width * 0.80,
        options: CGGradientDrawingOptions([])
    )
    ctx.restoreGState()

    ctx.restoreGState() // end background clip

    // ---------------------------------------------------------------------
    // 2. The strip: three columns, the middle one focused
    // ---------------------------------------------------------------------
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let columnW = style.columnWidth
    let gap = style.columnGap
    let centerX = art.midX
    let centerY = art.midY + S * 0.004

    // Light spilling from the strip onto the surface below it.
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    ctx.drawRadialGradient(
        gradient([rgb(0x3B8CFF, 0.28), rgb(0x000000, 0)], [0.0, 1.0]),
        startCenter: CGPoint(x: centerX, y: centerY - S * 0.20),
        startRadius: 0,
        endCenter: CGPoint(x: centerX, y: centerY - S * 0.20),
        endRadius: S * 0.34,
        options: CGGradientDrawingOptions([])
    )
    ctx.restoreGState()

    let radius = style.columnRadius

    // Neighbours first, so the focused column sits on top of them.
    for sign in [CGFloat(-1), CGFloat(1)] {
        let x = centerX + sign * (columnW + gap)
        let h = style.sideHeight
        let rect = CGRect(x: x - columnW / 2, y: centerY - h / 2, width: columnW, height: h)
        let path = roundedRect(rect, radius: radius)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient(
                [rgb(0xFFFFFF, 0.97), rgb(0xDCE9FF, 0.88), rgb(0x9FC4F5, 0.78)],
                [0.0, 0.5, 1.0]
            ),
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: fillAll
        )
        // Title bar: the band that makes a column read as a window.
        ctx.setFillColor(rgb(0x2C6FD6, 0.14))
        ctx.fill(
            CGRect(
                x: rect.minX,
                y: rect.maxY - rect.height * 0.22,
                width: rect.width,
                height: rect.height * 0.22
            )
        )
        ctx.setFillColor(rgb(0x2C6FD6, 0.30))
        ctx.fill(
            CGRect(
                x: rect.minX,
                y: rect.maxY - rect.height * 0.22,
                width: rect.width,
                height: max(1, S * 0.003)
            )
        )
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
        ctx.setLineWidth(max(1, S * 0.0022))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Focused column.
    let focusH = style.focusHeight
    let focusRect = CGRect(
        x: centerX - columnW / 2,
        y: centerY - focusH / 2,
        width: columnW,
        height: focusH
    )
    let focusPath = roundedRect(focusRect, radius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.075, color: rgb(0x0A84FF, 0.75))
    ctx.addPath(focusPath)
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(focusPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([accentLight, accent, rgb(0x0668D8)], [0.0, 0.45, 1.0]),
        start: CGPoint(x: focusRect.midX, y: focusRect.maxY),
        end: CGPoint(x: focusRect.midX, y: focusRect.minY),
        options: fillAll
    )
    // Title bar band.
    ctx.setFillColor(rgb(0xFFFFFF, 0.22))
    ctx.fill(
        CGRect(
            x: focusRect.minX,
            y: focusRect.maxY - focusRect.height * 0.20,
            width: focusRect.width,
            height: focusRect.height * 0.20
        )
    )

    // Specular sweep down the left edge of the focused column.
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.0)], [0.0, 1.0]),
        start: CGPoint(x: focusRect.minX, y: focusRect.midY),
        end: CGPoint(x: focusRect.minX + columnW * 0.55, y: focusRect.midY),
        options: fillAll
    )
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(focusPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
    ctx.setLineWidth(max(1, S * 0.0022))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // end column clip

    // ---------------------------------------------------------------------
    // 3. Rim light on the squircle
    // ---------------------------------------------------------------------
    if !style.isTiny {
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
        ctx.setLineWidth(max(1, S * 0.0022))
        ctx.strokePath()
        ctx.restoreGState()
    }

    return ctx.makeImage()
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: AppIconRenderer.swift <output-dir> [size ...]\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
if args.count > 2 {
    sizes = Array(args[2...]).compactMap { Double($0).map { CGFloat($0) } }
}

for s in sizes {
    guard let image = drawIcon(size: s) else {
        FileHandle.standardError.write("failed to render \(s)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outDir.appendingPathComponent("icon_\(Int(s))x\(Int(s)).png")
    writePNG(image, to: url)
    print("rendered \(url.path)")
}
