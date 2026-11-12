import AppKit
import SwiftUI

/// The Agent Ledger logo, drawn the same way as the app icon and the Chrome extension's icon
/// (see mac/scripts/make-icons.swift). In the menu bar the dot in the corner carries the state.
enum Logo {
    enum State: Equatable {
        /// Nothing is being recorded right now.
        case idle
        case recording
        case paused
        case attention
    }

    static func image(_ state: State, points: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect, state: state)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Agent Ledger"
        return image
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
    }

    private static func draw(in ctx: CGContext, rect: CGRect, state: State) {
        let s = rect.width
        let radius = s * 0.225
        let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [rgb(0.17, 0.23, 0.31), rgb(0.07, 0.10, 0.14)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()

        // Ledger page.
        let page = CGRect(x: rect.minX + s * 0.20, y: rect.minY + s * 0.16, width: s * 0.52, height: s * 0.64)
        ctx.setFillColor(rgb(0.95, 0.96, 0.97))
        ctx.addPath(CGPath(roundedRect: page, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil))
        ctx.fillPath()

        // Rows: a timeline of entries with actor markers.
        let rowColors = [rgb(0.93, 0.55, 0.20), rgb(0.24, 0.52, 0.93), rgb(0.18, 0.65, 0.62), rgb(0.93, 0.55, 0.20)]
        let rowH = page.height / 5.4
        for (i, color) in rowColors.enumerated() {
            let y = page.maxY - rowH * CGFloat(i + 1) - rowH * 0.15
            let dot = CGRect(x: page.minX + s * 0.06, y: y + rowH * 0.18, width: rowH * 0.46, height: rowH * 0.46)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: dot)
            let bar = CGRect(x: dot.maxX + s * 0.04, y: y + rowH * 0.27, width: page.width * (i % 2 == 0 ? 0.56 : 0.44), height: rowH * 0.28)
            ctx.setFillColor(rgb(0.55, 0.60, 0.67))
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
            ctx.fillPath()
        }

        // The dot, top right. Red while recording, as in the app icon.
        let d = s * 0.30
        let rec = CGRect(x: rect.maxX - d - s * 0.08, y: rect.maxY - d - s * 0.08, width: d, height: d)
        ctx.setFillColor(rgb(0.07, 0.10, 0.14))
        ctx.fillEllipse(in: rec.insetBy(dx: -s * 0.025, dy: -s * 0.025))
        switch state {
        case .recording:
            ctx.setFillColor(rgb(0.90, 0.20, 0.20))
            ctx.fillEllipse(in: rec)
            ctx.setFillColor(rgb(1, 0.55, 0.55, 0.9))
            ctx.fillEllipse(in: rec.insetBy(dx: d * 0.30, dy: d * 0.30).offsetBy(dx: -d * 0.08, dy: d * 0.08))
        case .idle:
            ctx.setFillColor(rgb(0.62, 0.66, 0.72))
            ctx.fillEllipse(in: rec)
        case .paused:
            ctx.setFillColor(rgb(0.62, 0.66, 0.72))
            ctx.fillEllipse(in: rec)
            ctx.setFillColor(rgb(0.07, 0.10, 0.14))
            let w = d * 0.16, h = d * 0.46
            ctx.fill(CGRect(x: rec.midX - w * 1.35, y: rec.midY - h / 2, width: w, height: h))
            ctx.fill(CGRect(x: rec.midX + w * 0.35, y: rec.midY - h / 2, width: w, height: h))
        case .attention:
            ctx.setFillColor(rgb(0.98, 0.62, 0.10))
            ctx.fillEllipse(in: rec)
            ctx.setFillColor(rgb(0.07, 0.10, 0.14))
            let w = d * 0.18
            ctx.fill(CGRect(x: rec.midX - w / 2, y: rec.midY - d * 0.08, width: w, height: d * 0.36))
            ctx.fillEllipse(in: CGRect(x: rec.midX - w / 2, y: rec.midY - d * 0.32, width: w, height: w))
        }
    }
}

extension AppModel {
    var logoState: Logo.State {
        if needsAttention { return .attention }
        if status.paused { return .paused }
        if status.sessions.contains(where: { $0.state == "recording" }) { return .recording }
        return .idle
    }

    var logoStateText: String {
        switch logoState {
        case .attention: return "Agent Ledger: needs attention"
        case .paused: return "Agent Ledger: paused"
        case .recording: return "Agent Ledger: recording"
        case .idle: return "Agent Ledger: ready"
        }
    }
}

/// Shows a Dock icon while the Ledger or Settings window is open, and hides it again when both are closed.
final class DockIconController {
    private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                DispatchQueue.main.async { self?.update(excluding: closing) }
            })
        }
    }

    static func isAppWindow(_ w: NSWindow) -> Bool {
        (w.isVisible || w.isMiniaturized) && !(w is NSPanel) && w.styleMask.contains(.titled) && w.level == .normal
    }

    private func update(excluding closing: NSWindow?) {
        let open = NSApp.windows.contains { $0 !== closing && Self.isAppWindow($0) }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if open { NSApp.activate(ignoringOtherApps: true) }
    }
}
