import Foundation

/// A session reduced to what a reviewer needs on one screen: where the agent went, what it read,
/// what it ran, what it changed, and how far the record can be trusted.
///
/// Built at read time from stored events and attributions, so it also applies to sessions
/// recorded before these rules existed. It never rewrites what was stored.
public struct SessionReport: Sendable {
    public struct Site: Sendable, Equatable {
        public var host: String
        public var ms: Double
        public var pages: Int
        /// The agent's own UI (new-tab page, claude.ai, chatgpt.com), not a site it worked on.
        public var agentUI: Bool
        /// Known only from what the agent reported; the recorder couldn't see the browser.
        public var reportedOnly: Bool
    }

    public struct Group: Sendable, Equatable {
        public var pattern: String
        public var count: Int
    }

    public struct Script: Sendable, Identifiable {
        public var id: Int64
        public var t: Double
        public var tab: Int?
        public var tool: String
        public var code: String
        public var durationMs: Double?
        public var failed: Bool
        public var resultPreview: String?
        public var requests: Int
        public var nonGetRequests: Int
        public var fetched: [Group]
        /// Ways the code could change something ("clicks", "sends a POST request"). Empty: looks read-only.
        public var signals: [String]
        public var couldChange: Bool { !signals.isEmpty || nonGetRequests > 0 }
    }

    public struct Change: Sendable, Identifiable {
        public var id: Int64
        public var t: Double
        public var kind: String
        public var text: String
        public var actor: String
        public var details: [String]
        /// A consequential action ("Delete", "Send", …), when the control's name says so.
        public var tag: String?
        /// From the agent's own report, not observed in the browser.
        public var reported: Bool
        /// Site the change happened on, when known.
        public var host: String? = nil
    }

    public struct Row: Sendable, Identifiable {
        public var id: Int64
        public var t: Double
        public var count: Int
        public var actor: String
        public var text: String
        public var kind: String
    }

    public struct Turn: Sendable, Identifiable {
        public var id: Int
        public var t: Double
        public var prompt: String?
        public var rows: [Row]
    }

    public var agent: String
    public var startedAt: Double
    public var activeMs: Double
    public var sites: [Site]
    public var prompts: Int
    public var tabs: Int
    /// The recorder had no view of the browser the agent used (for example the Claude desktop
    /// app's built-in browser). Everything in the report then comes from the agent's reports.
    public var unseenBrowser: String?
    /// The agent stayed inside its own app's browser (the Claude desktop app's browser pane, or the
    /// ChatGPT app's) and never touched your Chrome. Recorded as usual, but not worth a notification.
    /// For Codex this is inferred: it used its browser tool and Chrome saw nothing.
    public var inAppBrowserOnly = false

    public var opened: [Group]
    public var fetched: [Group]
    public var fetchedCount: Int
    public var readTools: [Group]

    public var scripts: [Script]
    public var changes: [Change]
    public var statusMessages: [Change]
    public var pageRequests: [Group]
    public var backgroundRequests: Int
    public var backgroundHosts: [String]

    public var observedClicks: Int
    public var observedTyping: Int
    public var reportedActions: Int

    public var gaps: Int
    public var attributed: Int
    public var unknown: Int
    public var coverage: String

    public var cwd: String?
    public var resumeCommand: String?

    public var turns: [Turn]
    /// Attributions after the read-time rules (background, page, the agent's own navigation).
    public var effective: [Int64: Attribution]
    /// The latest comparison with the agent's own log (a `reconcile.result` payload), if one ran.
    public var logCheck: JSONValue?
    /// Alerts raised for this session.
    public var alerts: [Change] = []

    public var pagesRead: Int { opened.reduce(0) { $0 + $1.count } + fetchedCount }
    public var unknownShare: Double { attributed == 0 ? 0 : Double(unknown) / Double(attributed) }
    public var headlineChanges: [Change] { changes.filter { $0.tag != nil } }
    public var workedSites: [Site] { sites.filter { !$0.agentUI } }

    // MARK: One-line texts

    static func approx(_ n: Int) -> String {
        n > 20 ? "about \(Int((Double(n) / 10).rounded()) * 10)" : "\(n)"
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }

    public static func minutes(_ ms: Double) -> String {
        let m = ms / 60000
        if m < 1 { return "under a minute" }
        if m < 90 { return "\(Int(m.rounded())) min" }
        return String(format: "%.1f h", m / 60)
    }

    public var changedText: String {
        if changes.isEmpty {
            let risky = scripts.filter(\.couldChange).count
            if risky > 0 { return "no changes observed, but \(Self.plural(risky, "script")) could have changed something" }
            return unseenBrowser == nil ? "no changes observed" : "no changes reported"
        }
        if let h = headlineChanges.first {
            let more = changes.count - 1
            return "\(h.tag!.lowercased()): \(h.text)" + (more > 0 ? " and \(Self.plural(more, "other change"))" : "")
        }
        return "made \(Self.plural(changes.count, "change"))"
    }

