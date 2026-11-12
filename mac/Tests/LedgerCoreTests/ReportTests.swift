import XCTest
@testable import LedgerCore

final class ReportTests: XCTestCase {
    let t0 = 1_794_200_000_000.0
    var events: [StoredEvent] = []
    var atts: [Int64: Attribution] = [:]

    override func setUp() { events = []; atts = [:] }

    @discardableResult
    func add(_ cat: String, at dt: Double, src: String = "ext.sw", kind: String = EventKind.observedEffect, tab: Int? = 5,
             url: String? = nil, actor: String? = nil, label: String = "identified", p: JSONValue? = nil) -> Int64 {
        let id = Int64(events.count + 1)
        events.append(StoredEvent(id: id, event: LedgerEvent(src: src, t: t0 + dt, kind: kind, cat: cat, tab: tab, frame: 0, url: url, p: p),
                                  receivedAt: t0 + dt, hash: ""))
        if let actor {
            atts[id] = Attribution(eventId: id, sessionId: "S", actor: actor, label: actor == "unknown" ? "unknown" : label, scope: nil,
                                   reasons: [], detectorVersion: "t", createdAt: t0)
        }
        return id
    }

    func tool(_ name: String, at dt: Double, id: String, input: JSONValue, end: Double? = nil) {
        add("tool.pre", at: dt, src: "hook.claude", kind: EventKind.attemptedOp, tab: nil,
            p: ["tool": .string("mcp__claude-in-chrome__" + name), "toolUseId": .string(id), "input": input,
                "route": "extension", "browser": true, "cwd": "/tmp/proj"])
        if let end {
            add("tool.post", at: end, src: "hook.claude", kind: EventKind.runtimeReport, tab: nil,
                p: ["tool": .string("mcp__claude-in-chrome__" + name), "toolUseId": .string(id), "result": ["preview": "ok"]])
        }
    }

    func report() -> SessionReport {
        let s = SessionRecord(id: "S", agent: "claude-code", runtimeSession: "rt-1", state: "ended", startedAt: t0,
                              lastActivityAt: t0 + 600_000, endedAt: t0 + 600_000, taskLabel: nil, labelSource: nil,
                              startReason: "", attribution: "identified", coverage: "ok", detectorVersion: "t")
        return SessionReport.build(session: s, events: events, attributions: atts, tabs: [(5, t0, nil)])
    }

    func testReadOnlySessionReportsNoChanges() {
        add("turn.prompt", at: 0, src: "hook.claude", kind: EventKind.runtimeIntent, tab: nil, p: ["prompt": "find my orders"])
        tool("navigate", at: 1000, id: "a", input: ["url": "https://www.amazon.com/your-orders/search?search=book"], end: 2000)
        let nav = add("nav.committed", at: 1500, url: "https://www.amazon.com/your-orders/search?search=book", actor: "unknown")
        tool("javascript_tool", at: 5000, id: "b",
             input: ["action": "javascript_exec", "tabId": 5, "text": "const r = await fetch('/dp/B00INIXN2I'); r.status"], end: 9000)
        for i in 0..<30 {
            add("net.request", at: 5100 + Double(i) * 100, url: "https://www.amazon.com/dp/B00INIXN2\(i % 10)", actor: "agent:claude-code",
                p: ["method": "GET", "type": "fetch", "status": 200])
        }
        for i in 0..<40 {
            add("net.request", at: 6000 + Double(i), url: "https://unagi.amazon.com/1/events/com.amazon.csm", actor: "unknown",
                p: ["method": "POST", "type": "ping", "mutating": true])
        }
        add("net.request", at: 30_000, url: "https://www.amazon.com/acp/p13n-rvi/abc12345def/getCarouselItems", actor: "unknown",
            p: ["method": "POST", "type": "xmlhttprequest", "mutating": true, "status": 200, "initiator": "https://www.amazon.com"])
        add("page.alert", at: 31_000, actor: "unknown", p: ["role": "dialog", "text": "Account & Lists"])
        add("page.alert", at: 32_000, actor: "unknown", p: ["live": "polite", "text": "Page 1 of 6"])
        add("ui.scroll", at: 33_000, actor: "unknown")

        let r = report()
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertTrue(r.statusMessages.isEmpty)
        XCTAssertEqual(r.backgroundRequests, 40)
        XCTAssertEqual(r.pageRequests.first?.count, 1)
        XCTAssertEqual(r.fetchedCount, 30)
        XCTAssertEqual(r.fetched.first?.pattern, "amazon.com/dp/…")
        XCTAssertEqual(r.scripts.count, 1)
        XCTAssertEqual(r.scripts[0].requests, 30)
        XCTAssertFalse(r.scripts[0].couldChange)
        XCTAssertEqual(r.effective[nav]?.actor, "agent:claude-code", "navigation the agent asked for")
        XCTAssertEqual(r.unknown, 1, "only the scroll stays unknown")
        XCTAssertLessThan(r.unknownShare, 0.02)
        XCTAssertTrue(r.oneLine.contains("amazon.com"))
        XCTAssertTrue(r.oneLine.contains("no changes observed"))
        XCTAssertEqual(r.resumeCommand, "cd \"/tmp/proj\" && claude --resume rt-1")
        XCTAssertEqual(r.turns.first?.prompt, "find my orders")
    }

