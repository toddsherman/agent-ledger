// Draws the Agent Ledger icon and writes the macOS AppIcon.icns plus the Chrome extension icons.
//   swift mac/scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Draws the artwork into a square of `size` points. `inset` leaves transparent padding (Chrome
/// Web Store icons keep artwork within 96 of 128 pixels).
func drawIcon(size: CGFloat, inset: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let s = rect.width
    let radius = s * 0.225
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background: deep slate gradient.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.17, green: 0.23, blue: 0.31, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Ledger page.
    let page = CGRect(x: rect.minX + s * 0.20, y: rect.minY + s * 0.16, width: s * 0.52, height: s * 0.64)
    let pagePath = CGPath(roundedRect: page, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil)
    ctx.setFillColor(NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).cgColor)
    ctx.addPath(pagePath)
    ctx.fillPath()

    // Ledger rows: a timeline of entries with actor markers.
    let rowColors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.55, blue: 0.20, alpha: 1), // agent
        NSColor(srgbRed: 0.24, green: 0.52, blue: 0.93, alpha: 1), // you
        NSColor(srgbRed: 0.18, green: 0.65, blue: 0.62, alpha: 1), // another agent
        NSColor(srgbRed: 0.93, green: 0.55, blue: 0.20, alpha: 1),
    ]
    let rowH = page.height / 5.4
    for (i, color) in rowColors.enumerated() {
        let y = page.maxY - rowH * CGFloat(i + 1) - rowH * 0.15
        let dot = CGRect(x: page.minX + s * 0.06, y: y + rowH * 0.18, width: rowH * 0.46, height: rowH * 0.46)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        let bar = CGRect(x: dot.maxX + s * 0.04, y: y + rowH * 0.27, width: page.width * (i % 2 == 0 ? 0.56 : 0.44), height: rowH * 0.28)
        ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.60, blue: 0.67, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
        ctx.fillPath()
    }

    // Recording dot with a ring, top right.
    let d = s * 0.30
    let rec = CGRect(x: rect.maxX - d - s * 0.08, y: rect.maxY - d - s * 0.08, width: d, height: d)
    ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor)
    ctx.fillEllipse(in: rec.insetBy(dx: -s * 0.025, dy: -s * 0.025))
    ctx.setFillColor(NSColor(srgbRed: 0.90, green: 0.20, blue: 0.20, alpha: 1).cgColor)
    ctx.fillEllipse(in: rec)
    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 0.9).cgColor)
    ctx.fillEllipse(in: rec.insetBy(dx: d * 0.30, dy: d * 0.30).offsetBy(dx: -d * 0.08, dy: d * 0.08))
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = root.appendingPathComponent("mac/.build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
// macOS icons keep a margin around the tile (about 10% per side at 1024).
let appArt = drawIcon(size: 1024, inset: 100)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try writePNG(appArt, pixels: px, to: iconset.appendingPathComponent("icon_\(name).png"))
}
let resources = root.appendingPathComponent("mac/Resources")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()

// Chrome: 16/32/48 fill the square; 128 keeps the Web Store's 16 px padding.
let ext = root.appendingPathComponent("extension/icons")
try writePNG(drawIcon(size: 128, inset: 0), pixels: 16, to: ext.appendingPathComponent("icon16.png"))
try writePNG(drawIcon(size: 128, inset: 0), pixels: 32, to: ext.appendingPathComponent("icon32.png"))
try writePNG(drawIcon(size: 128, inset: 4), pixels: 48, to: ext.appendingPathComponent("icon48.png"))
try writePNG(drawIcon(size: 128, inset: 16), pixels: 128, to: ext.appendingPathComponent("icon128.png"))
try writePNG(drawIcon(size: 1024, inset: 0), pixels: 1024, to: root.appendingPathComponent("mac/.build/icon-1024.png"))
print("Wrote \(resources.path)/AppIcon.icns and extension icons")
