// Draws the Chrome Web Store small promo tile (440×280) into docs/store-assets.
//   swift mac/scripts/make-store-assets.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("docs/store-assets")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let w = 440, h = 280
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor(srgbRed: 0.17, green: 0.23, blue: 0.31, alpha: 1).cgColor,
              NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])

if let icon = NSImage(contentsOf: root.appendingPathComponent("extension/icons/icon128.png")) {
    icon.draw(in: NSRect(x: 28, y: 76, width: 128, height: 128))
}
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.white]
("Agent Ledger" as NSString).draw(at: NSPoint(x: 168, y: 146), withAttributes: title)
let para = NSMutableParagraphStyle(); para.lineSpacing = 2
let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .regular),
                                          .foregroundColor: NSColor(white: 0.82, alpha: 1), .paragraphStyle: para]
("What AI agents did in Chrome,\nrecorded on your Mac." as NSString)
    .draw(in: NSRect(x: 170, y: 88, width: 262, height: 46), withAttributes: sub)
let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                            .foregroundColor: NSColor(srgbRed: 0.95, green: 0.6, blue: 0.3, alpha: 1)]
("Claude Code · Codex" as NSString).draw(at: NSPoint(x: 170, y: 64), withAttributes: small)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("promo-tile-440x280.png"))
print(out.appendingPathComponent("promo-tile-440x280.png").path)
