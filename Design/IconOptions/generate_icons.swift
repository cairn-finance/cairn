#!/usr/bin/env swift
//
// generate_icons.swift — Cairn app-icon concept generator
//
// Renders four 1024×1024 opaque sRGB PNG concepts with Core Graphics.
// Re-runnable:  swift Design/IconOptions/generate_icons.swift
//
// Design constraints (Apple, 2025–2026):
//   • 1024×1024 master, fully opaque, sRGB.
//   • Do NOT bake rounded corners; the system applies the mask.
//   • Keep the key art inside roughly the central 80% of the canvas.
//
import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let outDir = URL(fileURLWithPath:
    "Design/IconOptions", isDirectory: true)

// MARK: - Color / gradient helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func cg(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt64(h, radix: 16) ?? 0
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return CGColor(colorSpace: srgb, components: [r, g, b, alpha])!
}

func gradient(_ stops: [(String, CGFloat, CGFloat)]) -> CGGradient {
    // (hex, alpha, location)
    let colors = stops.map { cg($0.0, $0.1) as CGColor }
    let locs = stops.map { $0.2 }
    return CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locs)!
}

// MARK: - Canvas

func makeContext() -> CGContext {
    // `noneSkipLast` gives an opaque RGBX bitmap → PNG is written without an
    // alpha channel, satisfying Apple’s “no transparency” requirement.
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(cg("#000000"))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // Flip to a top-left origin so layout math reads naturally.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func save(_ ctx: CGContext, _ name: String) {
    guard let image = ctx.makeImage() else { fatalError("no image for \(name)") }
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed \(url.path)") }
    print("wrote \(url.path)")
}

// MARK: - Painting primitives

/// Fill the whole canvas with a linear gradient (top → bottom).
func fillBackground(_ ctx: CGContext, _ grad: CGGradient) {
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: side), options: [])
    ctx.restoreGState()
}