    func testRealChangeIsHeadlined() {
        tool("browser_batch", at: 1000, id: "a", input: ["actions": [
            ["name": "computer", "input": ["action": "left_click", "tabId": 5]],
            ["name": "computer", "input": ["action": "screenshot", "tabId": 5]]]], end: 3000)
        add("ui.click", at: 1200, src: "ext.content", actor: "agent:claude-code", p: ["target": ["name": "Delete record", "role": "button"]])
        add("net.request", at: 1400, url: "https://cms.test/api/record/12", actor: "agent:claude-code",
            p: ["method": "DELETE", "type": "fetch", "mutating": true, "status": 200])
        add("page.alert", at: 1900, src: "ext.content", actor: "agent:claude-code", p: ["role": "status", "text": "Record deleted"])
        let r = report()
        XCTAssertEqual(r.changes.count, 1)
        XCTAssertEqual(r.changes[0].tag, "Delete")
        XCTAssertEqual(r.statusMessages.count, 1)
        XCTAssertEqual(r.reportedActions, 1)
        XCTAssertTrue(r.oneLine.contains("delete"))
    }

    func testScriptSignals() {
        XCTAssertEqual(EventClass.scriptSignals(in: "[...document.querySelectorAll('a')].map(a => a.href)"), [])
        XCTAssertEqual(EventClass.scriptSignals(in: "if (a.value == 'x') await fetch('/orders')"), [])
        XCTAssertEqual(EventClass.scriptSignals(in: "document.querySelector('#save').click()"), ["clicks"])
        XCTAssertEqual(EventClass.scriptSignals(in: "el.value = 'new'; el.dispatchEvent(new Event('input'))"), ["sets a field value", "fires events"])
        XCTAssertEqual(EventClass.scriptSignals(in: "fetch('/api', {method: 'POST', body})"), ["sends a non-GET request"])
        XCTAssertEqual(EventClass.scriptSignals(in: "const tab = await cua.getTab(); await tab.click('#go')"), ["clicks", "clicks or types"])
    }

    func testClassifiers() {
        XCTAssertEqual(EventClass.pattern("https://www.amazon.com/gp/product/1735870501/ref=x?a=b"), "amazon.com/gp/product/…/ref=x")
        XCTAssertTrue(EventClass.isAgentUI(url: "chrome://new-tab-page/"))
        XCTAssertTrue(EventClass.isAgentUI(url: "https://claude.ai/artifact/abc"))
        XCTAssertFalse(EventClass.isAgentUI(url: "https://example.com/claude.ai"))
        let telemetry = LedgerEvent(src: "ext.sw", t: 0, kind: EventKind.observedEffect, cat: "net.request",
                                    url: "https://claude.ai/api/frame/telemetry", p: ["method": "POST", "mutating": true, "status": 204])
        XCTAssertTrue(EventClass.isBackground(telemetry))
        let real = LedgerEvent(src: "ext.sw", t: 0, kind: EventKind.observedEffect, cat: "net.request",
                               url: "https://example.com/api/log/entries", p: ["method": "POST", "mutating": true, "status": 201])
        XCTAssertFalse(EventClass.isBackground(real))
        XCTAssertEqual(EventClass.consequentialTag("Place your order"), "Pay")
        XCTAssertNil(EventClass.consequentialTag("Next page"))
    }

    // MARK: Alerts

