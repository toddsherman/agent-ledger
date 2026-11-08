// Frames window captures as 1280×800 Chrome Web Store screenshots with a caption.
//   swift mac/scripts/frame-screenshots.swift <captures-dir>
// Captures come from `ledgerctl snapshot` (see docs/chrome-web-store.md).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let input = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root.appendingPathComponent("docs/store-assets/raw").path)
let output = root.appendingPathComponent("docs/store-assets")

let shots: [(file: String, title: String, subtitle: String)] = [
    ("1-claude-changes", "See exactly what an agent changed",
     "Every field before → after, the submit, the request and the page's response."),
    ("2-your-edits", "Your own edits are labeled as yours",
     "Physical clicks and key presses tell your work apart from the agent's."),
    ("3-codex-changes", "Works with Codex too",
     "Codex claimed an already-open tab; the ledger recorded what it did."),
    ("4-evidence-timeline", "Agent reports and browser observations, side by side",
     "Every row says where it came from, so you can judge how far to trust it."),
]

let W = 1280, H = 800
for (i, shot) in shots.enumerated() {
    guard let capture = NSImage(contentsOf: input.appendingPathComponent("\(shot.file).png")) else {
        print("missing \(shot.file).png"); continue
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let ctx = NSGraphicsContext.current!.cgContext
    let colors = [NSColor(srgbRed: 0.17, green: 0.23, blue: 0.31, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])

    let center = NSMutableParagraphStyle(); center.alignment = .center
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .bold),
                                                .foregroundColor: NSColor.white, .paragraphStyle: center]
    let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .regular),
                                              .foregroundColor: NSColor(white: 0.80, alpha: 1), .paragraphStyle: center]
    (shot.title as NSString).draw(in: NSRect(x: 40, y: CGFloat(H) - 74, width: CGFloat(W) - 80, height: 44), withAttributes: title)
    (shot.subtitle as NSString).draw(in: NSRect(x: 40, y: CGFloat(H) - 108, width: CGFloat(W) - 80, height: 28), withAttributes: sub)

    // Fit the window below the caption, keeping its aspect ratio.
    let box = NSRect(x: 50, y: 24, width: CGFloat(W) - 100, height: CGFloat(H) - 150)
    let aspect = capture.size.width / capture.size.height
    var frame = box
    if box.width / box.height > aspect { frame.size.width = box.height * aspect; frame.origin.x = box.midX - frame.width / 2 }
    else { frame.size.height = box.width / aspect; frame.origin.y = box.maxY - frame.height }
    let radius: CGFloat = 10
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    capture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    let url = output.appendingPathComponent("screenshot-\(i + 1)-1280x800.png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}
