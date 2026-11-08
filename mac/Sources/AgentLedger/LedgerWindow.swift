import SwiftUI
import LedgerCore

struct LedgerWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    @State private var search = ""

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
                SessionRow(summary: s).tag(s.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Site, task, agent")
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
            .overlay {
                if model.summaries.isEmpty {
                    ContentUnavailableView("No recorded sessions yet", systemImage: "record.circle",
                                           description: Text("Sessions appear here when Claude Code or Codex uses Chrome."))
                }
            }
        } detail: {
            if let id = selection {
                SessionDetailView(sessionId: id).id(id)
            } else {
                ContentUnavailableView("Select a session", systemImage: "sidebar.left")
            }
        }
        .onAppear { if selection == nil { selection = model.summaries.first?.id } }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    var s: SessionRecord { summary.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentBadge(agent: s.agent)
                Text(Correlator.displayAgent(s.agent)).font(.subheadline.weight(.semibold))
                Chip(text: s.attribution.capitalized, color: Palette.attribution(s.attribution))
                if s.state != "ended" { Chip(text: s.state.capitalized, color: .red) }
                Spacer()
                Text(Fmt.day(s.startedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(s.taskLabel ?? (summary.hosts.first.map { "Work on \($0)" } ?? "Untitled session"))
                .font(.callout).lineLimit(2)
            HStack(spacing: 8) {
                Text(summary.hosts.prefix(3).joined(separator: ", ")).lineLimit(1)
                Spacer()
                Label("\(summary.changeCount)", systemImage: "pencil.and.list.clipboard")
                Label("\(summary.tabCount)", systemImage: "rectangle.on.rectangle")
                if summary.gapCount > 0 { Label("\(summary.gapCount)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case changes = "Changes", timeline = "Timeline", evidence = "Evidence"
    var id: String { rawValue }
}

struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    @State private var detail: AppModel.SessionDetail?
    @State private var tab: DetailTab = .changes
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
                            .pickerStyle(.segmented).frame(width: 300)
                        Spacer()
                        if tab == .timeline {
                            Picker("Actor", selection: $actorFilter) {
                                Text("All actors").tag("all")
                                Text("Agent").tag("agent")
                                Text("You").tag("human")
                                Text("Mixed / unknown").tag("other")
                                Text("Runtime reports").tag("reported")
                            }.frame(width: 200)
                            Toggle("Show page noise", isOn: $showNoise).toggleStyle(.checkbox)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    switch tab {
                    case .changes: ChangesView(detail: d)
                    case .timeline: TimelineView(detail: d, actorFilter: actorFilter, showNoise: showNoise)
                    case .evidence: EvidenceView(detail: d)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.dataVersion) { _, _ in reload() }
    }

    private func reload() {
        model.loadDetail(sessionId) { d in
            detail = d
            if !editingLabel { labelText = d?.session.taskLabel ?? "" }
        }
    }

    private func header(_ d: AppModel.SessionDetail) -> some View {
        let s = d.session
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(agent: s.agent)
                Text(Correlator.displayAgent(s.agent)).font(.title2.weight(.semibold))
                Chip(text: s.attribution.capitalized, color: Palette.attribution(s.attribution))
                Chip(text: s.state.capitalized, color: s.state == "ended" ? .secondary : .red)
                if s.coverage != "ok" { Chip(text: "Coverage degraded", color: .orange) }
                Spacer()
                if s.state != "ended" { Button("Stop recording") { model.stopRecording(s.id) } }
                Button { model.export(session: s.id) } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            if editingLabel {
                HStack {
                    TextField("Task label", text: $labelText).textFieldStyle(.roundedBorder)
                    Button("Save") { model.setLabel(session: s.id, label: labelText); editingLabel = false }
                    Button("Cancel") { editingLabel = false; labelText = s.taskLabel ?? "" }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.taskLabel ?? "No task label").font(.title3).foregroundStyle(s.taskLabel == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    if let src = s.labelSource { Text(src == "agent-prompt" ? "from the agent's prompt" : "set by you").font(.caption).foregroundStyle(.secondary) }
                    Button { editingLabel = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Started").foregroundStyle(.secondary); Text("\(Fmt.day(s.startedAt))  ·  \(s.endedAt.map { "lasted " + Fmt.duration($0 - s.startedAt) } ?? "ongoing")") }
                GridRow { Text("Why recorded").foregroundStyle(.secondary); Text(s.startReason).textSelection(.enabled) }
                if let r = s.runtimeSession { GridRow { Text("Runtime session").foregroundStyle(.secondary); Text(r).font(.caption.monospaced()).textSelection(.enabled) } }
                GridRow {
                    Text("Tabs").foregroundStyle(.secondary)
                    Text(d.tabs.map { "tab \($0.tab)" + ($0.evidence.map { " (\($0))" } ?? "") }.joined(separator: "; "))
                        .lineLimit(2).textSelection(.enabled)
                }
            }
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
                Text(Fmt.clock(event.event.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
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
            }
            if expanded { details.padding(.leading, 70) }
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
            Chip(text: corrected, color: .blue)
        } else if let a = attribution {
            Chip(text: EventFormatter.actorLabel(a), color: Palette.actor(a.actor))
        } else {
            Text("").frame(width: 1)
        }
    }

    @ViewBuilder private var sourceChip: some View {
        let src = event.event.src
        if src.hasPrefix("hook.") { Chip(text: "reported", color: .indigo) }
        else if src == "app" { Chip(text: "recorder", color: .secondary) }
        else if src == "mac.sensor" { Chip(text: "Mac", color: .secondary) }
        else { Chip(text: event.event.pre == true ? "observed·pre" : "observed", color: .mint) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = attribution {
                Text("Why: " + a.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Scope: \(a.scope ?? "—") · detector \(a.detectorVersion)").font(.caption2).foregroundStyle(.tertiary)
            }
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

    var changes: [StoredEvent] { detail.events.filter { EventFormatter.isChange($0.event) } }

    var body: some View {
        List {
            Section("What changed") {
                if changes.isEmpty {
                    Text("No submits, field changes, mutating requests, alerts or downloads were observed.").foregroundStyle(.secondary)
                }
                ForEach(changes) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        EventRow(detail: detail, event: e)
                        if e.event.cat == "form.submit", let fields = e.event.p?["fields"]?.arrayValue {
                            ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(EventFormatter.target(f["field"])).font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                                    if let b = EventFormatter.value(f["before"]) {
                                        Text(b).font(.caption).strikethrough().foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right").font(.caption2)
                                    }
                                    Text(EventFormatter.value(f["value"]) ?? "?").font(.caption).textSelection(.enabled)
                                }
                                .padding(.leading, 270)
                            }
                        }
                    }
                }
            }
            let gaps = detail.events.filter { $0.event.kind == EventKind.gap }
            Section("Coverage") {
                if gaps.isEmpty {
                    Text("No gaps recorded. That doesn't prove complete observation: page reads, screenshots and some programmatic changes leave no browser event.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(gaps) { g in EventRow(detail: detail, event: g) }
            }
            let agentOps = detail.events.filter { $0.event.cat == "tool.pre" }
            Section("Agent-reported operations (\(agentOps.count))") {
                ForEach(agentOps) { e in EventRow(detail: detail, event: e) }
            }
        }
        .listStyle(.inset)
    }
}

struct EvidenceView: View {
    let detail: AppModel.SessionDetail

    var body: some View {
        let observed = detail.events.filter { $0.event.src.hasPrefix("ext.") }
        let reported = detail.events.filter { $0.event.src.hasPrefix("hook.") }
        let atts = Array(detail.attributions.values)
        let byLabel = Dictionary(grouping: atts, by: { $0.label }).mapValues { $0.count }
        let byActor = Dictionary(grouping: atts, by: { EventFormatter.actorLabel($0) }).mapValues { $0.count }
        return Form {
            Section("Evidence sources") {
                LabeledContent("Observed in the browser", value: "\(observed.count) events")
                LabeledContent("Reported by the agent runtime", value: "\(reported.count) events")
                LabeledContent("Prebuffered (before recording started)", value: "\(detail.events.filter { $0.event.pre == true }.count) events")
                LabeledContent("Gaps", value: "\(detail.events.filter { $0.event.kind == EventKind.gap }.count)")
            }
            Section("Attribution of observed effects") {
                ForEach(byActor.sorted { $0.value > $1.value }, id: \.key) { LabeledContent($0.key, value: "\($0.value)") }
                ForEach(byLabel.sorted { $0.value > $1.value }, id: \.key) { LabeledContent("Label: \($0.key)", value: "\($0.value)") }
            }
            Section("Corrections") {
                if detail.corrections.isEmpty { Text("None. Right-click a timeline row to correct it.").foregroundStyle(.secondary) }
                ForEach(detail.corrections) { c in
                    LabeledContent(c.action, value: Fmt.day(c.createdAt) + (c.note.map { " · \($0)" } ?? ""))
                }
            }
            Section("How to read this") {
                Text("Identified: the agent reported the operation on this tab at that moment. Likely: inferred from debugger attachment and session binding. Mixed: agent activity and your physical clicks or keys overlapped. Unknown actor: nothing matched. Runtime reports are the agent's own account; observed events come from the browser independently.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