    func deleteOnCMS() {
        add("nav.committed", at: 500, url: "https://cms.test/records", p: ["transition": "link"])
        tool("computer", at: 1000, id: "a", input: ["action": "left_click", "tabId": 5], end: 3000)
        add("ui.click", at: 1200, src: "ext.content", url: "https://cms.test/records", actor: "agent:claude-code",
            p: ["target": ["name": "Delete record", "role": "button"]])
        add("net.request", at: 1400, url: "https://cms.test/api/record/12", actor: "agent:claude-code",
            p: ["method": "DELETE", "type": "fetch", "mutating": true, "status": 200])
    }

    func testAlertForConsequentialAction() {
        deleteOnCMS()
        let alerts = Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: nil)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].key.hasPrefix("action:"))
        XCTAssertTrue(alerts[0].title.contains("Delete"))
        XCTAssertTrue(alerts[0].title.contains("cms.test"))
    }

    func testAlertForSensitiveSiteReplacesTheActionAlert() {
        deleteOnCMS()
        var settings = LedgerSettings()
        settings.sensitiveHosts = ["cms.test"]
        let alerts = Alerts.evaluate(report: report(), events: events, settings: settings, knownRoutes: nil)
        XCTAssertEqual(alerts.map(\.key), ["sensitive:cms.test"])
    }

    func testNoAlertForYourOwnChangeOrAReadOnlySession() {
        add("nav.committed", at: 500, url: "https://cms.test/records", p: ["transition": "link"])
        add("ui.click", at: 1200, src: "ext.content", url: "https://cms.test/records", actor: "human", label: "likely",
            p: ["target": ["name": "Delete record", "role": "button"]])
        add("net.request", at: 1400, url: "https://cms.test/api/record/12", actor: "human", label: "likely",
            p: ["method": "DELETE", "type": "fetch", "mutating": true, "status": 200])
        tool("get_page_text", at: 2000, id: "r", input: ["tabId": 5], end: 2500)
        var settings = LedgerSettings()
        settings.sensitiveHosts = ["cms.test"]
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: settings, knownRoutes: ["extension:mcp__claude-in-chrome"]), [])
    }

    func testAlertForScriptThatCouldChangeASensitiveSite() {
        add("nav.committed", at: 500, url: "https://mail.example.com/inbox", p: ["transition": "link"])
        tool("javascript_tool", at: 1000, id: "j", input: ["text": "document.querySelector('#send').click()", "tabId": 5], end: 1500)
        var settings = LedgerSettings()
        settings.sensitiveHosts = ["example.com"]
        let alerts = Alerts.evaluate(report: report(), events: events, settings: settings, knownRoutes: nil)
        XCTAssertEqual(alerts.map(\.key), ["sensitive-script:mail.example.com"])
        settings.sensitiveHosts = []
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: settings, knownRoutes: nil), [])
    }

    func testInAppBrowserSessionsDontNotify() {
        // The Claude desktop app's browser pane: hooks report the calls, Chrome sees nothing.
        add("tool.pre", at: 1000, src: "hook.claude", kind: EventKind.attemptedOp, tab: nil,
            p: ["tool": "mcp__Claude_Browser__navigate", "toolUseId": "n", "input": ["url": "http://localhost:3000"],
                "route": "automation", "browser": true])
        add("tool.pre", at: 2000, src: "hook.claude", kind: EventKind.attemptedOp, tab: nil,
            p: ["tool": "mcp__Claude_Browser__file_upload", "toolUseId": "u", "input": ["paths": ["/tmp/a.png"]],
                "route": "automation", "browser": true])
        let s = SessionRecord(id: "S", agent: "claude-code", runtimeSession: "rt-1", state: "ended", startedAt: t0,
                              lastActivityAt: t0 + 5000, endedAt: t0 + 5000, taskLabel: nil, labelSource: nil,
                              startReason: "", attribution: "identified", coverage: "ok", detectorVersion: "t")
        let r = SessionReport.build(session: s, events: events, attributions: atts, tabs: [])
        XCTAssertTrue(r.inAppBrowserOnly)
        let quiet = Alerts.evaluate(report: r, events: events, settings: LedgerSettings(), knownRoutes: [])
        XCTAssertFalse(quiet.isEmpty, "the alerts stay in the record")
        XCTAssertTrue(quiet.allSatisfy { !$0.notify })
        var loud = LedgerSettings()
        loud.inAppBrowserNotices = true
        XCTAssertTrue(Alerts.evaluate(report: r, events: events, settings: loud, knownRoutes: []).contains { $0.notify })
        // A session that reached Chrome is not quiet.
        deleteOnCMS()
        XCTAssertFalse(report().inAppBrowserOnly)
        XCTAssertTrue(Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: nil).contains { $0.notify })
    }

    func testStatusWords() {
        XCTAssertEqual(Words.attribution("identified").text, "Confirmed")
        XCTAssertEqual(Words.attribution("likely").text, "Probable")
        XCTAssertEqual(Words.attribution("whatever").text, "Unclear")
        XCTAssertEqual(Words.state("inactive").text, "Idle")
        XCTAssertEqual(Words.source(src: "hook.claude", pre: false).text, "reported")
        XCTAssertEqual(Words.source(src: "ext.sw", pre: true).text, "earlier")
        XCTAssertFalse(Words.attribution("mixed").help.isEmpty)
    }

    func testBuiltInSiteGroups() {
        var s = LedgerSettings()
        XCTAssertEqual(s.sensitiveGroup(host: "secure.chase.com"), "Financial")
        XCTAssertEqual(s.sensitiveGroup(host: "mail.google.com"), "Email")
        XCTAssertNil(s.sensitiveGroup(host: "www.google.com"), "only the listed Google hosts count")
        XCTAssertEqual(s.sensitiveGroup(host: "console.aws.amazon.com"), "Developer and infrastructure", "the longest entry wins")
        XCTAssertEqual(s.sensitiveGroup(host: "www.amazon.com"), "Shopping and travel")
        XCTAssertEqual(s.sensitiveGroup(host: "www.irs.gov"), "Government, tax and health")
        XCTAssertNil(s.sensitiveGroup(host: "notgov"))
        XCTAssertNil(s.sensitiveGroup(host: "app.slack.com"), "work chat is off until switched on")
        XCTAssertNil(s.sensitiveGroup(host: "example.com"))
        s.siteGroups["chat"] = true
        s.siteGroups["financial"] = false
        XCTAssertEqual(s.sensitiveGroup(host: "app.slack.com"), "Work chat and messaging")
        XCTAssertNil(s.sensitiveGroup(host: "chase.com"))
        s.sensitiveExceptions = ["reddit.com"]
        XCTAssertNil(s.sensitiveGroup(host: "old.reddit.com"))
        s.sensitiveHosts = ["chase.com", "reddit.com"]
        XCTAssertEqual(s.sensitiveGroup(host: "chase.com"), SiteGroups.customName, "your own list beats a switched-off group")
        XCTAssertEqual(s.sensitiveGroup(host: "reddit.com"), SiteGroups.customName, "and beats an exception")
        // An older settings file without the new keys still loads with the defaults.
        let old = try! JSONDecoder().decode(LedgerSettings.self, from: Data(#"{"sensitiveHosts":["a.com"]}"#.utf8))
        XCTAssertTrue(old.groupEnabled("financial") && !old.groupEnabled("storage") && old.actionEnabled("delete"))
        // No entry is listed twice, and all are lowercase bare hosts.
        let all = SiteGroups.all.flatMap(\.hosts)
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertTrue(all.allSatisfy { $0 == $0.lowercased() && !$0.contains("/") && !$0.hasPrefix("www.") && !$0.hasPrefix(".") })
    }

    func testAlertNamesTheGroupOnABuiltInSite() {
        add("nav.committed", at: 500, url: "https://github.com/me/repo/settings", p: ["transition": "link"])
        tool("computer", at: 1000, id: "a", input: ["action": "left_click", "tabId": 5], end: 3000)
        add("ui.click", at: 1200, src: "ext.content", url: "https://github.com/me/repo/settings", actor: "agent:claude-code",
            p: ["target": ["name": "Delete this repository", "role": "button"]])
        add("net.request", at: 1400, url: "https://github.com/me/repo/settings/delete", actor: "agent:claude-code",
            p: ["method": "POST", "type": "main_frame", "mutating": true, "status": 302])
        let alerts = Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: nil)
        XCTAssertEqual(alerts.map(\.key), ["sensitive:github.com"])
        XCTAssertTrue(alerts[0].body.hasPrefix("Developer and infrastructure: "))
        var off = LedgerSettings()
        off.siteGroups["developer"] = false
        XCTAssertTrue(Alerts.evaluate(report: report(), events: events, settings: off, knownRoutes: nil)[0].key.hasPrefix("action:"))
    }

    func testActionAlertsCanBeSwitchedOff() {
        deleteOnCMS()
        var s = LedgerSettings()
        s.actionAlerts["delete"] = false
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: s, knownRoutes: nil), [])
    }

    func testSecurityConsentAndCardTags() {
        XCTAssertEqual(EventClass.consequentialTag("Change password"), EventClass.securityTag)
        XCTAssertEqual(EventClass.consequentialTag("Enable two-factor authentication"), EventClass.securityTag)
        XCTAssertEqual(EventClass.consequentialTag("Generate new token"), EventClass.securityTag)
        XCTAssertEqual(EventClass.consequentialTag("Add SSH key"), EventClass.securityTag)
        XCTAssertEqual(EventClass.consequentialTag("Authorize Acme App"), EventClass.consentTag)
        XCTAssertEqual(EventClass.consequentialTag("Allow"), EventClass.consentTag)
        XCTAssertNil(EventClass.consequentialTag("Allow all cookies"))
        XCTAssertEqual(EventClass.consequentialTag("Approve"), "Change")
        let card: JSONValue = ["field": ["name": "Card number", "autocomplete": "cc-number", "sensitive": "autocomplete:cc-number"],
                               "value": ["redacted": true]]
        let pw: JSONValue = ["field": ["name": "New password", "type": "password", "autocomplete": "new-password", "sensitive": "password-field"],
                             "value": ["redacted": true]]
        let login: JSONValue = ["field": ["name": "Password", "type": "password", "autocomplete": "current-password"], "value": ["redacted": true]]
        XCTAssertEqual(EventClass.formTag(fields: [card], submitter: "Continue"), "Pay")
        XCTAssertEqual(EventClass.formTag(fields: [pw], submitter: "Save"), EventClass.securityTag)
        XCTAssertEqual(EventClass.formTag(fields: [login], submitter: "Sign in"), "Change")
        XCTAssertEqual(EventClass.formTag(fields: [], submitter: "Send"), "Send")
    }

    func testAlertForConsentAndUpload() {
        add("nav.committed", at: 500, url: "https://auth.example.com/oauth/authorize", p: ["transition": "link"])
        tool("computer", at: 1000, id: "a", input: ["action": "left_click", "tabId": 5], end: 3000)
        add("ui.click", at: 1200, src: "ext.content", url: "https://auth.example.com/oauth/authorize", actor: "agent:claude-code",
            p: ["target": ["name": "Authorize", "role": "button"]])
        add("net.request", at: 1400, url: "https://auth.example.com/oauth/authorize", actor: "agent:claude-code",
            p: ["method": "POST", "type": "main_frame", "mutating": true, "status": 302])
        tool("file_upload", at: 5000, id: "u", input: ["paths": ["/tmp/a.pdf"], "tabId": 5], end: 5500)
        var s = LedgerSettings()
        let alerts = Alerts.evaluate(report: report(), events: events, settings: s, knownRoutes: nil)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(alerts[0].title.contains("Access granted on auth.example.com"))
        XCTAssertTrue(alerts[1].key.hasPrefix("upload:"))
        s.actionAlerts = ["consent": false, "upload": false]
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: s, knownRoutes: nil), [])
    }

    func testAlertForNewRouteAndGaps() {
        tool("navigate", at: 1000, id: "n", input: ["url": "https://example.com", "tabId": 5], end: 1500)
        XCTAssertEqual(Alerts.routes(in: events), ["extension:mcp__claude-in-chrome"])
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: nil), [],
                       "the first session only teaches the recorder what's normal")
        XCTAssertEqual(Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(),
                                       knownRoutes: ["extension:mcp__claude-in-chrome"]), [])
        let fresh = Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: ["shell"])
        XCTAssertEqual(fresh.map(\.key), ["route:extension:mcp__claude-in-chrome"])

        add("gap.recorder_stopped", at: 2000, src: "mac.app", kind: EventKind.gap, tab: nil, p: ["reason": "unexpected", "seconds": 90])
        add("gap.recorder_stopped", at: 3000, src: "mac.app", kind: EventKind.gap, tab: nil, p: ["reason": "quit", "seconds": 90])
        let gaps = Alerts.evaluate(report: report(), events: events, settings: LedgerSettings(), knownRoutes: nil)
        XCTAssertEqual(gaps.count, 1, "a stop you chose isn't an alert")
        XCTAssertFalse(gaps[0].notify, "the stop was already notified when it was found")
    }
}
