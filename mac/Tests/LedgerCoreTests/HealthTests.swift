import XCTest
@testable import LedgerCore

final class HealthTests: XCTestCase {
    let t0 = 1_794_200_000_000.0

    func ev(_ cat: String, t: Double, src: String = "ext.sw", kind: String = EventKind.context, p: JSONValue? = nil) -> LedgerEvent {
        LedgerEvent(src: src, inst: "i", seq: Int(t - t0), t: t, kind: kind, cat: cat, tab: nil, frame: nil, url: nil, p: p)
    }

    // MARK: Recorder stops

    func testStopReasons() {
        let hb = t0, now = t0 + 600_000
        func reason(quit: Double? = nil, boot: Double = 0, binary: Double? = nil, last: String? = "1", version: String = "1") -> String? {
            RecorderStop.decide(lastHeartbeat: hb, quitMarkerAt: quit, bootAt: boot, binaryChangedAt: binary,
                                lastVersion: last, version: version, now: now)?.reason
        }
        XCTAssertEqual(reason(), "unexpected")
        XCTAssertEqual(reason(quit: hb + 100), "quit")
        XCTAssertEqual(reason(quit: hb - 3_600_000), "unexpected", "an old quit marker doesn't explain a later stop")
        XCTAssertEqual(reason(boot: hb + 60_000), "restart")
        XCTAssertEqual(reason(last: "0.9"), "update")
        XCTAssertEqual(reason(binary: hb + 5000), "update")
        XCTAssertNil(RecorderStop.decide(lastHeartbeat: now - 3000, quitMarkerAt: nil, bootAt: 0, binaryChangedAt: nil,
                                         lastVersion: "1", version: "1", now: now), "a short stop isn't recorded")
        XCTAssertNil(RecorderStop.decide(lastHeartbeat: nil, quitMarkerAt: nil, bootAt: 0, binaryChangedAt: nil,
                                         lastVersion: nil, version: "1", now: now), "first launch")
        let f = RecorderStop.decide(lastHeartbeat: hb, quitMarkerAt: nil, bootAt: 0, binaryChangedAt: nil, lastVersion: "1", version: "1", now: now)!
        XCTAssertTrue(RecorderStop.notice(f).notify)
        XCTAssertEqual(RecorderStop.notice(f).payload["seconds"]?.intValue, 600)
        let q = RecorderStop.decide(lastHeartbeat: hb, quitMarkerAt: hb, bootAt: 0, binaryChangedAt: nil, lastVersion: "1", version: "1", now: now)!
        XCTAssertFalse(RecorderStop.notice(q).notify, "a stop you chose isn't an alert")
    }

    func testKeepAliveDecision() {
        XCTAssertEqual(KeepAlive.decide(appRunning: true, quitMarkerAt: nil, bootAt: 0, downSince: nil, now: t0), .running)
        XCTAssertEqual(KeepAlive.decide(appRunning: false, quitMarkerAt: t0 - 10, bootAt: t0 - 1000, downSince: t0 - 60_000, now: t0), .userQuit)
        XCTAssertEqual(KeepAlive.decide(appRunning: false, quitMarkerAt: t0 - 5000, bootAt: t0 - 1000, downSince: t0 - 900, now: t0), .waiting,
                       "a quit before the last restart no longer holds, but the grace period does")
        XCTAssertEqual(KeepAlive.decide(appRunning: false, quitMarkerAt: nil, bootAt: 0, downSince: t0 - KeepAlive.graceMs, now: t0), .launch)
        XCTAssertEqual(KeepAlive.decide(appRunning: false, quitMarkerAt: nil, bootAt: 0, downSince: nil, now: t0), .waiting)
    }

    // MARK: Hooks and extension

