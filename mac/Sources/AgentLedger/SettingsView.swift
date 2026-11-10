import SwiftUI
import LedgerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel
    @State private var draft = LedgerSettings()
    @State private var excluded = ""
    @State private var sensitive = ""

    var body: some View {
        TabView {
            capture.tabItem { Label("Capture", systemImage: "record.circle") }
            alerts.tabItem { Label("Alerts", systemImage: "bell.badge") }
            integrations.tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 430)
        .onAppear {
            draft = model.settings
            excluded = model.settings.excludedHosts.joined(separator: ", ")
            sensitive = model.settings.sensitiveHosts.joined(separator: ", ")
            model.refreshIntegrations()
        }
    }

    private func save() {
        var s = draft
        s.excludedHosts = excluded.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.sensitiveHosts = sensitive.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
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

    private var alerts: some View {
        Form {
            Section("Notifications") {
                Toggle("Tell me when an agent session ends", isOn: $draft.sessionEndNotices)
                Toggle("Tell me about alerts and recorder problems", isOn: $draft.alertNotices)
                Text("Alerts only notify. Agent Ledger never blocks or pauses an agent. Alerts are kept in the session's record even when notifications are off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sensitive sites") {
                TextField("Sites", text: $sensitive, prompt: Text("github.com, mail.google.com, mybank.com"))
                Text("Any change an agent makes on these sites raises an alert, as does a script that could change something. Subdomains are included. Elsewhere, alerts cover sends, deletes, payments and similar actions, a new way of reaching Chrome, and a browser the recorder can't see.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Self-test") {
                HStack {
                    Button("Run self-test") { model.runSelfTest(manual: true) }
                    Text(model.selfTest ?? "Checks the hook program, the extension and the ledger. Runs at launch and daily.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            HStack { Spacer(); Button("Save") { save() } }
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
            Section("Always on") {
                Toggle("Start at login and restart if the app stops", isOn: $draft.keepRunning)
                Text("Status: \(KeepRunning.statusText). Quit in the menu keeps the app closed until the next restart.")
                    .font(.caption).foregroundStyle(.secondary)
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
