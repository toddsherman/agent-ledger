import XCTest
@testable import LedgerCore

final class CorrelatorTests: XCTestCase {
    var store: LedgerStore!
    var c: Correlator!
    var commands: [JSONValue] = []

    override func setUp() {
        store = try! LedgerStore(url: tempDir().appendingPathComponent("c.sqlite"))
        c = Correlator(store: store)
        commands = []
        c.sendCommand = { [unowned self] cmd, _ in self.commands.append(cmd) }
    }

    func hook(_ cat: String, t: Double, tool: String = "mcp__claude-in-chrome__computer", tab: Int? = 5,
              session: String = "sess-A", id: String = "toolu_1", agent: HookAgent = .claude, browser: Bool = true) -> LedgerEvent {
        var p: [String: JSONValue] = ["agent": .string(agent.agentName), "session": .string(session), "tool": .string(tool),
                                      "toolUseId": .string(id), "browser": .bool(browser)]
        if let tab { p["tabIds"] = [.number(Double(tab))] }
        let kind = cat == "tool.pre" ? EventKind.attemptedOp : EventKind.runtimeReport
        return LedgerEvent(src: agent.src, t: t, kind: kind, cat: cat, tab: tab, p: .object(p))
    }

    func content(_ cat: String, t: Double, tab: Int = 5, focus: Bool = false, trusted: Bool = true) -> LedgerEvent {
        LedgerEvent(src: "ext.content", t: t, kind: EventKind.observedEffect, cat: cat, tab: tab, frame: 0,
                    url: "https://cms.test/record/1",
                    p: ["focus": .bool(focus), "trusted": .bool(trusted), "target": ["role": "button", "name": "Save"]])
    }

    func sw(_ cat: String, t: Double, tab: Int = 5, url: String = "https://cms.test/record/1") -> LedgerEvent {
        LedgerEvent(src: "ext.sw", inst: "sw", seq: Int(t), t: t, kind: cat.hasPrefix("nav") ? EventKind.observedEffect : EventKind.context,
                    cat: cat, tab: tab, frame: 0, url: url, p: [:])
    }

    func helper(_ agent: String, started: Bool, t: Double) -> LedgerEvent {
        LedgerEvent(src: "mac.sensor", t: t, kind: EventKind.context, cat: started ? "helper.started" : "helper.stopped",
                    p: ["agent": .string(agent), "pid": 4242])
    }

    func attributions(_ sid: String) -> [String: Attribution] {
        let events = try! store.events(forSession: sid)
        let atts = try! store.latestAttributions(session: sid)
        var out: [String: Attribution] = [:]
        for e in events { if let a = atts[e.id] { out[e.event.cat] = a } }
        return out
    }

