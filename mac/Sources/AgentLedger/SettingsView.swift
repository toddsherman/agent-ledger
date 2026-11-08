import SwiftUI
import LedgerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel
    @State private var draft = LedgerSettings()
    @State private var excluded = ""

    var body: some View {
        TabView {
            capture.tabItem { Label("Capture", systemImage: "record.circle") }
            integrations.tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 430)
        .onAppear {
            draft = model.settings
            excluded = model.settings.excludedHosts.joined(separator: ", ")
            model.refreshIntegrations()
        }
    }

    private func save() {
        var s = draft
        s.excludedHosts = excluded.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.pausedUntil = model.settings.pausedUntil
        model.apply(s)
    }

    private var capture: some View {
        Form {
            Toggle("Capture field values in recorded tabs", isOn: $draft.valuesEnabled)
            Text("Passwords, card numbers, one-time codes and hidden fields are never captured. Secret-looking text is redacted and values are cut at 2 KB.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the agent's prompt as the session label", isOn: $draft.promptLabels)
            Text("Prompts are kept only for sessions that use the browser, truncated to 500 characters.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Keep ordinary browsing metadata in memory for \(draft.prebufferMinutes) min", value: $draft.prebufferMinutes, in: 1...30)
            Text("Outside agent sessions nothing is written to disk. This buffer lets a late-detected session include how it began.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Never record these sites", text: $excluded, prompt: Text("bank.example.com, mail.google.com"))
            HStack { Spacer(); Button("Save") { save() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
    }

    private var integrations: some View {
        Form {
            Section("Chrome") {
                LabeledContent("Native host", value: model.hostRegisteredPath == AppModel.hostBinary ? "registered" :
                                (model.hostRegisteredPath == nil ? "not registered" : "points elsewhere"))
                HStack {
                    Button("Register native host") { model.registerHost() }
                    Text("Then load the extension folder in chrome://extensions (Developer mode → Load unpacked) and restart Chrome once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Extension ID", value: LedgerPaths.extensionID).font(.caption.monospaced())
            }
            Section("Agent hooks (logging only, never block)") {
                hookRow(.claude, title: "Claude Code", file: "~/.claude/settings.json")
                hookRow(.codex, title: "Codex", file: "~/.codex/hooks.json")
                Text("Existing hooks are kept; a backup is written next to the file before every change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func hookRow(_ agent: HookAgent, title: String, file: String) -> some View {
        HStack {
            Circle().fill(model.hooksInstalled[agent] == true ? Color.green : Color.orange).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(title)
                Text(file).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hooksInstalled[agent] == true {
                Button("Reinstall") { model.installHooks(agent) }
                Button("Remove") { model.uninstallHooks(agent) }
            } else {
                Button("Install") { model.installHooks(agent) }
            }
        }
    }

    private var data: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: updater.version)
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks },
                                                                           set: { updater.automaticallyChecks = $0 }))
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                } else {
                    Text("Updates are available in signed release builds.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Stepper("Keep recorded sessions for \(draft.retentionDays) days", value: $draft.retentionDays, in: 1...3650)
            HStack { Spacer(); Button("Save") { save() } }
            LabeledContent("Location", value: LedgerPaths.supportDir.path).font(.caption)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LedgerPaths.databaseURL]) }
                Button("Verify ledger integrity") { model.verifyIntegrity() }
            }
            Text("The ledger is append-only and hash-chained. That exposes casual edits; it doesn't stop a process that can rewrite the whole file.")
                .font(.caption).foregroundStyle(.secondary)
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