    func testHooksRemovedIsReportedOnce() {
        let m = HealthMonitor()
        var i = HealthMonitor.Inputs(now: t0, hooksExpected: ["claude-code": true, "codex": false],
                                     hooksPresent: ["claude-code": true, "codex": false], hookBinaryOK: true,
                                     chromeRunning: false, extensionConnected: false)
        XCTAssertEqual(m.evaluate(i), [])
        i.hooksPresent["claude-code"] = false
        XCTAssertEqual(m.evaluate(i).map(\.cat), ["gap.hooks_removed"])
        XCTAssertEqual(m.evaluate(i), [], "one removal, one notice")
        XCTAssertNotNil(m.warnings["hooks.claude-code"])
        i.hooksPresent["claude-code"] = true
        XCTAssertEqual(m.evaluate(i).map(\.cat), ["health.hooks_restored"])
        XCTAssertNil(m.warnings["hooks.claude-code"])
        // Hooks you removed in Settings are no longer expected.
        i.hooksPresent["claude-code"] = false
        i.hooksExpected["claude-code"] = false
        XCTAssertEqual(m.evaluate(i), [])
    }

    func testHookProgramMissing() {
        let m = HealthMonitor()
        var i = HealthMonitor.Inputs(now: t0, hooksExpected: ["codex": true], hooksPresent: ["codex": true], hookBinaryOK: false,
                                     chromeRunning: false, extensionConnected: false)
        XCTAssertEqual(m.evaluate(i).map(\.cat), ["gap.hook_binary_missing"])
        XCTAssertEqual(m.evaluate(i), [])
        i.hookBinaryOK = true
        XCTAssertEqual(m.evaluate(i), [])
        XCTAssertNil(m.warnings["hookBinary"])
    }

    func testExtensionMissingAfterGrace() {
        let m = HealthMonitor()
        var i = HealthMonitor.Inputs(now: t0, hookBinaryOK: true, chromeRunning: true, extensionConnected: false)
        XCTAssertEqual(m.evaluate(i), [], "Chrome just started")
        i.now = t0 + 60_000
        XCTAssertEqual(m.evaluate(i), [])
        i.now = t0 + 121_000
        XCTAssertEqual(m.evaluate(i).map(\.cat), ["gap.extension_disconnected"])
        i.now = t0 + 200_000
        XCTAssertEqual(m.evaluate(i), [])
        i.extensionConnected = true
        i.now = t0 + 300_000
        let back = m.evaluate(i)
        XCTAssertEqual(back.map(\.cat), ["health.extension_reconnected"])
        XCTAssertEqual(back[0].payload["seconds"]?.intValue, 300)
        XCTAssertNil(m.warnings["extension"])
        // Chrome not running is not a gap.
        i.chromeRunning = false; i.extensionConnected = false; i.now = t0 + 900_000
        XCTAssertEqual(m.evaluate(i), [])
    }

    // MARK: Versions

    func testVersionCompareAndDiff() {
        XCTAssertEqual(VersionWatch.compare("2.1.316", "2.1.317"), -1)
        XCTAssertEqual(VersionWatch.compare("2.10", "2.9.9"), 1)
        XCTAssertEqual(VersionWatch.compare("1.0", "1.0.0"), 0)
        let first = VersionWatch.diff(seen: [:], now: [.init(key: "codex", name: "Codex", version: "0.167.0")])
        XCTAssertTrue(first.changes.isEmpty, "the first sighting isn't a change")
        XCTAssertEqual(first.seen, ["codex": "0.167.0"])
        let next = VersionWatch.diff(seen: first.seen, now: [.init(key: "codex", name: "Codex", version: "0.168.0")])
        XCTAssertEqual(next.changes.count, 1)
        XCTAssertEqual(next.changes[0].from, "0.167.0")
        XCTAssertEqual(next.seen["codex"], "0.168.0")
    }

    // MARK: Ledger anchor

