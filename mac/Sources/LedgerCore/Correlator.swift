import Foundation

/// Human-input context sampled by the app (no keystroke contents, only times).
public enum HumanInputKind: String, Sendable { case mouseDown, keyDown }

/// One hook arrival, without inputs or results.
public struct HookSummary: Sendable, Equatable, Codable {
    public var t: Double
    public var agent: String
    public var cat: String
    public var tool: String?
    public var browser: Bool
    public var tabIds: Int
    public var inputKeys: [String]
}

/// Live view of a session for the menu bar.
public struct LiveSessionInfo: Sendable, Identifiable, Equatable {
    public var id: String
    public var agent: String
    public var state: String
    public var attribution: String
    public var tabs: [Int]
    public var startedAt: Double
    public var lastActivityAt: Double
    public var label: String?
    public var coverage: String
}

public struct LiveStatus: Sendable, Equatable {
    public var sessions: [LiveSessionInfo] = []
    public var helpers: [String: Int] = [:]
    public var extensionConnected = false
    public var lastExtensionEventAt: Double?
    public var lastHookAt: [String: Double] = [:]
    public var memoryEvents = 0
    public var paused = false
    public var humanInputSensorOK = true
    /// Recent hook arrivals (metadata only) for diagnosing agent integrations.
    public var recentHooks: [HookSummary] = []
    /// Chrome profiles with the extension connected (one service worker per profile).
    public var chromeInstalls = 0
    /// False when a connected profile doesn't allow the extension in incognito windows.
    public var incognitoCovered: Bool?
    /// Remote debugging on your everyday Chrome ("port 9222"), nil when off or unknown.
    public var remoteDebugging: String?
    /// Chrome processes agents started themselves, described for the menu.
    public var agentBrowsers: [String] = []
    public init() {}
}

/// Correlates sensor events into sessions, tab bindings and actor attributions.
///
/// Not thread-safe: the app calls it from one serial queue. Time is passed in explicitly so
/// the rules can be tested with recorded fixtures.
public final class Correlator {
    public static let detectorVersion = "0.1.0"

    public struct Config {
        public var tabFlushMs: Double = 120_000
        public var settleMs: Double = 90_000
        public var endAfterInactiveMs: Double = 10 * 60_000
        public var possibleTimeoutMs: Double = 60_000
        public var humanWindowBeforeMs: Double = 1500
        public var humanWindowAfterMs: Double = 400
        public var hookSlackBeforeMs: Double = 500
        public var hookSlackAfterMs: Double = 2000
        public var hookOpenMaxMs: Double = 60_000
        public var extensionSilentMs: Double = 80_000
        public var attributionDelayMs: Double = 2500
        public init() {}
    }

    // MARK: State types

    struct TabState {
        var url: String?
        var title: String?
        var groupId: Int?
        var windowId: Int?
        var debuggerAttached = false
        var debuggerChangedAt: Double = 0
        var peer: Int?
        var session: String?
    }

    struct ToolCall {
        var agent: HookAgent
        var runtimeKey: String
        var toolUseId: String
        var tool: String
        var tabs: [Int]
        var startedAt: Double
        var endedAt: Double?
        var route = BrowserRoute.extensionRoute
        var routeText = ""
        /// Tabs bound because of this call (a tab it opened), which it explains best.
        var boundTabs: [Int] = []
    }

    struct Runtime {
        var agent: HookAgent
        var session: String
        var lastActivityAt: Double
        var lastBrowserAt: Double?
        var pendingPrompt: LedgerEvent?
        var ledgerSession: String?
        var pendingTabCreateAt: Double?
        var pendingTabReason: String?
        var pendingTabCall: String?
        /// Agent process IDs seen in this runtime's hooks (to link browsers it starts).
        var pids: Set<Int32> = []
        /// Last call that may drive Chrome over the DevTools protocol (automation tools,
        /// remote debugging, launching Chrome).
        var lastAutomationAt: Double?
    }

    final class Live {
        var record: SessionRecord
        var tabs: Set<Int> = []
        var possibleSince: Double?
        var runtimeKey: String?
        var reasons: [String] = []
        var extensionSilentReported = false
        /// When the session last became inactive; only later activity reactivates it.
        var inactiveSince: Double?
        init(record: SessionRecord) { self.record = record }
    }

    struct MemEvent {
        var event: LedgerEvent
        var receivedAt: Double
    }

    // MARK: Properties

    public let store: LedgerStore
    public var config = Config()
    public var settings: LedgerSettings
    /// Sends a command to the extension (via the host connection that owns the tab, if known).
    public var sendCommand: (_ command: JSONValue, _ peer: Int?) -> Void = { _, _ in }

    private var memory: [MemEvent] = []
    private var tabs: [Int: TabState] = [:]
    private var groups: [Int: (title: String, agent: String?)] = [:]
    private var runtimes: [String: Runtime] = [:]
    private var toolCalls: [String: ToolCall] = [:]
    private var live: [String: Live] = [:]
    private var helpers: [String: Set<Int32>] = [:]
    private var humanInputs: [(kind: HumanInputKind, t: Double)] = []
    private var frontmost: [(t: Double, bundleId: String)] = []
    /// Chrome window focus changes over time (attribution is decided after a delay, so it
    /// must look up focus at the event's time, not the current state).
    private var windowFocus: [(t: Double, focused: Bool)] = []
    private var lastExtensionEventAt: Double?
    private var lastHookAt: [String: Double] = [:]
    private var humanInputSensorOK = true
    private var recentHooks: [HookSummary] = []
    /// Most recent attributed action per tab, used to credit its effects.
    private var lastAction: [Int: (t: Double, actor: String, what: String, display: String)] = [:]
    private var pendingAttribution: [(id: Int64, event: LedgerEvent, tab: Int, session: String, due: Double)] = []
    /// Sessions that ended while attributions were pending.
    private var recentlyEnded: [String: Live] = [:]
    /// The most recently activated tab (AppleScript acts on the active tab).
    private var lastActiveTab: (tab: Int, t: Double)?
    /// Extension connections by peer: one per Chrome profile.
    private var installs: [Int: (installId: String, incognito: Bool?)] = [:]
    private var everydayRemoteDebugging: String?
    /// Agent-started browsers that are running, by PID.
    private var agentBrowsers: [Int32: (info: JSONValue, session: String?)] = [:]

    public init(store: LedgerStore, settings: LedgerSettings = LedgerSettings()) {
        self.store = store
        self.settings = settings
    }

    // MARK: Public API

    /// Called by the app's sensor sampler whenever it sees a new mouse-down or key-down time.
    public func noteHumanInput(_ kind: HumanInputKind, at t: Double) {
        humanInputs.append((kind, t))
        if humanInputs.count > 2000 { humanInputs.removeFirst(humanInputs.count - 2000) }
    }

    public func noteFrontmost(bundleId: String, at t: Double) {
        frontmost.append((t, bundleId))
        if frontmost.count > 500 { frontmost.removeFirst(frontmost.count - 500) }
    }

    public func noteHumanInputSensor(ok: Bool) { humanInputSensorOK = ok }

