import Foundation

/// Human-readable descriptions of events, shared by the app UI and exported reports.
public enum EventFormatter {
    public static func quote(_ s: String?, max: Int = 80) -> String {
        guard let s, !s.isEmpty else { return "“”" }
        let flat = s.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        let t = flat.count > max ? String(flat.prefix(max)) + "…" : flat
        return "“\(t)”"
    }

    public static func target(_ v: JSONValue?) -> String {
        guard let v else { return "element" }
        let role = v["role"]?.stringValue ?? v["tag"]?.stringValue ?? "element"
        if let name = v["name"]?.stringValue, !name.isEmpty { return "\(role) \(quote(name, max: 60))" }
        if let n = v["nameAttr"]?.stringValue { return "\(role) [name=\(n)]" }
        if let sel = v["selector"]?.stringValue, !sel.isEmpty { return "\(role) \(sel)" }
        return role
    }

    public static func value(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        if v["redacted"]?.boolValue == true { return "[not captured: \(v["reason"]?.stringValue ?? "sensitive")]" }
        if v["omitted"]?.boolValue == true { return "[value capture off]" }
        if let c = v["checked"]?.boolValue { return c ? "checked" : "unchecked" }
        if let t = v["text"]?.stringValue, !t.isEmpty { return quote(t) }
        if let s = v["value"]?.stringValue { return quote(s) }
        if let f = v["files"]?.intValue { return "\(f) file(s)" }
        return nil
    }

    static func path(_ url: String?) -> String {
        guard let url, let u = URL(string: url) else { return url ?? "" }
        var p = u.path.isEmpty ? "/" : u.path
        if let q = u.query { p += "?" + q }
        return (u.host ?? "") + p
    }

    static func toolSummary(_ p: JSONValue?) -> String {
        let tool = p?["tool"]?.stringValue.map { Correlator.shortTool($0) } ?? "tool"
        guard let input = p?["input"]?.objectValue else { return tool }
        var bits: [String] = []
        for key in ["action", "url", "text", "value", "query", "ref", "selector", "key", "direction"] {
            guard let v = input[key] else { continue }
            if let s = v.stringValue { bits.append(key == "action" ? s : "\(key)=\(quote(s, max: 50))") }
            else if let n = v.intValue { bits.append("\(key)=\(n)") }
        }
        if let coord = input["coordinate"]?.arrayValue?.compactMap({ $0.intValue }), coord.count == 2 {
            bits.append("at (\(coord[0]), \(coord[1]))")
        }
        if let actions = input["actions"]?.arrayValue {
            bits.append("\(actions.count) actions: " + actions.prefix(4).compactMap { $0["name"]?.stringValue }.joined(separator: ", "))
        }
        if let code = input["code"]?.stringValue {
            bits.append("code " + quote(code.replacingOccurrences(of: "\n", with: " "), max: 70))
        }
        return bits.isEmpty ? tool : "\(tool)(\(bits.joined(separator: ", ")))"
    }

