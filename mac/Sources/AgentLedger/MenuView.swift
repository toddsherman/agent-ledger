import SwiftUI
import Combine
import LedgerCore

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var now = Date()
    @State private var showHealth = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if !setupSteps.isEmpty { setup; Divider() }
            if model.status.sessions.isEmpty {
                Text("No agent is using Chrome right now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.status.sessions) { s in sessionRow(s) }
            }
            Divider()
            actions
            Divider()
            health
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(TopEdgePin())
        .onReceive(ticker) { now = $0 }
        .onAppear { model.refreshIntegrations() }
    }

    private func settings(_ tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Setup

    private struct SetupStep: Identifiable { let id: String; let title: String; let button: String; let action: () -> Void }

    /// What still has to be done before sessions can be recorded. Empty once setup is finished.
    private var setupSteps: [SetupStep] {
        var out: [SetupStep] = []
        if model.extensionMissing {
            out.append(SetupStep(id: "ext", title: "Add the extension to Chrome", button: "Show me how") { settings("integrations") })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (agent, name, dir) in [(HookAgent.claude, "Claude Code", ".claude"), (HookAgent.codex, "Codex", ".codex")] {
            guard model.hooksInstalled[agent] == false,
                  FileManager.default.fileExists(atPath: home.appendingPathComponent(dir).path) else { continue }
            out.append(SetupStep(id: dir, title: "Let \(name) report to Agent Ledger", button: "Turn on") { model.installHooks(agent) })
        }
        return out
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finish setup").font(.subheadline.weight(.semibold))
            ForEach(setupSteps) { step in
                HStack(spacing: 6) {
                    Image(systemName: "circle").foregroundStyle(.orange).font(.caption)
                    Text(step.title).font(.callout)
                    Spacer()
                    Button(step.button, action: step.action).controlSize(.small)
                }
            }
            Text("Until this is done, part of what agents do in Chrome won't be recorded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack {
            headerIcon
            Text("Agent Ledger").font(.headline)
            Spacer()
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recordingCount: Int { model.status.sessions.filter { $0.state == "recording" }.count }

    private var headerIcon: some View {
        Image(nsImage: Logo.image(model.logoState, points: 22)).accessibilityHidden(true)
    }

    private var statusLine: String {
        if model.needsAttention { return "Needs attention" }
        if model.status.paused, let until = model.settings.pausedUntil { return "Paused until \(Fmt.shortClock(until))" }
        let rec = recordingCount
        if rec > 0 { return "Recording \(rec) session\(rec == 1 ? "" : "s")" }
        if !model.status.sessions.isEmpty { return "Session idle" }
        return "Ready, waiting for an agent"
    }

    private func sessionRow(_ s: LiveSessionInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
        AgentBadge(agent: s.agent, size: 24, uncertain: s.attribution != "identified")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.title(label: s.label, hosts: [], startedAt: s.startedAt))
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(s.state == "possible" ? "Checking…" : Fmt.duration(now.timeIntervalSince1970 * 1000 - s.startedAt))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            HStack(spacing: 6) {
                Chip(text: Words.attribution(s.attribution).text, color: Palette.attribution(s.attribution), help: Words.attribution(s.attribution).help)
                if s.coverage != "ok" { Chip(text: Words.incompleteRecord, color: .orange, help: Words.incompleteRecordHelp) }
            }
            HStack {
                Text("\(s.tabs.count) tab\(s.tabs.count == 1 ? "" : "s") · \(Words.state(s.state).text.lowercased())").font(.caption2).foregroundStyle(.secondary)
                    .help(Words.state(s.state).help)
                Spacer()
                if s.state != "possible" {
                    Button("Stop recording") { model.stopRecording(s.id) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Ends this session's record. The agent keeps running.")
                }
            }
        }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openWindow(id: "ledger")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                let n = model.unreviewed.count
                Label(n == 0 ? "Open Ledger" : "Review \(n) session\(n == 1 ? "" : "s")", systemImage: "list.bullet.rectangle")
            }
            .help("Open the Ledger window, where every recorded session is listed")
            if !model.status.sessions.isEmpty {
                Button { model.thisWasMe(minutes: 2) } label: { Label("That was me (last 2 minutes)", systemImage: "person.fill.checkmark") }
                    .help("Marks the last 2 minutes of clicks and typing in recorded tabs as yours, not the agent's")
            }
            if model.status.paused {
                Button { model.pause(hours: nil) } label: { Label("Resume recording", systemImage: "play.circle") }
            } else {
                Button { model.pause(hours: 1) } label: { Label("Pause recording for 1 hour", systemImage: "pause.circle") }
                    .help("Nothing is recorded while paused, even if an agent uses Chrome")
            }
            HStack {
                Button { settings(UserDefaults.standard.string(forKey: "settingsTab") ?? "general") } label: { Label("Settings…", systemImage: "gearshape") }
                Spacer()
                Button("Quit Agent Ledger") { model.quitByUser() }
                    .help("Stops recording. Agent Ledger stays closed until you open it or restart the Mac.")
            }
        }
        .buttonStyle(.borderless)
    }

    private var hasProblems: Bool {
        model.needsAttention || model.status.remoteDebugging != nil || !model.status.agentBrowsers.isEmpty
            || model.hooksInstalled.values.contains(false) || (model.selfTest?.contains("failed") ?? false)
    }

    @ViewBuilder private var health: some View {
        if hasProblems || showHealth {
            healthRows
            if !hasProblems {
                Button("Hide details") { showHealth = false }.buttonStyle(.link).font(.caption2)
            }
        } else {
            HStack(spacing: 6) {
                StatusMark(level: .ok).font(.caption2)
                Text("Everything is working").font(.caption)
                Spacer()
                Button("Details") { showHealth = true }.buttonStyle(.link).font(.caption2)
            }
        }
    }

    private var healthRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.status.extensionConnected {
                healthRow("Chrome extension", ok: true, detail: extensionDetail)
            } else if !model.chromeRunning {
                healthRow("Chrome extension", level: .off, detail: "Chrome isn't open")
            } else {
                healthRow("Chrome extension", ok: false, detail: "not connected")
            }
            if let rd = model.status.remoteDebugging {
                healthRow("Remote debugging is on in Chrome", ok: false, detail: rd)
            }
            ForEach(model.status.agentBrowsers, id: \.self) { b in
                healthRow("Agent-started browser", ok: false, detail: b)
            }
            healthRow("Claude Code reporting", ok: model.hooksInstalled[.claude] == true,
                      detail: model.hooksInstalled[.claude] == true ? lastHook("claude-code") : "off")
            healthRow("Codex reporting", ok: model.hooksInstalled[.codex] == true,
                      detail: model.hooksInstalled[.codex] == true ? lastHook("codex") : "off")
            ForEach(model.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = model.selfTest {
                Text(t).font(.caption2).foregroundStyle(t.contains("failed") ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var extensionDetail: String {
        let n = model.status.chromeInstalls
        var s = n > 1 ? "connected in \(n) profiles" : "connected"
        if model.status.incognitoCovered == false { s += "; incognito not recorded" }
        return s
    }

    private func lastHook(_ agent: String) -> String {
        guard let t = model.status.lastHookAt[agent] else { return "on, nothing reported yet" }
        return "last report \(Fmt.shortClock(t))"
    }

    private func healthRow(_ title: String, ok: Bool, detail: String) -> some View {
        healthRow(title, level: ok ? .ok : .warn, detail: detail)
    }

    private func healthRow(_ title: String, level: StatusMark.Level, detail: String) -> some View {
        HStack(spacing: 6) {
            StatusMark(level: level).font(.caption2)
            Text(title).font(.caption)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Keeps the menu panel the same height as its content, with its top edge under the menu bar.
/// The panel grows when the content does but never shrinks again, and centres shorter content
/// in the leftover space, so after anything collapsed the menu looked like it was floating.
private struct TopEdgePin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ view: PinView, context: Context) {}

    /// Sits behind the menu's content, so its height is the content's height.
    final class PinView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fit()
        }

        private func fit() {
            let height = bounds.height
            guard let window, height > 1 else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window, abs(window.frame.height - height) > 0.5 else { return }
                let f = window.frame
                window.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: true)
            }
        }
    }
}