/// Soft radial glow, useful for depth without hard edges.
func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
          hex: String, alpha: CGFloat) {
    let g = gradient([(hex, alpha, 0), (hex, 0, 1)])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func ellipse(_ rect: CGRect) -> CGPath { CGPath(ellipseIn: rect, transform: nil) }

/// A fully rounded “pill” — reads as a smooth stacked stone / river rock.
func pebble(_ rect: CGRect) -> CGPath {
    let r = min(rect.height / 2, rect.width / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Paints a shape with a vertical gradient and a soft top highlight.
/// `shadowY` > 0 casts a soft shadow downward.
func paintStone(_ ctx: CGContext, path: CGPath, rect: CGRect,
                top: String, bottom: String,
                shadowY: CGFloat = 10, shadowAlpha: CGFloat = 0.22,
                highlightAlpha: CGFloat = 0.18) {
    let base = cg(top)

    // Soft contact shadow (drawn first, beneath the stone).
    if shadowAlpha > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 26,
                      color: cg("#000000", shadowAlpha))
        ctx.addPath(path)
        ctx.setFillColor(base)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Body gradient.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let body = gradient([(top, 1, 0), (bottom, 1, 1)])
    ctx.drawLinearGradient(body, start: CGPoint(x: rect.midX, y: rect.minY),
                           end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    // Top highlight.
    if highlightAlpha > 0 {
        let hl = gradient([("#FFFFFF", highlightAlpha, 0), ("#FFFFFF", 0, 1)])
        let hw = rect.width * 0.82
        let hRect = CGRect(x: rect.midX - hw / 2, y: rect.minY + rect.height * 0.10,
                           width: hw, height: rect.height * 0.55)
        ctx.addPath(ellipse(hRect)); ctx.clip()
        ctx.drawLinearGradient(hl, start: CGPoint(x: hRect.midX, y: hRect.minY),
                               end: CGPoint(x: hRect.midX, y: hRect.maxY),
                               options: [.drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

// MARK: - Concept 1 — Stacked Stones (teal field, warm stones)

func concept1() {
    let ctx = makeContext()
    fillBackground(ctx, gradient([("#3CBAD2", 1, 0), ("#16869C", 1, 1)]))
    glow(ctx, center: CGPoint(x: 330, y: 250), radius: 640, hex: "#BFF0F8", alpha: 0.45)
    glow(ctx, center: CGPoint(x: 760, y: 860), radius: 620, hex: "#0C5666", alpha: 0.40)

    // Warm stone palette.
    paintStone(ctx, path: pebble(CGRect(x: 277, y: 632, width: 470, height: 196)),
               rect: CGRect(x: 277, y: 632, width: 470, height: 196),
               top: "#F2E9DA", bottom: "#C9B392", shadowAlpha: 0.28)
    paintStone(ctx, path: pebble(CGRect(x: 332, y: 492, width: 360, height: 172)),
               rect: CGRect(x: 332, y: 492, width: 360, height: 172),
               top: "#F6EFE3", bottom: "#D6C4A6")
    paintStone(ctx, path: pebble(CGRect(x: 387, y: 356, width: 250, height: 158)),
               rect: CGRect(x: 387, y: 356, width: 250, height: 158),
               top: "#F7F1E6", bottom: "#DCCBAF")
    // Dark walnut capstone — anchors the stack and adds the accent.
    paintStone(ctx, path: pebble(CGRect(x: 447, y: 232, width: 130, height: 132)),
               rect: CGRect(x: 447, y: 232, width: 130, height: 132),
               top: "#8A6540", bottom: "#4E3418", shadowAlpha: 0.30, highlightAlpha: 0.22)
    save(ctx, "01-stacked-stones.png")
}

// MARK: - Concept 2 — Cairn Mark (deep walnut field, off-white stack)

func concept2() {
    let ctx = makeContext()
    fillBackground(ctx, gradient([("#3A2A1A", 1, 0), ("#170F08", 1, 1)]))
    glow(ctx, center: CGPoint(x: 512, y: 320), radius: 560, hex: "#6B4A2E", alpha: 0.55)

    let stones: [(CGRect, String, String)] = [
        (CGRect(x: 302, y: 640, width: 420, height: 150), "#F7F2E9", "#DACBB2"),
        (CGRect(x: 352, y: 502, width: 320, height: 140), "#F9F5EE", "#E0D2BC"),
        (CGRect(x: 402, y: 370, width: 220, height: 130), "#FBF8F3", "#E5D9C5"),
    ]
    for (rect, top, bottom) in stones {
        paintStone(ctx, path: pebble(rect), rect: rect, top: top, bottom: bottom)
    }
    // Teal capstone — the brand accent, safe in tinted/mono because the
    // silhouette still reads as a stacked cairn.
    paintStone(ctx, path: ellipse(CGRect(x: 456, y: 252, width: 112, height: 108)),
               rect: CGRect(x: 456, y: 252, width: 112, height: 108),
               top: "#4FC7DC", bottom: "#1E8CA2", shadowAlpha: 0.30, highlightAlpha: 0.28)
    save(ctx, "02-cairn-mark.png")
}

// MARK: - Concept 3 — Trailhead (sand field, dark stones, teal ground)

func concept3() {
    let ctx = makeContext()
    fillBackground(ctx, gradient([("#FBF7EF", 1, 0), ("#EADFCB", 1, 1)]))
    glow(ctx, center: CGPoint(x: 512, y: 300), radius: 620, hex: "#FFFFFF", alpha: 0.65)

    // Teal ground shadow beneath the cairn.
    ctx.saveGState()
    ctx.addPath(ellipse(CGRect(x: 246, y: 790, width: 532, height: 96)))
    ctx.clip()
    ctx.drawLinearGradient(gradient([("#30B0C7", 0.55, 0), ("#30B0C7", 0.0, 1)]),
                           start: CGPoint(x: 512, y: 790),
                           end: CGPoint(x: 512, y: 886), options: [])
    ctx.restoreGState()

    // Dark walnut / ink stones for maximum contrast on a light field.
    let stones: [(CGRect, CGPath)] = [
        (CGRect(x: 282, y: 636, width: 460, height: 190), pebble(CGRect(x: 282, y: 636, width: 460, height: 190))),
        (CGRect(x: 337, y: 498, width: 350, height: 168), pebble(CGRect(x: 337, y: 498, width: 350, height: 168))),
        (CGRect(x: 392, y: 366, width: 240, height: 154), pebble(CGRect(x: 392, y: 366, width: 240, height: 154))),
    ]
    for (rect, path) in stones {
        paintStone(ctx, path: path, rect: rect, top: "#5A4128", bottom: "#2A1B0E",
                   shadowAlpha: 0.20, highlightAlpha: 0.14)
    }
    paintStone(ctx, path: ellipse(CGRect(x: 452, y: 250, width: 120, height: 116)),
               rect: CGRect(x: 452, y: 250, width: 120, height: 116),
               top: "#40BBD1", bottom: "#1A7F94", shadowAlpha: 0.22, highlightAlpha: 0.30)
    save(ctx, "03-trailhead.png")
}

// MARK: - Concept 4 — Summit (dark ink field, teal abstract stack)

func concept4() {
    let ctx = makeContext()
    fillBackground(ctx, gradient([("#103039", 1, 0), ("#050F14", 1, 1)]))
    glow(ctx, center: CGPoint(x: 512, y: 430), radius: 520, hex: "#30B0C7", alpha: 0.42)

    // Abstract, wide-flat pebbles narrowing upward: a cairn turned into a
    // minimal “summit” glyph. Silhouette-first for Clear/Tinted modes.
    let stones: [(CGRect, String, String)] = [
        (CGRect(x: 262, y: 618, width: 500, height: 150), "#9FE4F0", "#38B6CC"),
        (CGRect(x: 322, y: 486, width: 380, height: 140), "#7BD8E8", "#2BA3BA"),
        (CGRect(x: 384, y: 362, width: 256, height: 132), "#5ACCE0", "#2090A6"),
        (CGRect(x: 446, y: 252, width: 132, height: 118), "#B7EDF6", "#3FBBD1"),
    ]
    for (rect, top, bottom) in stones {
        paintStone(ctx, path: pebble(rect), rect: rect, top: top, bottom: bottom,
                   shadowAlpha: 0.24, highlightAlpha: 0.16)
    }
    save(ctx, "04-summit.png")
}

// MARK: - Run

concept1()
concept2()
concept3()
concept4()
print("done — 4 concepts in \(outDir.path)")
