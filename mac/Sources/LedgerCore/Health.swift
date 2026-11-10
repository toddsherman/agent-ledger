import Foundation

/// Wording shared by the menu, notifications and the timeline.
public enum HealthText {
    public static func stopReason(_ r: String?) -> String {
        switch r {
        case "quit": return "you quit it"
        case "restart": return "the Mac restarted or was off"
        case "update": return "it was updated"
        default: return "it stopped unexpectedly"
        }
    }
}

/// One thing the recorder wants on the record, and perhaps in front of you.
public struct HealthNotice: Equatable, Sendable {
    public var kind: String
    public var cat: String
    public var payload: JSONValue
    public var title: String
    public var body: String
    /// Post a notification (when alert notices are on).
    public var notify: Bool
    /// Marks the live sessions as having gaps.
    public var degrade: Bool

    public init(kind: String = EventKind.gap, cat: String, payload: JSONValue = .object([:]), title: String,
                body: String, notify: Bool = true, degrade: Bool = true) {
        self.kind = kind; self.cat = cat; self.payload = payload; self.title = title; self.body = body
        self.notify = notify; self.degrade = degrade
    }
}

/// Why the recorder wasn't running, decided at launch from what the last run left behind.
public enum RecorderStop {
    public struct Finding: Equatable, Sendable {
        public var from: Double
        public var to: Double
        /// `quit`, `restart`, `update`, `unexpected`.
        public var reason: String
        public var seconds: Double { max(0, (to - from) / 1000) }
        public var unexpected: Bool { reason == "unexpected" }
    }

    /// - lastHeartbeat: when the previous run last wrote its status file (it writes every 2 s).
    /// - quitMarkerAt: when you chose Quit, if you did.
    /// - binaryChangedAt: when the app's program file last changed (an update or reinstall).
    /// Stops shorter than `minMs` aren't worth a record.
    public static func decide(lastHeartbeat: Double?, quitMarkerAt: Double?, bootAt: Double, binaryChangedAt: Double?,
                              lastVersion: String?, version: String, now: Double, minMs: Double = 10_000) -> Finding? {
        guard let hb = lastHeartbeat, hb > 0, now - hb >= minMs else { return nil }
        let reason: String
        if let q = quitMarkerAt, q >= hb - 5000 { reason = "quit" }
        else if let v = lastVersion, v != version { reason = "update" }
        else if let b = binaryChangedAt, b > hb - 60_000 { reason = "update" }
        else if bootAt > hb { reason = "restart" }
        else { reason = "unexpected" }
        return Finding(from: hb, to: now, reason: reason)
    }

    public static func notice(_ f: Finding) -> HealthNotice {
        let span = EventFormatter.span(Int(f.seconds))
        return HealthNotice(cat: "gap.recorder_stopped",
                            payload: ["from": .number(f.from), "to": .number(f.to), "seconds": .number(f.seconds.rounded()),
                                      "reason": .string(f.reason)],
                            title: "Agent Ledger wasn't recording",
                            body: "The recorder was off for \(span): \(HealthText.stopReason(f.reason)). Anything agents did in Chrome in that time isn't in the ledger.",
                            notify: f.unexpected)
    }
}

/// Watches the pieces the recorder depends on and reports each change once.
/// Pure: the app passes in what it sampled, so the rules can be tested.
public final class HealthMonitor {
    public struct Inputs: Sendable {
        public var now: Double
        /// Per agent (`claude-code`, `codex`): hooks were installed by you, and are in place now.
        public var hooksExpected: [String: Bool]
        public var hooksPresent: [String: Bool]
        public var hookBinaryOK: Bool
        public var chromeRunning: Bool
        public var extensionConnected: Bool
        public init(now: Double, hooksExpected: [String: Bool] = [:], hooksPresent: [String: Bool] = [:],
                    hookBinaryOK: Bool = true, chromeRunning: Bool = false, extensionConnected: Bool = false) {
            self.now = now; self.hooksExpected = hooksExpected; self.hooksPresent = hooksPresent
            self.hookBinaryOK = hookBinaryOK; self.chromeRunning = chromeRunning; self.extensionConnected = extensionConnected
        }
    }

    /// How long Chrome may run without the extension before it counts as a gap.
    public var extensionGraceMs = 120_000.0

    /// Standing problems, keyed so the menu can list them: key → text.
    public private(set) var warnings: [String: String] = [:]
    private var hooksMissing: Set<String> = []
    private var binaryMissing = false
    private var extensionDownSince: Double?
    private var extensionReported = false

    public init() {}

    public func setWarning(_ key: String, _ text: String?) { warnings[key] = text }

