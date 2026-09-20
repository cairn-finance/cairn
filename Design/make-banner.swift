// Regenerates docs/images/banner.png, the README header.
//
// Run from the repository root:
//
//     swift Design/make-banner.swift
//
// It composes the banner from real app assets: the 1024pt app icon, the brand
// ink/teal gradient from CairnApp/DesignSystem.swift, and two device
// screenshots. The background is opaque so the image reads the same in
// GitHub's light and dark themes.

import AppKit
import Foundation

let width: CGFloat = 1280
let height: CGFloat = 640

let root = FileManager.default.currentDirectoryPath
let iconPath = "\(root)/CairnApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let phonePath = "\(root)/Screenshots/appstore/iphone/01_home.png"
let macPath = "\(root)/Screenshots/appstore/mac/01_home.png"
let outputPath = "\(root)/docs/images/banner.png"

// Brand tokens, mirrored from CairnTheme.
let ink = NSColor(srgbRed: 0.043, green: 0.141, blue: 0.188, alpha: 1)       // #0B2430
let inkLight = NSColor(srgbRed: 0.086, green: 0.298, blue: 0.376, alpha: 1)  // #164C60
let inkGlow = NSColor(srgbRed: 0.247, green: 0.776, blue: 0.871, alpha: 1)   // #3FC6DE
let cream = NSColor(srgbRed: 0.957, green: 0.945, blue: 0.918, alpha: 1)     // #F4F1EA

// An explicit bitmap rep so the output is exactly 1280×640, independent of the
// display's backing scale factor.
let size = NSSize(width: width, height: height)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("Could not create bitmap")
}
rep.size = size
let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

// Background: the hero gradient, then a soft teal glow in the top-right.
NSGradient(starting: ink, ending: inkLight)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)
NSGradient(
    colors: [inkGlow.withAlphaComponent(0.32), inkGlow.withAlphaComponent(0)]
)!.draw(
    fromCenter: NSPoint(x: width - 150, y: height - 120), radius: 0,
    toCenter: NSPoint(x: width - 150, y: height - 120), radius: 520,
    options: []
)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawImage(_ path: String, in rect: NSRect, cornerRadius: CGFloat, shadow: Bool, border: Bool) {
    guard let img = NSImage(contentsOfFile: path) else {
        FileHandle.standardError.write("Missing image: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 28
        s.shadowOffset = NSSize(width: 0, height: -10)
        s.set()
    }
    let clip = roundedRect(rect, radius: cornerRadius)
    clip.addClip()
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    if border {
        NSGraphicsContext.saveGraphicsState()
        let stroke = roundedRect(rect.insetBy(dx: 0.5, dy: 0.5), radius: cornerRadius)
        stroke.lineWidth = 1
        NSColor.white.withAlphaComponent(0.16).setStroke()
        stroke.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// Device shots on the right: the Mac window sits behind, the phone in front.
let macWidth: CGFloat = 620
let macHeight = macWidth * 1800 / 2880
drawImage(
    macPath,
    in: NSRect(x: 585, y: 150, width: macWidth, height: macHeight),
    cornerRadius: 14, shadow: true, border: true
)

let phoneHeight: CGFloat = 468
let phoneWidth = phoneHeight * 1284 / 2778
drawImage(
    phonePath,
    in: NSRect(x: 1046, y: 86, width: phoneWidth, height: phoneHeight),
    cornerRadius: 26, shadow: true, border: true
)

// App icon, top-left.
let iconSide: CGFloat = 104
let iconRect = NSRect(x: 76, y: height - 76 - iconSide, width: iconSide, height: iconSide)
drawImage(iconPath, in: iconRect, cornerRadius: 23, shadow: false, border: false)

// Wordmark and tagline.
let title = NSAttributedString(string: "Cairn", attributes: [
    .font: NSFont.systemFont(ofSize: 78, weight: .bold),
    .foregroundColor: cream,
])
title.draw(at: NSPoint(x: 74, y: 262))

let tagline = NSAttributedString(
    string: "Your money. Your data.\nNo account, no server, no tracking.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 27, weight: .medium),
        .foregroundColor: inkGlow,
    ]
)
tagline.draw(at: NSPoint(x: 78, y: 176))

let platforms = NSAttributedString(string: "Open source  ·  iPhone  ·  iPad  ·  Mac", attributes: [
    .font: NSFont.systemFont(ofSize: 18, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.72),
])
platforms.draw(at: NSPoint(x: 80, y: 128))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode banner")
}
do {
    try FileManager.default.createDirectory(
        atPath: "\(root)/docs/images", withIntermediateDirectories: true
    )
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fatalError("Could not write banner: \(error)")
}
print("Wrote \(outputPath)")