    func testClaudeHookStartsSessionAndIdentifiesClick() throws {
        let t0 = 1_000_000.0
        c.ingest([sw("nav.committed", t: t0 - 30_000)]) // earlier browsing in the tab, in memory only
        XCTAssertEqual(try store.eventCount(), 0)
        c.ingest([hook("tool.pre", t: t0)])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.agent, "claude-code")
        XCTAssertEqual(s.runtimeSession, "sess-A")
        XCTAssertEqual(commands.first?["type"]?.stringValue, "arm")
        XCTAssertEqual(commands.first?["tab"]?.intValue, 5)
        c.ingest([content("ui.click", t: t0 + 200)], receivedAt: t0 + 600)
        c.ingest([hook("tool.post", t: t0 + 400)])
        c.tick(now: t0 + 10_000)
        let a = attributions(s.id)
        XCTAssertEqual(a["ui.click"]?.actor, "agent:claude-code")
        XCTAssertEqual(a["ui.click"]?.label, "identified")
        // The earlier navigation was flushed from memory into the session as prebuffered.
        let nav = try store.events(forSession: s.id).first { $0.event.cat == "nav.committed" }
        XCTAssertEqual(nav?.event.pre, true)
    }

    func testHumanClickIsAttributedToHuman() throws {
        let t0 = 2_000_000.0
        c.ingest([hook("tool.pre", t: t0), hook("tool.post", t: t0 + 300)])
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 + 1000)
        c.noteHumanInput(.mouseDown, at: t0 + 20_000)
        c.ingest([content("ui.click", t: t0 + 20_050, focus: true)], receivedAt: t0 + 20_100)
        c.tick(now: t0 + 30_000)
        let sid = try XCTUnwrap(store.sessions().first?.id)
        XCTAssertEqual(attributions(sid)["ui.click"]?.actor, "human")
    }

    func testOverlapIsMixed() throws {
        let t0 = 3_000_000.0
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 - 1000)
        c.ingest([hook("tool.pre", t: t0)])
        c.noteHumanInput(.mouseDown, at: t0 + 100)
        c.ingest([content("ui.click", t: t0 + 150, focus: true)], receivedAt: t0 + 200)
        c.tick(now: t0 + 10_000)
        let sid = try XCTUnwrap(store.sessions().first?.id)
        XCTAssertEqual(attributions(sid)["ui.click"]?.actor, "mixed")
    }

    func testPassiveCodexDetectionPromotesOnUnexplainedInteraction() throws {
        let t0 = 4_000_000.0
        c.ingest([helper("codex", started: true, t: t0 - 60_000)])
        c.ingest([sw("tab.snapshot", t: t0 - 5000, tab: 9)])
        c.ingest([sw("debugger.attached", t: t0, tab: 9)])
        XCTAssertTrue(try store.sessions().isEmpty, "possible sessions are not persisted")
        XCTAssertEqual(commands.last?["type"]?.stringValue, "arm")
        c.ingest([content("ui.click", t: t0 + 1500, tab: 9)])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(s.attribution, "likely")
        XCTAssertEqual(s.state, "recording")
        let events = try store.events(forSession: s.id).map { $0.event.cat }
        XCTAssertTrue(events.contains("debugger.attached"))
        XCTAssertTrue(events.contains("ui.click"))
    }

    func testDevToolsWithoutHelperDoesNotStart() throws {
        let t0 = 5_000_000.0
        c.ingest([sw("debugger.attached", t: t0, tab: 3)])
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertTrue(commands.isEmpty)
        let decisions = try store.recentEvents(limit: 10).filter { $0.event.cat == "detector.decision" }
        XCTAssertEqual(decisions.first?.event.p?["decision"]?.stringValue, "not-started")
        XCTAssertNil(decisions.first?.event.url, "decisions carry no URL")
    }

    func testPossibleSessionTimesOutWithHumanOnlyActivity() throws {
        let t0 = 6_000_000.0
        c.ingest([helper("codex", started: true, t: t0 - 60_000)])
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 - 1000)
        c.ingest([sw("debugger.attached", t: t0, tab: 4)])
        c.noteHumanInput(.mouseDown, at: t0 + 2000)
        c.ingest([content("ui.click", t: t0 + 2050, tab: 4, focus: true)])
        c.tick(now: t0 + 70_000)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(commands.last?["type"]?.stringValue, "disarm")
    }

    func testLifecycleInactiveThenEnded() throws {
        let t0 = 7_000_000.0
        c.ingest([hook("tool.pre", t: t0), hook("tool.post", t: t0 + 100)])
        c.ingest([LedgerEvent(src: "hook.claude", t: t0 + 1000, kind: EventKind.runtimeReport, cat: "turn.stop",
                              p: ["session": "sess-A"])])
        XCTAssertEqual(try store.sessions().first?.state, "inactive")
        c.tick(now: t0 + 11 * 60_000)
        XCTAssertEqual(try store.sessions().first?.state, "ended")
        XCTAssertEqual(commands.last?["type"]?.stringValue, "disarm")
    }

    func testUnboundBrowsingIsNeverPersisted() throws {
        let t0 = 8_000_000.0
        for i in 0..<20 { c.ingest([sw("nav.committed", t: t0 + Double(i) * 1000, tab: 100 + i, url: "https://bank.example/\(i)")]) }
        c.tick(now: t0 + 60_000)
        XCTAssertEqual(try store.eventCount(), 0)
        c.tick(now: t0 + 20 * 60_000)
        XCTAssertEqual(c.status(now: t0 + 20 * 60_000).memoryEvents, 0, "memory prebuffer expires")
    }

    func testPromptBecomesLabelOnlyWhenBrowserUsed() throws {
        let t0 = 9_000_000.0
        c.ingest([LedgerEvent(src: "hook.claude", t: t0, kind: EventKind.runtimeIntent, cat: "turn.prompt",
                              p: ["session": "sess-B", "prompt": "Update the spring launch post"])])
        XCTAssertEqual(try store.eventCount(), 0)
        c.ingest([hook("tool.pre", t: t0 + 1000, session: "sess-B", id: "t9")])
        XCTAssertEqual(try store.sessions().first?.taskLabel, "Update the spring launch post")
    }

    func testCodexBrowserHookBindsAttachedTab() throws {
        let t0 = 10_000_000.0
        c.ingest([sw("debugger.attached", t: t0, tab: 12)])
        c.ingest([hook("tool.pre", t: t0 + 800, tool: "js", tab: nil, session: "codex-1", id: "c1", agent: .codex)])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(try store.sessionTabs(session: s.id).map { $0.tab }, [12])
    }
}