    /// "Claude Code on amazon.com for 80 min: read about 630 pages, ran 47 scripts, changed nothing."
    public var oneLine: String {
        let where_ = workedSites.prefix(2).map(\.host).joined(separator: ", ")
        let extra = workedSites.count > 2 ? " and \(workedSites.count - 2) more" : ""
        var bits: [String] = []
        if pagesRead > 0 { bits.append("read \(Self.approx(pagesRead)) page\(pagesRead == 1 ? "" : "s")") }
        if !scripts.isEmpty { bits.append("ran \(Self.plural(scripts.count, "script"))") }
        bits.append(changedText)
        let place = where_.isEmpty ? (unseenBrowser.map { " in \($0)" } ?? "") : " on \(where_)\(extra)"
        return "\(Correlator.displayAgent(agent))\(place) for \(Self.minutes(activeMs)): \(bits.joined(separator: ", "))."
    }

    /// What "no changes" rests on, or a count of what changed.
    public var changeBasis: String {
        var basis: [String] = []
        basis.append(observedClicks == 0 ? "no clicks" : Self.plural(observedClicks, "click"))
        basis.append(observedTyping == 0 ? "no typing" : "\(observedTyping) typing or field events")
        if reportedActions > 0 { basis.append("\(Self.plural(reportedActions, "click or typing call")) reported by the agent") }
        let risky = scripts.filter(\.couldChange).count
        if !scripts.isEmpty {
            basis.append(risky == 0 ? "\(Self.plural(scripts.count, "script")) that look read-only"
                : "\(risky) of \(Self.plural(scripts.count, "script")) could have changed something")
        }
        if !pageRequests.isEmpty {
            let n = pageRequests.reduce(0) { $0 + $1.count }
            basis.append("\(Self.plural(n, "request")) the page sent by itself (\(pageRequests.prefix(3).map(\.pattern).joined(separator: ", ")))")
        }
        if backgroundRequests > 0 { basis.append("\(Self.plural(backgroundRequests, "background request")) left out") }
        return basis.joined(separator: "; ")
    }

    public var trustLine: String {
        var bits: [String] = []
        bits.append(gaps == 0 ? "No gaps recorded" : Self.plural(gaps, "gap"))
        if attributed > 0 {
            let pct = unknownShare * 100
            bits.append(unknown == 0 ? "every observed event has an actor"
                : String(format: "%.1f%% of observed events have an unknown actor (%d of %d)", pct, unknown, attributed))
        }
        if let b = unseenBrowser { bits.append("the recorder couldn't see \(b); this record is the agent's own report") }
        else if coverage != "ok" { bits.append("coverage was degraded for part of the session") }
        if let c = logCheck { bits.append(AgentLogs.trustText(c)) }
        return bits.joined(separator: "; ") + "."
    }
}

// MARK: - Classification

public enum EventClass {
    static let telemetryHosts = ["unagi.amazon.com", "fls-na.amazon.com", "google-analytics.com", "analytics.google.com",
                                 "googletagmanager.com", "doubleclick.net", "sentry.io", "datadoghq.com", "segment.io",
                                 "segment.com", "mixpanel.com", "amplitude.com", "newrelic.com", "nr-data.net",
                                 "bugsnag.com", "hotjar.com", "fullstory.com", "clarity.ms", "statsig.com",
                                 "launchdarkly.com", "intercom.io", "facebook.com", "play.google.com", "browser-intake-datadoghq.com"]
    static let telemetryWords: Set<String> = ["telemetry", "beacon", "collect", "rum", "csm", "metrics", "analytics",
                                              "clientmetrics", "log", "logs", "logging", "ping", "heartbeat", "track", "tracking"]

