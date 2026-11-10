import Foundation

/// Reads the agents' own session logs (Claude Code transcripts, Codex rollout files) to check
/// that the hooks reported every browser tool call.
///
/// Only tool calls that reach a browser are read out of the logs. Prompts, replies, tool
/// results and the agent's final message are never parsed into values or stored.
public enum AgentLogs {
    public struct LoggedCall: Equatable, Sendable {
        public var id: String
        public var tool: String
        public var t: Double
        public var input: JSONValue?
    }

    public struct Result: Equatable, Sendable {
        public var logFound: Bool
        /// Browser tool calls in the agent's log during the session.
        public var logged: Int
        /// Of those, calls the hooks also reported.
        public var matched: Int
        /// Calls in the log with no hook event.
        public var missing: [LoggedCall]
        /// Browser calls the hooks reported that aren't in the log.
        public var hookOnly: Int
        public var complete: Bool { logFound && missing.isEmpty }

        public var payload: JSONValue {
            ["logFound": .bool(logFound), "logged": .number(Double(logged)), "matched": .number(Double(matched)),
             "missing": .number(Double(missing.count)), "hookOnly": .number(Double(hookOnly))]
        }
    }

    public static func resultText(_ p: JSONValue?) -> String {
        guard p?["logFound"]?.boolValue == true else { return "Checked against the agent's log: the log wasn't found" }
        let logged = p?["logged"]?.intValue ?? 0, matched = p?["matched"]?.intValue ?? 0
        let missing = p?["missing"]?.intValue ?? 0
        if logged == 0 { return "Checked against the agent's log: it lists no browser calls for this session" }
        var s = "Checked against the agent's log: hooks reported \(matched) of \(logged) browser calls"
        if missing > 0 { s += "; \(missing) added from the log" }
        return s
    }

    /// Short form for the Trust line.
    public static func trustText(_ p: JSONValue?) -> String {
        guard p?["logFound"]?.boolValue == true else { return "the agent's own log wasn't found, so hook coverage is unchecked" }
        let logged = p?["logged"]?.intValue ?? 0, matched = p?["matched"]?.intValue ?? 0
        let missing = p?["missing"]?.intValue ?? 0
        if logged == 0 { return "the agent's own log lists no browser calls" }
        return missing == 0 ? "hooks reported all \(logged) browser calls in the agent's own log"
            : "hooks reported \(matched) of \(logged) browser calls in the agent's own log (\(missing) added from the log)"
    }

    // MARK: Finding logs

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.claude/projects/<project>/<runtime-session>.jsonl`, plus that session's subagent files.
    public static func claudeLogs(runtimeSession: String, root: URL? = nil) -> [URL] {
        guard isSafeId(runtimeSession) else { return [] }
        let base = root ?? home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var out: [URL] = []
        for dir in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            let f = dir.appendingPathComponent(runtimeSession + ".jsonl")
            guard fm.fileExists(atPath: f.path) else { continue }
            out.append(f)
            let subs = dir.appendingPathComponent(runtimeSession).appendingPathComponent("subagents")
            for s in (try? fm.contentsOfDirectory(at: subs, includingPropertiesForKeys: nil)) ?? [] where s.pathExtension == "jsonl" {
                out.append(s)
            }
        }
        return out
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<runtime-session>.jsonl`.
    public static func codexLogs(runtimeSession: String, root: URL? = nil) -> [URL] {
        guard isSafeId(runtimeSession) else { return [] }
        return codexRollouts(root: root).filter { $0.lastPathComponent.hasSuffix("-\(runtimeSession).jsonl") }
    }

    static func codexRollouts(root: URL? = nil) -> [URL] {
        let base = root ?? home.appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let f as URL in walker where f.lastPathComponent.hasPrefix("rollout-") && f.pathExtension == "jsonl" { out.append(f) }
        return out
    }