final class CorrelatorRegressionTests: XCTestCase {
    func testHumanClickStaysHumanWhenChromeLosesFocusBeforeAttribution() throws {
        let store = try LedgerStore(url: tempDir().appendingPathComponent("r.sqlite"))
        let c = Correlator(store: store)
        let t0 = 20_000_000.0
        let pre = LedgerEvent(src: "hook.claude", t: t0, kind: EventKind.attemptedOp, cat: "tool.pre", tab: 5,
                              p: ["session": "s", "tool": "mcp__claude-in-chrome__navigate", "toolUseId": "a", "browser": true, "tabIds": [5]])
        let post = LedgerEvent(src: "hook.claude", t: t0 + 200, kind: EventKind.runtimeReport, cat: "tool.post", tab: 5,
                               p: ["session": "s", "tool": "mcp__claude-in-chrome__navigate", "toolUseId": "a", "browser": true, "tabIds": [5]])
        c.ingest([pre, post], receivedAt: t0 + 300)
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 + 30_000)
        c.noteHumanInput(.mouseDown, at: t0 + 40_000)
        let click = LedgerEvent(src: "ext.content", t: t0 + 40_100, kind: EventKind.observedEffect, cat: "ui.click", tab: 5,
                                p: ["focus": true, "trusted": true])
        c.ingest([click], receivedAt: t0 + 40_400)
        // You switch to another app before the delayed attribution runs.
        c.ingest([LedgerEvent(src: "ext.sw", t: t0 + 41_000, kind: EventKind.context, cat: "window.focus", win: -1,
                              p: ["chromeFocused": false])], receivedAt: t0 + 41_000)
        c.noteFrontmost(bundleId: "com.anthropic.claudefordesktop", at: t0 + 41_000)
        c.tick(now: t0 + 45_000)
        let sid = try XCTUnwrap(store.sessions().first?.id)
        let ev = try store.events(forSession: sid).first { $0.event.cat == "ui.click" }!
        XCTAssertEqual(try store.latestAttributions(session: sid)[ev.id]?.actor, "human")
    }

    func testShortFollowUpPromptDoesNotReplaceTaskLabel() {
        XCTAssertTrue(Correlator.betterLabel("Update the spring launch post", than: nil))
        XCTAssertFalse(Correlator.betterLabel("yes", than: "Update the spring launch post"))
        XCTAssertTrue(Correlator.betterLabel("Update the spring launch post", than: "ok"))
    }
}

final class PossibleSessionPrivacyTests: XCTestCase {
    func testGapsForUnconfirmedSessionStayInMemory() throws {
        let store = try LedgerStore(url: tempDir().appendingPathComponent("p.sqlite"))
        let c = Correlator(store: store)
        let t0 = 30_000_000.0
        c.ingest([LedgerEvent(src: "mac.sensor", t: t0 - 1000, kind: EventKind.context, cat: "helper.started", p: ["agent": "codex", "pid": 9])])
        c.ingest([LedgerEvent(src: "ext.sw", t: t0, kind: EventKind.context, cat: "debugger.attached", tab: 8, url: "chrome://extensions/")])
        c.ingest([LedgerEvent(src: "ext.sw", t: t0 + 500, kind: EventKind.gap, cat: "gap.page_inaccessible", tab: 8, url: "chrome://extensions/",
                              p: ["reason": "restricted-url"])])
        c.tick(now: t0 + 70_000)
        let cats = try store.recentEvents(limit: 20).map { $0.event.cat }
        XCTAssertFalse(cats.contains("gap.page_inaccessible"))
        XCTAssertTrue(cats.contains("detector.decision"))
    }
}

