import SwiftUI
import LedgerCore

struct LedgerWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    @State private var search = ""
    @Environment(\.openSettings) private var openSettings

    var filtered: [SessionSummary] {
        guard !search.isEmpty else { return model.summaries }
        let q = search.lowercased()
        return model.summaries.filter { s in
            (s.session.taskLabel ?? "").lowercased().contains(q) || s.hosts.contains { $0.lowercased().contains(q) } ||
                Correlator.displayAgent(s.session.agent).lowercased().contains(q) || s.session.id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { s in
                SessionRow(summary: s, digest: model.digests[s.id]).tag(s.id)
            }
            .safeAreaInset(edge: .bottom) {
                if !model.unreviewed.isEmpty {
                    HStack {
                        Text("\(model.unreviewed.count) to review").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Mark all reviewed") { model.markAllReviewed() }.buttonStyle(.borderless).font(.caption)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Site, task, agent")
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
            .overlay {
                if model.summaries.isEmpty {
                    if model.extensionMissing || !model.hooksInstalled.values.contains(true) {
                        ContentUnavailableView {
                            Label("Setup isn't finished", systemImage: "wrench.and.screwdriver")
                        } description: {
                            Text("Agent Ledger can't record sessions yet.")
                        } actions: {
                            Button("Open setup") { model.openSettings(tab: "integrations") }
                        }
                    } else {
                        ContentUnavailableView("No recorded sessions yet", systemImage: "record.circle",
                                               description: Text("A session appears here when Claude Code or Codex uses Chrome."))
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let id = selection {
                SessionDetailView(sessionId: id).id(id)
            } else if !model.summaries.isEmpty {
                ContentUnavailableView("Select a session", systemImage: "sidebar.left",
                                       description: Text("Pick a session on the left to see what the agent did."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let m = model.message {
                HStack(spacing: 6) {
                    Image(systemName: m.lowercased().contains("failed") ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(m.lowercased().contains("failed") ? .orange : .secondary)
                    Text(m).font(.callout).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
            }
        }
        .onAppear {
            if let s = model.deepLink?.session { selection = s }
            if selection == nil { selection = model.summaries.first?.id }
            model.refreshIntegrations()
        }
        .onOpenURL { model.handle(url: $0) }
        .onChange(of: model.settingsRequest) { _, tab in
            guard tab != nil else { return }
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
            model.settingsRequest = nil
        }
        .onChange(of: model.deepLink) { _, link in if let s = link?.session { selection = s } }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    var digest: AppModel.Digest?
    var s: SessionRecord { summary.session }

    /// The sites under the title. Left out when the title is already the list of sites.
    private var sitesLine: String {
        let sites = Fmt.sites(summary.hosts)
        let hasTask = Fmt.task(s.taskLabel) != nil
        return hasTask ? Fmt.siteList(sites) : ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
        AgentBadge(agent: s.agent, size: 26, uncertain: s.attribution != "identified")
            .padding(.top, 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.title(label: s.taskLabel, hosts: summary.hosts, startedAt: s.startedAt))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if s.state == "ended", digest?.reviewed == false {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Not reviewed yet").accessibilityLabel("Not reviewed")
                }
                Text(Fmt.listDay(s.startedAt)).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .help(Fmt.day(s.startedAt))
            }
            if let d = digest {
                Text(Fmt.withoutAgent(d.oneLine, agent: s.agent)).font(.caption)
                    .foregroundStyle(d.changes > 0 ? Color.primary : Color.secondary).lineLimit(2)
            }
            if s.attribution != "identified" || s.state != "ended" {
                HStack(spacing: 6) {
                    if s.attribution != "identified" {
                        Chip(text: Words.attribution(s.attribution).text, color: Palette.attribution(s.attribution), help: Words.attribution(s.attribution).help)
                    }
                    if s.state != "ended" { Chip(text: Words.state(s.state).text, color: .red, help: Words.state(s.state).help) }
                }
            }
            if !Fmt.sites(summary.hosts).isEmpty || (digest?.changes ?? 0) > 0 || (digest?.riskyScripts ?? 0) > 0
                || summary.tabCount > 1 || summary.gapCount > 0 {
            HStack(spacing: 8) {
                Text(sitesLine).lineLimit(1)
                Spacer()
                if let d = digest {
                    if d.changes > 0 {
                        Label("\(d.changes)", systemImage: "pencil.and.list.clipboard").foregroundStyle(Color.primary)
                            .help("Changes the agent made").accessibilityLabel("\(d.changes) changes")
                    }
                    if d.riskyScripts > 0 { Label("\(d.riskyScripts)", systemImage: "curlybraces").foregroundStyle(.orange).help("Scripts that could have changed something") }
                }
                if summary.tabCount > 1 {
                    Label("\(summary.tabCount)", systemImage: "rectangle.on.rectangle")
                        .help("Tabs the agent used").accessibilityLabel("\(summary.tabCount) tabs")
                }
                if summary.gapCount > 0 {
                    Label("\(summary.gapCount)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help(Words.incompleteRecordHelp).accessibilityLabel("\(summary.gapCount) parts not recorded")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            }
        }
        }
        .padding(.vertical, 3)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary", changes = "Changes", timeline = "Timeline", evidence = "Evidence"
    var id: String { rawValue }
}

struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    @State private var detail: AppModel.SessionDetail?
    @State private var missing = false
    @State private var tab: DetailTab = .summary
    @State private var actorFilter = "all"
    @State private var showNoise = false
    @State private var editingLabel = false
    @State private var labelText = ""

    var body: some View {
        Group {
            if let d = detail {
                VStack(alignment: .leading, spacing: 0) {
                    header(d).padding(16)
                    Divider()
                    HStack {
                        Picker("", selection: $tab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Spacer()
                        if tab == .timeline {
                            Picker("Show", selection: $actorFilter) {
                                Text("Everything").tag("all")
                                Text("The agent").tag("agent")
                                Text("You").tag("human")
                                Text("Unclear").tag("other")
                                Text("The agent's own reports").tag("reported")
                            }.fixedSize()
                            Toggle("Minor page events", isOn: $showNoise).toggleStyle(.checkbox)
                                .help("Also show scrolling, focus changes and other small page events")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    switch tab {
                    case .summary: SummaryView(detail: d)
                    case .changes: ChangesView(detail: d)
                    case .timeline: TimelineView(detail: d, actorFilter: actorFilter, showNoise: showNoise)
                    case .evidence: EvidenceView(detail: d)
                    }
                }
            } else if missing {
                ContentUnavailableView("This session is no longer in the ledger", systemImage: "clock.arrow.circlepath",
                                       description: Text("It may be older than the time you chose to keep sessions for."))
            } else {
                ProgressView()
            }
        }
        .onAppear {
            reload()
            applyTab(model.deepLink)
        }
        .onChange(of: model.deepLink) { _, link in applyTab(link) }
        .onChange(of: model.dataVersion) { _, _ in reload() }
    }

    private func applyTab(_ link: AppModel.DeepLink?) {
        guard let raw = link?.tab?.lowercased(), link?.session == nil || link?.session == sessionId else { return }
        if let t = DetailTab.allCases.first(where: { $0.rawValue.lowercased() == raw }) { tab = t }
    }

    private func reload() {
        model.loadDetail(sessionId) { d in
            detail = d
            missing = d == nil
            if !editingLabel { labelText = d?.session.taskLabel ?? "" }
        }
    }

    private func header(_ d: AppModel.SessionDetail) -> some View {
        let s = d.session
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(agent: s.agent, size: 28)
                Text(Correlator.displayAgent(s.agent)).font(.title2.weight(.semibold))
                Chip(text: Words.attribution(s.attribution).text, color: Palette.attribution(s.attribution), help: Words.attribution(s.attribution).help)
                Chip(text: Words.state(s.state).text, color: s.state == "ended" ? .secondary : .red, help: Words.state(s.state).help)
                if s.coverage != "ok" { Chip(text: Words.incompleteRecord, color: .orange, help: Words.incompleteRecordHelp) }
                Spacer()
                if s.state != "ended" {
                    Button("Stop recording") { model.stopRecording(s.id) }.help("Ends this session's record. The agent keeps running.")
                }
                Button { model.export(session: s.id) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Save this session as a report and a data file, and show them in Finder")
            }
            if editingLabel {
                HStack {
                    TextField("Title", text: $labelText).textFieldStyle(.roundedBorder)
                    Button("Save") { model.setLabel(session: s.id, label: labelText); editingLabel = false }
                    Button("Cancel") { editingLabel = false; labelText = s.taskLabel ?? "" }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.taskLabel.map(Fmt.oneLine) ?? "Untitled session").font(.title3).foregroundStyle(s.taskLabel == nil ? .secondary : .primary)
                        .lineLimit(3).textSelection(.enabled).help(s.taskLabel ?? "")
                    if let src = s.labelSource { Text(src == "agent-prompt" ? "from the agent's prompt" : "set by you").font(.caption).foregroundStyle(.secondary) }
                    Button { editingLabel = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        .help("Edit the title").accessibilityLabel("Edit the title")
                }
            }
            Text(([Fmt.day(s.startedAt), s.endedAt.map { "lasted " + Fmt.duration($0 - s.startedAt) } ?? "still going"]
                  + (Fmt.sites(d.report.workedSites.map(\.host)).isEmpty ? [] : [Fmt.sites(d.report.workedSites.map(\.host)).prefix(4).joined(separator: ", ")]))
                .joined(separator: "  ·  "))
                .foregroundStyle(.secondary).lineLimit(1)
            .font(.callout)
        }
    }
}

struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let detail: AppModel.SessionDetail
    let event: StoredEvent
    @State private var expanded = false

    var attribution: Attribution? { detail.attributions[event.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.clock(event.event.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: Fmt.clockWidth, alignment: .leading)
                actorChip.frame(width: 120, alignment: .leading)
                sourceChip.frame(width: 70, alignment: .leading)
                Text(EventFormatter.describe(event.event))
                    .font(event.event.kind == EventKind.gap ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(event.event.kind == EventKind.gap ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 2)
                Spacer(minLength: 0)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(expanded ? "Hide details" : "Show details").accessibilityLabel(expanded ? "Hide details" : "Show details")
            }
            if expanded { details.padding(.leading, Fmt.detailIndent) }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("This was me") { model.correct(session: detail.session.id, event: event.id, action: "this-was-me") }
            Button("Wrong agent") { model.correct(session: detail.session.id, event: event.id, action: "wrong-agent") }
            Button("Confirm agent did this") { model.correct(session: detail.session.id, event: event.id, action: "agent-confirmed") }
        }
    }

    @ViewBuilder private var actorChip: some View {
        if let corrected = correctedLabel(detail.correction(for: event)) {
            Chip(text: corrected, color: .blue, help: "You corrected who did this.")
        } else if let a = attribution {
            Chip(text: EventFormatter.actorLabel(a), color: Palette.actor(a.actor),
                 help: a.reasons.isEmpty ? "" : "Why: " + a.reasons.joined(separator: "; "))
        } else {
            Text("").frame(width: 1)
        }
    }

    @ViewBuilder private var sourceChip: some View {
        let w = Words.source(src: event.event.src, pre: event.event.pre == true)
        Chip(text: w.text, color: w.text == "reported" ? .indigo : (w.text == "observed" || w.text == "earlier" ? .mint : .secondary), help: w.help)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = attribution {
                Text("Why: " + a.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text("Who did this?").font(.caption).foregroundStyle(.secondary)
                Button("Me") { model.correct(session: detail.session.id, event: event.id, action: "this-was-me") }
                Button("The agent") { model.correct(session: detail.session.id, event: event.id, action: "agent-confirmed") }
                Button("Not this agent") { model.correct(session: detail.session.id, event: event.id, action: "wrong-agent") }
            }
            .controlSize(.small)
            if let url = event.event.url { Text(url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3) }
            Text(event.event.p?.canonicalString() ?? "{}")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(30)
            Text("event \(event.id) · \(event.event.src) · tab \(event.event.tab.map(String.init) ?? "–") · received +\(Int(event.receivedAt - event.event.t)) ms · hash \(event.hash.prefix(12))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct TimelineView: View {
    let detail: AppModel.SessionDetail
    let actorFilter: String
    let showNoise: Bool

    static let noise: Set<String> = ["dom.summary", "ui.scroll", "page.visibility", "ui.focus", "tab.activated", "tab.snapshot"]

    var rows: [StoredEvent] {
        detail.events.filter { e in
            if !showNoise && Self.noise.contains(e.event.cat) { return false }
            let actor = detail.attributions[e.id]?.actor
            switch actorFilter {
            case "agent": return actor?.hasPrefix("agent:") == true
            case "human": return actor == "human" || detail.correction(for: e)?.action == "this-was-me"
            case "other": return actor == "mixed" || actor == "unknown"
            case "reported": return e.event.src.hasPrefix("hook.")
            default: return true
            }
        }
    }

    var body: some View {
        List(rows) { e in EventRow(detail: detail, event: e) }
            .listStyle(.inset)
            .overlay { if rows.isEmpty { ContentUnavailableView("Nothing matches", systemImage: "line.3.horizontal.decrease.circle") } }
    }
}

struct ChangesView: View {
    let detail: AppModel.SessionDetail

    var changes: [StoredEvent] {
        let ids = Set(detail.report.changes.map(\.id) + detail.report.statusMessages.map(\.id))
        return detail.events.filter { ids.contains($0.id) }
    }

    var body: some View {
        List {
            Section("What changed") {
                if changes.isEmpty {
                    Text("No changes seen. Based on: \(detail.report.changeBasis).").foregroundStyle(.secondary)
                }
                ForEach(changes) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        EventRow(detail: detail, event: e)
                        if e.event.cat == "form.submit", let fields = e.event.p?["fields"]?.arrayValue {
                            ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(EventFormatter.target(f["field"])).font(.caption).foregroundStyle(.secondary)
                                        .frame(minWidth: 120, idealWidth: 180, maxWidth: 220, alignment: .leading)
                                    if let b = EventFormatter.value(f["before"]) {
                                        Text(b).font(.caption).strikethrough().foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right").font(.caption2)
                                    }
                                    Text(EventFormatter.value(f["value"]) ?? "?").font(.caption).textSelection(.enabled)
                                }
                                .padding(.leading, Fmt.detailIndent)
                            }
                        }
                    }
                }
            }
            let gaps = detail.events.filter { $0.event.kind == EventKind.gap }
            Section("Coverage: what couldn't be recorded") {
                if gaps.isEmpty {
                    Text("Nothing was missed that Agent Ledger knows of. That isn't proof: reading a page, taking a screenshot and some changes made by scripts leave no trace in Chrome.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(gaps) { g in EventRow(detail: detail, event: g) }
            }
            let agentOps = detail.events.filter { $0.event.cat == "tool.pre" }
            Section("What the agent reported doing (\(agentOps.count))") {
                ForEach(agentOps) { e in EventRow(detail: detail, event: e) }
            }
        }
        .listStyle(.inset)
    }
}

struct EvidenceView: View {
    let detail: AppModel.SessionDetail

    static let correctionNames = ["this-was-me": "You said this was you", "wrong-agent": "You said it wasn't this agent",
                                  "agent-confirmed": "You confirmed the agent did this", "reviewed": "Marked reviewed",
                                  "unreviewed": "Review undone"]

    var body: some View {
        let observed = detail.events.filter { $0.event.src.hasPrefix("ext.") }
        let reported = detail.events.filter { $0.event.src.hasPrefix("hook.") }
        let atts = Array(detail.attributions.values)
        let byLabel = Dictionary(grouping: atts, by: { $0.label }).mapValues { $0.count }
        let byActor = Dictionary(grouping: atts, by: { EventFormatter.actorLabel($0) }).mapValues { $0.count }
        return Form {
            Section("Where the record comes from") {
                LabeledContent("Seen in Chrome", value: "\(observed.count) events")
                LabeledContent("Reported by the agent", value: "\(reported.count) events")
                LabeledContent("Seen shortly before recording started", value: "\(detail.events.filter { $0.event.pre == true }.count) events")
                LabeledContent("Parts not recorded", value: "\(detail.events.filter { $0.event.kind == EventKind.gap }.count)")
            }
            Section("Who did what") {
                ForEach(byActor.sorted { $0.value > $1.value }, id: \.key) { LabeledContent($0.key, value: "\($0.value)") }
                ForEach(byLabel.sorted { $0.value > $1.value }, id: \.key) { LabeledContent("Label: \($0.key)", value: "\($0.value)") }
            }
            Section("Corrections") {
                if detail.corrections.isEmpty { Text("None. To correct who did something, open a row in the Timeline.").foregroundStyle(.secondary) }
                ForEach(detail.corrections) { c in
                    LabeledContent(Self.correctionNames[c.action] ?? c.action, value: Fmt.day(c.createdAt) + (c.note.map { " · \($0)" } ?? ""))
                }
            }
            Section("Technical details") {
                LabeledContent("Session", value: detail.session.id)
                LabeledContent("Why recording started", value: detail.session.startReason)
                if let r = detail.session.runtimeSession { LabeledContent("Agent's session ID", value: r) }
                if !detail.tabs.isEmpty {
                    LabeledContent("Tabs", value: detail.tabs.map { "tab \($0.tab)" + ($0.evidence.map { " (\($0))" } ?? "") }.joined(separator: "; "))
                }
            }
            .textSelection(.enabled)
            Section("How to read this") {
                Text(["identified", "likely", "mixed", "unknown"].map { Words.attribution($0).help }.joined(separator: " ")
                     + " \"Reported\" rows are the agent's own account; \"observed\" rows were seen in Chrome independently. Point at any label for an explanation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
