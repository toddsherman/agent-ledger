import SwiftUI
import Combine
import LedgerCore

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.status.sessions.isEmpty {
                Text("No agent is using the browser right now.")
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
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack {
            Image(systemName: "record.circle").foregroundStyle(.red)
            Text("Agent Ledger").font(.headline)
            Spacer()
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        if model.status.paused, let until = model.settings.pausedUntil { return "Paused until \(Fmt.clock(until).prefix(5))" }
        let rec = model.status.sessions.filter { $0.state == "recording" }.count
        if rec > 0 { return "Recording \(rec) session\(rec == 1 ? "" : "s")" }
        if !model.status.sessions.isEmpty { return "Session inactive" }
        return "Watching"
    }

    private func sessionRow(_ s: LiveSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentBadge(agent: s.agent)
                Text(Correlator.displayAgent(s.agent)).font(.subheadline.weight(.semibold))
                Chip(text: s.attribution.capitalized, color: Palette.attribution(s.attribution))
                if s.coverage != "ok" { Chip(text: "Gaps", color: .orange) }
                Spacer()
                Text(s.state == "possible" ? "checking…" : Fmt.duration(now.timeIntervalSince1970 * 1000 - s.startedAt))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let label = s.label {
                Text(label).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(s.tabs.count) tab\(s.tabs.count == 1 ? "" : "s") · \(s.state)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if s.state != "possible" {
                    Button("Stop recording") { model.stopRecording(s.id) }
                        .buttonStyle(.borderless).font(.caption)
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
            } label: { Label("Open Ledger…", systemImage: "list.bullet.rectangle") }
            Button { model.thisWasMe(minutes: 2) } label: { Label("That was me (last 2 minutes)", systemImage: "person.fill.checkmark") }
                .disabled(model.status.sessions.isEmpty)
            if model.status.paused {
                Button { model.pause(hours: nil) } label: { Label("Resume recording", systemImage: "play.circle") }
            } else {
                Button { model.pause(hours: 1) } label: { Label("Pause recording for 1 hour", systemImage: "pause.circle") }
            }
            if updater.isAvailable {
                Button { updater.checkForUpdates() } label: { Label("Check for Updates…", systemImage: "arrow.down.circle") }
                    .disabled(!updater.canCheckForUpdates)
            }
            HStack {
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 3) {
            healthRow("Chrome extension", ok: model.status.extensionConnected,
                      detail: model.status.extensionConnected ? "connected" : "not heard from")
            healthRow("Claude Code hooks", ok: model.hooksInstalled[.claude] == true,
                      detail: model.hooksInstalled[.claude] == true ? lastHook("claude-code") : "not installed")
            healthRow("Codex hooks", ok: model.hooksInstalled[.codex] == true,
                      detail: model.hooksInstalled[.codex] == true ? lastHook("codex") : "not installed")
            let helpers = model.status.helpers
            Text("Agent browser helpers: Claude \(helpers["claude-code"] ?? 0), Codex \(helpers["codex"] ?? 0)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lastHook(_ agent: String) -> String {
        guard let t = model.status.lastHookAt[agent] else { return "installed, no events yet" }
        return "last event \(Fmt.clock(t))"
    }

    private func healthRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(title).font(.caption)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
