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

        md += "## Tabs\n\n"
        for t in tabs { md += "- Tab \(t.tab), from \(clock(t.boundAt))\(t.unboundAt.map { " to \(clock($0))" } ?? ""): \(t.evidence ?? "")\n" }

        let changes = events.filter { EventFormatter.isChange($0.event) }
        md += "\n## Changes\n\n"
        if changes.isEmpty { md += "No submits, field changes, mutating requests, alerts or downloads were observed.\n" }
        for c in changes {
            md += "- \(clock(c.event.t)) · \(EventFormatter.actorLabel(atts[c.id])) · \(EventFormatter.describe(c.event))\n"
            if c.event.cat == "form.submit", let fields = c.event.p?["fields"]?.arrayValue {
                for f in fields {
                    let name = EventFormatter.target(f["field"])
                    let v = EventFormatter.value(f["value"]) ?? "?"
                    if let b = EventFormatter.value(f["before"]) { md += "  - \(name): \(b) → \(v)\n" }
                    else { md += "  - \(name): \(v)\n" }
                }
            }
        }

        let gaps = events.filter { $0.event.kind == EventKind.gap }
        md += "\n## Gaps\n\n"
        md += gaps.isEmpty ? "None recorded. Absence of a gap does not prove complete observation: reads, screenshots and some programmatic changes leave no browser event.\n"
            : gaps.map { "- \(clock($0.event.t)) · \(EventFormatter.gapText($0.event))\n" }.joined()

        if !corrections.isEmpty {
            md += "\n## Your corrections\n\n"
            for c in corrections { md += "- \(c.action)\(c.note.map { ": \($0)" } ?? "") (\(time(c.createdAt)))\n" }
        }

        md += "\n## Timeline\n\n| Time | Actor | Source | Event |\n| --- | --- | --- | --- |\n"
        for e in events where !["dom.summary", "ui.scroll", "page.visibility"].contains(e.event.cat) {
            let desc = EventFormatter.describe(e.event).replacingOccurrences(of: "|", with: "\\|")
                .split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            let src = e.event.src.hasPrefix("hook.") ? "runtime report" : (e.event.src == "app" ? "recorder" : "observed")
            md += "| \(clock(e.event.t))\(e.event.pre == true ? " (pre)" : "") | \(EventFormatter.actorLabel(atts[e.id])) | \(src) | \(desc) |\n"
        }

        md += "\n## Evidence notes\n\n"
        md += "- \"runtime report\" rows come from the agent's own hooks. \"observed\" rows come from the browser, independently of the agent.\n"
        md += "- Attribution labels: Identified (an agent reported the operation on this tab), Likely (inferred), Mixed (agent and physical input overlapped), Unknown actor.\n"
        md += "- Ledger integrity check: \(chain.ok ? "hash chain intact over \(chain.checked) events" : "hash chain broken at event \(chain.firstBadEventId ?? -1)"). This detects casual edits, not a process that can rewrite the whole file.\n"
        return md
    }

    /// Writes both files to the exports folder and returns their URLs.
    public static func export(store: LedgerStore, session id: String, to dir: URL = LedgerPaths.exportsDir) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let j = dir.appendingPathComponent("\(id).jsonl")
        let m = dir.appendingPathComponent("\(id).md")
        try jsonl(store: store, session: id).write(to: j, options: .atomic)
        try markdown(store: store, session: id).write(to: m, atomically: true, encoding: .utf8)
        return [j, m]
    }
}