    func testAnchorNoticesOutsideWrites() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("a.sqlite"), anchor = dir.appendingPathComponent("anchor.json")
        do {
            let s = try LedgerStore(url: db, anchorURL: anchor)
            XCTAssertEqual(s.openingCheck, .noAnchor)
            _ = try s.append([ev("a", t: t0), ev("b", t: t0 + 1)], receivedAt: t0 + 2)
            XCTAssertEqual(s.liveCheck(), .ok)
        }
        do {
            let s = try LedgerStore(url: db, anchorURL: anchor)
            XCTAssertEqual(s.openingCheck, .ok, "an untouched ledger reopens clean")
            XCTAssertNil(HealthMonitor.notice(opening: s.openingCheck!))
        }
        // Another program appends while the app is closed.
        let before = try XCTUnwrap(LedgerStore.Anchor.read(anchor))
        do {
            let other = try LedgerStore(url: db)
            _ = try other.append([ev("forged", t: t0 + 10)], receivedAt: before.at + 60_000)
        }
        let s = try LedgerStore(url: db, anchorURL: anchor)
        XCTAssertEqual(s.openingCheck, .addedOutside(count: 1, firstId: 3))
        XCTAssertNotNil(HealthMonitor.notice(opening: s.openingCheck!))
        // Reported once: the next open accepts the state.
        XCTAssertEqual(try LedgerStore(url: db, anchorURL: anchor).openingCheck, .ok)
    }

    func testAnchorNoticesRemovedEvents() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("r.sqlite"), anchor = dir.appendingPathComponent("anchor.json")
        do {
            let s = try LedgerStore(url: db, anchorURL: anchor)
            _ = try s.append([ev("a", t: t0), ev("b", t: t0 + 1)], receivedAt: t0 + 2)
        }
        // The anchor names an event that isn't in the ledger (the file was swapped for an older copy).
        let j: JSONValue = ["id": 9, "hash": "deadbeef", "at": .number(t0)]
        try j.canonicalData().write(to: anchor)
        let s = try LedgerStore(url: db, anchorURL: anchor)
        XCTAssertEqual(s.openingCheck, .removedOrChanged(anchorId: 9, lastId: 2))
        XCTAssertEqual(HealthMonitor.notice(opening: s.openingCheck!)?.cat, "gap.ledger_changed")
    }

    func testLiveCheckNoticesAnotherWriterAndAReplacedFile() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("l.sqlite"), anchor = dir.appendingPathComponent("anchor.json")
        let s = try LedgerStore(url: db, anchorURL: anchor)
        _ = try s.append([ev("a", t: t0)], receivedAt: t0)
        XCTAssertEqual(s.liveCheck(), .ok)
        let other = try LedgerStore(url: db)
        _ = try other.append([ev("forged", t: t0 + 1)], receivedAt: t0 + 1)
        XCTAssertEqual(s.liveCheck(), .tailChanged)
        s.acceptCurrentState()
        XCTAssertEqual(s.liveCheck(), .ok, "one change is reported once")

        try FileManager.default.moveItem(at: db, to: dir.appendingPathComponent("moved.sqlite"))
        FileManager.default.createFile(atPath: db.path, contents: Data())
        XCTAssertEqual(s.liveCheck(), .fileReplaced)
    }

    // MARK: Agent logs

    func write(_ lines: [JSONValue], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data()
        for l in lines { d.append(l.canonicalData()); d.append(0x0A) }
        try d.write(to: url)
    }

    func iso(_ ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    func claudeLine(_ t: Double, id: String, tool: String, input: JSONValue) -> JSONValue {
        ["type": "assistant", "timestamp": .string(iso(t)),
         "message": ["content": [["type": "text", "text": "final answer text that must never be stored"],
                                 ["type": "tool_use", "id": .string(id), "name": .string(tool), "input": input]]]]
    }

    func testClaudeLogParsingKeepsOnlyBrowserCalls() throws {
        let root = tempDir()
        let log = root.appendingPathComponent("-proj/rt-1.jsonl")
        try write([
            claudeLine(t0 + 1000, id: "a", tool: "mcp__claude-in-chrome__navigate", input: ["url": "https://example.com", "tabId": 5]),
            claudeLine(t0 + 2000, id: "b", tool: "Read", input: ["file_path": "/tmp/x"]),
            claudeLine(t0 + 3000, id: "c", tool: "Bash", input: ["command": "ls -la"]),
            claudeLine(t0 + 4000, id: "d", tool: "Bash", input: ["command": "open https://example.com/x"]),
            ["type": "user", "timestamp": .string(iso(t0 + 4500)), "message": ["content": "\"tool_use\" mentioned by the user"]],
            claudeLine(t0 + 900_000, id: "late", tool: "mcp__claude-in-chrome__navigate", input: ["url": "https://example.com"]),
        ], to: log)
        try write([claudeLine(t0 + 5000, id: "s", tool: "mcp__claude-in-chrome__find", input: ["query": "x", "tabId": 5])],
                  to: root.appendingPathComponent("-proj/rt-1/subagents/agent-1.jsonl"))

        let logs = AgentLogs.claudeLogs(runtimeSession: "rt-1", root: root)
        XCTAssertEqual(logs.count, 2)
        let calls = logs.flatMap { AgentLogs.browserCalls(agent: .claude, log: $0, from: t0, to: t0 + 60_000) }
        XCTAssertEqual(Set(calls.map(\.id)), ["a", "d", "s"])
        XCTAssertEqual(AgentLogs.claudeLogs(runtimeSession: "../etc", root: root), [], "IDs are never used as paths unless they look like IDs")
    }

    func testCodexLogParsing() throws {
        let root = tempDir()
        let log = root.appendingPathComponent("2026/11/08/rollout-2026-11-08T13-03-02-rt-9.jsonl")
        func call(_ t: Double, id: String, ns: String?, name: String, args: JSONValue) -> JSONValue {
            var p: [String: JSONValue] = ["type": "function_call", "call_id": .string(id), "name": .string(name),
                                          "arguments": .string(String(decoding: args.canonicalData(), as: UTF8.self))]
            if let ns { p["namespace"] = .string(ns) }
            return ["type": "response_item", "timestamp": .string(iso(t)), "payload": .object(p)]
        }
        try write([
            call(t0 + 1000, id: "c1", ns: "mcp__cua_repl", name: "js", args: ["code": "const t = await cua.getTab({url:'x'})", "title": "Open"]),
            call(t0 + 2000, id: "c2", ns: "mcp__cua_repl", name: "js", args: ["completion_summary": "done"]),
            call(t0 + 3000, id: "c3", ns: nil, name: "shell", args: ["command": "ls"]),
            ["type": "response_item", "timestamp": .string(iso(t0 + 3500)), "payload": ["type": "message", "content": "function_call"]],
        ], to: log)
        XCTAssertEqual(AgentLogs.codexLogs(runtimeSession: "rt-9", root: root).count, 1)
        let calls = AgentLogs.browserCalls(agent: .codex, log: log, from: t0, to: t0 + 60_000)
        XCTAssertEqual(calls.map(\.id), ["c1"])
        XCTAssertEqual(calls.first?.tool, "mcp__cua_repl__js")
    }

    func testReconcileIsPure() {
        let logged = ["a", "b", "b", "c"].map { AgentLogs.LoggedCall(id: $0, tool: "t", t: t0, input: nil) }
        let r = AgentLogs.reconcile(logged: logged, hookIds: ["a", "c", "z"], logFound: true)
        XCTAssertEqual(r.logged, 3)
        XCTAssertEqual(r.matched, 2)
        XCTAssertEqual(r.missing.map(\.id), ["b"])
        XCTAssertEqual(r.hookOnly, 1)
        XCTAssertFalse(r.complete)
        XCTAssertTrue(AgentLogs.resultText(r.payload).contains("2 of 3"))
        XCTAssertTrue(AgentLogs.trustText(AgentLogs.reconcile(logged: [], hookIds: [], logFound: false).payload).contains("wasn't found"))
    }

    func testMissedCallsAreAddedFromTheLogOnce() throws {
        let store = try LedgerStore(url: tempDir().appendingPathComponent("g.sqlite"))
        let s = SessionRecord(id: "S-1", agent: "claude-code", runtimeSession: "rt-1", state: "ended", startedAt: t0,
                              lastActivityAt: t0 + 60_000, endedAt: t0 + 60_000, taskLabel: nil, labelSource: nil,
                              startReason: "", attribution: "identified", coverage: "ok", detectorVersion: "t")
        try store.upsertSession(s)
        // The hooks reported call "a" only.
        Correlator.recordSessionEvent(store: store, session: "S-1", src: "hook.claude", kind: EventKind.attemptedOp, cat: "tool.pre",
                                      p: ["session": "rt-1", "browser": true, "toolUseId": "a", "tool": "mcp__claude-in-chrome__navigate"], at: t0 + 1000)
        let root = tempDir()
        try write([
            claudeLine(t0 + 1000, id: "a", tool: "mcp__claude-in-chrome__navigate", input: ["url": "https://example.com", "tabId": 5]),
            claudeLine(t0 + 2000, id: "b", tool: "mcp__claude-in-chrome__javascript_tool", input: ["text": "document.title", "tabId": 5]),
        ], to: root.appendingPathComponent("-proj/rt-1.jsonl"))

        let r = try XCTUnwrap(AgentLogs.run(store: store, session: "S-1", claudeRoot: root))
        XCTAssertEqual(r.logged, 2)
        XCTAssertEqual(r.missing.map(\.id), ["b"])
        var events = try store.events(forSession: "S-1")
        let added = events.filter { $0.event.cat == "tool.logged" }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].event.src, "log.claude")
        XCTAssertEqual(added[0].event.p?["tabIds"]?.arrayValue?.first?.intValue, 5)
        XCTAssertEqual(events.filter { $0.event.cat == "reconcile.result" }.count, 1)
        XCTAssertFalse(events.contains { String(decoding: ($0.event.p ?? .null).canonicalData(), as: UTF8.self).contains("final answer") },
                       "the agent's messages are never stored")

        // A second run adds nothing.
        try AgentLogs.run(store: store, session: "S-1", claudeRoot: root)
        events = try store.events(forSession: "S-1")
        XCTAssertEqual(events.filter { $0.event.cat == "tool.logged" }.count, 1)
        XCTAssertEqual(events.filter { $0.event.cat == "reconcile.result" }.count, 1)

        let report = try XCTUnwrap(SessionReport.build(store: store, session: "S-1"))
        XCTAssertTrue(report.trustLine.contains("1 of 2"))
        XCTAssertEqual(report.scripts.count, 1, "a script found only in the log still shows under Ran")

        // No log at all: said plainly, nothing invented.
        let none = try XCTUnwrap(AgentLogs.check(store: store, session: "S-1", claudeRoot: tempDir()))
        XCTAssertFalse(none.logFound)
        XCTAssertEqual(none.hookOnly, 0)
    }

    // MARK: Proof and senders

    func testProofHoldsAndCatchesEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LedgerStore(url: dir.appendingPathComponent("l.sqlite"))
        func ev(_ cat: String, _ url: String?) -> LedgerEvent {
            LedgerEvent(src: "ext.sw", inst: "i", t: 1000, kind: EventKind.context, cat: cat, tab: 5, url: url, p: ["a": "b\u{1f}c"])
        }
        let ids = try store.append([ev("nav.committed", "https://a.test/"), ev("other", nil), ev("ui.click", "https://a.test/x")])
        try store.upsertSession(SessionRecord(id: "S", agent: "claude-code", runtimeSession: nil, state: "ended", startedAt: 0,
                                              lastActivityAt: 0, endedAt: 1, taskLabel: nil, labelSource: nil, startReason: "",
                                              attribution: "identified", coverage: "ok", detectorVersion: "t"))
        try store.link(session: "S", eventIds: [ids[0], ids[2]])
        let data = try XCTUnwrap(Proof.bundle(store: store, session: "S"))
        let ok = Proof.verify(data)
        XCTAssertTrue(ok.ok, ok.problem ?? "")
        XCTAssertEqual([ok.events, ok.others], [2, 1])

        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "https://a.test/x", with: "https://a.test/y")
        let edited = Proof.verify(Data(text.utf8))
        XCTAssertFalse(edited.ok)
        XCTAssertEqual(edited.firstBadId, ids[2])

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        lines.remove(at: 2)
        XCTAssertFalse(Proof.verify(Data(lines.joined(separator: "\n").utf8)).ok, "a removed event breaks the next hash")
        XCTAssertNil(try Proof.bundle(store: store, session: "nope"))
    }

    func testSenderCheck() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/AgentLedger")
        XCTAssertTrue(SenderCheck.isKnown(path: "/Users/x/Library/Application Support/AgentLedger/bin/ledger-hook", supportDir: support))
        XCTAssertTrue(SenderCheck.isKnown(path: "/Applications/Agent Ledger.app/Contents/Helpers/ledger-host", supportDir: support))
        XCTAssertFalse(SenderCheck.isKnown(path: "/usr/bin/python3", supportDir: support))
        XCTAssertFalse(SenderCheck.isKnown(path: "/tmp/ledger-hook", supportDir: support))
        XCTAssertFalse(SenderCheck.isKnown(path: nil, supportDir: support))
    }
}
