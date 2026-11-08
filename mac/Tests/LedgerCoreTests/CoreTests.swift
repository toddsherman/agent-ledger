import XCTest
@testable import LedgerCore

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class RedactorTests: XCTestCase {
    struct Case: Decodable { let `in`: String; let out: String }
    struct Fixture: Decodable { let values: [Case]; let urls: [Case] }

    func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "redaction", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testValueFixtures() throws {
        for c in try fixture().values { XCTAssertEqual(Redactor.scrub(c.in), c.out, "value: \(c.in)") }
    }

    func testURLFixtures() throws {
        for c in try fixture().urls { XCTAssertEqual(Redactor.url(c.in), c.out, "url: \(c.in)") }
    }

    func testTruncate() {
        let s = String(repeating: "a", count: 3000)
        let t = Redactor.value(s)
        XCTAssertTrue(t.hasPrefix(String(repeating: "a", count: 2048)))
        XCTAssertTrue(t.hasSuffix("…[+952 chars]"))
    }

    func testSanitizeKeepsCodeAndDropsBinary() {
        let img = String(repeating: "QUJD", count: 600)
        let v: JSONValue = ["code": "document.title", "password": "hunter2", "image": .string(img), "tabId": 5]
        let s = Redactor.sanitize(v)
        XCTAssertEqual(s["code"]?.stringValue, "document.title")
        XCTAssertEqual(s["password"]?.stringValue, "[redacted]")
        XCTAssertEqual(s["image"]?.stringValue, "[binary 2400 chars]")
        XCTAssertEqual(s["tabId"]?.intValue, 5)
    }
}

final class StoreTests: XCTestCase {
    func makeStore() throws -> LedgerStore {
        try LedgerStore(url: tempDir().appendingPathComponent("t.sqlite"))
    }

    func ev(_ cat: String, t: Double, tab: Int? = nil) -> LedgerEvent {
        LedgerEvent(src: "ext.sw", inst: "i", seq: Int(t), t: t, kind: EventKind.context, cat: cat, tab: tab,
                    url: "https://example.com/", p: ["n": .number(t)])
    }

    func testAppendAndVerify() throws {
        let s = try makeStore()
        let ids = try s.append([ev("a", t: 1), ev("b", t: 2), ev("c", t: 3)], receivedAt: 10)
        XCTAssertEqual(ids.count, 3)
        let v = try s.verifyChain()
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.checked, 3)
    }

    func testEventsAreAppendOnly() throws {
        let s = try makeStore()
        try s.append([ev("a", t: 1)])
        XCTAssertThrowsError(try s.db.run("UPDATE events SET cat = 'x'"))
        XCTAssertThrowsError(try s.db.run("DELETE FROM events"))
    }

    func testTamperIsDetected() throws {
        let s = try makeStore()
        try s.append([ev("a", t: 1), ev("b", t: 2), ev("c", t: 3)])
        try s.db.exec("DROP TRIGGER events_no_update")
        try s.db.run("UPDATE events SET url = 'https://evil.example/' WHERE id = 2")
        let v = try s.verifyChain()
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.firstBadEventId, 2)
    }

    func testPurgeReanchorsChain() throws {
        let s = try makeStore()
        try s.append([ev("a", t: 1), ev("b", t: 2), ev("c", t: 3), ev("d", t: 4)])
        let removed = try s.purge(olderThan: 2.5)
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(try s.verifyChain().ok)
        try s.append([ev("e", t: 5)])
        let v = try s.verifyChain()
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.checked, 3)
    }

    func testSessionsLinksAndAttributions() throws {
        let s = try makeStore()
        let ids = try s.append([ev("nav.committed", t: 1, tab: 7), ev("ui.click", t: 2, tab: 7)])
        let rec = SessionRecord(id: "S1", agent: "claude-code", runtimeSession: "r1", state: "recording",
                                startedAt: 1, lastActivityAt: 2, startReason: "hook", attribution: "identified",
                                detectorVersion: "t")
        try s.upsertSession(rec)
        try s.bindTab(session: "S1", tab: 7, at: 1, evidence: "hook")
        try s.link(session: "S1", eventIds: ids)
        try s.addAttributions([Attribution(eventId: ids[1], sessionId: "S1", actor: "agent:claude-code",
                                           label: "identified", scope: "operation", reasons: ["r"],
                                           detectorVersion: "t", createdAt: 3)])
        XCTAssertEqual(try s.events(forSession: "S1").count, 2)
        XCTAssertEqual(try s.latestAttributions(session: "S1")[ids[1]]?.actor, "agent:claude-code")
        let summary = try s.sessionSummaries().first
        XCTAssertEqual(summary?.tabCount, 1)
        XCTAssertEqual(summary?.hosts, ["example.com"])
    }
}

final class HookTranslatorTests: XCTestCase {
    func json(_ v: JSONValue) -> Data { v.canonicalData() }

    func testClaudeBrowserPreToolUse() {
        let input: JSONValue = [
            "hook_event_name": "PreToolUse", "session_id": "sess-1", "cwd": "/tmp",
            "tool_name": "mcp__claude-in-chrome__computer", "tool_use_id": "toolu_1",
            "tool_input": ["action": "left_click", "coordinate": [10, 20], "tabId": 123],
        ]
        let e = HookTranslator.translate(stdin: json(input), agent: .claude, now: 1000)!
        XCTAssertEqual(e.cat, "tool.pre")
        XCTAssertEqual(e.kind, EventKind.attemptedOp)
        XCTAssertEqual(e.tab, 123)
        XCTAssertEqual(e.p?["browser"]?.boolValue, true)
        XCTAssertEqual(e.p?["session"]?.stringValue, "sess-1")
        XCTAssertEqual(e.p?["input"]?["action"]?.stringValue, "left_click")
    }

