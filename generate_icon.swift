#!/usr/bin/env swift
import AppKit

// Draws the MirrorGuard icon: two overlapping "display" rounded rects on a
// dark gradient, crossed by a red prohibition slash — "mirroring blocked".
// CG coordinate origin: bottom-left.
func drawIcon(ctx: CGContext, s: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()

    // ── 1. Background: dark gradient rounded rect ────────────────────────────
    let bgRadius = s * 0.22
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [CGColor(red: 0.05, green: 0.32, blue: 0.58, alpha: 1),   // lighter at top
                 CGColor(red: 0.00, green: 0.25, blue: 0.50, alpha: 1)] as CFArray, // #004080 at bottom
        locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: s / 2, y: s),
                           end:   CGPoint(x: s / 2, y: 0),
                           options: [])
    ctx.restoreGState()

    // ── 2. Two overlapping display rects (the "mirror") ──────────────────────
    let dispW = s * 0.46
    let dispH = s * 0.34
    let dispR = s * 0.06
    // Back display (up-right), front display (down-left) — offset to overlap.
    let offset = s * 0.10
    let cx = s / 2
    let cy = s / 2

    func drawDisplay(originX: CGFloat, originY: CGFloat, faceTop: CGColor, faceBot: CGColor) {
        let rect = CGRect(x: originX, y: originY, width: dispW, height: dispH)
        let path = CGPath(roundedRect: rect, cornerWidth: dispR, cornerHeight: dispR, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02),
                      blur: s * 0.05,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [faceTop, faceBot] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end:   CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 0.6))
        ctx.setLineWidth(s * 0.008)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // Back screen (top-right, slightly dimmer)
    drawDisplay(originX: cx - dispW / 2 + offset, originY: cy - dispH / 2 + offset,
                faceTop: CGColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 1),
                faceBot: CGColor(red: 0.60, green: 0.62, blue: 0.66, alpha: 1))
    // Front screen (bottom-left, brighter)
    drawDisplay(originX: cx - dispW / 2 - offset, originY: cy - dispH / 2 - offset,
                faceTop: CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1),
                faceBot: CGColor(red: 0.74, green: 0.76, blue: 0.80, alpha: 1))

    // ── 3. Red prohibition slash across the pair ─────────────────────────────
    let slashColor = CGColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 0.95)
    ctx.setStrokeColor(slashColor)
    ctx.setLineWidth(s * 0.075)
    ctx.setLineCap(.round)
    let m = s * 0.20  // inset from corners
    ctx.move(to: CGPoint(x: m, y: m))
    ctx.addLine(to: CGPoint(x: s - m, y: s - m))
    ctx.strokePath()
}

// ── Render at given pixel size ───────────────────────────────────────────────
func renderIcon(pixels: Int) -> Data? {
    guard let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: NSColorSpaceName.deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: bmp)?.cgContext else { return nil }
    drawIcon(ctx: ctx, s: CGFloat(pixels))
    return bmp.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
}

// ── Main ─────────────────────────────────────────────────────────────────────
let destDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let sizes: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png",256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png",512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png",1024),
]

for (filename, pixels) in sizes {
    if let data = renderIcon(pixels: pixels) {
        let url = URL(fileURLWithPath: destDir).appendingPathComponent(filename)
        try! data.write(to: url)
        print("✓  \(filename)  (\(pixels)px)")
    } else {
        print("✗  Failed: \(filename)")
    }
}
print("Done.")
