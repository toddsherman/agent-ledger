import Foundation

/// Exports a session as JSONL (raw events with attributions) and a Markdown retrospective.
public enum Exporter {
    static func time(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func clock(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    public static func jsonl(store: LedgerStore, session id: String) throws -> Data {
        guard let s = try store.session(id: id) else { return Data() }
        let events = try store.events(forSession: id)
        let atts = try store.latestAttributions(session: id)
        let corrections = try store.corrections(session: id)
        var out = Data()
        func line(_ v: JSONValue) { out.append(v.canonicalData()); out.append(0x0A) }
        line(["type": "session", "id": .string(s.id), "agent": .string(s.agent), "runtimeSession": s.runtimeSession.map { .string($0) } ?? .null,
              "state": .string(s.state), "startedAt": .number(s.startedAt), "endedAt": s.endedAt.map { .number($0) } ?? .null,
              "taskLabel": s.taskLabel.map { .string($0) } ?? .null, "startReason": .string(s.startReason),
              "attribution": .string(s.attribution), "coverage": .string(s.coverage), "detectorVersion": .string(s.detectorVersion)])
        for b in try store.sessionTabs(session: id) {
            line(["type": "tab_binding", "tab": .number(Double(b.tab)), "boundAt": .number(b.boundAt),
                  "unboundAt": b.unboundAt.map { .number($0) } ?? .null, "evidence": b.evidence.map { .string($0) } ?? .null])
        }
        for se in events {
            var ev = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(se.event))
            if case .object(var o) = ev {
                o["type"] = "event"
                o["id"] = .number(Double(se.id))
                o["receivedAt"] = .number(se.receivedAt)
                o["hash"] = .string(se.hash)
                if let a = atts[se.id] {
                    o["attribution"] = ["actor": .string(a.actor), "label": .string(a.label), "scope": a.scope.map { .string($0) } ?? .null,
                                        "reasons": .array(a.reasons.map { .string($0) }), "detector": .string(a.detectorVersion)]
                }
                ev = .object(o)
            }
            line(ev)
        }
        for c in corrections {
            line(["type": "correction", "action": .string(c.action), "from": c.fromT.map { .number($0) } ?? .null,
                  "to": c.toT.map { .number($0) } ?? .null, "note": c.note.map { .string($0) } ?? .null, "createdAt": .number(c.createdAt)])
        }
        return out
    }

    public static func markdown(store: LedgerStore, session id: String) throws -> String {
        guard let s = try store.session(id: id) else { return "" }
        let events = try store.events(forSession: id)
        let atts = try store.latestAttributions(session: id)
        let corrections = try store.corrections(session: id)
        let tabs = try store.sessionTabs(session: id)
        let chain = try store.verifyChain()
        var md = "# Agent Ledger session \(s.id)\n\n"
        md += "| | |\n| --- | --- |\n"
        md += "| Agent | \(Correlator.displayAgent(s.agent)) (\(s.attribution)) |\n"
        if let r = s.runtimeSession { md += "| Runtime session | `\(r)` |\n" }
        if let l = s.taskLabel { md += "| Task | \(l.replacingOccurrences(of: "|", with: "\\|")) |\n" }
        md += "| Started | \(time(s.startedAt)) |\n"
        md += "| Ended | \(s.endedAt.map(time) ?? "still \(s.state)") |\n"
        md += "| Why recording started | \(s.startReason) |\n"
        md += "| Coverage | \(s.coverage == "ok" ? "No known gaps" : "Degraded: see Gaps") |\n"
        md += "| Detector | \(s.detectorVersion) |\n\n"

        let report = SessionReport.build(session: s, events: events, attributions: atts,
                                         tabs: tabs.map { ($0.tab, $0.boundAt, $0.unboundAt) })
        if let rev = corrections.last(where: { $0.action == "reviewed" || $0.action == "unreviewed" }), rev.action == "reviewed" {
            md += "Reviewed \(time(rev.createdAt))\(rev.note.map { ": \($0)" } ?? "").\n\n"
        }
        md += summaryMarkdown(report)

        md += "\n## Tabs\n\n"
        for t in tabs { md += "- Tab \(t.tab), from \(clock(t.boundAt))\(t.unboundAt.map { " to \(clock($0))" } ?? ""): \(t.evidence ?? "")\n" }

        let gaps = events.filter { $0.event.kind == EventKind.gap }
        md += "\n## Gaps\n\n"
        md += gaps.isEmpty ? "None recorded. Absence of a gap does not prove complete observation: reads, screenshots and some programmatic changes leave no browser event.\n"
            : gaps.map { "- \(clock($0.event.t)) · \(EventFormatter.gapText($0.event))\n" }.joined()

        if !corrections.isEmpty {
            md += "\n## Your corrections\n\n"
            for c in corrections { md += "- \(c.action)\(c.note.map { ": \($0)" } ?? "") (\(time(c.createdAt)))\n" }
        }

        md += "\n## Timeline\n\nGrouped by your prompts. Runs of similar events are collapsed; the JSONL export has every event.\n"
        for turn in report.turns {
            let head = turn.prompt.map { EventFormatter.quote($0.split(whereSeparator: { $0.isNewline }).joined(separator: " "), max: 200) } ?? "Before the first prompt"
            md += "\n### \(clock(turn.t)) · \(head)\n\n"
            if turn.rows.isEmpty { md += "No browser activity.\n" }
            for r in turn.rows {
                let text = r.text.replacingOccurrences(of: "|", with: "\\|").split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                md += "- \(clock(r.t)) · \(r.actor) · \(text)\(r.count > 1 ? " ×\(r.count)" : "")\n"
            }
        }

        md += "\n## Evidence notes\n\n"
        md += "- \"runtime report\" rows come from the agent's own hooks. \"observed\" rows come from the browser, independently of the agent.\n"
        md += "- \"Page script\" means the page did it by itself: no agent call was open on the tab and there was no physical input. Background requests are telemetry (beacons and known telemetry endpoints).\n"
        md += "- Script labels come from reading the code. \"Looks read-only\" is not proof: code built at run time can hide an action.\n"
        md += "- Attribution labels: Identified (an agent reported the operation on this tab), Likely (inferred), Mixed (agent and physical input overlapped), Unknown actor.\n"
        md += "- Ledger integrity check: \(chain.ok ? "hash chain intact over \(chain.checked) events" : "hash chain broken at event \(chain.firstBadEventId ?? -1)"). This detects casual edits, not a process that can rewrite the whole file.\n"
        return md
    }

    /// The first screen of a session as Markdown: result, where, read, ran, changed, trust.
    public static func summaryMarkdown(_ r: SessionReport) -> String {
        var md = "## Summary\n\n**\(r.oneLine)**\n\n"
        if !r.alerts.isEmpty {
            md += "### Alerts\n\n"
            for a in r.alerts {
                md += "- \(clock(a.t)) **\(a.text)**" + (a.details.isEmpty ? "" : ": " + a.details.joined(separator: " ")) + "\n"
            }
            md += "\n"
        }
        md += "### Where\n\n"
        if r.sites.isEmpty { md += "No pages recorded.\n" }
        for site in r.workedSites {
            md += site.reportedOnly ? "- \(site.host): \(SessionReport.plural(site.pages, "page")) opened (reported by the agent, not observed)\n"
                : "- \(site.host): \(SessionReport.minutes(site.ms)), \(SessionReport.plural(site.pages, "page")) opened in the tab\n"
        }
        let ui = r.sites.filter(\.agentUI).map(\.host)
        if !ui.isEmpty { md += "- The agent's own pages (\(ui.joined(separator: ", "))) are left out.\n" }
        md += "- \(SessionReport.plural(r.prompts, "prompt")), \(SessionReport.plural(r.tabs, "tab"))\n"

        md += "\n### Read\n\n"
        if r.opened.isEmpty && r.fetched.isEmpty && r.readTools.isEmpty { md += "Nothing recorded.\n" }
        for g in r.opened.prefix(8) { md += "- Opened \(g.count) × \(g.pattern)\n" }
        if r.opened.count > 8 { md += "- …and \(r.opened.count - 8) more page patterns\n" }
        for g in r.fetched.prefix(8) { md += "- Fetched \(g.count) × \(g.pattern)\n" }
        if r.fetched.count > 8 { md += "- …and \(r.fetched.dropFirst(8).reduce(0) { $0 + $1.count }) more requests across \(r.fetched.count - 8) patterns\n" }
        if !r.readTools.isEmpty { md += "- Read calls: " + r.readTools.map { "\($0.count) × \($0.pattern)" }.joined(separator: ", ") + "\n" }

        md += "\n### Ran\n\n"
        if r.scripts.isEmpty { md += "No scripts.\n" }
        else {
            let risky = r.scripts.filter(\.couldChange)
            md += "\(SessionReport.plural(r.scripts.count, "script")): \(r.scripts.count - risky.count) look read-only, \(risky.count) could have changed something.\n\n"
            for sc in r.scripts {
                let first = sc.code.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
                var line = "- \(clock(sc.t)) · \(sc.couldChange ? "could have changed something (\((sc.signals + (sc.nonGetRequests > 0 ? ["\(sc.nonGetRequests) non-GET requests"] : [])).joined(separator: ", ")))" : "looks read-only")"
                if let d = sc.durationMs { line += String(format: " · %.1f s", d / 1000) }
                if sc.failed { line += " · failed" }
                if sc.requests > 0 { line += " · \(SessionReport.plural(sc.requests, "request"))" + (sc.fetched.first.map { ", mostly \($0.pattern)" } ?? "") }
                md += line + "\n  `\(String(first.prefix(140)).replacingOccurrences(of: "`", with: "'"))`\n"
            }
        }

        md += "\n### Changed\n\n"
        if r.changes.isEmpty { md += "No changes observed. Based on: \(r.changeBasis).\n" }
        for c in r.changes {
            md += "- \(clock(c.t)) · \(c.actor)\(c.reported ? " (reported)" : "") · \(c.tag.map { "**\($0)** · " } ?? "")\(c.text)\n"
            for d in c.details where c.kind == "submit" { md += "  - \(d)\n" }
        }
        if !r.changes.isEmpty { md += "\nAlso: \(r.changeBasis).\n" }
        if !r.statusMessages.isEmpty {
            md += "\nStatus messages after an action:\n\n"
            for m in r.statusMessages { md += "- \(clock(m.t)) · \(m.text)\n" }
        }

        md += "\n### Trust\n\n\(r.trustLine)\n"
        if let c = r.logCheck { md += "\n\(AgentLogs.resultText(c)).\n" }
        if let cmd = r.resumeCommand { md += "\nBack to the conversation: `\(cmd)`\n" }
        else if let cwd = r.cwd { md += "\nProject folder: `\(cwd)`\n" }
        return md
    }

    /// Writes the record, the report and the proof to the exports folder and returns their URLs.
    public static func export(store: LedgerStore, session id: String, to dir: URL = LedgerPaths.exportsDir) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let j = dir.appendingPathComponent("\(id).jsonl")
        let m = dir.appendingPathComponent("\(id).md")
        try jsonl(store: store, session: id).write(to: j, options: .atomic)
        try markdown(store: store, session: id).write(to: m, atomically: true, encoding: .utf8)
        if let proof = try Proof.bundle(store: store, session: id) {
            let p = dir.appendingPathComponent("\(id).proof.jsonl")
            try proof.write(to: p, options: .atomic)
            return [j, m, p]
        }
        return [j, m]
    }
}