    func testBatchTabIdsAndImageResultSummary() {
        let img = String(repeating: "iVBO", count: 400)
        let input: JSONValue = [
            "hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "mcp__claude-in-chrome__browser_batch",
            "tool_use_id": "t2",
            "tool_input": ["actions": [["name": "navigate", "input": ["url": "https://a.test", "tabId": 9]],
                                       ["name": "computer", "input": ["action": "screenshot", "tabId": 10]]]],
            "tool_response": [["type": "text", "text": "Navigated"], ["type": "image", "source": ["type": "base64", "data": .string(img)]]],
        ]
        let e = HookTranslator.translate(stdin: json(input), agent: .claude, now: 1)!
        XCTAssertEqual(e.p?["tabIds"]?.arrayValue?.compactMap { $0.intValue }.sorted(), [9, 10])
        XCTAssertEqual(e.p?["result"]?["images"]?.intValue, 1)
        XCTAssertEqual(e.p?["result"]?["preview"]?.stringValue, "Navigated")
        XCTAssertFalse(e.p!.canonicalString().contains(img))
    }

    func testCodexNonBrowserToolKeepsNoInput() {
        let input: JSONValue = ["hook_event_name": "PreToolUse", "session_id": "c1", "turn_id": "t1",
                                "tool_name": "Bash", "tool_use_id": "x", "tool_input": ["command": "ls ~/secret"]]
        let e = HookTranslator.translate(stdin: json(input), agent: .codex, now: 1)!
        XCTAssertEqual(e.p?["browser"]?.boolValue, false)
        XCTAssertNil(e.p?["input"])
        XCTAssertEqual(e.p?["turn"]?.stringValue, "t1")
    }

    func testCodexBrowserCodeDetected() {
        let input: JSONValue = ["hook_event_name": "PreToolUse", "session_id": "c1", "tool_name": "js",
                                "tool_use_id": "x",
                                "tool_input": ["code": "const tabs = await browser.user.openTabs(); await browser.user.claimTab(tabs[0])"]]
        let e = HookTranslator.translate(stdin: json(input), agent: .codex, now: 1)!
        XCTAssertEqual(e.p?["browser"]?.boolValue, true)
        XCTAssertNotNil(e.p?["input"]?["code"])
    }

    func testPromptTruncated() {
        let long = String(repeating: "x", count: 900)
        let input: JSONValue = ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": .string(long)]
        let e = HookTranslator.translate(stdin: json(input), agent: .claude, now: 1)!
        XCTAssertEqual(e.kind, EventKind.runtimeIntent)
        XCTAssertTrue(e.p!["prompt"]!.stringValue!.hasSuffix("…[+400 chars]"))
    }

    func testUnknownEventIgnored() {
        XCTAssertNil(HookTranslator.translate(stdin: json(["hook_event_name": "Notification"]), agent: .claude))
        XCTAssertNil(HookTranslator.translate(stdin: Data("not json".utf8), agent: .claude))
    }
}

final class TransportTests: XCTestCase {
    func testSpoolRoundTrip() {
        let dir = tempDir()
        let e = LedgerEvent(src: "x", t: 1, kind: EventKind.gap, cat: "gap.test")
        XCTAssertTrue(Spool.append(role: "test", line: WireMessage(type: "events", events: [e]).line(), dir: dir))
        XCTAssertTrue(Spool.append(role: "test", line: WireMessage(type: "events", events: [e, e]).line(), dir: dir))
        let msgs = Spool.drain(dir: dir)
        XCTAssertEqual(msgs.flatMap { $0.events ?? [] }.count, 3)
        XCTAssertTrue(Spool.drain(dir: dir).isEmpty)
    }

    func testSocketRoundTrip() throws {
        let path = "/tmp/al-\(UUID().uuidString.prefix(8)).sock"
        let server = IngestServer(path: path)
        let got = expectation(description: "line")
        let reply = expectation(description: "reply")
        var roles: [String?] = []
        server.onLine = { peer, line in
            if let m = try? JSONDecoder().decode(WireMessage.self, from: line), m.type == "events" {
                roles.append(peer.role)
                got.fulfill()
                DispatchQueue.global().async {
                    server.broadcast(role: "host", Data("{\"type\":\"ping\"}\n".utf8))
                }
            }
        }
        try server.start()
        let c = SocketClient()
        XCTAssertTrue(c.connect(path: path))
        XCTAssertTrue(c.send(WireMessage(type: "hello", role: "host", pid: 1).line()))
        XCTAssertTrue(c.send(WireMessage(type: "events", events: []).line()))
        DispatchQueue.global().async {
            if let lines = c.readLines(), lines.first.map({ String(decoding: $0, as: UTF8.self) }) == "{\"type\":\"ping\"}" {
                reply.fulfill()
            }
        }
        wait(for: [got, reply], timeout: 3)
        XCTAssertEqual(roles, ["host"])
        c.close()
        server.stop()
    }
}
