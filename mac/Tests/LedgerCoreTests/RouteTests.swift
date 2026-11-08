import XCTest
@testable import LedgerCore

final class ShellAnalyzerTests: XCTestCase {
    func kinds(_ cmd: String) -> [String] { ShellAnalyzer.analyze(cmd).kinds }

    func testCommandsThatReachChrome() {
        XCTAssertEqual(kinds("open http://localhost:4399/cms"), ["open-url"])
        XCTAssertEqual(ShellAnalyzer.analyze("open 'https://example.com/a?token=abc123def456ghi'").urls.count, 1)
        XCTAssertEqual(kinds("open -a \"Google Chrome\" --args --remote-debugging-port=9222"), ["open-url", "remote-debugging"])
        XCTAssertEqual(kinds("osascript -e 'tell application \"Google Chrome\" to get URL of active tab of front window'"),
                       ["applescript"])
        XCTAssertEqual(kinds("osascript <<EOF\ntell application \"Google Chrome\"\n execute front window's active tab javascript \"1\"\nend tell\nEOF"),
                       ["applescript"])
        let launch = ShellAnalyzer.analyze("\"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\" --user-data-dir=/tmp/p --remote-debugging-port=9333 --headless=new about:blank &")
        XCTAssertEqual(launch.kinds, ["launch-chrome", "remote-debugging"])
        XCTAssertEqual(launch.flags, ["user-data-dir", "remote-debugging", "headless"])
        XCTAssertEqual(kinds("cd app && npx playwright test"), ["automation-tool"])
        XCTAssertEqual(kinds("curl -s http://127.0.0.1:9222/json/version"), ["remote-debugging"])
        XCTAssertEqual(kinds("sqlite3 ~/Library/Application\\ Support/Google/Chrome/Default/History 'select url from urls'"),
                       ["profile-data"])
        XCTAssertEqual(kinds("B=\"$HOME/Library/Application Support/Google/Chrome\"; ls \"$B\""), ["profile-data"])
        XCTAssertEqual(kinds("sudo -u me env FOO=1 chrome-cli list tabs"), ["chrome-cli"])
    }

    func testCommandsThatDont() {
        XCTAssertEqual(kinds("cd \"/Volumes/RAID4/Projects/chrome extension\" && git status"), [])
        XCTAssertEqual(kinds("grep -rn osascript . | grep 'Google Chrome'"), [])
        XCTAssertEqual(kinds("echo \"open https://example.com\""), [])
        XCTAssertEqual(kinds("git commit -m \"Open https://x.test in Chrome\""), [])
        XCTAssertEqual(kinds("open -a Safari https://example.com"), [])
        XCTAssertEqual(kinds("osascript -e 'tell application \"Finder\" to activate'"), [])
        XCTAssertEqual(kinds("node scripts/e2e/check.mjs --since -10m"), [])
        XCTAssertEqual(kinds("pgrep -x \"Google Chrome\""), [])
        XCTAssertEqual(kinds("ls ~/secret"), [])
        XCTAssertEqual(kinds("echo --remote-debugging-port=9222 --user-data-dir=/x"), [])
    }

    func testHeredocBodiesAreDataNotCommands() {
        // Live 2026-11-08: a Python edit whose heredoc held docs about `--remote-debugging-port`
        // and `open <url>` was recorded as reaching Chrome.
        let edit = """
        cd "/Volumes/RAID4/Projects/chrome extension" && python3 -I - <<'EOF'
        s = '''| Shell: `open <url>`, then a headless Chrome with `--user-data-dir` and `--remote-debugging-port` |
        open https://example.com
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless
        '''
        EOF
        echo done
        """
        XCTAssertEqual(kinds(edit), [])
        let script = "osascript <<'APPLE'\ntell application \"Google Chrome\" to get URL of active tab of front window\nAPPLE"
        XCTAssertEqual(kinds(script), ["applescript"])
        XCTAssertEqual(kinds("cat <<<\"open https://x.test\""), [])
    }
}

final class RouteTranslatorTests: XCTestCase {
    func json(_ v: JSONValue) -> Data { v.canonicalData() }

