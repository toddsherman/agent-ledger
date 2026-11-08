import Foundation

public struct InstallReport: Sendable, Equatable {
    public var path: String
    public var backup: String?
    public var changed: Bool
    public var message: String
}

/// Adds and removes Agent Ledger's logging-only hooks without disturbing other hooks.
///
/// Entries are appended after existing ones (Codex records trust per hook position, so
/// existing positions must not move) and identified later by the `ledger-hook` command.
public enum HookInstaller {
    public static let marker = "ledger-hook"

    public static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    public static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(hookBinary: String, agent: HookAgent) -> String {
        "\(shellQuote(hookBinary)) --agent \(agent.rawValue)"
    }

    /// (event, matcher, timeout) entries to add per agent.
    static func plan(for agent: HookAgent) -> [(event: String, matcher: String?, timeout: Int)] {
        switch agent {
        case .claude:
            let browser = "mcp__.*claude-in-chrome.*"
            return [("PreToolUse", browser, 10), ("PostToolUse", browser, 10), ("PostToolUseFailure", browser, 10),
                    ("UserPromptSubmit", nil, 10), ("Stop", nil, 10), ("SessionStart", nil, 10), ("SessionEnd", nil, 10)]
        case .codex:
            return [("PreToolUse", nil, 10), ("PostToolUse", nil, 10), ("UserPromptSubmit", nil, 10), ("Stop", nil, 10),
                    ("SessionStart", nil, 10), ("SessionEnd", nil, 3), ("Interrupt", nil, 3)]
        }
    }

    static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a JSON object"])
        }
        return obj
    }

    static func write(_ obj: [String: Any], to url: URL) throws -> String? {
        let fm = FileManager.default
        var backup: String?
        if fm.fileExists(atPath: url.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let stem = url.path + ".agentledger-backup-" + f.string(from: Date())
            var b = stem
            var n = 1
            while fm.fileExists(atPath: b) { n += 1; b = "\(stem)-\(n)" }
            try fm.copyItem(atPath: url.path, toPath: b)
            backup = b
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return backup
    }

    static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    public static func isInstalled(agent: HookAgent, url: URL? = nil) -> Bool {
        let u = url ?? (agent == .claude ? claudeSettingsURL : codexHooksURL)
        guard let obj = try? load(u), let hooks = obj["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]])?.contains { ($0["hooks"] as? [Any])?.contains(where: isOurs) ?? false } ?? false
        }
    }

    @discardableResult
    public static func install(agent: HookAgent, hookBinary: String, url: URL? = nil) throws -> InstallReport {
        let u = url ?? (agent == .claude ? claudeSettingsURL : codexHooksURL)
        var obj = try load(u)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        // Replace any previous Agent Ledger entries (e.g. after the app moved).
        hooks = strip(hooks)
        let cmd = command(hookBinary: hookBinary, agent: agent)
        for item in plan(for: agent) {
            var groups = hooks[item.event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["type": "command", "command": cmd, "timeout": item.timeout, "async": true]
            // Codex always runs SessionEnd/Interrupt synchronously and reports "async" there as an
            // error; the hook takes milliseconds, so run those synchronously.
            if agent == .codex && (item.event == "SessionEnd" || item.event == "Interrupt") { entry["async"] = nil }
            var group: [String: Any] = ["hooks": [entry]]
            if let m = item.matcher { group["matcher"] = m }
            groups.append(group)
            hooks[item.event] = groups
        }
        obj["hooks"] = hooks
        let backup = try write(obj, to: u)
        return InstallReport(path: u.path, backup: backup, changed: true,
                             message: "Added \(plan(for: agent).count) logging-only hooks for \(agent.agentName)")
    }

    static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                if let hs = g["hooks"] as? [Any] {
                    let filtered = hs.filter { !isOurs($0) }
                    if filtered.isEmpty && !hs.isEmpty { continue }
                    g["hooks"] = filtered
                }
                kept.append(g)
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    @discardableResult
    public static func uninstall(agent: HookAgent, url: URL? = nil) throws -> InstallReport {
        let u = url ?? (agent == .claude ? claudeSettingsURL : codexHooksURL)
        guard isInstalled(agent: agent, url: u) else {
            return InstallReport(path: u.path, backup: nil, changed: false, message: "No Agent Ledger hooks found")
        }
        var obj = try load(u)
        obj["hooks"] = strip(obj["hooks"] as? [String: Any] ?? [:])
        let backup = try write(obj, to: u)
        return InstallReport(path: u.path, backup: backup, changed: true, message: "Removed Agent Ledger hooks")
    }
}

/// Registers `ledger-host` as Chrome's native messaging host for the extension.
public enum NativeHostInstaller {
    public static var manifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(LedgerPaths.nativeHostName).json")
    }

    public static func manifest(hostBinary: String, extensionIDs: [String] = LedgerPaths.extensionIDs) -> [String: Any] {
        ["name": LedgerPaths.nativeHostName,
         "description": "Agent Ledger native host",
         "path": hostBinary,
         "type": "stdio",
         "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }]
    }

    /// True when the registered manifest is missing, points at another binary, or lacks an ID.
    public static func needsUpdate(hostBinary: String, url: URL = manifestURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        let origins = Set(obj["allowed_origins"] as? [String] ?? [])
        let wanted = Set(LedgerPaths.extensionIDs.map { "chrome-extension://\($0)/" })
        return obj["path"] as? String != hostBinary || !wanted.isSubset(of: origins)
    }

    /// Chrome's per-user data folder exists (Chrome has been run).
    public static var chromeInstalled: Bool {
        FileManager.default.fileExists(atPath: manifestURL.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    public static func installedPath(url: URL = manifestURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["path"] as? String
    }

    @discardableResult
    public static func install(hostBinary: String, url: URL = manifestURL) throws -> InstallReport {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest(hostBinary: hostBinary),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return InstallReport(path: url.path, backup: nil, changed: true,
                             message: "Registered native host. Restart Chrome if the extension was already loaded.")
    }

    @discardableResult
    public static func uninstall(url: URL = manifestURL) throws -> InstallReport {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        return InstallReport(path: url.path, backup: nil, changed: true, message: "Removed native host registration")
    }
}
