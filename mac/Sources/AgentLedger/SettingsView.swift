import SwiftUI
import LedgerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel
    @State private var draft = LedgerSettings()
    @State private var excluded = ""
    @State private var sensitive = ""
    @State private var exceptions = ""
    @State private var shownGroup: String?
    @State private var loaded = false
    @FocusState private var focusedField: String?
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            capture.tabItem { Label("Recording", systemImage: "record.circle") }.tag("capture")
            alerts.tabItem { Label("Alerts", systemImage: "bell.badge") }.tag("alerts")
            integrations.tabItem { Label("Setup", systemImage: "puzzlepiece.extension") }.tag("integrations")
            storage.tabItem { Label("Storage", systemImage: "externaldrive") }.tag("storage")
        }
        .frame(width: 560, height: 520)
        .onAppear {
            draft = model.settings
            excluded = model.settings.excludedHosts.joined(separator: ", ")
            sensitive = model.settings.sensitiveHosts.joined(separator: ", ")
            exceptions = model.settings.sensitiveExceptions.joined(separator: ", ")
            model.refreshIntegrations()
            if !["general", "capture", "alerts", "integrations", "storage"].contains(tab) { tab = "general" }
            loaded = true
            // Don't start with the cursor in a text field: it scrolls the tab down to that field.
            DispatchQueue.main.async { focusedField = nil }
        }
        // Settings apply as you change them. Typed lists wait until you pause.
        .onChange(of: draft) { _, _ in save() }
        .task(id: excluded + "|" + sensitive + "|" + exceptions) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { save() }
        }
        .onDisappear { save() }
    }

    private func save() {
        guard loaded else { return }
        var s = draft
        s.excludedHosts = Self.hosts(excluded)
        s.sensitiveHosts = Self.hosts(sensitive)
        s.sensitiveExceptions = Self.hosts(exceptions)
        s.pausedUntil = model.settings.pausedUntil
        if s != model.settings { model.apply(s) }
    }

    /// "https://www.Chase.com/login, mybank.com" → ["chase.com", "mybank.com"]
    static func hosts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { raw -> String? in
            var h = raw.lowercased()
            if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
            h = String(h.prefix { $0 != "/" && $0 != "?" && $0 != ":" })
            if h.hasPrefix("www.") { h.removeFirst(4) }
            return h.isEmpty ? nil : h
        }
    }

    private func groupBinding(_ g: SiteGroup) -> Binding<Bool> {
        Binding(get: { draft.groupEnabled(g.id) },
                set: { draft.siteGroups[g.id] = $0 == g.defaultOn ? nil : $0 })
    }

    private func actionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.actionEnabled(id) }, set: { draft.actionAlerts[id] = $0 ? nil : false })
    }

    private func groupRow(_ g: SiteGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: groupBinding(g)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(g.name)
                        Button(shownGroup == g.id ? "Hide sites" : "\(g.hosts.count) sites") { shownGroup = shownGroup == g.id ? nil : g.id }
                            .buttonStyle(.link).font(.caption).help("Show the sites in this group")
                    }
                    Text(g.detail + ".").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if shownGroup == g.id {
                Text(g.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var capture: some View {
        Form {
            Toggle("Capture field values in recorded tabs", isOn: $draft.valuesEnabled)
            Text("Passwords, card numbers, one-time codes and hidden fields are never captured. Secret-looking text is redacted and values are cut at 2 KB.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the agent's prompt as the session label", isOn: $draft.promptLabels)
            Text("Prompts are kept only for sessions that use the browser, truncated to 500 characters.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Remember the last \(draft.prebufferMinutes) minutes of tab activity", value: $draft.prebufferMinutes, in: 1...30)
            Text("Kept in memory only, so a session that is spotted late still shows how it began. Nothing is saved unless an agent is using Chrome.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Never record these sites", text: $excluded, prompt: Text("bank.example.com, mail.google.com")).focused($focusedField, equals: "excluded")
            Text("Separate sites with commas. Subdomains are included. Changes apply as you make them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var alerts: some View {
        ScrollViewReader { proxy in
        Form {
            Section("Notifications") {
                Toggle("Tell me when an agent session ends", isOn: $draft.sessionEndNotices).id("alerts-top")
                Toggle("Tell me about alerts and recording problems", isOn: $draft.alertNotices)
                Toggle(isOn: $draft.inAppBrowserNotices) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include agents using their own in-app browser")
                        Text("Off: when Claude or Codex works only in the browser inside its own app, and never in your Chrome, the session is recorded without notifications.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!draft.sessionEndNotices && !draft.alertNotices)
                if model.notificationsOff {
                    HStack {
                        Label("Notifications for Agent Ledger are turned off in System Settings.", systemImage: "bell.slash")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Notification Settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(u) }
                        }.controlSize(.small)
                    }
                }
                Text("Alerts only notify. Agent Ledger never blocks or pauses an agent. Alerts are kept in the session's record even when notifications are off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(SiteGroups.all) { g in groupRow(g) }
            } header: {
                Text("Sites to watch")
            } footer: {
                Text("Any change an agent makes on a watched site raises an alert, as does a script that could change something. Subdomains are included. These are starter lists, mostly US, and they update with the app.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Your own sites") {
                TextField("Also watch", text: $sensitive, prompt: Text("mybank.com, registrar.example")).focused($focusedField, equals: "watch")
                TextField("Never alert on", text: $exceptions, prompt: Text("reddit.com")).focused($focusedField, equals: "never")
                Text("Add your bank, credit union, registrar or anything else the lists miss. \"Never alert on\" takes a site out of the built-in lists.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Alerts.actionKinds) { k in
                    Toggle(isOn: actionBinding(k.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name)
                            Text(k.detail + ".").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $draft.lookalikeAlerts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lookalike sites")
                        Text("A change on a site whose name imitates a well-known one, such as paypa1.com or chase-secure-login.com. Judged from the name alone, so a few will be wrong.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Actions on any site")
            } footer: {
                Text("These are recognised from the name of the button or the fields in the form, so some will be missed and a few will be wrong. Three alerts are always on: a new way of reaching Chrome, a browser Agent Ledger can't see, and Chrome's own red warning page appearing in an agent's tab.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The first text field takes the cursor and scrolls the tab down to it. Undo both.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = nil
                proxy.scrollTo("alerts-top", anchor: .top)
            }
        }
        }
    }

    private var integrations: some View {
        Form {
            Section("Chrome") {
                HStack(spacing: 6) {
                    StatusMark(level: model.status.extensionConnected ? .ok : (model.chromeRunning ? .warn : .off))
                    Text("Extension")
                    Spacer()
                    Text(model.status.extensionConnected ? "Connected" : (model.chromeRunning ? "Not connected" : "Chrome isn't open"))
                        .foregroundStyle(.secondary)
                }
                if !model.status.extensionConnected {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To add the extension to Chrome:").font(.callout)
                        Text("1. Click Copy folder path below.\n2. In Chrome, open chrome://extensions and turn on Developer mode (top right).\n3. Click Load unpacked, press ⌘⇧G, paste the path and press Return, then click Select.\n4. Quit and reopen Chrome once.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.status.extensionConnected { HStack {
                    Button("Copy folder path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppModel.extensionDir.path, forType: .string)
                        model.message = "Copied the extension folder's path."
                    }
                    Button("Show extension folder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.extensionDir]) }
                } }
                HStack(spacing: 6) {
                    StatusMark(level: hostReady ? .ok : .warn)
                    Text("Connection to Chrome")
                    Spacer()
                    Text(hostReady ? "Ready" : (model.hostRegisteredPath == nil ? "Not set up" : "Set up for another copy of Agent Ledger"))
                        .foregroundStyle(.secondary)
                    if !hostReady { Button("Repair") { model.registerHost() } }
                }
            }
            Section("Agent reporting (read-only; never blocks an agent)") {
                hookRow(.claude, title: "Claude Code", file: "~/.claude/settings.json")
                hookRow(.codex, title: "Codex", file: "~/.codex/hooks.json")
                Text("This adds a logging hook to the agent's settings file, so the agent tells Agent Ledger which browser tools it uses. Your other hooks are kept, and a backup is written next to the file before every change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Check that it works") {
                HStack {
                    Button("Run self-test") { model.runSelfTest(manual: true) }
                    Text(model.selfTest ?? "Checks the reporting helper, the extension and the record. Runs at launch and daily.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private var hostReady: Bool { model.hostRegisteredPath == AppModel.hostBinary }

    private func hookRow(_ agent: HookAgent, title: String, file: String) -> some View {
        HStack {
            StatusMark(level: model.hooksInstalled[agent] == true ? .ok : .warn)
            VStack(alignment: .leading) {
                Text(title)
                Text(file).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hooksInstalled[agent] == true {
                Text("On").foregroundStyle(.secondary)
                Button("Repair") { model.installHooks(agent) }.help("Writes the hook again, for example after the settings file was replaced")
                Button("Turn off") { model.uninstallHooks(agent) }.help("Removes Agent Ledger's hook. Sessions from this agent will be recognised less reliably.")
            } else {
                Text("Off").foregroundStyle(.secondary)
                Button("Turn on") { model.installHooks(agent) }
            }
        }
    }

    private var general: some View {
        Form {
            Section("Always on") {
                Toggle("Start at login and restart if the app stops", isOn: $draft.keepRunning)
                Text("Status: \(KeepRunning.statusText). If you quit Agent Ledger yourself, it stays closed until you open it or restart the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private static let retentionChoices = [30, 90, 180, 365, 730, 3650]

    private static func retentionName(_ days: Int) -> String {
        switch days {
        case 30: return "30 days"
        case 90: return "90 days"
        case 180: return "6 months"
        case 365: return "1 year"
        case 730: return "2 years"
        case 3650: return "10 years"
        default: return "\(days) days"
        }
    }

    private var storage: some View {
        Form {
            Section("How long to keep sessions") {
                Picker("Keep for", selection: $draft.retentionDays) {
                    ForEach(Self.retentionChoices + (Self.retentionChoices.contains(draft.retentionDays) ? [] : [draft.retentionDays]), id: \.self) {
                        Text(Self.retentionName($0)).tag($0)
                    }
                }
                Text("Sessions older than this are deleted.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Where the record is kept") {
                LabeledContent("Folder", value: LedgerPaths.supportDir.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LedgerPaths.databaseURL]) }
                    Button("Check for tampering") { model.verifyIntegrity() }
                }
                Text("Entries can be added but not edited, and each one is chained to the one before, so an edit made later shows up in this check. It doesn't stop a program that rewrites the whole file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