    static func hostMatches(_ host: String, _ list: [String]) -> Bool {
        list.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A request that carries telemetry, not an action: a beacon, or a POST to a known
    /// telemetry host or endpoint.
    public static func isBackground(_ e: LedgerEvent) -> Bool {
        guard e.cat == "net.request" else { return false }
        if e.p?["type"]?.stringValue == "ping" { return true }
        guard let u = e.url.flatMap(URL.init(string:)), let host = u.host?.lowercased() else { return false }
        if hostMatches(host, telemetryHosts) { return true }
        guard e.p?["mutating"]?.boolValue == true else { return false }
        let segments = u.path.lowercased().split(separator: "/").map(String.init)
        let named = segments.contains { telemetryWords.contains($0) }
        let status = e.p?["status"]?.intValue ?? 0
        return named && (status == 204 || status == 202 || status == 0)
    }

    /// Pages that belong to the agent, not to a site it worked on.
    public static func isAgentUI(url: String?) -> Bool {
        guard let url else { return false }
        if url.hasPrefix("chrome://new-tab-page") || url.hasPrefix("chrome://newtab") || url == "about:blank" { return true }
        if url.hasPrefix("chrome-extension://") { return true }
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return hostMatches(host, ["claude.ai", "chatgpt.com", "chat.openai.com"])
    }

    static let pager = try! NSRegularExpression(pattern: #"^(page|slide|item|step)?\s*\d+\s*(of|/)\s*\d+$"#, options: [.caseInsensitive])

    /// Whether a status message is worth showing by itself: an alert, status or live region with
    /// a short, readable text. Menus, carousel pagers and leaked style text are not.
    public static func isReadableStatus(_ e: LedgerEvent) -> Bool {
        guard e.cat == "page.alert" else { return false }
        let role = e.p?["role"]?.stringValue ?? ""
        if role == "dialog" || role == "menu" || role == "tooltip" { return false }
        let text = (e.p?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > 300 { return false }
        if text.contains("{") && (text.contains("font-") || text.contains("@") || text.contains(":")) { return false }
        let r = NSRange(text.startIndex..., in: text)
        if pager.firstMatch(in: text, range: r) != nil { return false }
        return true
    }

    /// "amazon.com/your-orders/search": host plus path, with ids replaced and the query dropped.
    public static func pattern(_ url: String?) -> String {
        guard let url, let u = URL(string: url), let host = u.host else { return url ?? "" }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let segs = u.path.split(separator: "/").map { seg -> String in
            let s = String(seg)
            let digits = s.filter(\.isNumber).count
            let looksLikeId = s.count >= 8 && (digits * 3 >= s.count || s.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil)
            let code = s.count >= 8 && digits > 0 && s.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
            return (Int(s) != nil || looksLikeId || code) ? "…" : s
        }
        return segs.isEmpty ? h : h + "/" + segs.joined(separator: "/")
    }

    static func host(_ url: String?) -> String? {
        guard let h = url.flatMap(URL.init(string:))?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func grouped(_ urls: [String]) -> [SessionReport.Group] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for u in urls {
            let p = pattern(u)
            if counts[p] == nil { order.append(p) }
            counts[p, default: 0] += 1
        }
        return order.map { SessionReport.Group(pattern: $0, count: counts[$0]!) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.pattern < $1.pattern }
    }

    // MARK: Scripts

    static let scriptSignals: [(String, String)] = [
        (#"\.click\s*\("#, "clicks"),
        (#"\.submit\s*\(|requestSubmit\s*\("#, "submits a form"),
        (#"\.(value|checked|selectedIndex)\s*=[^=]"#, "sets a field value"),
        (#"dispatchEvent\s*\("#, "fires events"),
        (#"method\s*['"]?\s*:\s*['"`](POST|PUT|PATCH|DELETE)"#, "sends a non-GET request"),
        (#"\.open\s*\(\s*['"`](POST|PUT|PATCH|DELETE)"#, "sends a non-GET request"),
        (#"sendBeacon\s*\("#, "sends a beacon"),
        (#"document\.cookie\s*=[^=]"#, "sets a cookie"),
        (#"(localStorage|sessionStorage)\.(setItem|removeItem|clear)\s*\("#, "changes site storage"),
        (#"location\.(href\s*=[^=]|assign\s*\(|replace\s*\()|location\s*=[^=]"#, "navigates"),
        (#"\b(cua|page|tab|locator)\w*\.(click|dblclick|type|fill|press|check|uncheck|selectOption|setInputFiles|dragTo|tap)\s*\("#, "clicks or types"),
        (#"\.(fill|press|selectOption|setInputFiles)\s*\("#, "clicks or types"),
        (#"execCommand\s*\("#, "edits the page"),
    ]

    /// Ways a script's code could change something. An empty list means "looks read-only", never
    /// "did not change anything": code built at run time defeats this check.
    public static func scriptSignals(in code: String) -> [String] {
        var out: [String] = []
        let r = NSRange(code.startIndex..., in: code)
        for (pattern, label) in scriptSignals {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if re.firstMatch(in: code, range: r) != nil, !out.contains(label) { out.append(label) }
        }
        return out
    }

    // MARK: Tool operations

    /// One operation inside a tool call. `browser_batch` holds several.
    public struct Op {
        public var name: String
        public var input: JSONValue?
        public var tab: Int?
    }

    public static func ops(_ p: JSONValue?) -> [Op] {
        let tool = Correlator.shortTool(p?["tool"]?.stringValue ?? "")
        let input = p?["input"]
        if let actions = input?["actions"]?.arrayValue {
            return actions.map { a in
                Op(name: a["name"]?.stringValue ?? "action", input: a["input"], tab: a["input"]?["tabId"]?.intValue)
            }
        }
        return [Op(name: tool, input: input, tab: input?["tabId"]?.intValue ?? p?["tabIds"]?.arrayValue?.first?.intValue)]
    }

    static let readOps: Set<String> = ["read_page", "get_page_text", "find", "read_console_messages", "read_network_requests"]
    static let passiveComputer: Set<String> = ["screenshot", "zoom", "wait", "hover", "scroll", "scroll_to"]
    static let credentialOps: Set<String> = ["request_credentials", "autofill_credential", "enter_verification_code"]

    public enum OpKind { case script, read, screenshot, navigate, action, upload, credential, housekeeping }

    public static func kind(_ op: Op) -> OpKind {
        let n = op.name
        if n == "javascript_tool" || n == "js" || n.hasSuffix("evaluate") || n.hasSuffix("evaluate_script") { return .script }
        if op.input?["code"]?.stringValue != nil { return .script }
        if readOps.contains(n) || n.contains("snapshot") { return .read }
        if n == "navigate" || n == "preview_start" || n.hasSuffix("_navigate") || n == "tabs_create_mcp", op.input?["url"] != nil { return .navigate }
        if n == "computer" {
            let a = op.input?["action"]?.stringValue ?? ""
            if a == "screenshot" || a == "zoom" { return .screenshot }
            return passiveComputer.contains(a) ? .housekeeping : .action
        }
        if n == "form_input" || n.hasSuffix("_click") || n.hasSuffix("_type") || n.hasSuffix("_fill") || n.hasSuffix("_press_key")
            || n.hasSuffix("_select_option") || n.hasSuffix("_fill_form") { return .action }
        if n == "file_upload" || n == "upload_image" || n.hasSuffix("_file_upload") { return .upload }
        if credentialOps.contains(n) { return .credential }
        if n.contains("screenshot") { return .screenshot }
        return .housekeeping
    }

    public static let securityTag = "Security change"
    public static let consentTag = "Access granted"

    static let consequential: [(String, String)] = [
        (#"\b((change|reset|update|set|create|new) (your |a |new )?(password|passcode|pin)|two[- ]factor|2[- ]step|two[- ]step|2fa|passkey|security key|recovery (email|phone|code|key)|backup codes?|(add|new|generate|create|regenerate) (an? |new )?(ssh key|api key|access token|personal access token|token|app password|secret))\b"#, securityTag),
        (#"^\s*(allow|authori[sz]e|grant access|approve access|yes, allow)\b(?!\s+(all\b|cookies|selection|selected|essential|necessary|notifications))"#, consentTag),
        (#"\b(delete|remove|discard|erase|trash)\b"#, "Delete"),
        (#"\b(send|reply|forward)\b"#, "Send"),
        (#"\b(post|publish|tweet|comment)\b"#, "Post"),
        (#"\b(pay|buy|purchase|place (your )?order|checkout|check out|subscribe|donate)\b"#, "Pay"),
        (#"\b(transfer|withdraw|deposit)\b"#, "Transfer"),
        (#"\b(invite|share|grant|add (member|collaborator|user))\b"#, "Share"),
        (#"\b(save|update|apply|confirm|submit|change|enable|disable|turn (on|off)|merge|approve|cancel (order|subscription|plan))\b"#, "Change"),
    ]

    /// What submitting a form amounts to: card fields mean a payment and a new-password field a security
    /// change, whatever the button says. Otherwise the button's name decides.
    static func formTag(fields: [JSONValue], submitter: String?) -> String {
        let named = consequentialTag(submitter)
        if named == securityTag || named == consentTag { return named! }
        var card = false, newPassword = false
        for f in fields {
            let d = f["field"]
            let ac = (d?["autocomplete"]?.stringValue ?? "").lowercased()
            let sens = d?["sensitive"]?.stringValue ?? f["value"]?["reason"]?.stringValue ?? ""
            if ac.contains("cc-number") || ac.contains("cc-csc") || sens.hasPrefix("autocomplete:cc-") { card = true }
            if ac.contains("new-password") { newPassword = true }
        }
        if newPassword { return securityTag }
        if card { return "Pay" }
        return named ?? "Change"
    }

    /// The consequential action a control's name suggests, from a fixed list.
    public static func consequentialTag(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count < 80 else { return nil }
        let r = NSRange(name.startIndex..., in: name)
        for (pattern, tag) in consequential {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if re.firstMatch(in: name, range: r) != nil { return tag }
        }
        return nil
    }
}

// MARK: - Builder

public extension SessionReport {
    static let actionCats: Set<String> = ["ui.click", "form.submit", "ui.key", "field.change", "field.input", "edit.change", "ui.paste"]
    static let noiseCats: Set<String> = ["selftest.result", "dom.summary", "ui.scroll", "page.visibility", "ui.focus", "tab.activated", "tab.snapshot",
                                         "tab.updated", "capture.armed", "capture.content_armed", "capture.disarmed",
                                         "debugger.attached", "debugger.detached", "session.recording", "session.inactive",
                                         "tool.post", "turn.stop", "session.tab_bound", "session.tab_unbound", "tab.created",
                                         "tab.removed", "detector.decision"]

    static func build(store: LedgerStore, session id: String) throws -> SessionReport? {
        guard let s = try store.session(id: id) else { return nil }
        return build(session: s, events: try store.events(forSession: id),
                     attributions: try store.latestAttributions(session: id),
                     tabs: try store.sessionTabs(session: id).map { ($0.tab, $0.boundAt, $0.unboundAt) })
    }

    static func build(session s: SessionRecord, events: [StoredEvent], attributions: [Int64: Attribution],
                      tabs: [(tab: Int, boundAt: Double, unboundAt: Double?)]) -> SessionReport {
        let agentActor = "agent:\(s.agent)"
        var effective = attributions

        // Tool calls, paired by id.
        struct Call { var pre: StoredEvent; var end: Double?; var failed = false; var preview: String? }
        var calls: [Call] = []
        var callIndex: [String: Int] = [:]
        for se in events {
            let e = se.event
            switch e.cat {
            case "tool.pre", "tool.logged":
                // `tool.logged`: a call the hooks missed, added from the agent's own log.
                if let k = e.p?["toolUseId"]?.stringValue { callIndex[k] = calls.count }
                calls.append(Call(pre: se))
            case "tool.post", "tool.failure":
                guard let k = e.p?["toolUseId"]?.stringValue, let i = callIndex[k] else { continue }
                calls[i].end = e.t
                calls[i].failed = e.cat == "tool.failure" || e.p?["result"]?["isError"]?.boolValue == true
                calls[i].preview = e.p?["result"]?["preview"]?.stringValue
            default: break
            }
        }

        var scripts: [Script] = []
        var navOps: [(t: Double, url: String, tab: Int?)] = []
        var readCounts: [String: Int] = [:]
        var reportedActions = 0
        var reportedChanges: [Change] = []
        var actionTimes: [(t: Double, tab: Int?)] = []
        var unseenTools = 0, extensionTools = 0, inAppTools = 0, automationTools = 0
        var unseenName: String?
        for c in calls {
            let p = c.pre.event.p
            let toolName = p?["tool"]?.stringValue ?? ""
            let route = p?["route"]?.stringValue ?? ""
            if toolName.hasPrefix("mcp__Claude_Browser__") { unseenTools += 1; inAppTools += 1; unseenName = "the Claude desktop app's built-in browser" }
            else if route == BrowserRoute.automation { unseenTools += 1; automationTools += 1; unseenName = unseenName ?? "a browser driven by an automation tool" }
            else if route == BrowserRoute.extensionRoute { extensionTools += 1 }
            for op in EventClass.ops(p) {
                switch EventClass.kind(op) {
                case .script:
                    let code = op.input?["text"]?.stringValue ?? op.input?["code"]?.stringValue ?? op.input?["function"]?.stringValue ?? ""
                    scripts.append(Script(id: c.pre.id, t: c.pre.event.t, tab: op.tab, tool: op.name, code: code,
                                          durationMs: c.end.map { $0 - c.pre.event.t }, failed: c.failed, resultPreview: c.preview,
                                          requests: 0, nonGetRequests: 0, fetched: [], signals: EventClass.scriptSignals(in: code)))
                    if !EventClass.scriptSignals(in: code).isEmpty { actionTimes.append((c.pre.event.t, op.tab)) }
                case .read, .screenshot:
                    readCounts[op.name == "computer" ? "screenshot" : op.name, default: 0] += 1
                case .navigate:
                    if let u = op.input?["url"]?.stringValue, u != "back", u != "forward" { navOps.append((c.pre.event.t, u, op.tab)) }
                case .action:
                    reportedActions += 1
                    actionTimes.append((c.pre.event.t, op.tab))
                case .upload:
                    reportedChanges.append(Change(id: c.pre.id, t: c.pre.event.t, kind: "upload",
                                                  text: "Uploaded a file (\(op.name))", actor: Correlator.displayAgent(s.agent),
                                                  details: [], tag: nil, reported: true))
                case .credential:
                    let goal = op.input?["goal"]?.stringValue.map { ": \(EventFormatter.quote($0, max: 80))" } ?? ""
                    reportedChanges.append(Change(id: c.pre.id, t: c.pre.event.t, kind: "credential",
                                                  text: "Used the password manager (\(op.name))\(goal). Values are never recorded",
                                                  actor: Correlator.displayAgent(s.agent), details: [], tag: nil, reported: true))
                case .housekeeping: break
                }
            }
        }

        // Read-time actor rules.
        func set(_ se: StoredEvent, actor: String, label: String, reason: String) {
            var a = effective[se.id] ?? Attribution(eventId: se.id, sessionId: s.id, actor: actor, label: label, scope: "inference",
                                                    reasons: [], detectorVersion: "report-1", createdAt: se.receivedAt)
            a.actor = actor; a.label = label
            a.reasons = a.reasons.filter { $0 != "no agent operation or physical input matched this event" } + [reason]
            effective[se.id] = a
        }
        var background: Set<Int64> = []
        var agentUIEvents: Set<Int64> = []
        for se in events {
            let e = se.event
            if EventClass.isBackground(e) {
                background.insert(se.id)
                if effective[se.id] != nil { set(se, actor: "page", label: "background", reason: "telemetry request (beacon or known telemetry endpoint)") }
                continue
            }
            if e.cat == "net.request", EventClass.isAgentUI(url: e.p?["initiator"]?.stringValue) || EventClass.isAgentUI(url: e.url) {
                agentUIEvents.insert(se.id)
                background.insert(se.id)
                if effective[se.id] != nil { set(se, actor: agentActor, label: "likely", reason: "request from the agent's own page") }
                continue
            }
            guard let a = effective[se.id], a.actor == "unknown" else { continue }
            switch e.cat {
            case "nav.committed", "nav.history", "nav.fragment":
                if EventClass.isAgentUI(url: e.url) {
                    agentUIEvents.insert(se.id)
                    set(se, actor: agentActor, label: "likely", reason: "the agent's own page in a tab it opened")
                } else if let op = navOps.last(where: { e.t >= $0.t - 2000 && e.t <= $0.t + 20000 && Correlator.sameURL(e.url ?? "", $0.url) }) {
                    _ = op
                    set(se, actor: agentActor, label: "identified", reason: "the agent's navigate call named this URL just before")
                }
            case "net.request", "page.alert", "dom.summary", "page.validation", "nav.error":
                set(se, actor: "page", label: "likely", reason: "no agent call was open on the tab and there was no physical input; the page did this by itself")
            default: break
            }
        }

        // Sites and time on each, from main-frame navigations per tab.
        var visits: [Int: [(t: Double, url: String)]] = [:]
        for se in events {
            let e = se.event
            guard let tab = e.tab, let url = e.url, e.cat == "nav.committed" || e.cat == "nav.history" || e.cat == "tab.updated" else { continue }
            if e.cat == "nav.committed", (e.frame ?? 0) != 0 { continue }
            if visits[tab]?.last?.url == url { continue }
            visits[tab, default: []].append((e.t, url))
        }
        let lastT = events.last(where: { !$0.event.cat.hasPrefix("session.") })?.event.t ?? s.lastActivityAt
        let firstT = events.first(where: { $0.event.pre != true })?.event.t ?? s.startedAt
        var siteMs: [String: Double] = [:], sitePages: [String: Int] = [:], siteUI: [String: Bool] = [:]
        var siteOrder: [String] = []
        for (tab, list) in visits {
            let unbound = tabs.filter { $0.tab == tab }.compactMap(\.unboundAt).max() ?? lastT
            for (i, v) in list.enumerated() {
                let ui = EventClass.isAgentUI(url: v.url)
                guard let h = (v.url.hasPrefix("chrome") || v.url.hasPrefix("about:")) ? (ui ? "new tab" : nil) : EventClass.host(v.url) else { continue }
                let end = i + 1 < list.count ? list[i + 1].t : max(unbound, v.t)
                if siteMs[h] == nil { siteOrder.append(h) }
                siteMs[h, default: 0] += max(0, min(end, lastT) - max(v.t, firstT))
                sitePages[h, default: 0] += 1
                siteUI[h] = ui
            }
        }
        var sites = siteOrder.map { Site(host: $0, ms: siteMs[$0] ?? 0, pages: sitePages[$0] ?? 0, agentUI: siteUI[$0] ?? false, reportedOnly: false) }
        for op in navOps {
            guard let h = EventClass.host(op.url), !sites.contains(where: { $0.host == h }) else { continue }
            sites.append(Site(host: h, ms: 0, pages: navOps.filter { EventClass.host($0.url) == h }.count,
                              agentUI: EventClass.isAgentUI(url: op.url), reportedOnly: true))
        }
        sites.sort { ($0.agentUI ? 1 : 0, -$0.ms) < ($1.agentUI ? 1 : 0, -$1.ms) }

        // Requests: fetched by the agent, sent by the page, and linked to the script that was running.
        var fetchedURLs: [String] = []
        var pageRequestURLs: [String] = []
        var scriptRequests: [Int: [String]] = [:]
        var mutatingByTab: [(t: Double, tab: Int?, id: Int64)] = []
        var changes: [Change] = []
        var observedClicks = 0, observedTyping = 0
        var openedURLs: [String] = navOps.map(\.url).filter { !EventClass.isAgentUI(url: $0) }
        let scriptOrder = scripts.indices.sorted { scripts[$0].t < scripts[$1].t }
        var backgroundHosts: [String: Int] = [:]

        func actorText(_ se: StoredEvent) -> String { EventFormatter.actorLabel(effective[se.id]) }

        for se in events {
            let e = se.event
            let actor = effective[se.id]?.actor ?? ""
            if background.contains(se.id) {
                if !agentUIEvents.contains(se.id), let h = EventClass.host(e.url) { backgroundHosts[h, default: 0] += 1 }
                continue
            }
            switch e.cat {
            case "net.request":
                let method = e.p?["method"]?.stringValue ?? "GET"
                let mutating = e.p?["mutating"]?.boolValue == true
                if let i = scriptOrder.last(where: { scripts[$0].t <= e.t + 50 && e.t - scripts[$0].t < 900_000 &&
                        (scripts[$0].tab == nil || scripts[$0].tab == e.tab) }), actor != "page", actor != "human" {
                    scripts[i].requests += 1
                    if mutating { scripts[i].nonGetRequests += 1 }
                    scriptRequests[i, default: []].append(e.url ?? "")
                }
                if actor == "page" {
                    if mutating { pageRequestURLs.append(e.url ?? "") }
                } else if mutating {
                    mutatingByTab.append((e.t, e.tab, se.id))
                    let status = e.p?["status"]?.intValue.map { " → \($0)" } ?? ""
                    changes.append(Change(id: se.id, t: e.t, kind: "request", text: "\(method) \(EventClass.pattern(e.url))\(status)",
                                          actor: actorText(se), details: [e.url ?? ""], tag: nil, reported: false))
                } else if actor.hasPrefix("agent:") {
                    fetchedURLs.append(e.url ?? "")
                }
            case "nav.committed":
                if (e.frame ?? 0) == 0, actor.hasPrefix("agent:"), !EventClass.isAgentUI(url: e.url), let u = e.url,
                   !navOps.contains(where: { Correlator.sameURL(u, $0.url) && abs(e.t - $0.t) < 20000 }) {
                    openedURLs.append(u)
                }
            case "ui.click":
                observedClicks += 1
                actionTimes.append((e.t, e.tab))
            case "field.input", "ui.key", "ui.paste":
                observedTyping += 1
                actionTimes.append((e.t, e.tab))
            case "form.submit":
                actionTimes.append((e.t, e.tab))
                let fields = (e.p?["fields"]?.arrayValue ?? []).map { f -> String in
                    let name = EventFormatter.target(f["field"])
                    let v = EventFormatter.value(f["value"]) ?? "?"
                    if let b = EventFormatter.value(f["before"]) { return "\(name): \(b) → \(v)" }
                    return "\(name): \(v)"
                }
                let submitter = e.p?["submitter"]?["name"]?.stringValue
                changes.append(Change(id: se.id, t: e.t, kind: "submit", text: EventFormatter.describe(e), actor: actorText(se),
                                      details: fields, tag: EventClass.formTag(fields: e.p?["fields"]?.arrayValue ?? [], submitter: submitter),
                                      reported: false))
            case "field.change", "edit.change":
                observedTyping += 1
                actionTimes.append((e.t, e.tab))
                changes.append(Change(id: se.id, t: e.t, kind: "edit", text: EventFormatter.describe(e), actor: actorText(se),
                                      details: [], tag: nil, reported: false))
            case "download.created":
                changes.append(Change(id: se.id, t: e.t, kind: "download", text: EventFormatter.describe(e), actor: actorText(se),
                                      details: [], tag: nil, reported: false))
            default: break
            }
        }
        for (i, urls) in scriptRequests { scripts[i].fetched = Array(EventClass.grouped(urls).prefix(4)) }

        // Consequential clicks: the control's name says so, and a mutating request followed.
        for se in events where se.event.cat == "ui.click" {
            let e = se.event
            let name = e.p?["target"]?["name"]?.stringValue ?? e.p?["target"]?["text"]?.stringValue
            guard let tag = EventClass.consequentialTag(name),
                  let req = mutatingByTab.first(where: { $0.tab == e.tab && $0.t >= e.t - 100 && $0.t <= e.t + 5000 }) else { continue }
            if let i = changes.firstIndex(where: { $0.id == req.id }) {
                changes[i].tag = tag
                changes[i].text = "Clicked \(EventFormatter.quote(name, max: 60)), then " + changes[i].text
            }
        }
        changes.append(contentsOf: reportedChanges)
        let urlById = Dictionary(events.map { ($0.id, $0.event.url) }, uniquingKeysWith: { a, _ in a })
        for i in changes.indices { changes[i].host = EventClass.host(urlById[changes[i].id] ?? nil) }
        changes.sort { ($0.tag == nil ? 1 : 0, $0.t) < ($1.tag == nil ? 1 : 0, $1.t) }

        // Status messages count only when they follow an action or a real request.
        var statusMessages: [Change] = []
        let triggers = actionTimes + mutatingByTab.map { ($0.t, $0.tab) }
        for se in events where EventClass.isReadableStatus(se.event) {
            let e = se.event
            guard triggers.contains(where: { ($0.tab == nil || $0.tab == e.tab) && e.t >= $0.t - 100 && e.t <= $0.t + 5000 }) else { continue }
            statusMessages.append(Change(id: se.id, t: e.t, kind: "status", text: EventFormatter.describe(e), actor: actorText(se),
                                         details: [], tag: nil, reported: false))
        }
        let shownStatus = Set(statusMessages.map(\.id))

        // Trust.
        let gaps = events.filter { $0.event.kind == EventKind.gap }.count
        let attributedIds = events.filter { effective[$0.id] != nil }
        let unknown = attributedIds.filter { effective[$0.id]?.actor == "unknown" }.count

        // Timeline by prompt, with runs of similar rows collapsed.
        var turns: [Turn] = [Turn(id: 0, t: s.startedAt, prompt: nil, rows: [])]
        var promptCount = 0
        func add(_ se: StoredEvent, kind: String, key: String, text: String, actor: String) {
            var turn = turns.removeLast()
            if var last = turn.rows.last, last.kind == kind + "|" + key, last.actor == actor {
                last.count += 1
                turn.rows[turn.rows.count - 1] = last
            } else {
                turn.rows.append(Row(id: se.id, t: se.event.t, count: 1, actor: actor, text: text, kind: kind + "|" + key))
            }
            turns.append(turn)
        }
        for se in events {
            let e = se.event
            if e.cat == "turn.prompt" {
                promptCount += 1
                turns.append(Turn(id: turns.count, t: e.t, prompt: e.p?["prompt"]?.stringValue, rows: []))
                continue
            }
            if noiseCats.contains(e.cat) { continue }
            if background.contains(se.id) {
                add(se, kind: "background", key: "", text: "background requests", actor: "Page script")
                continue
            }
            if e.cat == "page.alert", !shownStatus.contains(se.id) { continue }
            let actor = e.src.hasPrefix("hook.") ? "\(Correlator.displayAgent(s.agent)) (reported)" : actorText(se)
            switch e.cat {
            case "net.request":
                let m = e.p?["method"]?.stringValue ?? "GET"
                let pat = EventClass.pattern(e.url)
                add(se, kind: "net", key: m + pat, text: "\(m) \(pat)", actor: actor)
            case "tool.pre":
                let ops = EventClass.ops(e.p)
                let names = ops.map { op -> String in
                    switch EventClass.kind(op) {
                    case .script: return "ran a script"
                    case .navigate: return "opened \(EventClass.pattern(op.input?["url"]?.stringValue))"
                    case .read: return "read the page (\(op.name))"
                    case .screenshot: return "took a screenshot"
                    case .action: return "\(op.input?["action"]?.stringValue ?? op.name)"
                    case .upload: return "uploaded a file"
                    case .credential: return "used the password manager"
                    case .housekeeping: return op.name
                    }
                }
                var uniq: [String] = []
                for n in names where !uniq.contains(n) { uniq.append(n) }
                let text = uniq.joined(separator: ", ")
                add(se, kind: "tool", key: text, text: text.prefix(1).uppercased() + text.dropFirst(), actor: actor)
            default:
                add(se, kind: e.cat, key: EventClass.pattern(e.url), text: EventFormatter.describe(e), actor: actor)
            }
        }
        turns.removeAll { $0.prompt == nil && $0.rows.isEmpty }

        // Link back to the conversation.
        let cwd = events.first(where: { $0.event.src.hasPrefix("hook.") && $0.event.p?["cwd"]?.stringValue != nil })?.event.p?["cwd"]?.stringValue
        var resume: String?
        if let r = s.runtimeSession {
            let cd = cwd.map { "cd \"\($0)\" && " } ?? ""
            if s.agent == "claude-code" { resume = "\(cd)claude --resume \(r)" }
            else if s.agent == "codex" { resume = "\(cd)codex resume \(r)" }
        }

        let observedTabs = Set(tabs.map(\.tab)).count
        let unseen = (unseenTools > 0 && extensionTools == 0 && observedTabs == 0) ? unseenName : nil
        if unseen != nil { for i in sites.indices { sites[i].reportedOnly = true } }

        let sawChrome = observedTabs > 0 || events.contains { $0.event.src.hasPrefix("ext.") }
        let inAppOnly = !sawChrome && automationTools == 0
            && (s.agent == "codex" ? (extensionTools > 0 || inAppTools > 0) : (inAppTools > 0 && extensionTools == 0))

        var built = SessionReport(
            agent: s.agent, startedAt: s.startedAt, activeMs: max(0, lastT - firstT), sites: sites, prompts: promptCount,
            tabs: observedTabs, unseenBrowser: unseen,
            opened: EventClass.grouped(openedURLs), fetched: EventClass.grouped(fetchedURLs), fetchedCount: fetchedURLs.count,
            readTools: readCounts.map { Group(pattern: $0.key, count: $0.value) }.sorted { $0.count > $1.count },
            scripts: scripts, changes: changes, statusMessages: statusMessages,
            pageRequests: EventClass.grouped(pageRequestURLs), backgroundRequests: background.count - agentUIEvents.count,
            backgroundHosts: backgroundHosts.sorted { $0.value > $1.value }.map(\.key),
            observedClicks: observedClicks, observedTyping: observedTyping, reportedActions: reportedActions,
            gaps: gaps, attributed: attributedIds.count, unknown: unknown, coverage: s.coverage,
            cwd: cwd, resumeCommand: resume, turns: turns, effective: effective,
            logCheck: events.last { $0.event.cat == "reconcile.result" }?.event.p,
            alerts: events.filter { $0.event.cat == "alert.raised" }.map {
                Change(id: $0.id, t: $0.event.t, kind: "alert", text: $0.event.p?["title"]?.stringValue ?? "Alert", actor: "",
                       details: [$0.event.p?["body"]?.stringValue ?? ""], tag: nil, reported: false)
            })
        built.inAppBrowserOnly = inAppOnly
        return built
    }
}