    public static func newestCodexRollout(root: URL? = nil) -> URL? {
        codexRollouts(root: root).max { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isSafeId(_ s: String) -> Bool {
        !s.isEmpty && s.count < 100 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func firstLine(of url: URL, max: Int = 1 << 20) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: max) else { return nil }
        return d.firstIndex(of: 0x0A).map { d[d.startIndex..<$0] } ?? d
    }

    /// Calls `body` with each line of a file, reading in chunks so large transcripts stay cheap.
    static func forEachLine(_ url: URL, _ body: (Data) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        var buf = Data()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                body(buf[buf.startIndex..<nl])
                buf.removeSubrange(buf.startIndex...nl)
            }
        }
        if !buf.isEmpty { body(buf) }
    }

    static func parseTime(_ s: String?) -> Double? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: Reading browser calls

    private static let claudeMarker = Data("\"tool_use\"".utf8)
    private static let codexMarker = Data("\"function_call\"".utf8)

    /// Browser tool calls in a log between `from` and `to` (ms). Everything else in the file is skipped.
    public static func browserCalls(agent: HookAgent, log: URL, from: Double, to: Double) -> [LoggedCall] {
        var out: [LoggedCall] = []
        forEachLine(log) { line in
            switch agent {
            case .claude:
                guard line.range(of: claudeMarker) != nil, let j = JSONValue.parse(Data(line)),
                      j["type"]?.stringValue == "assistant", let t = parseTime(j["timestamp"]?.stringValue),
                      t >= from, t <= to else { return }
                for block in j["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue,
                          HookTranslator.isBrowserCall(agent: agent, toolName: name, input: block["input"]) else { continue }
                    out.append(LoggedCall(id: id, tool: name, t: t, input: block["input"]))
                }
            case .codex:
                guard line.range(of: codexMarker) != nil, let j = JSONValue.parse(Data(line)),
                      j["type"]?.stringValue == "response_item", let p = j["payload"],
                      p["type"]?.stringValue == "function_call", let id = p["call_id"]?.stringValue,
                      let name = p["name"]?.stringValue, let t = parseTime(j["timestamp"]?.stringValue),
                      t >= from, t <= to else { return }
                let tool = p["namespace"]?.stringValue.map { "\($0)__\(name)" } ?? name
                let input = p["arguments"]?.stringValue.flatMap { JSONValue.parse(Data($0.utf8)) }
                guard HookTranslator.isBrowserCall(agent: agent, toolName: tool, input: input) else { return }
                out.append(LoggedCall(id: id, tool: tool, t: t, input: input))
            }
        }
        return out
    }

    // MARK: Reconciling

    /// Pure comparison of the log's browser calls with the IDs the hooks reported.
    public static func reconcile(logged: [LoggedCall], hookIds: Set<String>, logFound: Bool) -> Result {
        var seen = Set<String>()
        let unique = logged.filter { seen.insert($0.id).inserted }
        let missing = unique.filter { !hookIds.contains($0.id) }
        return Result(logFound: logFound, logged: unique.count, matched: unique.count - missing.count, missing: missing,
                      hookOnly: hookIds.subtracting(seen).count)
    }

    static let slackMs = 5000.0

    /// Compares one ledger session with the agent's log. Reads only; nothing is stored.
    /// Returns nil when the session has no runtime session ID to look up.
    public static func check(store: LedgerStore, session id: String, claudeRoot: URL? = nil, codexRoot: URL? = nil) throws -> Result? {
        guard let s = try store.session(id: id), let runtime = s.runtimeSession,
              let agent: HookAgent = s.agent == "claude-code" ? .claude : (s.agent == "codex" ? .codex : nil) else { return nil }
        let from = s.startedAt - slackMs, to = (s.endedAt ?? s.lastActivityAt) + slackMs
        let logs = agent == .claude ? claudeLogs(runtimeSession: runtime, root: claudeRoot)
                                    : codexLogs(runtimeSession: runtime, root: codexRoot)
        let logged = logs.flatMap { browserCalls(agent: agent, log: $0, from: from, to: to) }
        // A runtime session can span several ledger sessions, so match hook events by time, not by link.
        var hookIds = Set<String>()
        for e in try store.events(from: from - 60_000, to: to + 60_000, src: agent.src) {
            guard e.event.cat.hasPrefix("tool."), e.event.p?["session"]?.stringValue == runtime,
                  e.event.p?["browser"]?.boolValue == true, let k = e.event.p?["toolUseId"]?.stringValue else { continue }
            hookIds.insert(k)
        }
        var r = reconcile(logged: logged, hookIds: hookIds, logFound: !logs.isEmpty)
        // Hook events outside the session's own window aren't this session's to answer for.
        let inWindow = try store.events(forSession: id).filter { $0.event.cat == "tool.pre" && $0.event.p?["browser"]?.boolValue == true }
            .compactMap { $0.event.p?["toolUseId"]?.stringValue }
        r.hookOnly = Set(inWindow).subtracting(logged.map(\.id)).count
        if logs.isEmpty { r.hookOnly = 0 }
        return r
    }

    /// Stores the result on the session and adds the calls the hooks missed, taken from the log.
    /// Only the app calls this (it owns the ledger). Repeating it adds nothing new.
    @discardableResult
    public static func record(store: LedgerStore, session id: String, result r: Result, agent: HookAgent,
                              runtimeSession: String, now: Double = nowMs()) throws -> Bool {
        let existing = try store.events(forSession: id)
        let already = Set(existing.filter { $0.event.cat == "tool.logged" }.compactMap { $0.event.p?["toolUseId"]?.stringValue })
        // Calls already added from the log count as missing from the hooks every time.
        let last = existing.last { $0.event.cat == "reconcile.result" }?.event.p
        var changed = false
        for c in r.missing where !already.contains(c.id) {
            var p: [String: JSONValue] = [
                "agent": .string(agent.agentName), "session": .string(runtimeSession), "tool": .string(c.tool),
                "toolUseId": .string(c.id), "browser": true, "logged": true,
            ]
            if let cmd = BrowserRoute.shellCommand(toolName: c.tool, input: c.input) {
                p["input"] = ["command": .string(Redactor.truncate(Redactor.scrub(cmd), max: 2000))]
                p["route"] = .string(BrowserRoute.shell)
            } else if let input = c.input {
                p["input"] = Redactor.sanitize(input)
                let tabs = HookTranslator.tabIds(in: input)
                if !tabs.isEmpty { p["tabIds"] = .array(tabs.map { .number(Double($0)) }) }
                p["route"] = .string(BrowserRoute.byName(agent: agent, toolName: c.tool) ?? BrowserRoute.extensionRoute)
            }
            Correlator.recordSessionEvent(store: store, session: id, src: "log.\(agent.rawValue)", kind: EventKind.runtimeReport,
                                          cat: "tool.logged", p: .object(p), at: c.t)
            changed = true
        }
        if last != r.payload {
            Correlator.recordSessionEvent(store: store, session: id, kind: EventKind.context, cat: "reconcile.result",
                                          p: r.payload, at: now)
            changed = true
        }
        return changed
    }

    /// Checks one session against the agent's log and stores the outcome. App only.
    @discardableResult
    public static func run(store: LedgerStore, session id: String, claudeRoot: URL? = nil, codexRoot: URL? = nil) throws -> Result? {
        guard let r = try check(store: store, session: id, claudeRoot: claudeRoot, codexRoot: codexRoot),
              let s = try store.session(id: id), let runtime = s.runtimeSession else { return nil }
        try record(store: store, session: id, result: r, agent: s.agent == "codex" ? .codex : .claude, runtimeSession: runtime)
        return r
    }
}