    func pre(_ tool: String, _ input: JSONValue, agent: HookAgent = .claude) -> LedgerEvent? {
        HookTranslator.translate(stdin: json(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": .string(tool),
                                              "tool_use_id": "t", "tool_input": input]), agent: agent, now: 1)
    }

    func testShellCommandReachingChromeIsKept() {
        let e = pre("Bash", ["command": "open http://localhost:4399/cms", "description": "Open the CMS"])!
        XCTAssertEqual(e.p?["browser"]?.boolValue, true)
        XCTAssertEqual(e.p?["route"]?.stringValue, "shell")
        XCTAssertEqual(e.p?["routeKinds"]?.arrayValue?.compactMap { $0.stringValue }, ["open-url"])
        XCTAssertEqual(e.p?["input"]?["command"]?.stringValue, "open http://localhost:4399/cms")
        XCTAssertNil(e.p?["input"]?["description"])
    }

    func testOtherShellCommandsKeepNothing() {
        let e = pre("Bash", ["command": "cat ~/notes.txt"])!
        XCTAssertEqual(e.p?["browser"]?.boolValue, false)
        XCTAssertNil(e.p?["route"])
        XCTAssertNil(e.p?["input"])
    }

    func testShellOutputIsNotKept() {
        let post: JSONValue = ["hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Bash", "tool_use_id": "t",
                               "tool_input": ["command": "sqlite3 ~/Library/Application\\ Support/Google/Chrome/Default/Cookies .dump"],
                               "tool_response": ["stdout": "secret-cookie-value-123", "stderr": ""]]
        let e = HookTranslator.translate(stdin: json(post), agent: .claude, now: 1)!
        XCTAssertEqual(e.p?["route"]?.stringValue, "shell")
        XCTAssertFalse(e.p!.canonicalString().contains("secret-cookie"))
        XCTAssertEqual(e.p?["result"]?["textLength"]?.intValue, 23)
    }

    func testCodexShellArrayCommand() {
        let e = pre("shell", ["command": ["bash", "-lc", "open https://example.com"]], agent: .codex)!
        XCTAssertEqual(e.p?["route"]?.stringValue, "shell")
        let quiet = pre("shell", ["command": ["bash", "-lc", "grep -r playwright src"]], agent: .codex)!
        XCTAssertEqual(quiet.p?["browser"]?.boolValue, false)
    }

    func testAutomationTool() {
        let e = pre("mcp__playwright__browser_navigate", ["url": "https://example.com"])!
        XCTAssertEqual(e.p?["route"]?.stringValue, "automation")
        XCTAssertEqual(e.p?["browser"]?.boolValue, true)
        XCTAssertEqual(e.p?["input"]?["url"]?.stringValue, "https://example.com")
    }

    func testComputerUse() {
        let chrome = pre("mcp__computer-use__app_screenshot", ["app": "Google Chrome"])!
        XCTAssertEqual(chrome.p?["browser"]?.boolValue, true)
        XCTAssertEqual(chrome.p?["route"]?.stringValue, "computer-use")
        let other = pre("mcp__computer-use__app_type", ["app": "Notes", "text": "my diary"])!
        XCTAssertEqual(other.p?["browser"]?.boolValue, false)
        XCTAssertNil(other.p?["route"])
        XCTAssertFalse(other.p!.canonicalString().contains("diary"))
        let screen = pre("mcp__computer-use__screenshot", ["action": "screenshot"])!
        XCTAssertEqual(screen.p?["browser"]?.boolValue, false)
        XCTAssertEqual(screen.p?["route"]?.stringValue, "computer-use")
        XCTAssertEqual(screen.p?["chromeTarget"], .null)
        let typed = pre("mcp__computer-use__type", ["text": "hunter2"])!
        XCTAssertEqual(typed.p?["input"]?["textLength"]?.intValue, 7)
        XCTAssertFalse(typed.p!.canonicalString().contains("hunter2"))
    }

    func testClaudeInChromeStillExtension() {
        let e = pre("mcp__claude-in-chrome__navigate", ["url": "https://a.test", "tabId": 4])!
        XCTAssertEqual(e.p?["route"]?.stringValue, "extension")
        XCTAssertEqual(e.tab, 4)
    }
}