    public func status(now: Double) -> LiveStatus {
        var s = LiveStatus()
        s.sessions = live.values.map { l in
            LiveSessionInfo(id: l.record.id, agent: l.record.agent, state: l.record.state,
                            attribution: l.record.attribution, tabs: l.tabs.sorted(), startedAt: l.record.startedAt,
                            lastActivityAt: l.record.lastActivityAt, label: l.record.taskLabel,
                            coverage: l.record.coverage)
        }.sorted { $0.startedAt > $1.startedAt }
        s.helpers = helpers.mapValues { $0.count }
        s.lastExtensionEventAt = lastExtensionEventAt
        s.extensionConnected = lastExtensionEventAt.map { now - $0 < config.extensionSilentMs } ?? false
        s.lastHookAt = lastHookAt
        s.memoryEvents = memory.count
        s.paused = settings.isPaused(now: now)
        s.humanInputSensorOK = humanInputSensorOK
        s.recentHooks = recentHooks
        s.chromeInstalls = Set(installs.values.map { $0.installId }).count
        let flags = installs.values.compactMap { $0.incognito }
        s.incognitoCovered = flags.isEmpty ? nil : !flags.contains(false)
        s.remoteDebugging = everydayRemoteDebugging
        s.agentBrowsers = agentBrowsers.values.map { b in
            let p = b.info
            var bits = [Correlator.displayAgent(p["agent"]?.stringValue ?? "")]
            bits.append(p["app"]?.stringValue ?? "Chrome")
            if let r = p["remoteDebugging"]?.stringValue { bits.append("remote debugging \(r)") }
            if p["headless"]?.boolValue == true { bits.append("headless") }
            return bits.joined(separator: " · ")
        }.sorted()
        return s
    }

    /// Ingests a batch of events from one peer.
    public func ingest(_ events: [LedgerEvent], peer: Int? = nil, receivedAt: Double = nowMs()) {
        for e in events.sorted(by: { $0.t < $1.t }) {
            process(e, peer: peer, receivedAt: receivedAt)
        }
    }

    /// Periodic housekeeping: session timeouts, memory pruning, silence detection.
    public func tick(now: Double) {
        resolveAttributions(now: now, force: false)
        let horizon = now - Double(max(1, settings.prebufferMinutes)) * 60_000
        if let firstKeep = memory.firstIndex(where: { $0.event.t >= horizon }) {
            if firstKeep > 0 { memory.removeFirst(firstKeep) }
        } else {
            memory.removeAll()
        }
        if memory.count > 60_000 { memory.removeFirst(memory.count - 60_000) }
        toolCalls = toolCalls.filter { now - ($0.value.endedAt ?? $0.value.startedAt) < 10 * 60_000 }
        humanInputs.removeAll { now - $0.t > 10 * 60_000 }

        for l in Array(live.values) {
            switch l.record.state {
            case "possible":
                if let since = l.possibleSince, now - since > config.possibleTimeoutMs {
                    dropPossible(l, now: now, reason: "no corroborating agent evidence within \(Int(config.possibleTimeoutMs / 1000)) s")
                }
            case "recording":
                if now - l.record.lastActivityAt > config.settleMs { setState(l, "inactive", at: now) }
                if let last = lastExtensionEventAt, now - last > config.extensionSilentMs, !l.extensionSilentReported {
                    l.extensionSilentReported = true
                    persistApp(EventKind.gap, "gap.extension_silent",
                               p: ["since": .number(last), "seconds": .number((now - last) / 1000)],
                               link: [l], at: now)
                    l.record.coverage = "degraded"
                    save(l)
                }
            case "inactive":
                if now - l.record.lastActivityAt > config.endAfterInactiveMs { end(l, at: now, reason: "inactive timeout") }
            default: break
            }
        }
    }

    /// Writes attributions whose wait is over (or all of them when `force`).
    public func resolveAttributions(now: Double, force: Bool) {
        guard !pendingAttribution.isEmpty else { return }
        var ready: [(id: Int64, event: LedgerEvent, tab: Int, session: String, due: Double)] = []
        // An effect (request, toast, navigation) waits for any earlier action on the same tab
        // that is still waiting, so it can be credited to that action.
        let waitingActions = pendingAttribution.filter { $0.due > now && Self.actionCats.contains($0.event.cat) }
        pendingAttribution.removeAll { p in
            guard force || p.due <= now else { return false }
            if !force && Self.effectCats.contains(p.event.cat) &&
                waitingActions.contains(where: { $0.tab == p.tab && $0.event.t <= p.event.t + 50 }) { return false }
            ready.append(p)
            return true
        }
        ready.sort { $0.event.t < $1.event.t }
        var atts: [Attribution] = []
        for p in ready {
            guard let l = live[p.session] ?? recentlyEnded[p.session] else { continue }
            let a = attribute(p.event, tab: p.tab, session: l, eventId: p.id)
            atts.append(a)
            if a.actor.hasPrefix("agent:") || a.actor == "unknown", live[p.session] != nil { touch(l, at: p.event.t) }
        }
        try? store.addAttributions(atts)
        if pendingAttribution.isEmpty { recentlyEnded.removeAll() }
    }

    // MARK: Corrections

    public func stopRecording(session id: String, now: Double) {
        guard let l = live[id] else { return }
        try? store.addCorrection(session: id, eventId: nil, fromT: nil, toT: now, action: "stop-recording", note: nil)
        end(l, at: now, reason: "stopped by user")
    }

    public func excludeTab(session id: String, tab: Int, now: Double) {
        guard let l = live[id] else { return }
        try? store.addCorrection(session: id, eventId: nil, fromT: now, toT: nil, action: "exclude-tab", note: "tab \(tab)")
        unbind(l, tab: tab, at: now, reason: "excluded by user")
    }

    public func markThisWasMe(lastMinutes: Double, now: Double) {
        let from = now - lastMinutes * 60_000
        for l in live.values where l.record.state != "possible" {
            try? store.addCorrection(session: l.record.id, eventId: nil, fromT: from, toT: now, action: "this-was-me",
                                     note: "last \(Int(lastMinutes)) min")
        }
    }

    public func pauseChanged(now: Double) {
        guard settings.isPaused(now: now) else { return }
        for l in Array(live.values) { end(l, at: now, reason: "recording paused") }
    }

    // MARK: Event processing

