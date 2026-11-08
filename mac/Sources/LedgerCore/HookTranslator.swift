import Foundation

public enum HookAgent: String, Sendable {
    case claude, codex

    public var src: String { "hook.\(rawValue)" }
    public var agentName: String { self == .claude ? "claude-code" : "codex" }
}

/// Converts agent hook stdin JSON into a ledger event. Pure, so it can be tested with fixtures.
public enum HookTranslator {
    public static let promptLimit = 500
    static let resultPreviewLimit = 500

    static let codexBrowserCode = try! NSRegularExpression(
        pattern: "agent\\.browsers|browser\\.(user|tabs|nameSession|capabilities|newTab|tab)|claimTab|openTabs|markDeliverable|markHandoff|\\.goto\\(|playwright|\\bcua\\.",
        options: [])

    /// Whether a tool call is a browser operation for the given agent.
    public static func isBrowserTool(agent: HookAgent, toolName: String, input: JSONValue?) -> Bool {
        let name = toolName.lowercased()
        if name.contains("claude-in-chrome") || name.contains("claude_in_chrome") { return true }
        if agent == .codex {
            if name.contains("browser") || name.contains("chrome") || name.contains("playwright") { return true }
            if let input {
                let text = input.canonicalString()
                let range = NSRange(location: 0, length: (text as NSString).length)
                if codexBrowserCode.firstMatch(in: text, range: range) != nil { return true }
            }
        }
        return false
    }

    /// Tab IDs named in tool input, including inside `browser_batch` actions.
    public static func tabIds(in input: JSONValue?) -> [Int] {
        var out: [Int] = []
        func visit(_ v: JSONValue, depth: Int) {
            guard depth < 6 else { return }
            switch v {
            case .object(let o):
                for (k, val) in o {
                    if k == "tabId" || k == "tab_id", let id = val.intValue, !out.contains(id) { out.append(id) }
                    else { visit(val, depth: depth + 1) }
                }
            case .array(let a): a.forEach { visit($0, depth: depth + 1) }
            default: break
            }
        }
        if let input { visit(input, depth: 0) }
        return out
    }

    /// Short summary of a tool result: never stores images or full page text.
    public static func summarizeResult(_ r: JSONValue?) -> JSONValue {
        guard let r else { return .null }
        var texts: [String] = []
        var images = 0
        var isError = false
        func visit(_ v: JSONValue, depth: Int) {
            guard depth < 6 else { return }
            switch v {
            case .string(let s): texts.append(s)
            case .array(let a): a.forEach { visit($0, depth: depth + 1) }
            case .object(let o):
                if o["is_error"]?.boolValue == true || o["isError"]?.boolValue == true { isError = true }
                if o["type"]?.stringValue == "image" || o["source"]?["type"]?.stringValue == "base64" {
                    images += 1; return
                }
                if let t = o["text"]?.stringValue { texts.append(t) }
                if let c = o["content"] { visit(c, depth: depth + 1) }
                if let e = o["error"] { isError = true; visit(e, depth: depth + 1) }
                for key in ["stdout", "output", "result", "message"] { if let x = o[key] { visit(x, depth: depth + 1) } }
            default: break
            }
        }
        visit(r, depth: 0)
        let joined = texts.joined(separator: "\n")
        let preview = Redactor.truncate(Redactor.scrub(String(joined.prefix(resultPreviewLimit * 2))),
                                        max: resultPreviewLimit)
        return ["isError": .bool(isError), "textLength": .number(Double(joined.count)),
                "images": .number(Double(images)), "preview": .string(preview)]
    }

    public static func translate(stdin data: Data, agent: HookAgent, now: Double = nowMs(),
                                 ppid: Int32 = 0, agentPid: Int32 = 0) -> LedgerEvent? {
        guard let input = JSONValue.parse(data), case .object(let o) = input else { return nil }
        let eventName = o["hook_event_name"]?.stringValue ?? ""
        let kind: String
        let cat: String
        switch eventName {
        case "SessionStart": kind = EventKind.runtimeReport; cat = "session.start"
        case "SessionEnd": kind = EventKind.runtimeReport; cat = "session.end"
        case "UserPromptSubmit": kind = EventKind.runtimeIntent; cat = "turn.prompt"
        case "PreToolUse": kind = EventKind.attemptedOp; cat = "tool.pre"
        case "PostToolUse": kind = EventKind.runtimeReport; cat = "tool.post"
        case "PostToolUseFailure": kind = EventKind.runtimeReport; cat = "tool.failure"
        case "Stop": kind = EventKind.runtimeReport; cat = "turn.stop"
        case "Interrupt": kind = EventKind.runtimeReport; cat = "turn.interrupt"
        case "SubagentStart": kind = EventKind.runtimeReport; cat = "subagent.start"
        case "SubagentStop": kind = EventKind.runtimeReport; cat = "subagent.stop"
        default: return nil
        }

        var p: [String: JSONValue] = [
            "agent": .string(agent.agentName),
            "hook": .string(eventName),
        ]
        if let s = o["session_id"]?.stringValue { p["session"] = .string(s) }
        if let t = o["turn_id"]?.stringValue { p["turn"] = .string(t) }
        if let c = o["cwd"]?.stringValue { p["cwd"] = .string(c) }
        if let m = o["model"]?.stringValue { p["model"] = .string(m) }
        if let src = o["source"]?.stringValue { p["source"] = .string(src) }
        if let reason = o["reason"]?.stringValue { p["reason"] = .string(reason) }
        if let at = o["agent_type"]?.stringValue { p["agentType"] = .string(at) }
        if let aid = o["agent_id"]?.stringValue { p["subagent"] = .string(aid) }
        if ppid > 0 { p["ppid"] = .number(Double(ppid)) }
        if agentPid > 0 { p["agentPid"] = .number(Double(agentPid)) }

        var tabForEnvelope: Int?
        if cat.hasPrefix("tool.") {
            let toolName = o["tool_name"]?.stringValue ?? "?"
            let toolInput = o["tool_input"]
            let browser = isBrowserTool(agent: agent, toolName: toolName, input: toolInput)
            p["tool"] = .string(toolName)
            p["browser"] = .bool(browser)
            if let id = o["tool_use_id"]?.stringValue { p["toolUseId"] = .string(id) }
            if let keys = toolInput?.objectValue?.keys.sorted() { p["inputKeys"] = .array(keys.prefix(20).map { .string($0) }) }
            if browser {
                if let toolInput { p["input"] = Redactor.sanitize(toolInput) }
                let tabs = tabIds(in: toolInput)
                if !tabs.isEmpty {
                    p["tabIds"] = .array(tabs.map { .number(Double($0)) })
                    tabForEnvelope = tabs.first
                }
                if let server = o["mcp_server"] { p["mcpServer"] = Redactor.sanitize(server) }
                if cat != "tool.pre" {
                    p["result"] = summarizeResult(o["tool_response"] ?? o["error"])
                    if cat == "tool.failure" { p["error"] = .string(Redactor.value(o["error"]?.stringValue ?? "", max: 500)) }
                }
            }
        }
        if cat == "turn.prompt", let prompt = o["prompt"]?.stringValue {
            p["prompt"] = .string(Redactor.truncate(Redactor.scrub(prompt), max: promptLimit))
        }

        return LedgerEvent(src: agent.src, inst: "\(agent.src)-\(agentPid > 0 ? agentPid : ppid)", seq: nil, t: now,
                           kind: kind, cat: cat, tab: tabForEnvelope, p: .object(p))
    }
}
