import XCTest
@testable import LedgerCore

final class InstallerTests: XCTestCase {
    func testInstallAppendsAfterExistingHooksAndUninstallRestores() throws {
        let url = tempDir().appendingPathComponent("hooks.json")
        let original: [String: Any] = [
            "env": ["X": "1"],
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "orca-hook.sh", "timeout": 10]]]],
                "Stop": [["hooks": [["type": "command", "command": "orca-hook.sh"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let r = try HookInstaller.install(agent: .codex, hookBinary: "/Users/x/Library/Application Support/AgentLedger/bin/ledger-hook", url: url)
        XCTAssertNotNil(r.backup)
        XCTAssertTrue(HookInstaller.isInstalled(agent: .codex, url: url))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let pre = (after["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(((pre[0]["hooks"] as! [[String: Any]])[0]["command"] as! String), "orca-hook.sh", "existing hook keeps position 0")
        let ours = (pre[1]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(ours["async"] as? Bool, true)
        XCTAssertEqual(ours["command"] as? String, "'/Users/x/Library/Application Support/AgentLedger/bin/ledger-hook' --agent codex")
        // Reinstall does not duplicate.
        try HookInstaller.install(agent: .codex, hookBinary: "/tmp/ledger-hook", url: url)
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(((again["hooks"] as! [String: Any])["PreToolUse"] as! [Any]).count, 2)
        try HookInstaller.uninstall(agent: .codex, url: url)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
        XCTAssertEqual(restored, original as NSDictionary)
        for b in try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) where b.contains("backup") {
            XCTAssertTrue(b.hasPrefix("hooks.json.agentledger-backup-"))
        }
    }

    func testClaudeMatchersTargetBrowserTools() throws {
        let url = tempDir().appendingPathComponent("settings.json")
        try HookInstaller.install(agent: .claude, hookBinary: "/b/ledger-hook", url: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = obj["hooks"] as! [String: Any]
        let pre = (hooks["PreToolUse"] as! [[String: Any]])[0]
        let matcher = try NSRegularExpression(pattern: pre["matcher"] as! String)
        let name = "mcp__claude-in-chrome__computer"
        XCTAssertNotNil(matcher.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)))
        XCTAssertNil((hooks["UserPromptSubmit"] as! [[String: Any]])[0]["matcher"])
    }
}

final class NativeHostInstallerTests: XCTestCase {
    func testNeedsUpdateWhenPathOrOriginsDiffer() throws {
        let url = tempDir().appendingPathComponent("com.agentledger.host.json")
        XCTAssertTrue(NativeHostInstaller.needsUpdate(hostBinary: "/a/ledger-host", url: url))
        try NativeHostInstaller.install(hostBinary: "/a/ledger-host", url: url)
        XCTAssertFalse(NativeHostInstaller.needsUpdate(hostBinary: "/a/ledger-host", url: url))
        XCTAssertTrue(NativeHostInstaller.needsUpdate(hostBinary: "/b/ledger-host", url: url))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["allowed_origins"] as? [String], LedgerPaths.extensionIDs.map { "chrome-extension://\($0)/" })
    }
}