    private func process(_ e: LedgerEvent, peer: Int?, receivedAt: Double) {
        if e.src.hasPrefix("ext.") { lastExtensionEventAt = max(lastExtensionEventAt ?? 0, e.t) }
        if e.cat == "health.heartbeat" { return }
        if e.cat == "health.extension_hello", let peer, let id = e.p?["installId"]?.stringValue {
            installs[peer] = (id, e.p?["incognitoAllowed"]?.boolValue)
        }

        if e.src.hasPrefix("hook.") {
            processHook(e, receivedAt: receivedAt)
            return
        }
        if e.src == "mac.sensor" {
            processSensor(e, receivedAt: receivedAt)
            return
        }

        updateTabState(e, peer: peer)

        // Gaps and health persist and link to affected sessions, except for a tab whose
        // session is still only "possible": nothing from an unconfirmed session goes to disk.
        if e.kind == EventKind.gap || e.kind == EventKind.sensorHealth {
            if let tab = e.tab, let sid = tabs[tab]?.session, live[sid]?.record.state == "possible" {
                remember(e, receivedAt: receivedAt)
                return
            }
            let affected: [Live]
            if let tab = e.tab, let sid = tabs[tab]?.session, let l = live[sid] { affected = [l] }
            else if e.kind == EventKind.gap { affected = live.values.filter { $0.record.state != "possible" } }
            else { affected = [] }
            if e.kind == EventKind.gap {
                for l in affected { l.record.coverage = "degraded"; save(l) }
            }
            persist(e, receivedAt: receivedAt, link: affected)
            return
        }

        detect(e)

        if let tab = e.tab, let sid = tabs[tab]?.session, let l = live[sid] {
            if let host = e.url.flatMap({ URL(string: $0)?.host }), settings.isExcluded(host: host) {
                if e.cat == "nav.committed" {
                    persistApp(EventKind.gap, "gap.excluded_site", p: ["tab": .number(Double(tab))], link: [l], at: e.t)
                }
                return
            }
            if l.record.state == "possible" {
                remember(e, receivedAt: receivedAt)
                if corroborates(e, l) { promote(l, at: e.t, reason: corroborationReason(e)) }
                return
            }
            let ids = persist(e, receivedAt: receivedAt, link: [l])
            if let id = ids.first, e.kind == EventKind.observedEffect {
                // Hooks can arrive slightly after the browser effects they caused, so attribution
                // waits briefly for runtime reports.
                pendingAttribution.append((id, e, tab, l.record.id, receivedAt + config.attributionDelayMs))
            }
        } else {
            remember(e, receivedAt: receivedAt)
        }
    }

    private func remember(_ e: LedgerEvent, receivedAt: Double) {
        memory.append(MemEvent(event: e, receivedAt: receivedAt))
    }

    private func updateTabState(_ e: LedgerEvent, peer: Int?) {
        guard let tab = e.tab ?? e.p?["tabId"]?.intValue else {
            if e.cat == "window.focus" {
                windowFocus.append((e.t, e.p?["chromeFocused"]?.boolValue ?? true))
                if windowFocus.count > 500 { windowFocus.removeFirst(windowFocus.count - 500) }
            }
            if e.cat.hasPrefix("group.") { updateGroup(e) }
            return
        }
        var s = tabs[tab] ?? TabState()
        if let peer, e.src.hasPrefix("ext.") { s.peer = peer }
        if let w = e.win { s.windowId = w }
        switch e.cat {
        case "tab.snapshot", "tab.created", "tab.updated":
            if let u = e.url { s.url = u }
            if let t = e.p?["title"]?.stringValue { s.title = t }
            if let g = e.p?["groupId"]?.intValue { s.groupId = g >= 0 ? g : nil }
        case "nav.committed", "nav.history":
            if e.frame == 0 || e.frame == nil, let u = e.url { s.url = u }
        case "debugger.attached": s.debuggerAttached = true; s.debuggerChangedAt = e.t
        case "debugger.detached": s.debuggerAttached = false; s.debuggerChangedAt = e.t
        case "tab.activated": lastActiveTab = (tab, e.t)
        default: break
        }
        tabs[tab] = s
        if e.cat == "tab.removed" {
            if let sid = s.session, let l = live[sid] { unbind(l, tab: tab, at: e.t, reason: "tab closed") }
            tabs[tab] = nil
        }
        if e.cat == "tab.replaced", let old = e.p?["replaced"]?.intValue, let prev = tabs[old] {
            tabs[tab] = prev
            tabs[old] = nil
            if let sid = prev.session, let l = live[sid] { l.tabs.remove(old); l.tabs.insert(tab) }
        }
    }

    private func updateGroup(_ e: LedgerEvent) {
        guard let gid = e.p?["groupId"]?.intValue else { return }
        if e.cat == "group.removed" { groups[gid] = nil; return }
        let title = e.p?["title"]?.stringValue ?? ""
        var agent = groups[gid]?.agent
        if agent == nil, Self.startsWithEmoji(title), recentBrowserRuntime(.codex, within: 120_000, now: e.t) != nil {
            agent = HookAgent.codex.agentName
        }
        groups[gid] = (title, agent)
    }

