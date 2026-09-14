// Generates abstract app-icon concepts for Cairn.
// Run: swift Design/IconOptions/generate_icons.swift
//
// Output: five 1024x1024 fully opaque sRGB PNGs (no alpha channel), mask-safe
// (all marks sit inside the central ~80% so the system rounded-rect never clips
// them). No stone imagery, no text, no baked-in corners or gloss.
//
// Coordinate system: Core Graphics bitmap space (origin bottom-left, y up).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let center = CGPoint(x: 512, y: 512)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [r, g, b, 1])!
}

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

/// Vertical field gradient, `top` at the top of the canvas and `bottom` at the base.
func fillGradient(_ context: CGContext, top: UInt32, bottom: UInt32) {
    let gradient = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(top), rgb(bottom)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

/// Strokes an arc as many short round-capped segments, blending red→blue along
/// the sweep. Gives a smooth gradient stroke without clipping tricks.
func strokeGradientArc(
    _ context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    start: CGFloat,
    end: CGFloat,
    width: CGFloat,
    from: CGColor,
    to: CGColor,
    steps: Int = 260
) {
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(width)
    let a = from.components!
    let b = to.components!
    for index in 0..<steps {
        let t0 = CGFloat(index) / CGFloat(steps)
        let t1 = CGFloat(index + 1) / CGFloat(steps)
        let angle0 = start + (end - start) * t0
        let angle1 = start + (end - start) * t1
        let p0 = CGPoint(x: center.x + radius * cos(angle0), y: center.y + radius * sin(angle0))
        let p1 = CGPoint(x: center.x + radius * cos(angle1), y: center.y + radius * sin(angle1))
        let r = a[0] + (b[0] - a[0]) * t0
        let g = a[1] + (b[1] - a[1]) * t0
        let bl = a[2] + (b[2] - a[2]) * t0
        context.setStrokeColor(CGColor(colorSpace: sRGB, components: [r, g, bl, 1])!)
        context.move(to: p0)
        context.addLine(to: p1)
        context.strokePath()
    }
}

func strokeLine(_ context: CGContext, _ points: [CGPoint], width: CGFloat, color: CGColor) {
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(width)
    context.setStrokeColor(color)
    context.beginPath()
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}

func fillRoundedRect(_ context: CGContext, rect: CGRect, radius: CGFloat, color: CGColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.setFillColor(color)
    context.addPath(path)
    context.fillPath()
}

func strokeRoundedRect(_ context: CGContext, rect: CGRect, radius: CGFloat, width: CGFloat, color: CGColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.addPath(path)
    context.strokePath()
}

func fillCircle(_ context: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func write(_ context: CGContext, name: String) {
    let image = context.makeImage()!
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Design/IconOptions/\(name)") as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "Failed to write \(name)")
    print("wrote \(name)")
}

// 1 — Monogram: a single heavy two-tone C. Letterform, no other cues.
do {
    let context = makeContext()
    fillGradient(context, top: 0x0A2A34, bottom: 0x04151B)
    strokeGradientArc(
        context,
        center: center,
        radius: 288,
        start: 34 * .pi / 180,
        end: 326 * .pi / 180,
        width: 136,
        from: rgb(0x3FC6DE),
        to: rgb(0xF4F1EA)
    )
    write(context, name: "01-monogram.png")
}

// 2 — Aperture: nested rounded frames, a deliberate geometric target.
do {
    let context = makeContext()
    fillGradient(context, top: 0x10222B, bottom: 0x051016)
    let widths: CGFloat = 56
    strokeRoundedRect(context, rect: CGRect(x: 202, y: 202, width: 620, height: 620), radius: 150, width: widths, color: rgb(0x2FB3CB))
    strokeRoundedRect(context, rect: CGRect(x: 302, y: 302, width: 420, height: 420), radius: 105, width: widths, color: rgb(0x7FD9E8))
    strokeRoundedRect(context, rect: CGRect(x: 402, y: 402, width: 220, height: 220), radius: 56, width: widths, color: rgb(0xF2F7F8))
    write(context, name: "02-aperture.png")
}

// 3 — Ascent: a clean ascending bar series.
do {
    let context = makeContext()
    fillGradient(context, top: 0x0E3A47, bottom: 0x061A21)
    let barWidth: CGFloat = 112
    let gap: CGFloat = 42
    let heights: [CGFloat] = [210, 340, 470, 600]
    let colors: [UInt32] = [0xF4F1EA, 0xBFEFF8, 0x7ADBEC, 0x37BBD3]
    let groupWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - groupWidth / 2
    for index in heights.indices {
        let height = heights[index]
        fillRoundedRect(
            context,
            rect: CGRect(x: x, y: 228, width: barWidth, height: height),
            radius: barWidth / 2,
            color: rgb(colors[index])
        )
        x += barWidth + gap
    }
    write(context, name: "03-ascent.png")
}

// 4 — Peak: nested chevrons, a single confident direction.
do {
    let context = makeContext()
    fillGradient(context, top: 0x0B2430, bottom: 0x04121A)
    strokeLine(context, [CGPoint(x: 250, y: 358), CGPoint(x: 512, y: 620), CGPoint(x: 774, y: 358)], width: 116, color: rgb(0xF4F1EA))
    strokeLine(context, [CGPoint(x: 420, y: 358), CGPoint(x: 512, y: 450), CGPoint(x: 604, y: 358)], width: 58, color: rgb(0x3FC6DE))
    write(context, name: "04-peak.png")
}

// 5 — Pulse: one bold market line on a light field. No axes, no labels.
do {
    let context = makeContext()
    fillGradient(context, top: 0xFCF9F3, bottom: 0xECE2D1)
    let points = [
        CGPoint(x: 172, y: 474),
        CGPoint(x: 348, y: 474),
        CGPoint(x: 462, y: 642),
        CGPoint(x: 596, y: 372),
        CGPoint(x: 722, y: 520),
        CGPoint(x: 852, y: 520),
    ]
    strokeLine(context, points, width: 78, color: rgb(0x0E5E6E))
    fillCircle(context, center: CGPoint(x: 852, y: 520), radius: 52, color: rgb(0x2AA6BE))
    write(context, name: "05-pulse.png")
}