final class EffectInheritanceTests: XCTestCase {
    func testRequestAndToastAfterHumanSubmitAreCreditedToHuman() throws {
        let store = try LedgerStore(url: tempDir().appendingPathComponent("e.sqlite"))
        let c = Correlator(store: store)
        let t0 = 40_000_000.0
        c.ingest([LedgerEvent(src: "hook.claude", t: t0, kind: EventKind.attemptedOp, cat: "tool.pre", tab: 5,
                              p: ["session": "s", "tool": "mcp__claude-in-chrome__navigate", "toolUseId": "n", "browser": true, "tabIds": [5]]),
                  LedgerEvent(src: "hook.claude", t: t0 + 300, kind: EventKind.runtimeReport, cat: "tool.post", tab: 5,
                              p: ["session": "s", "tool": "mcp__claude-in-chrome__navigate", "toolUseId": "n", "browser": true, "tabIds": [5]])],
                 receivedAt: t0 + 400)
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 + 10_000)
        c.noteHumanInput(.mouseDown, at: t0 + 20_000)
        // The request arrives before the click that caused it.
        c.ingest([LedgerEvent(src: "ext.sw", t: t0 + 20_120, kind: EventKind.observedEffect, cat: "net.request", tab: 5,
                              url: "http://localhost:4399/cms/api/record/2", p: ["method": "POST", "status": 200, "mutating": true])],
                 receivedAt: t0 + 20_300)
        c.ingest([LedgerEvent(src: "ext.content", t: t0 + 20_100, kind: EventKind.observedEffect, cat: "ui.click", tab: 5,
                              p: ["focus": true, "trusted": true]),
                  LedgerEvent(src: "ext.content", t: t0 + 20_110, kind: EventKind.observedEffect, cat: "form.submit", tab: 5,
                              p: ["focus": true, "trusted": true]),
                  LedgerEvent(src: "ext.content", t: t0 + 20_400, kind: EventKind.observedEffect, cat: "page.alert", tab: 5,
                              p: ["focus": true, "role": "status", "text": "Saved"])],
                 receivedAt: t0 + 20_550)
        // The request is due before the click is: it must wait for the click's attribution.
        c.tick(now: t0 + 22_850)
        c.tick(now: t0 + 30_000)
        let sid = try XCTUnwrap(store.sessions().first?.id)
        let atts = try store.latestAttributions(session: sid)
        var byCat: [String: Attribution] = [:]
        for e in try store.events(forSession: sid) { if let a = atts[e.id] { byCat[e.event.cat] = a } }
        XCTAssertEqual(byCat["form.submit"]?.actor, "human")
        XCTAssertEqual(byCat["net.request"]?.actor, "human")
        XCTAssertEqual(byCat["page.alert"]?.actor, "human")
        XCTAssertTrue(byCat["net.request"]?.reasons.first?.hasPrefix("follows form.submit") ?? false)
    }
}

final class CodexClaimTests: XCTestCase {
    func testCodexGetTabByURLBindsExistingTab() throws {
        let store = try LedgerStore(url: tempDir().appendingPathComponent("x.sqlite"))
        let c = Correlator(store: store)
        var commands: [JSONValue] = []
        c.sendCommand = { cmd, _ in commands.append(cmd) }
        let t0 = 50_000_000.0
        c.ingest([LedgerEvent(src: "ext.sw", t: t0 - 60_000, kind: EventKind.context, cat: "tab.snapshot", tab: 42,
                              url: "http://localhost:4399/cms/record/2", p: ["title": "Edit record"])])
        c.ingest([LedgerEvent(src: "hook.codex", t: t0, kind: EventKind.attemptedOp, cat: "tool.pre",
                              p: ["agent": "codex", "session": "cx", "tool": "mcp__cua_repl__js", "toolUseId": "c1", "browser": true,
                                  "input": ["code": "let tab = await cua.getTab({ url: \"http://localhost:4399/cms/record/2\" }, { browser: \"chrome\" });"]])])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(try store.sessionTabs(session: s.id).map { $0.tab }, [42])
        XCTAssertEqual(commands.first?["type"]?.stringValue, "arm")
    }

    func testCodexSessionEndHookIsNotAsync() throws {
        let url = tempDir().appendingPathComponent("hooks.json")
        try HookInstaller.install(agent: .codex, hookBinary: "/b/ledger-hook", url: url)
        let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["hooks"] as! [String: Any]
        let end = ((hooks["SessionEnd"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertNil(end["async"])
        let pre = ((hooks["PreToolUse"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(pre["async"] as? Bool, true)
    }
}