    static func routeLabel(_ p: JSONValue?) -> String {
        let kinds = p?["routeKinds"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        return Correlator.routeText(route: BrowserRoute.shell, tool: "", kinds: kinds, input: nil)
    }

    public static func agentName(_ p: JSONValue?) -> String {
        Correlator.displayAgent(p?["agent"]?.stringValue ?? "")
    }

    public static func describe(_ e: LedgerEvent) -> String {
        let p = e.p
        switch e.cat {
        case "nav.committed":
            let tr = p?["transition"]?.stringValue.map { " (\($0))" } ?? ""
            return (e.frame ?? 0) == 0 ? "Navigated to \(path(e.url))\(tr)" : "Frame navigated to \(path(e.url))"
        case "nav.history": return "Page route changed to \(path(e.url))"
        case "nav.fragment": return "Fragment changed: \(path(e.url))"
        case "nav.error": return "Navigation failed: \(p?["error"]?.stringValue ?? "")"
        case "nav.new_target": return "Opened a new tab from tab \(p?["sourceTab"]?.intValue ?? -1)"
        case "tab.created": return "Tab \(e.tab ?? -1) created"
        case "tab.updated":
            let changed = p?["changed"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: ", ") ?? ""
            return "Tab updated (\(changed)): \(p?["title"]?.stringValue ?? path(e.url))"
        case "tab.removed": return "Tab \(e.tab ?? -1) closed"
        case "tab.snapshot": return "Tab open: \(p?["title"]?.stringValue ?? path(e.url))"
        case "tab.activated": return "Tab \(e.tab ?? -1) became active"
        case "debugger.attached": return "A debugger attached to tab \(e.tab ?? -1)"
        case "debugger.detached": return "The debugger detached from tab \(e.tab ?? -1)"
        case "capture.armed": return "Recording armed on tab \(e.tab ?? -1)"
        case "capture.disarmed": return "Recording disarmed on tab \(e.tab ?? -1)"
        case "capture.content_armed": return "Page capture started (\(p?["prebuffered"]?.intValue ?? 0) prebuffered interactions)"
        case "capture.content_disarmed": return "Page capture stopped"
        case "ui.click": return "Clicked \(target(p?["target"]))"
        case "ui.focus": return "Focused \(target(p?["target"]))"
        case "ui.key":
            let mods = p?["mods"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let key = (mods + [p?["key"]?.stringValue ?? "?"]).joined(separator: "+")
            return "Pressed \(key) in \(target(p?["target"]))"
        case "ui.paste": return "Pasted \(p?["length"]?.intValue.map { "\($0) characters" } ?? "text") into \(target(p?["target"]))"
        case "ui.scroll": return "Scrolled to \(p?["y"]?.intValue ?? 0) px"
        case "field.input":
            let v = value(p?["value"]).map { ": \($0)" } ?? ""
            let role = p?["target"]?["role"]?.stringValue ?? ""
            let verb = ["combobox", "listbox"].contains(role) ? "Selected in" : (["checkbox", "radio", "switch"].contains(role) ? "Toggled" : "Typed into")
            return "\(verb) \(target(p?["target"]))\(v)"
        case "field.change":
            let after = value(p?["after"]) ?? "?"
            if let before = value(p?["before"]), before != after { return "Changed \(target(p?["target"])): \(before) → \(after)" }
            return "Set \(target(p?["target"])) to \(after)"
        case "edit.change":
            return "Edited \(target(p?["target"])): \(value(p?["before"]) ?? "?") → \(value(p?["after"]) ?? "?")"
        case "form.submit":
            let n = p?["fields"]?.arrayValue?.count
            let action = path(p?["form"]?["action"]?.stringValue)
            return "Submitted form\(n.map { " (\($0) fields)" } ?? "") → \(p?["form"]?["method"]?.stringValue?.uppercased() ?? "") \(action)"
        case "page.alert": return "Page showed \(p?["role"]?.stringValue ?? "message"): \(quote(p?["text"]?.stringValue, max: 140))"
        case "page.validation": return "Validation message on \(target(p?["target"])): \(quote(p?["message"]?.stringValue))"
        case "page.visibility": return "Page visibility: \(p?["vis"]?.stringValue ?? "?")"
        case "dom.summary":
            return "Page changed: +\(p?["added"]?.intValue ?? 0) / −\(p?["removed"]?.intValue ?? 0) nodes, \(p?["text"]?.intValue ?? 0) text edits"
        case "net.request":
            let status = p?["status"]?.intValue.map(String.init) ?? (p?["error"]?.stringValue ?? "?")
            return "\(p?["method"]?.stringValue ?? "?") \(path(e.url)) → \(status) (\(p?["type"]?.stringValue ?? ""), \(p?["durationMs"]?.intValue ?? 0) ms)"
        case "download.created":
            let by = p?["byExtensionName"]?.stringValue.map { " by extension \($0)" } ?? ""
            return "Download started: \(p?["filename"]?.stringValue ?? path(e.url))\(by)"
        case "download.changed": return "Download \(p?["state"]?.stringValue ?? p?["error"]?.stringValue ?? "updated")"
        case "tool.pre" where p?["route"]?.stringValue == BrowserRoute.shell:
            return "\(agentName(p)) ran a \(routeLabel(p)): \(quote(p?["input"]?["command"]?.stringValue, max: 140))"
        case "tool.pre" where p?["route"]?.stringValue == BrowserRoute.automation:
            return "\(agentName(p)) used browser automation: \(toolSummary(p))"
        case "tool.pre" where p?["route"]?.stringValue == BrowserRoute.computerUse:
            let app = p?["input"]?["app"]?.stringValue.map { " in \($0)" } ?? ""
            let by = p?["chromeBy"]?.stringValue.map { " (\($0))" } ?? ""
            return "\(agentName(p)) computer use on Chrome: \(p?["input"]?["action"]?.stringValue ?? Correlator.shortTool(p?["tool"]?.stringValue ?? ""))\(app)\(by)"
        case "tool.pre": return "\(agentName(p)) started \(toolSummary(p))"
        case "tool.post" where p?["route"]?.stringValue == BrowserRoute.shell:
            let err = p?["result"]?["isError"]?.boolValue == true ? " with an error" : ""
            return "\(agentName(p)) finished the shell command\(err) (output not recorded)"
        case "tool.post":
            let preview = p?["result"]?["preview"]?.stringValue.flatMap { $0.isEmpty ? nil : ": " + quote($0, max: 100) } ?? ""
            let err = p?["result"]?["isError"]?.boolValue == true ? " (error)" : ""
            return "\(agentName(p)) finished \(Correlator.shortTool(p?["tool"]?.stringValue ?? "tool"))\(err)\(preview)"
        case "tool.failure": return "\(agentName(p)) tool failed: \(Correlator.shortTool(p?["tool"]?.stringValue ?? "")) \(quote(p?["error"]?.stringValue))"
        case "turn.prompt": return "Prompt to \(agentName(p)): \(quote(p?["prompt"]?.stringValue, max: 160))"
        case "turn.stop": return "\(agentName(p)) finished its turn"
        case "turn.interrupt": return "\(agentName(p)) was interrupted"
        case "session.start": return "\(agentName(p)) session started"
        case "session.end": return "\(agentName(p)) session ended"
        case "session.started": return "Recording started: \(p?["reason"]?.stringValue ?? "")"
        case "session.tab_bound": return "Tab \(p?["tab"]?.intValue ?? -1) added to session: \(p?["evidence"]?.stringValue ?? "")"
        case "session.tab_unbound": return "Tab \(p?["tab"]?.intValue ?? -1) left session: \(p?["reason"]?.stringValue ?? "")"
        case "session.inactive": return "Session inactive"
        case "session.recording": return "Session active again"
        case "session.ended": return "Recording ended: \(p?["reason"]?.stringValue ?? "")"
        case "detector.decision":
            return "Detector \(p?["decision"]?.stringValue ?? ""): \(p?["reasons"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "; ") ?? "")"
        case "helper.started": return "\(Correlator.displayAgent(p?["agent"]?.stringValue ?? "")) browser helper connected (pid \(p?["pid"]?.intValue ?? 0))"
        case "helper.stopped": return "\(Correlator.displayAgent(p?["agent"]?.stringValue ?? "")) browser helper disconnected"
        case "browser.started":
            var bits: [String] = []
            if let rd = p?["remoteDebugging"]?.stringValue { bits.append("remote debugging \(rd)") }
            if p?["headless"]?.boolValue == true { bits.append("headless") }
            if p?["automation"]?.boolValue == true { bits.append("automation flag") }
            if let d = p?["userDataDir"]?.stringValue { bits.append("profile folder \(d)") }
            let extra = bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
            let app = p?["app"]?.stringValue ?? "Chrome"
            if let a = p?["agent"]?.stringValue {
                return "\(Correlator.displayAgent(a)) started a separate \(app), pid \(p?["pid"]?.intValue ?? 0)\(extra)"
            }
            if p?["everyday"]?.boolValue == true { return "Your Chrome started\(extra)" }
            return "\(app) started outside your normal Chrome profile\(extra)"
        case "browser.stopped": return "\(p?["app"]?.stringValue ?? "Browser") pid \(p?["pid"]?.intValue ?? 0) quit"
        case "browser.remote_debugging":
            return p?["enabled"]?.boolValue == true
                ? "Remote debugging turned on in your Chrome (\(p?["detail"]?.stringValue ?? "on")): DevTools-protocol clients can control it"
                : "Remote debugging turned off in your Chrome"
        case "health.remote_debugging_unknown": return "Can't tell whether Chrome's remote debugging is on: \(p?["reason"]?.stringValue ?? "")"
        case "health.hooks_restored": return "The \(Correlator.displayAgent(p?["agent"]?.stringValue ?? "")) hooks are back in place"
        case "health.extension_reconnected": return "The Agent Ledger extension reconnected after \(EventFormatter.span(Int(p?["seconds"]?.doubleValue ?? 0)))"
        case "selftest.result": return "Recorder self-test passed (\(p?["checked"]?.stringValue ?? ""))"
        case "version.changed":
            return "\(p?["what"]?.stringValue ?? "A component") changed from \(p?["from"]?.stringValue ?? "?") to \(p?["to"]?.stringValue ?? "?")"
        case "reconcile.result": return AgentLogs.resultText(p)
        case "tool.logged":
            return "From the agent's own log (no hook arrived): \(Correlator.shortTool(p?["tool"]?.stringValue ?? "tool"))"
        case "alert.raised": return "Alert: \(p?["title"]?.stringValue ?? "") — \(p?["body"]?.stringValue ?? "")"
        case "ext.agents":
            let names = p?["agents"]?.arrayValue?.compactMap { a -> String? in
                guard let n = a["name"]?.stringValue else { return nil }
                return "\(n) \(a["version"]?.stringValue ?? "")\(a["enabled"]?.boolValue == false ? " (disabled)" : "")"
            }.joined(separator: ", ") ?? ""
            return "Agent extensions installed: \(names)"
        default:
            if e.kind == EventKind.gap { return gapText(e) }
            return e.cat
        }
    }

    public static func span(_ secs: Int) -> String {
        if secs < 90 { return "\(secs) s" }
        if secs < 5400 { return "\(secs / 60) min" }
        return String(format: "%.1f h", Double(secs) / 3600)
    }

    public static func gapText(_ e: LedgerEvent) -> String {
        let p = e.p
        switch e.cat {
        case "gap.app_down":
            let secs = ((p?["to"]?.doubleValue ?? 0) - (p?["from"]?.doubleValue ?? 0)) / 1000
            return "Gap: the app wasn't running for \(Int(secs)) s; \(p?["droppedUnarmedEvents"]?.intValue ?? 0) unrecorded-tab events were dropped"
        case "gap.host_disconnected": return "Gap: extension lost its connection to the app (\(p?["reason"]?.stringValue ?? ""))"
        case "gap.page_inaccessible": return "Gap: page can't be observed (\(path(e.url)))"
        case "gap.content_unavailable": return "Gap: page capture couldn't start in this tab"
        case "gap.extension_silent": return "Gap: no data from the extension for \(p?["seconds"]?.intValue ?? 0) s"
        case "gap.debugger_poll_failed": return "Gap: debugger state unavailable"
        case "gap.extension_queue_overflow": return "Gap: \(p?["dropped"]?.intValue ?? 0) events dropped (extension queue full)"
        case "gap.app_restarted": return "Gap: the app restarted during this session"
        case "gap.excluded_site": return "Gap: navigated to an excluded site; not recorded"
        case "gap.recorder_stopped":
            let secs = Int(p?["seconds"]?.doubleValue ?? 0)
            return "Gap: the recorder wasn't running for \(EventFormatter.span(secs)) (\(HealthText.stopReason(p?["reason"]?.stringValue)))"
        case "gap.hooks_removed": return "Gap: the \(Correlator.displayAgent(p?["agent"]?.stringValue ?? "")) hooks were removed or changed outside Agent Ledger"
        case "gap.hook_binary_missing": return "Gap: the hook program is missing, so agents can't report to the recorder"
        case "gap.extension_disconnected": return "Gap: Chrome was running without the Agent Ledger extension connected"
        case "gap.ledger_changed": return "Gap: the ledger was changed outside Agent Ledger (\(p?["detail"]?.stringValue ?? "unknown change"))"
        case "gap.selftest_failed": return "Gap: the recorder's self-test failed (\(p?["failed"]?.stringValue ?? ""))"
        case "gap.dependency_changed": return "Gap: \(p?["detail"]?.stringValue ?? "an agent update changed something the recorder depends on")"
        case "gap.tab_missing": return "Gap: tab was gone before recording could start"
        default: return "Gap: \(e.cat)"
        }
    }

    public static func actorLabel(_ a: Attribution?) -> String {
        guard let a else { return "—" }
        switch a.actor {
        case "agent:claude-code": return a.label == "identified" ? "Claude Code" : "Likely Claude Code"
        case "agent:codex": return a.label == "identified" ? "Codex" : "Likely Codex"
        case "agent:unknown": return "Likely an agent"
        case "human": return "Likely you"
        case "mixed": return "Mixed"
        case "page": return "Page script"
        default: return "Unknown actor"
        }
    }

    /// Whether an event belongs in the "Changes" summary.
    public static func isChange(_ e: LedgerEvent) -> Bool {
        switch e.cat {
        case "form.submit", "field.change", "edit.change", "page.alert", "download.created", "page.validation": return true
        case "net.request": return e.p?["mutating"]?.boolValue == true
        default: return false
        }
    }
}

/// One set of plain words for a session's status, used by the menu, the list and the session header.
public enum Words {
    /// How sure the record is about which agent ran the session.
    public static func attribution(_ label: String) -> (text: String, help: String) {
        switch label {
        case "identified": return ("Confirmed", "Confirmed: the agent itself reported working in these tabs.")
        case "likely": return ("Probable", "Probable: the agent didn't report this session. It was recognised from what happened in Chrome.")
        case "mixed": return ("Agent and you", "Agent and you: the agent's activity overlapped with your own clicks or typing.")
        default: return ("Unclear", "Unclear: nothing identified who was acting.")
        }
    }

    public static func state(_ state: String) -> (text: String, help: String) {
        switch state {
        case "recording": return ("Recording", "The agent is using Chrome and its tabs are being recorded.")
        case "inactive": return ("Idle", "The agent hasn't used Chrome for a while. The session ends if it stays idle.")
        case "possible": return ("Checking", "Something looks like an agent. Recording starts if it is confirmed.")
        case "ended": return ("Ended", "The session is over.")
        default: return (state.capitalized, "")
        }
    }

    public static let incompleteRecord = "Incomplete record"
    public static let incompleteRecordHelp = "Part of this session couldn't be recorded. Open the session's Changes tab and look under Coverage."

    /// Where a timeline row came from.
    public static func source(src: String, pre: Bool) -> (text: String, help: String) {
        if src.hasPrefix("hook.") || src.hasPrefix("log.") { return ("reported", "The agent's own report of what it did.") }
        if src == "app" { return ("recorder", "Written by Agent Ledger itself.") }
        if src == "mac.sensor" { return ("Mac", "Seen on this Mac, outside Chrome.") }
        return pre ? ("earlier", "Seen in Chrome shortly before recording started.") : ("observed", "Seen in Chrome by the extension, independently of the agent.")
    }
}