final class RouteInstallerTests: XCTestCase {
    func testClaudeMatcherCoversRoutes() throws {
        let m = try NSRegularExpression(pattern: HookInstaller.claudeMatcher)
        func matches(_ s: String) -> Bool { m.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }
        for yes in ["Bash", "mcp__claude-in-chrome__computer", "mcp__playwright__browser_click", "mcp__chrome-devtools__navigate_page",
                    "mcp__computer-use__screenshot", "mcp__Claude_Browser__navigate"] {
            XCTAssertTrue(matches(yes), yes)
        }
        for no in ["Read", "Edit", "Write", "mcp__github__create_issue", "BashOutput"] { XCTAssertFalse(matches(no), no) }
    }

    func testOldInstallNeedsUpgrade() throws {
        let url = tempDir().appendingPathComponent("settings.json")
        let old: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "mcp__.*claude-in-chrome.*",
                                                            "hooks": [["type": "command", "command": "'/x/ledger-hook' --agent claude"]]]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        XCTAssertTrue(HookInstaller.needsUpgrade(agent: .claude, url: url))
        try HookInstaller.install(agent: .claude, hookBinary: "/x/ledger-hook", url: url)
        XCTAssertFalse(HookInstaller.needsUpgrade(agent: .claude, url: url))
    }
}

