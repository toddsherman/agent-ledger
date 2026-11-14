import Foundation

/// Things worth interrupting you for. Alerts only notify; the recorder never blocks or pauses an agent.
public enum Alerts {
    public struct Alert: Equatable, Sendable {
        /// Stable per session, so an alert is raised once.
        public var key: String
        public var title: String
        public var body: String
        public var eventId: Int64?
        /// False for problems that already produced their own notification.
        public var notify = true
    }

    /// Consequential actions that raise an alert on any site. Each has a switch in Settings.
    public struct ActionKind: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String
        /// The change tag this kind covers, if it comes from one.
        public var tag: String?
    }

    public static let actionKinds: [ActionKind] = [
        ActionKind(id: "pay", name: "Payments and orders", detail: "Pay, buy, place order, subscribe, or a form with card fields", tag: "Pay"),
        ActionKind(id: "transfer", name: "Money transfers", detail: "Transfer, withdraw, deposit", tag: "Transfer"),
        ActionKind(id: "security", name: "Security settings", detail: "Passwords, two-factor, recovery details, new keys and tokens", tag: EventClass.securityTag),
        ActionKind(id: "consent", name: "Access approvals", detail: "Allow or Authorize on a sign-in or permission screen", tag: EventClass.consentTag),
        ActionKind(id: "send", name: "Sends", detail: "Send, reply, forward", tag: "Send"),
        ActionKind(id: "post", name: "Posts", detail: "Post, publish, comment", tag: "Post"),
        ActionKind(id: "share", name: "Sharing and invites", detail: "Share, invite, add a member", tag: "Share"),
        ActionKind(id: "delete", name: "Deletes", detail: "Delete, remove, discard", tag: "Delete"),
        ActionKind(id: "upload", name: "File uploads", detail: "A file from this Mac given to a page", tag: nil),
    ]

    /// The tab title Chrome gives its Safe Browsing warning page. English only: a Chrome in another
    /// language uses another title, and the warning goes unnoticed.
    static let chromeWarningTitle = "Security error"

    static func actionKind(tag: String) -> ActionKind? { actionKinds.first { $0.tag == tag } }

    static let gapTitles: [String: String] = [
        "gap.recorder_stopped": "The recorder stopped during this session",
        "gap.ledger_changed": "The ledger was changed during this session",
        "gap.hooks_removed": "An agent's hooks were removed during this session",
        "gap.extension_disconnected": "Chrome wasn't recorded for part of this session",
        "gap.selftest_failed": "The recorder failed its self-test during this session",
    ]

    /// Every alert the session's record supports. The caller drops those already raised.
    /// - knownRoutes: routes into the browser seen in earlier sessions; nil the first time,
    ///   when nothing counts as new.
    public static func evaluate(report r: SessionReport, events: [StoredEvent], settings: LedgerSettings,
                                knownRoutes: Set<String>?) -> [Alert] {
        var out: [Alert] = []
        let agent = Correlator.displayAgent(r.agent)

        // 1. A real change on a site you marked sensitive.
        var perHost: [String: [SessionReport.Change]] = [:]
        for c in r.changes where !c.reported && c.actor != "Likely you" {
            guard let h = c.host, settings.isSensitive(host: h) else { continue }
            perHost[h, default: []].append(c)
        }
        for (h, cs) in perHost.sorted(by: { $0.key < $1.key }) {
            // Lead with the most serious change (a tagged action), then the earliest.
            let first = cs.min { ($0.tag == nil || $0.tag == "Change" ? 1 : 0, $0.t) < ($1.tag == nil || $1.tag == "Change" ? 1 : 0, $1.t) }!
            let group = settings.sensitiveGroup(host: h) ?? SiteGroups.customName
            out.append(Alert(key: "sensitive:\(h)", title: "\(agent) changed something on \(h)",
                             body: "\(group): " + first.text + (cs.count > 1 ? " (and \(cs.count - 1) more)" : ""), eventId: first.id))
        }
        // Scripts that could change a sensitive site count too: the change may not be visible.
        for s in r.scripts where s.couldChange {
            guard let tab = s.tab,
                  let url = events.last(where: { $0.event.tab == tab && $0.event.t <= s.t && $0.event.url != nil && $0.event.cat.hasPrefix("nav.") })?.event.url,
                  let h = EventClass.host(url), settings.isSensitive(host: h), perHost[h] == nil,
                  !out.contains(where: { $0.key == "sensitive-script:\(h)" }) else { continue }
            out.append(Alert(key: "sensitive-script:\(h)", title: "\(agent) ran a script on \(h) that could change it",
                             body: "The script " + s.signals.joined(separator: ", ") + ".", eventId: s.id))
        }

        // 1b. A change on a site whose name imitates a well-known one.
        if settings.lookalikeAlerts {
            var perLookalike: [String: [SessionReport.Change]] = [:]
            for c in r.changes where !c.reported && c.actor != "Likely you" {
                guard let h = c.host, !settings.isSensitive(host: h),
                      !LedgerSettings.matches(host: h, in: settings.sensitiveExceptions), Lookalike.match(host: h) != nil else { continue }
                perLookalike[h, default: []].append(c)
            }
            for (h, cs) in perLookalike.sorted(by: { $0.key < $1.key }) {
                let m = Lookalike.match(host: h)!
                let first = cs.min { $0.t < $1.t }!
                out.append(Alert(key: "lookalike:\(h)", title: "\(agent) changed something on \(h), which looks like \(m.real)",
                                 body: "Check the address: \(m.reason). " + first.text + (cs.count > 1 ? " (and \(cs.count - 1) more)" : ""),
                                 eventId: first.id))
            }
        }

        // 1c. Data sent to a site that collects whatever it is given (a webhook catcher, a paste site).
        if settings.groupEnabled("drops") {
            var seenDrops = Set<String>()
            for se in events where se.event.cat == "net.request" {
                guard let h = EventClass.host(se.event.url), let m = SiteGroups.match(host: h), m.group.id == "drops",
                      !LedgerSettings.matches(host: h, in: settings.sensitiveExceptions) else { continue }
                let initiator = se.event.p?["initiator"]?.stringValue
                if EventClass.isAgentUI(url: initiator) { continue }
                let method = se.event.p?["method"]?.stringValue ?? "GET"
                let from = EventClass.host(initiator)
                // Browsing the drop site itself is not a send; a request from another page, or one that carries a body, is.
                let fromElsewhere = from.map { !($0 == m.entry || $0.hasSuffix("." + m.entry)) } ?? false
                guard method != "GET" || fromElsewhere else { continue }
                guard !out.contains(where: { $0.key == "sensitive:\(h)" }), seenDrops.insert(h).inserted else { continue }
                out.append(Alert(key: "drop:\(h)", title: "Data may have been sent to \(h)",
                                 body: "During \(agent)'s session, \(from ?? "a page") made a \(method) request to \(h). That site collects whatever is sent to it.",
                                 eventId: se.id))
            }
        }

        // 1d. Chrome showed its own red warning page (Safe Browsing) in a tab of this session.
        var warned = Set<String>()
        for se in events where se.event.cat == "tab.updated" && se.event.p?["title"]?.stringValue == chromeWarningTitle {
            guard let url = se.event.url, url.hasPrefix("http"), let h = EventClass.host(url), let tab = se.event.tab,
                  warned.insert(h).inserted else { continue }
            let wentPast = events.contains {
                $0.event.t > se.event.t && $0.event.tab == tab && $0.event.cat == "nav.committed" && ($0.event.frame ?? 0) == 0
                    && EventClass.host($0.event.url) == h
            }
            if wentPast {
                out.append(Alert(key: "warned-past:\(h)", title: "\(agent)'s session went past Chrome's warning for \(h)",
                                 body: "Chrome marked \(h) as dangerous and the page was opened anyway. Check what happened there.", eventId: se.id))
            } else {
                out.append(Alert(key: "warned:\(h)", title: "Chrome warned about \(h) in \(agent)'s session",
                                 body: "Chrome marked \(h) as dangerous and showed its warning page. The page behind it was not opened.", eventId: se.id))
            }
        }

        // 2. A consequential action anywhere (send, delete, pay, …), named by the control.
        for c in r.changes where !c.reported && c.tag != nil && c.tag != "Change" && c.actor != "Likely you" {
            guard c.host.map({ !settings.isSensitive(host: $0) }) ?? true else { continue }
            guard let kind = actionKind(tag: c.tag!), settings.actionEnabled(kind.id) else { continue }
            out.append(Alert(key: "action:\(c.id)", title: "\(agent): \(c.tag!)\(c.host.map { " on \($0)" } ?? "")",
                             body: c.text, eventId: c.id))
        }

        if settings.actionEnabled("upload") {
            for c in r.changes where c.kind == "upload" {
                out.append(Alert(key: "upload:\(c.id)", title: "\(agent) uploaded a file", body: c.text, eventId: c.id))
            }
        }

        // 3. A route into the browser that hasn't been seen before.
        if let known = knownRoutes {
            for route in routes(in: events).subtracting(known).sorted() {
                out.append(Alert(key: "route:\(route)", title: "\(agent) reached the browser a new way",
                                 body: "First use of \(routeLabel(route)). Check that the record covers it."))
            }
        }
        if let name = r.unseenBrowser {
            out.append(Alert(key: "unseen", title: "\(agent) used a browser the recorder can't see",
                             body: "It used \(name). The record holds only what the agent reported."))
        }

        // 4. The recorder stopped or the record was changed while the session ran.
        for se in events where se.event.kind == EventKind.gap {
            guard let title = gapTitles[se.event.cat] else { continue }
            if se.event.cat == "gap.recorder_stopped", se.event.p?["reason"]?.stringValue == "quit" { continue }
            out.append(Alert(key: "gap:\(se.id)", title: title, body: EventFormatter.describe(se.event), eventId: se.id, notify: false))
        }
        // An agent working in its own app's browser never touched your Chrome: keep the alerts
        // in the record, but don't notify unless you asked for that.
        if !settings.inAppBrowserNotices {
            for i in out.indices where r.inAppBrowserOnly || out[i].key.hasPrefix("route:automation:mcp__Claude_Browser") {
                out[i].notify = false
            }
        }
        return out
    }

    /// Route plus the tool family, e.g. `automation:mcp__playwright`, `extension:mcp__claude-in-chrome`, `shell`.
    public static func routes(in events: [StoredEvent]) -> Set<String> {
        var out = Set<String>()
        for se in events where se.event.cat == "tool.pre" || se.event.cat == "tool.logged" {
            guard se.event.p?["browser"]?.boolValue == true, let route = se.event.p?["route"]?.stringValue, !route.isEmpty else { continue }
            let tool = se.event.p?["tool"]?.stringValue ?? ""
            if route == BrowserRoute.shell { out.insert(route); continue }
            let family = tool.range(of: "__", options: .backwards).map { String(tool[..<$0.lowerBound]) } ?? tool
            out.insert(route + ":" + family.replacingOccurrences(of: ",", with: "_"))
        }
        return out
    }

    static func routeLabel(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let family = parts.count > 1 ? " (\(parts[1]))" : ""
        switch parts[0] {
        case BrowserRoute.shell: return "shell commands that reach Chrome"
        case BrowserRoute.automation: return "a browser automation tool" + family
        case BrowserRoute.computerUse: return "screen control of Chrome" + family
        default: return "a browser extension tool" + family
        }
    }

    public static func raisedKeys(in events: [StoredEvent]) -> Set<String> {
        Set(events.filter { $0.event.cat == "alert.raised" }.compactMap { $0.event.p?["key"]?.stringValue })
    }

    /// Stores new alerts on the session and returns them. App only.
    public static func raise(store: LedgerStore, session id: String, settings: LedgerSettings, now: Double = nowMs()) throws -> [Alert] {
        let events = try store.events(forSession: id)
        guard let report = try SessionReport.build(store: store, session: id) else { return [] }
        var knownText = try store.meta("routes.seen")
        if try store.meta("routes.seeded") == nil {
            // Once: everything already in the ledger counts as known, so old habits don't raise alerts.
            var all = Set((knownText ?? "").split(separator: ",").map(String.init))
            for src in ["hook.claude", "hook.codex", "log.claude", "log.codex"] {
                all.formUnion(routes(in: try store.events(from: 0, to: now, src: src)))
            }
            let had = knownText != nil
            if had || !all.isEmpty { knownText = all.sorted().joined(separator: ","); try store.setMeta("routes.seen", knownText!) }
            try store.setMeta("routes.seeded", "1")
        }
        let known = knownText.map { Set($0.split(separator: ",").map(String.init)) }
        let used = routes(in: events)
        let raised = raisedKeys(in: events)
        let fresh = evaluate(report: report, events: events, settings: settings, knownRoutes: known).filter { !raised.contains($0.key) }
        for a in fresh {
            Correlator.recordSessionEvent(store: store, session: id, kind: EventKind.context, cat: "alert.raised",
                                          p: ["key": .string(a.key), "title": .string(a.title), "body": .string(a.body),
                                              "event": a.eventId.map { JSONValue.number(Double($0)) } ?? .null], at: now)
        }
        if !used.isSubset(of: known ?? []) {
            try store.setMeta("routes.seen", (known ?? []).union(used).sorted().joined(separator: ","))
        }
        return fresh
    }
}