    public func evaluate(_ i: Inputs) -> [HealthNotice] {
        var out: [HealthNotice] = []
        for agent in i.hooksExpected.keys.sorted() where i.hooksExpected[agent] == true {
            let name = Correlator.displayAgent(agent)
            let present = i.hooksPresent[agent] ?? false
            if !present, !hooksMissing.contains(agent) {
                hooksMissing.insert(agent)
                warnings["hooks." + agent] = "\(name) hooks were removed or changed. Reinstall them in Settings."
                out.append(HealthNotice(cat: "gap.hooks_removed", payload: ["agent": .string(agent)],
                                        title: "\(name) hooks are gone",
                                        body: "Something removed or changed the hooks that report \(name)'s browser use. Its sessions won't be identified until you reinstall them in Settings."))
            } else if present, hooksMissing.contains(agent) {
                hooksMissing.remove(agent)
                warnings["hooks." + agent] = nil
                out.append(HealthNotice(kind: EventKind.sensorHealth, cat: "health.hooks_restored",
                                        payload: ["agent": .string(agent)], title: "", body: "", notify: false, degrade: false))
            }
        }
        for agent in hooksMissing where i.hooksExpected[agent] != true {
            hooksMissing.remove(agent); warnings["hooks." + agent] = nil
        }
        let anyHooks = i.hooksExpected.values.contains(true)
        if anyHooks, !i.hookBinaryOK, !binaryMissing {
            binaryMissing = true
            warnings["hookBinary"] = "The hook program is missing. Relaunch Agent Ledger to restore it."
            out.append(HealthNotice(cat: "gap.hook_binary_missing", title: "Agent Ledger's hook program is missing",
                                    body: "Agents can't report browser use until it's restored. Relaunching Agent Ledger puts it back."))
        } else if i.hookBinaryOK, binaryMissing {
            binaryMissing = false
            warnings["hookBinary"] = nil
        }

        if i.chromeRunning, !i.extensionConnected {
            if extensionDownSince == nil { extensionDownSince = i.now }
            if let since = extensionDownSince, !extensionReported, i.now - since >= extensionGraceMs {
                extensionReported = true
                warnings["extension"] = "Chrome is running without the Agent Ledger extension. Check chrome://extensions (Developer mode must stay on)."
                out.append(HealthNotice(cat: "gap.extension_disconnected", payload: ["since": .number(since)],
                                        title: "Chrome isn't being recorded",
                                        body: "Chrome is running but the Agent Ledger extension isn't connected. Check that it's still enabled at chrome://extensions."))
            }
        } else {
            if extensionReported, i.extensionConnected, let since = extensionDownSince {
                out.append(HealthNotice(kind: EventKind.sensorHealth, cat: "health.extension_reconnected",
                                        payload: ["seconds": .number(((i.now - since) / 1000).rounded())],
                                        title: "", body: "", notify: false, degrade: false))
            }
            extensionDownSince = nil
            extensionReported = false
            warnings["extension"] = nil
        }
        return out
    }

    // MARK: Ledger integrity

    public static func notice(opening check: LedgerStore.AnchorCheck) -> HealthNotice? {
        let detail: String
        switch check {
        case .ok, .noAnchor: return nil
        case .removedOrChanged(let a, let last):
            detail = last < a ? "events \(last + 1)–\(a) were removed while the app wasn't running"
                              : "event \(a) was altered while the app wasn't running"
        case .addedOutside(let n, let first):
            detail = "\(n) event\(n == 1 ? "" : "s") from \(first) on were added while the app wasn't running"
        }
        return ledgerChanged(detail)
    }

    public static func notice(live check: LedgerStore.LiveCheck) -> HealthNotice? {
        switch check {
        case .ok: return nil
        case .fileReplaced: return ledgerChanged("the database file was replaced or deleted while the app was running")
        case .tailChanged: return ledgerChanged("another program wrote to or removed events from the ledger")
        }
    }

    public static func notice(chain v: ChainVerification) -> HealthNotice? {
        v.ok ? nil : ledgerChanged("event \(v.firstBadEventId ?? -1) no longer matches its hash")
    }

    static func ledgerChanged(_ detail: String) -> HealthNotice {
        HealthNotice(cat: "gap.ledger_changed", payload: ["detail": .string(detail)],
                     title: "The ledger was changed outside Agent Ledger",
                     body: detail.prefix(1).uppercased() + detail.dropFirst() + ". Treat records from around this time with care.")
    }
}

/// Versions of the agent software the recorder depends on, and whether the pieces it relies on
/// are still where it expects them.
public enum VersionWatch {
    public struct Component: Equatable, Sendable {
        public var key: String
        public var name: String
        public var version: String
        public init(key: String, name: String, version: String) { self.key = key; self.name = name; self.version = version }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Newest Claude Code version installed (`~/.local/share/claude/versions/<v>`).
    public static func claudeCodeVersion(dir: URL? = nil) -> String? {
        let d = dir ?? home.appendingPathComponent(".local/share/claude/versions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return names.filter { $0.first?.isNumber == true }.max { compare($0, $1) < 0 }
    }

    /// Version in the newest Codex session file's first line.
    public static func codexVersion(root: URL? = nil) -> String? {
        guard let f = AgentLogs.newestCodexRollout(root: root), let first = AgentLogs.firstLine(of: f),
              let j = JSONValue.parse(first) else { return nil }
        return j["payload"]?["cli_version"]?.stringValue
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Compares what's installed with what was last seen. Returns the changes and the new record.
    public static func diff(seen: [String: String], now: [Component]) -> (changes: [(Component, from: String)], seen: [String: String]) {
        var out: [(Component, from: String)] = []
        var next = seen
        for c in now {
            if let old = seen[c.key], old != c.version { out.append((c, from: old)) }
            next[c.key] = c.version
        }
        return (out, next)
    }

    /// Things an agent update can move. Each entry: what broke, in plain words.
    public static func dependencyProblems(home: URL? = nil) -> [String] {
        let h = home ?? Self.home
        let fm = FileManager.default
        var out: [String] = []
        if fm.fileExists(atPath: h.appendingPathComponent(".claude/chrome").path),
           !fm.fileExists(atPath: h.appendingPathComponent(".claude/chrome/chrome-native-host").path) {
            out.append("Claude Code's Chrome helper isn't where the recorder expects it (~/.claude/chrome/chrome-native-host)")
        }
        let codexPlugin = h.appendingPathComponent(".codex/plugins/cache/openai-bundled/chrome")
        if fm.fileExists(atPath: codexPlugin.path),
           !fm.fileExists(atPath: codexPlugin.appendingPathComponent("latest/extension-host/macos/arm64/ChatGPT for Chrome").path) {
            out.append("Codex's Chrome helper isn't where the recorder expects it (ChatGPT for Chrome)")
        }
        return out
    }
}