    static func startsWithEmoji(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && first.value > 0x2100)
    }

    // MARK: Hooks

    private func runtimeKey(_ agent: HookAgent, _ session: String) -> String { "\(agent.rawValue):\(session)" }

    private func processHook(_ event: LedgerEvent, receivedAt: Double) {
        var e = event
        let agent: HookAgent = e.src == "hook.codex" ? .codex : .claude
        lastHookAt[agent.agentName] = e.t
        recentHooks.append(HookSummary(t: e.t, agent: agent.agentName, cat: e.cat, tool: e.p?["tool"]?.stringValue,
                                       browser: e.p?["browser"]?.boolValue ?? false,
                                       tabIds: e.p?["tabIds"]?.arrayValue?.count ?? 0,
                                       inputKeys: (e.p?["inputKeys"]?.arrayValue ?? []).compactMap { $0.stringValue }))
        if recentHooks.count > 100 { recentHooks.removeFirst(recentHooks.count - 100) }
        guard let session = e.p?["session"]?.stringValue else { return }
        let key = runtimeKey(agent, session)
        var rt = runtimes[key] ?? Runtime(agent: agent, session: session, lastActivityAt: e.t)
        rt.lastActivityAt = max(rt.lastActivityAt, e.t)
        for k in ["agentPid", "ppid"] { if let pid = e.p?[k]?.intValue, pid > 1 { rt.pids.insert(Int32(pid)) } }
        var browser = e.p?["browser"]?.boolValue ?? false
        let route = e.p?["route"]?.stringValue ?? BrowserRoute.extensionRoute
        if !browser, route == BrowserRoute.computerUse, e.p?["chromeTarget"] == .null, chromeWasFrontmost(at: e.t),
           case .object(var o) = e.p {
            // Whole-screen computer use while Chrome was in front acts on Chrome.
            browser = true
            o["browser"] = true
            o["chromeBy"] = "Chrome was the frontmost app"
            e.p = .object(o)
        }
        let kinds = e.p?["routeKinds"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let flags = e.p?["flags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        var tabIds = e.p?["tabIds"]?.arrayValue?.compactMap { $0.intValue } ?? []
        if agent == .codex, browser, let code = e.p?["input"]?["code"]?.stringValue {
            // Codex names Chrome tab IDs in its code (cua.getTab("1511630265")); trust only IDs
            // of tabs this browser actually has.
            for id in Self.codexTabIds(in: code) where tabs[id] != nil && !tabIds.contains(id) { tabIds.append(id) }
        }

        switch e.cat {
        case "turn.prompt":
            rt.pendingPrompt = e
            runtimes[key] = rt
            if let sid = rt.ledgerSession, let l = live[sid], l.record.state != "ended" {
                persist(e, receivedAt: receivedAt, link: [l])
                // Keep the task the session started with; a later short reply ("yes") must not
                // replace it. Only fill a missing label or upgrade a very short one.
                if settings.promptLabels, l.record.labelSource != "user", let prompt = e.p?["prompt"]?.stringValue,
                   Self.betterLabel(prompt, than: l.record.taskLabel) {
                    l.record.taskLabel = prompt
                    l.record.labelSource = "agent-prompt"
                    save(l)
                }
            }
            return
        case "tool.pre", "tool.post", "tool.failure":
            guard browser else { runtimes[key] = rt; touchRuntimeSession(rt, at: e.t); return }
            rt.lastBrowserAt = e.t
            let callId = e.p?["toolUseId"]?.stringValue ?? "\(key)-\(e.t)"
            let tool = e.p?["tool"]?.stringValue ?? "?"
            let routeText = Self.routeText(route: route, tool: tool, kinds: kinds, input: e.p?["input"])
            if route == BrowserRoute.automation || !Set(kinds).isDisjoint(with: ["remote-debugging", "automation-tool", "launch-chrome"]) {
                rt.lastAutomationAt = e.t
            }
            if e.cat == "tool.pre" {
                if agent == .codex {
                    // Codex runs its browser calls one at a time, so a new call ends any earlier one
                    // whose PostToolUse never arrived (failed calls may not report one).
                    for (id, c) in toolCalls where c.runtimeKey == key && c.endedAt == nil && id != callId {
                        toolCalls[id]?.endedAt = e.t
                    }
                }
                toolCalls[callId] = ToolCall(agent: agent, runtimeKey: key, toolUseId: callId, tool: tool, tabs: tabIds,
                                             startedAt: e.t, route: route, routeText: routeText)
                if tool.hasSuffix("tabs_create_mcp") || tool.contains("new_tab") {
                    rt.pendingTabCreateAt = e.t; rt.pendingTabReason = nil; rt.pendingTabCall = callId
                }
                if route == BrowserRoute.shell, kinds.contains("open-url") || kinds.contains("applescript") ||
                    (kinds.contains("launch-chrome") && !flags.contains("user-data-dir")) {
                    rt.pendingTabCreateAt = e.t
                    rt.pendingTabCall = callId
                    rt.pendingTabReason = "created right after \(agent == .claude ? "Claude Code" : "Codex") ran a \(routeText)"
                }
            } else if var call = toolCalls[callId] {
                call.endedAt = e.t
                if call.tabs.isEmpty { call.tabs = tabIds }
                toolCalls[callId] = call
            } else {
                toolCalls[callId] = ToolCall(agent: agent, runtimeKey: key, toolUseId: callId, tool: tool, tabs: tabIds,
                                             startedAt: e.t - 1000, endedAt: e.t, route: route, routeText: routeText)
            }
            runtimes[key] = rt
            guard !settings.isPaused(now: e.t) else { decision("paused", reasons: ["recording paused"], tab: tabIds.first, at: e.t); return }
            let l = ensureSession(for: key, at: e.t, reason: "\(agent == .claude ? "Claude Code" : "Codex") \(routeText)")
            rt = runtimes[key]!
            for tab in tabIds {
                bind(l, tab: tab, at: e.t, evidence: "\(Self.shortTool(tool)) named tab \(tab) (runtime-reported)")
                if agent == .claude, let g = tabs[tab]?.groupId { groups[g] = (groups[g]?.title ?? "", agent.agentName) }
            }
            let viaDevTools = route == BrowserRoute.automation || kinds.contains("remote-debugging") || kinds.contains("automation-tool")
            if (agent == .codex || viaDevTools) && tabIds.isEmpty {
                // Codex hooks and DevTools-protocol tools don't name tabs: bind tabs whose debugger
                // attached around this call.
                let what = agent == .codex && route == BrowserRoute.extensionRoute ? "Codex browser call" : "\(Self.displayAgent(agent.agentName)) \(routeText)"
                for (tab, s) in tabs where s.debuggerAttached && abs(s.debuggerChangedAt - e.t) < 5000 && claimable(s, by: l) {
                    bind(l, tab: tab, at: e.t, evidence: "debugger attached within 5 s of a \(what)")
                }
            }
            if route == BrowserRoute.shell, kinds.contains("applescript"), let a = lastActiveTab, let s = tabs[a.tab], claimable(s, by: l) {
                bind(l, tab: a.tab, at: e.t, evidence: "AppleScript sent to Chrome while tab \(a.tab) was the active tab (likely its target)")
            }
            if agent == .codex && route == BrowserRoute.extensionRoute && tabIds.isEmpty {
                // Codex claims existing tabs by URL (cua.getTab({url}), claimTab): bind open tabs
                // whose URL appears in the call's code.
                if let code = e.p?["input"]?["code"]?.stringValue {
                    for url in Self.urls(in: code) {
                        for (tab, s) in tabs where s.session != l.record.id {
                            if let u = s.url, Self.sameURL(u, url) {
                                bind(l, tab: tab, at: e.t, evidence: "Codex claimed the open tab at \(url) (URL in its browser call)")
                            }
                        }
                    }
                }
            }
            persist(e, receivedAt: receivedAt, link: [l])
            touch(l, at: e.t)
            if l.record.state == "inactive" { setState(l, "recording", at: e.t) }
        case "turn.stop", "turn.interrupt":
            runtimes[key] = rt
            if let sid = rt.ledgerSession, let l = live[sid] {
                persist(e, receivedAt: receivedAt, link: [l])
                if l.record.state == "recording" { setState(l, "inactive", at: e.t) }
            }
        case "session.end":
            runtimes[key] = rt
            if let sid = rt.ledgerSession, let l = live[sid] {
                persist(e, receivedAt: receivedAt, link: [l])
                end(l, at: e.t, reason: "agent session ended")
            }
            runtimes[key] = nil
        default:
            runtimes[key] = rt
            if let sid = rt.ledgerSession, let l = live[sid] { persist(e, receivedAt: receivedAt, link: [l]) }
        }
    }

    /// A tab a new agent call may take over: unbound, or bound to another session that is no
    /// longer actively recording (an earlier conversation that went idle on the same tab).
    private func claimable(_ s: TabState, by l: Live) -> Bool {
        guard let sid = s.session else { return true }
        return sid != l.record.id && live[sid]?.record.state != "recording"
    }

    private func touchRuntimeSession(_ rt: Runtime, at t: Double) {
        if let sid = rt.ledgerSession, let l = live[sid], l.record.state != "possible" { touch(l, at: t) }
    }

    static let urlPattern = try! NSRegularExpression(pattern: "https?://[^\\s\"'`)<>]+")
    static let codexTabPattern = try! NSRegularExpression(
        pattern: "(?:getTab|claimTab)\\(\\s*(?:\\{\\s*(?:id|tabId)\\s*:\\s*)?[\"'`]?(\\d{3,12})\\b")

    /// Chrome tab IDs that Codex's browser code names explicitly.
    static func codexTabIds(in code: String) -> [Int] {
        let ns = code as NSString
        return codexTabPattern.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }

    static func urls(in text: String) -> [String] {
        let ns = text as NSString
        return urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Compares a tab's (redacted) URL with a URL from agent input, ignoring a trailing slash.
    static func sameURL(_ tabURL: String, _ candidate: String) -> Bool {
        func norm(_ s: String) -> String { var x = s; while x.hasSuffix("/") { x.removeLast() }; return x }
        return norm(tabURL) == norm(Redactor.url(candidate))
    }

    static let minimumLabelLength = 20

    static func betterLabel(_ candidate: String, than current: String?) -> Bool {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        return current.count < minimumLabelLength && c.count >= minimumLabelLength
    }

    /// How a browser call reached Chrome, for reasons and the timeline.
    static func routeText(route: String, tool: String, kinds: [String], input: JSONValue?) -> String {
        switch route {
        case BrowserRoute.shell:
            let names = ["open-url": "opened a URL", "applescript": "AppleScript", "launch-chrome": "started Chrome",
                         "remote-debugging": "DevTools debugging port", "automation-tool": "automation tool",
                         "profile-data": "read Chrome profile files", "chrome-cli": "chrome-cli"]
            return "shell command that reaches Chrome (\(kinds.map { names[$0] ?? $0 }.joined(separator: ", ")))"
        case BrowserRoute.automation: return "browser automation tool \(shortTool(tool))"
        case BrowserRoute.computerUse:
            return "computer use on Chrome (\(input?["action"]?.stringValue ?? shortTool(tool)))"
        default: return "browser tool \(shortTool(tool))"
        }
    }

    static func shortTool(_ name: String) -> String {
        if let r = name.range(of: "__", options: .backwards) { return String(name[r.upperBound...]) }
        return name
    }

    private func recentBrowserRuntime(_ agent: HookAgent, within ms: Double, now: Double) -> Runtime? {
        runtimes.values.filter { $0.agent == agent && ($0.lastBrowserAt.map { now - $0 < ms } ?? false) }
            .max { ($0.lastBrowserAt ?? 0) < ($1.lastBrowserAt ?? 0) }
    }

    private func ensureSession(for key: String, at t: Double, reason: String) -> Live {
        var rt = runtimes[key]!
        if let sid = rt.ledgerSession, let l = live[sid], l.record.state != "ended" { return l }
        let rec = SessionRecord(id: Self.newSessionId(at: t), agent: rt.agent.agentName, runtimeSession: rt.session,
                                state: "recording", startedAt: t, lastActivityAt: t, startReason: reason,
                                attribution: "identified", detectorVersion: Self.detectorVersion)
        let l = Live(record: rec)
        l.runtimeKey = key
        if settings.promptLabels, let prompt = rt.pendingPrompt?.p?["prompt"]?.stringValue {
            l.record.taskLabel = prompt
            l.record.labelSource = "agent-prompt"
        }
        live[rec.id] = l
        rt.ledgerSession = rec.id
        runtimes[key] = rt
        save(l)
        if let prompt = rt.pendingPrompt, settings.promptLabels { persist(prompt, receivedAt: t, link: [l]) }
        persistApp(EventKind.context, "session.started",
                   p: ["agent": .string(rec.agent), "runtimeSession": .string(rt.session), "reason": .string(reason),
                       "attribution": "identified"],
                   link: [l], at: t)
        return l
    }

    // MARK: Mac sensors

    private func processSensor(_ e: LedgerEvent, receivedAt: Double) {
        switch e.cat {
        case "helper.started", "helper.stopped":
            guard let agent = e.p?["agent"]?.stringValue, let pid = e.p?["pid"]?.intValue else { return }
            var set = helpers[agent] ?? []
            if e.cat == "helper.started" { set.insert(Int32(pid)) } else { set.remove(Int32(pid)) }
            helpers[agent] = set
            let affected = live.values.filter { $0.record.agent == agent && $0.record.state != "possible" }
            persist(e, receivedAt: receivedAt, link: Array(affected))
        case "browser.started":
            processBrowserStarted(e, receivedAt: receivedAt)
        case "browser.stopped":
            guard let pid = e.p?["pid"]?.intValue else { return }
            let b = agentBrowsers.removeValue(forKey: Int32(pid))
            let l = b?.session.flatMap { live[$0] }
            persist(e, receivedAt: receivedAt, link: l.map { [$0] } ?? [])
        case "browser.remote_debugging":
            everydayRemoteDebugging = e.p?["enabled"]?.boolValue == true ? (e.p?["detail"]?.stringValue ?? "on") : nil
            persist(e, receivedAt: receivedAt, link: live.values.filter { $0.record.state != "possible" })
        default:
            persist(e, receivedAt: receivedAt, link: [])
        }
    }

    /// A Chrome-family browser started outside your normal Chrome: by an agent, for
    /// automation, or with remote debugging. Agent-started browsers join (or start) that
    /// agent's session.
    private func processBrowserStarted(_ e: LedgerEvent, receivedAt: Double) {
        guard let pid = e.p?["pid"]?.intValue else { return }
        let app = e.p?["app"]?.stringValue ?? "Chrome"
        var detail: [String] = []
        if let rd = e.p?["remoteDebugging"]?.stringValue { detail.append("remote debugging \(rd)") }
        if e.p?["headless"]?.boolValue == true { detail.append("headless") }
        if e.p?["automation"]?.boolValue == true { detail.append("automation") }
        if let dir = e.p?["userDataDir"]?.stringValue { detail.append("profile \(dir)") }
        let suffix = detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"

        var linked: [Live] = []
        if let agent = e.p?["agent"]?.stringValue {
            let reason = "\(Self.displayAgent(agent)) started a separate \(app)\(suffix)"
            // Match the nearest agent process only: agents run inside other agents (Codex started
            // from a Claude Code shell), and the outer one didn't start this browser.
            let agentPid = e.p?["agentPid"]?.intValue.map { Int32($0) }
            let byPid = agentPid.flatMap { pid in
                runtimes.first { $0.value.agent.agentName == agent && $0.value.pids.contains(pid) }?.key
            }
            let byRecency = runtimes.filter { $0.value.agent.agentName == agent && e.t - $0.value.lastActivityAt < 10 * 60_000 }
                .max { $0.value.lastActivityAt < $1.value.lastActivityAt }?.key
            if !settings.isPaused(now: e.t) {
                if let key = byPid ?? byRecency, runtimes[key] != nil {
                    runtimes[key]?.lastAutomationAt = e.t
                    linked = [ensureSession(for: key, at: e.t, reason: reason)]
                } else {
                    linked = [ensureAgentSession(agent: agent, at: e.t, reason: reason)]
                }
                for l in linked { touch(l, at: e.t) }
            }
        } else if e.p?["everyday"]?.boolValue == true, let rd = e.p?["remoteDebugging"]?.stringValue {
            everydayRemoteDebugging = rd
        }
        if e.p?["everyday"]?.boolValue != true || e.p?["agent"] != nil {
            agentBrowsers[Int32(pid)] = (e.p ?? .null, linked.first?.record.id)
        }
        persist(e, receivedAt: receivedAt, link: linked)
    }

    /// The agent's most recent live session, or a new one when there is no runtime report to
    /// key it by (hooks not installed, or the browser was started outside a hooked call).
    private func ensureAgentSession(agent: String, at t: Double, reason: String) -> Live {
        if let l = live.values.filter({ $0.record.agent == agent && $0.record.state != "ended" && $0.record.state != "possible" })
            .max(by: { $0.record.lastActivityAt < $1.record.lastActivityAt }) { return l }
        let rec = SessionRecord(id: Self.newSessionId(at: t), agent: agent, runtimeSession: nil, state: "recording",
                                startedAt: t, lastActivityAt: t, startReason: reason, attribution: "likely",
                                detectorVersion: Self.detectorVersion)
        let l = Live(record: rec)
        live[rec.id] = l
        save(l)
        persistApp(EventKind.context, "session.started",
                   p: ["agent": .string(agent), "reason": .string(reason), "attribution": "likely"], link: [l], at: t)
        return l
    }

    /// Forgets a Chrome profile's extension connection when its host disconnects.
    public func peerDisconnected(_ peer: Int) { installs[peer] = nil }

    // MARK: Passive detection

    private func claudeCallCovers(tab: Int, at t: Double) -> ToolCall? {
        toolCalls.values.first { c in
            c.agent == .claude && c.tabs.contains(tab) && t >= c.startedAt - config.hookSlackBeforeMs &&
                t <= (c.endedAt ?? (c.startedAt + config.hookOpenMaxMs)) + config.hookSlackAfterMs
        }
    }

    private func detect(_ e: LedgerEvent) {
        guard let tab = e.tab else { return }
        let state = tabs[tab]

        // A tab created right after an agent asked for a new tab belongs to that agent.
        if e.cat == "tab.created" {
            for (key, rt) in runtimes {
                if let at = rt.pendingTabCreateAt, e.t - at >= -500, e.t - at < 5000, let sid = rt.ledgerSession, let l = live[sid] {
                    bind(l, tab: tab, at: e.t, evidence: rt.pendingTabReason ??
                        "created right after \(rt.agent == .claude ? "Claude Code" : "Codex") asked for a new tab")
                    if let id = rt.pendingTabCall { toolCalls[id]?.boundTabs.append(tab) }
                    var r = rt; r.pendingTabCreateAt = nil; r.pendingTabReason = nil; r.pendingTabCall = nil; runtimes[key] = r
                    return
                }
            }
        }

        // Joining a known agent's tab group.
        if e.cat == "tab.updated", let g = state?.groupId, state?.session == nil, let agent = groups[g]?.agent {
            if let l = live.values.filter({ $0.record.agent == agent && $0.record.state != "ended" })
                .max(by: { $0.record.lastActivityAt < $1.record.lastActivityAt }) {
                bind(l, tab: tab, at: e.t, evidence: "joined \(agent) tab group \"\(groups[g]?.title ?? "")\"")
                return
            }
        }

        guard e.cat == "debugger.attached", state?.session == nil else { return }
        if settings.isPaused(now: e.t) { return }
        if claudeCallCovers(tab: tab, at: e.t) != nil { return }

        if let rt = recentBrowserRuntime(.codex, within: 10_000, now: e.t), let sid = rt.ledgerSession, let l = live[sid] {
            bind(l, tab: tab, at: e.t, evidence: "debugger attached during Codex browser activity")
            return
        }
        // A DevTools-protocol route (automation tool, debugging port) used just before.
        if let rt = runtimes.values.filter({ r in r.lastAutomationAt.map { e.t - $0 > -1000 && e.t - $0 < 10_000 } ?? false })
            .max(by: { ($0.lastAutomationAt ?? 0) < ($1.lastAutomationAt ?? 0) }),
           let sid = rt.ledgerSession, let l = live[sid] {
            bind(l, tab: tab, at: e.t, evidence: "debugger attached right after \(Self.displayAgent(rt.agent.agentName)) used a DevTools-protocol route")
            return
        }

        let alive = helpers.filter { !$0.value.isEmpty }.map { $0.key }.sorted()
        guard !alive.isEmpty else {
            var reasons = ["debugger attached to tab \(tab) but no agent browser helper is connected (DevTools or other tooling?)"]
            if let rd = everydayRemoteDebugging {
                reasons.append("remote debugging is on for this Chrome (\(rd)), so an outside DevTools client may be connected")
            }
            decision("not-started", reasons: reasons, tab: tab, at: e.t)
            return
        }
        // Claude Code reports its browser calls through hooks when installed; an attachment it
        // did not report is more likely someone else's.
        var candidates = alive
        if candidates.count > 1, let last = lastHookAt[HookAgent.claude.agentName], e.t - last < 6 * 3600_000 {
            candidates.removeAll { $0 == HookAgent.claude.agentName }
        }
        let agent = candidates.count == 1 ? candidates[0] : "unknown"
        let reason = "debugger attached to tab \(tab) while \(alive.joined(separator: " and ")) helper connected"
        let rec = SessionRecord(id: Self.newSessionId(at: e.t), agent: agent, runtimeSession: nil, state: "possible",
                                startedAt: e.t, lastActivityAt: e.t, startReason: reason,
                                attribution: agent == "unknown" ? "unknown" : "likely",
                                detectorVersion: Self.detectorVersion)
        let l = Live(record: rec)
        l.possibleSince = e.t
        l.reasons = [reason]
        live[rec.id] = l
        bind(l, tab: tab, at: e.t, evidence: reason)
    }

    private func humanEvidence(_ e: LedgerEvent) -> String? {
        let focused = e.p?["focus"]?.boolValue ?? false
        if e.src == "ext.content" && !focused { return nil }
        if e.p?["trusted"]?.boolValue == false { return nil }
        guard chromeWasFrontmost(at: e.t) else { return nil }
        let kinds: [HumanInputKind]
        switch e.cat {
        case "ui.click", "ui.focus": kinds = [.mouseDown]
        case "field.input", "field.change", "ui.key", "ui.paste", "edit.change": kinds = [.keyDown, .mouseDown]
        case "form.submit": kinds = [.keyDown, .mouseDown]
        case "nav.committed", "nav.history": kinds = [.keyDown, .mouseDown]
        case "ui.scroll": return nil
        default: return nil
        }
        let before = config.humanWindowBeforeMs * (e.cat == "field.input" ? 2 : 1)
        // The input itself must land while Chrome is in front: typing in another app just before
        // an agent brings Chrome forward (`open <url>`) isn't input to Chrome.
        if let hit = humanInputs.last(where: { kinds.contains($0.kind) && $0.t >= e.t - before && $0.t <= e.t + config.humanWindowAfterMs &&
            chromeWasFrontmost(at: $0.t, slack: 0) }) {
            return "physical \(hit.kind == .mouseDown ? "mouse click" : "key press") \(Int(abs(e.t - hit.t))) ms from the event while Chrome was frontmost"
        }
        return nil
    }

    private func chromeWasFrontmost(at t: Double, slack: Double = 200) -> Bool {
        let windowFocused = windowFocus.last(where: { $0.t <= t + slack })?.focused ?? true
        guard let last = frontmost.last(where: { $0.t <= t + slack }) else { return windowFocused }
        return last.bundleId.hasPrefix("com.google.Chrome") && windowFocused
    }

    private func corroborates(_ e: LedgerEvent, _ l: Live) -> Bool {
        let interactive = ["ui.click", "field.input", "field.change", "form.submit", "ui.key", "edit.change", "nav.committed"]
        guard interactive.contains(e.cat) else { return false }
        if e.p?["trusted"]?.boolValue == false { return false }
        if e.cat == "nav.committed" {
            let quals = e.p?["qualifiers"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            if quals.contains("client_redirect") || quals.contains("server_redirect") { return false }
            if e.p?["transition"]?.stringValue == "auto_subframe" || e.frame != 0 { return false }
        }
        guard let tab = e.tab, tabs[tab]?.debuggerAttached == true else { return false }
        return humanEvidence(e) == nil
    }

    private func corroborationReason(_ e: LedgerEvent) -> String {
        "\(e.cat) on a debugger-attached tab with no physical input from you"
    }

    private func promote(_ l: Live, at t: Double, reason: String) {
        l.reasons.append(reason)
        l.record.state = "recording"
        l.record.startReason = l.reasons.joined(separator: "; ")
        l.record.lastActivityAt = t
        let since = (l.possibleSince ?? t) - config.tabFlushMs
        l.possibleSince = nil
        save(l)
        persistApp(EventKind.context, "session.started",
                   p: ["agent": .string(l.record.agent), "reason": .string(l.record.startReason),
                       "attribution": .string(l.record.attribution)], link: [l], at: t)
        flushMemory(for: l, since: since)
        for tab in l.tabs {
            try? store.bindTab(session: l.record.id, tab: tab, at: t, evidence: l.reasons.first ?? reason)
        }
        decision("started", reasons: l.reasons, tab: l.tabs.first, at: t)
    }

    private func dropPossible(_ l: Live, now: Double, reason: String) {
        decision("not-started", reasons: l.reasons + [reason], tab: l.tabs.first, at: now)
        for tab in l.tabs {
            sendCommand(["type": "disarm", "tab": .number(Double(tab)), "session": .string(l.record.id)], tabs[tab]?.peer)
            tabs[tab]?.session = nil
        }
        live[l.record.id] = nil
    }

    private func flushMemory(for l: Live, since: Double) {
        var flushed: [MemEvent] = []
        memory.removeAll { m in
            guard let tab = m.event.tab, l.tabs.contains(tab), m.event.t >= since else { return false }
            flushed.append(m)
            return true
        }
        guard !flushed.isEmpty else { return }
        let events = flushed.map { m -> LedgerEvent in var e = m.event; e.pre = e.pre ?? true; return e }
        let ids = (try? store.append(events)) ?? []
        try? store.link(session: l.record.id, eventIds: ids)
        var atts: [Attribution] = []
        for (i, e) in events.enumerated() where i < ids.count && (e.kind == EventKind.observedEffect) {
            if let tab = e.tab { atts.append(attribute(e, tab: tab, session: l, eventId: ids[i])) }
        }
        try? store.addAttributions(atts)
    }

    // MARK: Attribution

    func attribute(_ e: LedgerEvent, tab: Int, session l: Live, eventId: Int64) -> Attribution {
        var reasons: [String] = []
        var agentActor: String?
        var agentLabel = "likely"
        var scope = "inference"

        if let call = claudeCallCovers(tab: tab, at: e.t) {
            agentActor = "agent:\(HookAgent.claude.agentName)"
            agentLabel = "identified"
            scope = "operation"
            reasons.append("Claude Code reported \(Self.shortTool(call.tool)) on tab \(tab) (call \(call.toolUseId.suffix(8)))")
        } else if let call = toolCalls.values.filter({ c in
                      c.runtimeKey == l.runtimeKey && (c.agent == .codex || c.route != BrowserRoute.extensionRoute) &&
                          e.t >= c.startedAt - config.hookSlackBeforeMs &&
                          e.t <= (c.endedAt ?? (c.startedAt + config.hookOpenMaxMs)) + config.hookSlackAfterMs
                  }).max(by: { a, b in
                      let ka = (a.boundTabs.contains(tab) || a.tabs.contains(tab) ? 1 : 0, a.startedAt <= e.t ? a.startedAt : -a.startedAt)
                      let kb = (b.boundTabs.contains(tab) || b.tabs.contains(tab) ? 1 : 0, b.startedAt <= e.t ? b.startedAt : -b.startedAt)
                      return ka < kb
                  }) {
            // Calls that don't name tabs (Codex, shell commands, automation tools) cover the
            // session's tabs for their duration.
            agentActor = "agent:\(call.agent.agentName)"
            agentLabel = call.tabs.contains(tab) ? "identified" : "likely"
            scope = call.tabs.contains(tab) ? "operation" : "runtime-session"
            if call.agent == .codex && call.route == BrowserRoute.extensionRoute {
                reasons.append("Codex reported a browser call (\(Self.shortTool(call.tool))) in this session at the time")
            } else {
                reasons.append("\(Self.displayAgent(call.agent.agentName)) ran a \(call.routeText) in this session at the time")
            }
        } else if tabs[tab]?.debuggerAttached == true, l.record.agent != "unknown" {
            agentActor = "agent:\(l.record.agent)"
            agentLabel = "likely"
            reasons.append("tab \(tab) had a debugger attached while bound to this \(l.record.agent) session")
        }

        let human = humanEvidence(e)
        if let human { reasons.append(human) }
        if e.p?["trusted"]?.boolValue == false { reasons.append("event was synthesized by page script (isTrusted=false)") }

        let actor: String
        let label: String
        switch (agentActor, human) {
        case (let a?, nil):
            actor = a; label = agentLabel
        case (_?, _?):
            actor = "mixed"; label = "mixed"
        case (nil, _?):
            actor = "human"; label = "likely"; scope = "inference"
        case (nil, nil):
            if Self.effectCats.contains(e.cat), let cause = lastAction[tab], e.t - cause.t >= -100, e.t - cause.t <= 3000,
               cause.actor != "unknown" {
                actor = cause.actor; label = cause.actor == "mixed" ? "mixed" : "likely"
                reasons.append("follows \(cause.what) \(Int(max(0, e.t - cause.t))) ms earlier, attributed to \(cause.display); likely its result")
            } else if e.p?["trusted"]?.boolValue == false || e.cat == "dom.summary" {
                // Script-synthesized events, and DOM churn no action explains (a toast timing
                // out), come from the page itself.
                actor = "page"; label = "likely"
            } else {
                actor = "unknown"; label = "unknown"
                if reasons.isEmpty { reasons.append("no agent operation or physical input matched this event") }
            }
        }
        let result = Attribution(eventId: eventId, sessionId: l.record.id, actor: actor, label: label, scope: scope,
                                 reasons: reasons, detectorVersion: Self.detectorVersion, createdAt: nowMs())
        if Self.actionCats.contains(e.cat), actor != "unknown", actor != "page" {
            lastAction[tab] = (e.t, actor, e.cat, EventFormatter.actorLabel(result))
        }
        return result
    }

    static let actionCats: Set<String> = ["ui.click", "form.submit", "ui.key", "field.change", "field.input", "edit.change", "ui.paste"]
    static let effectCats: Set<String> = ["net.request", "page.alert", "nav.committed", "nav.history", "nav.error",
                                          "page.validation", "download.created", "dom.summary"]

    // MARK: Session helpers

    private func bind(_ l: Live, tab: Int, at t: Double, evidence: String) {
        if let other = tabs[tab]?.session, other != l.record.id, let o = live[other] {
            unbind(o, tab: tab, at: t, reason: "claimed by session \(l.record.id)")
            if o.record.state == "possible" && o.tabs.isEmpty {
                // A runtime report explained what passive detection saw.
                live[o.record.id] = nil
                decision("superseded", reasons: o.reasons + ["explained by \(Self.displayAgent(l.record.agent)) runtime report"],
                         tab: tab, at: t)
            }
        }
        var s = tabs[tab] ?? TabState()
        let isNew = s.session != l.record.id
        s.session = l.record.id
        tabs[tab] = s
        l.tabs.insert(tab)
        guard isNew else { return }
        if l.record.state != "possible" {
            try? store.bindTab(session: l.record.id, tab: tab, at: t, evidence: evidence)
            var bp: [String: JSONValue] = ["tab": .number(Double(tab)), "evidence": .string(evidence)]
            if let peer = s.peer, let inst = installs[peer] { bp["chromeInstall"] = .string(inst.installId) }
            persistApp(EventKind.context, "session.tab_bound", p: .object(bp), link: [l], at: t, tab: tab)
            flushMemory(for: l, since: t - config.tabFlushMs)
        }
        let policy: JSONValue = ["values": .bool(settings.valuesEnabled), "prebufferMs": 60_000, "maxValue": 2048]
        sendCommand(["type": "arm", "tab": .number(Double(tab)), "session": .string(l.record.id), "policy": policy,
                     "agent": .string(Self.displayAgent(l.record.agent))], s.peer)
    }

    private func unbind(_ l: Live, tab: Int, at t: Double, reason: String) {
        l.tabs.remove(tab)
        if tabs[tab]?.session == l.record.id { tabs[tab]?.session = nil }
        if l.record.state != "possible" {
            try? store.unbindTab(session: l.record.id, tab: tab, at: t)
            persistApp(EventKind.context, "session.tab_unbound", p: ["tab": .number(Double(tab)), "reason": .string(reason)],
                       link: [l], at: t, tab: tab)
        }
        sendCommand(["type": "disarm", "tab": .number(Double(tab)), "session": .string(l.record.id)], tabs[tab]?.peer)
    }

    private func setState(_ l: Live, _ state: String, at t: Double) {
        guard l.record.state != state else { return }
        l.record.state = state
        l.inactiveSince = state == "inactive" ? t : nil
        save(l)
        persistApp(EventKind.context, "session.\(state)", p: [:], link: [l], at: t)
    }

    private func end(_ l: Live, at t: Double, reason: String) {
        for tab in Array(l.tabs) {
            sendCommand(["type": "disarm", "tab": .number(Double(tab)), "session": .string(l.record.id)], tabs[tab]?.peer)
            if tabs[tab]?.session == l.record.id { tabs[tab]?.session = nil }
            if l.record.state != "possible" { try? store.unbindTab(session: l.record.id, tab: tab, at: t) }
        }
        if l.record.state == "possible" { live[l.record.id] = nil; return }
        l.record.state = "ended"
        l.record.endedAt = t
        save(l)
        persistApp(EventKind.context, "session.ended", p: ["reason": .string(reason)], link: [l], at: t)
        live[l.record.id] = nil
        recentlyEnded[l.record.id] = l
        if let key = l.runtimeKey, var rt = runtimes[key], rt.ledgerSession == l.record.id {
            rt.ledgerSession = nil
            runtimes[key] = rt
        }
    }

    private func touch(_ l: Live, at t: Double) {
        guard t > l.record.lastActivityAt else { return }
        l.record.lastActivityAt = t
        // Late-resolved effects from before the agent stopped must not reopen the session.
        if l.record.state == "inactive", t > (l.inactiveSince ?? 0) { setState(l, "recording", at: t) }
        else { save(l) }
    }

    private func save(_ l: Live) {
        guard l.record.state != "possible" else { return }
        try? store.upsertSession(l.record)
    }

    @discardableResult
    private func persist(_ e: LedgerEvent, receivedAt: Double, link: [Live]) -> [Int64] {
        let ids = (try? store.append([e], receivedAt: receivedAt)) ?? []
        for l in link where l.record.state != "possible" { try? store.link(session: l.record.id, eventIds: ids) }
        return ids
    }

    private var appSeq = 0
    private let appInst = "app-\(Int(nowMs()))"

    private func persistApp(_ kind: String, _ cat: String, p: JSONValue, link: [Live], at t: Double, tab: Int? = nil) {
        appSeq += 1
        let e = LedgerEvent(src: "app", inst: appInst, seq: appSeq, t: t, kind: kind, cat: cat, tab: tab, p: p)
        persist(e, receivedAt: nowMs(), link: link)
    }

    /// Detector decisions persist without URLs so false starts can be measured.
    private func decision(_ decision: String, reasons: [String], tab: Int?, at t: Double) {
        persistApp(EventKind.context, "detector.decision",
                   p: ["decision": .string(decision), "reasons": .array(reasons.map { .string($0) }),
                       "detector": .string(Self.detectorVersion)],
                   link: [], at: t, tab: tab)
    }

    static func newSessionId(at t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return "S-\(f.string(from: Date(timeIntervalSince1970: t / 1000)))-\(UUID().uuidString.prefix(4))"
    }

    public static func displayAgent(_ agent: String) -> String {
        switch agent {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return "Unknown agent"
        }
    }

    /// Resumes sessions that were live when the app last quit, so they can end cleanly.
    public func restoreLiveSessions(now: Double) {
        guard let sessions = try? store.sessions(limit: 50) else { return }
        for s in sessions where s.state == "recording" || s.state == "inactive" {
            var rec = s
            rec.coverage = "degraded"
            let l = Live(record: rec)
            if let tabsBound = try? store.sessionTabs(session: s.id) {
                for b in tabsBound where b.unboundAt == nil {
                    l.tabs.insert(b.tab)
                    var t = tabs[b.tab] ?? TabState()
                    t.session = s.id
                    tabs[b.tab] = t
                }
            }
            if let rs = s.runtimeSession {
                let agent: HookAgent = s.agent == "codex" ? .codex : .claude
                let key = runtimeKey(agent, rs)
                l.runtimeKey = key
                runtimes[key] = Runtime(agent: agent, session: rs, lastActivityAt: s.lastActivityAt, ledgerSession: s.id)
            }
            live[s.id] = l
            save(l)
            persistApp(EventKind.gap, "gap.app_restarted", p: ["lastActivityAt": .number(s.lastActivityAt)], link: [l], at: now)
        }
    }

    /// Re-sends arm commands for live sessions (after the extension reconnects).
    public func rearmAll() {
        for l in live.values {
            for tab in l.tabs {
                let policy: JSONValue = ["values": .bool(settings.valuesEnabled), "prebufferMs": 60_000, "maxValue": 2048]
                sendCommand(["type": "arm", "tab": .number(Double(tab)), "session": .string(l.record.id), "policy": policy,
                             "agent": .string(Self.displayAgent(l.record.agent))], tabs[tab]?.peer)
            }
        }
    }
}