final class BrowserProcessTests: XCTestCase {
    func snap(_ pid: Int32, _ ppid: Int32, _ path: String, _ args: [String] = []) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, ppid: ppid, startedAt: 1, path: path, args: args)
    }

    func testAgentStartedChrome() throws {
        let chrome = snap(900, 800, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                          ["--user-data-dir=/tmp/pw", "--remote-debugging-port=9333", "--enable-automation", "about:blank"])
        let ancestors = [snap(800, 700, "/opt/homebrew/bin/node"),
                         snap(700, 600, "/Users/x/Library/Application Support/Claude/claude-code/2.1.317/a/claude.app/Contents/MacOS/claude")]
        let info = try XCTUnwrap(BrowserProcesses.classify(chrome, ancestors: ancestors))
        XCTAssertEqual(info.agent, "claude-code")
        XCTAssertEqual(info.agentPid, 700)
        XCTAssertEqual(info.remoteDebugging, "port 9333")
        XCTAssertTrue(info.automation)
        XCTAssertFalse(info.isEveryday)
        XCTAssertTrue(info.isNotable)
    }

    func testEverydayChromeAndHelpers() throws {
        let everyday = try XCTUnwrap(BrowserProcesses.classify(snap(10, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), ancestors: []))
        XCTAssertTrue(everyday.isEveryday)
        XCTAssertFalse(everyday.isNotable)
        XCTAssertNil(BrowserProcesses.classify(snap(11, 10, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                                                    ["--type=renderer"]), ancestors: []))
        let playwright = snap(12, 5, "/Users/x/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
                              ["--remote-debugging-pipe", "--headless"])
        let info = try XCTUnwrap(BrowserProcesses.classify(playwright, ancestors: [snap(5, 1, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")]))
        XCTAssertEqual(info.agent, "codex")
        XCTAssertEqual(info.remoteDebugging, "pipe")
    }
}

final class RouteCorrelatorTests: XCTestCase {
    var store: LedgerStore!
    var c: Correlator!

    override func setUp() {
        store = try! LedgerStore(url: tempDir().appendingPathComponent("r.sqlite"))
        c = Correlator(store: store)
    }

    func hook(_ cat: String, t: Double, tool: String, route: String?, browser: Bool, extra: [String: JSONValue] = [:],
              id: String = "toolu_9", agent: HookAgent = .claude) -> LedgerEvent {
        var p: [String: JSONValue] = ["agent": .string(agent.agentName), "session": "sess-R", "tool": .string(tool),
                                      "toolUseId": .string(id), "browser": .bool(browser), "agentPid": 700]
        if let route { p["route"] = .string(route) }
        for (k, v) in extra { p[k] = v }
        return LedgerEvent(src: agent.src, t: t, kind: cat == "tool.pre" ? EventKind.attemptedOp : EventKind.runtimeReport,
                           cat: cat, p: .object(p))
    }

    func testShellOpenURLStartsSessionAndBindsTheNewTab() throws {
        let t0 = 2_000_000.0
        let extra: [String: JSONValue] = ["routeKinds": ["open-url"], "urls": ["http://localhost:4399/cms"],
                                          "input": ["command": "open http://localhost:4399/cms"]]
        c.ingest([hook("tool.pre", t: t0, tool: "Bash", route: "shell", browser: true, extra: extra)])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertTrue(s.startReason.contains("shell command that reaches Chrome (opened a URL)"), s.startReason)
        c.ingest([hook("tool.post", t: t0 + 150, tool: "Bash", route: "shell", browser: true, extra: extra)])
        c.ingest([LedgerEvent(src: "ext.sw", inst: "sw", seq: 1, t: t0 + 600, kind: EventKind.context, cat: "tab.created", tab: 77,
                              url: "http://localhost:4399/cms", p: [:])])
        let tabs = try store.sessionTabs(session: s.id)
        XCTAssertEqual(tabs.map { $0.tab }, [77])
        XCTAssertTrue(tabs[0].evidence?.contains("ran a shell command") == true, tabs[0].evidence ?? "")
        c.ingest([LedgerEvent(src: "ext.sw", inst: "sw", seq: 2, t: t0 + 900, kind: EventKind.observedEffect, cat: "nav.committed",
                              tab: 77, frame: 0, url: "http://localhost:4399/cms", p: ["transition": "link"])], receivedAt: t0 + 900)
        c.resolveAttributions(now: t0 + 10_000, force: true)
        let atts = try store.latestAttributions(session: s.id)
        let nav = try XCTUnwrap(atts.values.first)
        XCTAssertEqual(nav.actor, "agent:claude-code")
        XCTAssertEqual(nav.label, "likely")
        XCTAssertTrue(nav.reasons.joined().contains("ran a shell command"), nav.reasons.joined())
    }

    func testTypingElsewhereBeforeAnAgentBringsChromeForwardIsNotYou() throws {
        // Live run 2026-11-08: Codex ran `open <url>` and then started a separate Chrome; a key
        // press in another app just before Chrome came forward made the navigation "Mixed".
        let t0 = 2_500_000.0
        let open: [String: JSONValue] = ["routeKinds": ["open-url"], "input": ["command": "open http://localhost:4399/diagnostic"]]
        let launch: [String: JSONValue] = ["routeKinds": ["launch-chrome", "remote-debugging"], "flags": ["user-data-dir"],
                                           "input": ["command": "Google Chrome --user-data-dir=/tmp/x"]]
        c.noteFrontmost(bundleId: "com.apple.Terminal", at: t0 - 10_000)
        c.ingest([hook("tool.pre", t: t0, tool: "Bash", route: "shell", browser: true, extra: open, id: "a", agent: .codex),
                  hook("tool.post", t: t0 + 150, tool: "Bash", route: "shell", browser: true, extra: open, id: "a", agent: .codex),
                  hook("tool.pre", t: t0 + 300, tool: "Bash", route: "shell", browser: true, extra: launch, id: "b", agent: .codex)])
        c.noteHumanInput(.keyDown, at: t0 + 450)
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 + 550)
        c.ingest([LedgerEvent(src: "ext.sw", inst: "sw", seq: 1, t: t0 + 600, kind: EventKind.context, cat: "tab.created", tab: 88,
                              url: "http://localhost:4399/diagnostic", p: [:]),
                  LedgerEvent(src: "ext.sw", inst: "sw", seq: 2, t: t0 + 850, kind: EventKind.observedEffect, cat: "nav.committed",
                              tab: 88, frame: 0, url: "http://localhost:4399/diagnostic", p: ["transition": "start_page"])],
                 receivedAt: t0 + 850)
        c.resolveAttributions(now: t0 + 10_000, force: true)
        let s = try XCTUnwrap(store.sessions().first)
        let nav = try XCTUnwrap(store.latestAttributions(session: s.id).values.first)
        XCTAssertEqual(nav.actor, "agent:codex")
        XCTAssertEqual(nav.label, "likely")
        XCTAssertTrue(nav.reasons.joined().contains("opened a URL"), nav.reasons.joined())
    }

    func testWholeScreenComputerUseCountsOnlyWhenChromeIsInFront() throws {
        let t0 = 3_000_000.0
        let input: [String: JSONValue] = ["input": ["action": "screenshot"], "chromeTarget": .null]
        c.noteFrontmost(bundleId: "com.apple.finder", at: t0 - 5000)
        c.ingest([hook("tool.pre", t: t0, tool: "mcp__computer-use__screenshot", route: "computer-use", browser: false, extra: input)])
        XCTAssertEqual(try store.sessions().count, 0)
        XCTAssertEqual(try store.eventCount(), 0)
        c.noteFrontmost(bundleId: "com.google.Chrome", at: t0 + 1000)
        c.ingest([hook("tool.pre", t: t0 + 2000, tool: "mcp__computer-use__screenshot", route: "computer-use", browser: false,
                       extra: input, id: "toolu_10")])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertTrue(s.startReason.contains("computer use on Chrome (screenshot)"), s.startReason)
        let pre = try store.events(forSession: s.id).first { $0.event.cat == "tool.pre" }
        XCTAssertEqual(pre?.event.p?["chromeBy"]?.stringValue, "Chrome was the frontmost app")
    }

    func testAgentStartedBrowserJoinsTheRuntimeSession() throws {
        let t0 = 4_000_000.0
        c.ingest([hook("tool.pre", t: t0, tool: "mcp__playwright__browser_navigate", route: "automation", browser: true,
                       extra: ["input": ["url": "https://example.com"]])])
        let s = try XCTUnwrap(store.sessions().first)
        let started = LedgerEvent(src: "mac.sensor", t: t0 + 800, kind: EventKind.context, cat: "browser.started",
                                  p: ["pid": 900, "app": "Chromium", "agent": "claude-code", "agentPid": 700,
                                      "ancestorPids": [800, 700], "remoteDebugging": "pipe", "everyday": false])
        c.ingest([started])
        XCTAssertEqual(try store.sessions().count, 1)
        let cats = try store.events(forSession: s.id).map { $0.event.cat }
        XCTAssertTrue(cats.contains("browser.started"))
        XCTAssertEqual(c.status(now: t0 + 900).agentBrowsers.count, 1)
        c.ingest([LedgerEvent(src: "mac.sensor", t: t0 + 5000, kind: EventKind.context, cat: "browser.stopped",
                              p: ["pid": 900, "app": "Chromium"])])
        XCTAssertTrue(try store.events(forSession: s.id).contains { $0.event.cat == "browser.stopped" })
        XCTAssertEqual(c.status(now: t0 + 6000).agentBrowsers.count, 0)
    }

    func testNestedAgentsCreditTheNearestOne() throws {
        // Live run 2026-11-08: Codex, started from a Claude Code shell, started Chrome; the outer
        // Claude Code runtime (pid 1883) was credited at first.
        let t0 = 4_500_000.0
        var outer = hook("turn.prompt", t: t0 - 60_000, tool: "", route: nil, browser: false)
        outer.p = ["agent": "claude-code", "session": "outer", "agentPid": 1883, "prompt": "work"]
        c.ingest([outer, hook("tool.pre", t: t0, tool: "Bash", route: "shell", browser: true,
                              extra: ["routeKinds": ["launch-chrome"], "flags": ["user-data-dir"], "agentPid": 46992], agent: .codex)])
        let codexSession = try XCTUnwrap(store.sessions().first)
        c.ingest([LedgerEvent(src: "mac.sensor", t: t0 + 300, kind: EventKind.context, cat: "browser.started",
                              p: ["pid": 47032, "app": "Google Chrome", "agent": "codex", "agentPid": 46992,
                                  "ancestorPids": [47031, 46992, 46990, 46988, 1883], "everyday": false])])
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertTrue(try store.events(forSession: codexSession.id).contains { $0.event.cat == "browser.started" })
    }

    func testAgentStartedBrowserWithoutHooksStartsLikelySession() throws {
        let started = LedgerEvent(src: "mac.sensor", t: 5_000_000, kind: EventKind.context, cat: "browser.started",
                                  p: ["pid": 901, "app": "Google Chrome", "agent": "codex", "ancestorPids": [55],
                                      "userDataDir": "/tmp/x", "everyday": false])
        c.ingest([started])
        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(s.attribution, "likely")
        XCTAssertTrue(s.startReason.contains("Codex started a separate Google Chrome"), s.startReason)
    }

    func testNonBrowserShellLeavesNoTrace() throws {
        c.ingest([hook("tool.pre", t: 6_000_000, tool: "Bash", route: nil, browser: false)])
        XCTAssertEqual(try store.sessions().count, 0)
        XCTAssertEqual(try store.eventCount(), 0)
    }
}
