import Foundation

public struct LedgerSettings: Codable, Equatable, Sendable {
    /// Capture field values (never passwords, card or one-time-code fields).
    public var valuesEnabled = true
    /// Use the prompt that started a turn as the session label, only if the session uses the browser.
    public var promptLabels = true
    public var retentionDays = 90
    /// How long ordinary browsing metadata stays in memory (never on disk).
    public var prebufferMinutes = 10
    /// Hosts that are never recorded, even inside agent sessions.
    public var excludedHosts: [String] = []
    /// Recording paused until this time (ms), if set.
    public var pausedUntil: Double?
    /// Start at login and relaunch if the app stops (a launchd agent inside the app bundle).
    public var keepRunning = true
    /// Post a one-line notification when an agent session ends.
    public var sessionEndNotices = true
    /// Post notifications for alerts (recorder stopped, unseen browser, changes on sensitive sites).
    public var alertNotices = true
    /// Also notify about sessions where the agent only used the browser inside its own app
    /// (the Claude desktop app's browser pane, the ChatGPT app's browser). Off: they are recorded quietly.
    public var inAppBrowserNotices = false
    /// Your own sites where any real change raises an alert, on top of the built-in groups.
    public var sensitiveHosts: [String] = []
    /// Built-in site groups switched away from their default (group id → on).
    public var siteGroups: [String: Bool] = [:]
    /// Sites left out of the built-in groups.
    public var sensitiveExceptions: [String] = []
    /// Action alerts switched off (or back on), by `Alerts.ActionKind` id. Missing means on.
    public var actionAlerts: [String: Bool] = [:]

    public init() {}

    /// Missing keys keep their defaults, so settings written by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .valuesEnabled) ?? valuesEnabled
        promptLabels = try c.decodeIfPresent(Bool.self, forKey: .promptLabels) ?? promptLabels
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays
        prebufferMinutes = try c.decodeIfPresent(Int.self, forKey: .prebufferMinutes) ?? prebufferMinutes
        excludedHosts = try c.decodeIfPresent([String].self, forKey: .excludedHosts) ?? excludedHosts
        pausedUntil = try c.decodeIfPresent(Double.self, forKey: .pausedUntil)
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? keepRunning
        sessionEndNotices = try c.decodeIfPresent(Bool.self, forKey: .sessionEndNotices) ?? sessionEndNotices
        alertNotices = try c.decodeIfPresent(Bool.self, forKey: .alertNotices) ?? alertNotices
        sensitiveHosts = try c.decodeIfPresent([String].self, forKey: .sensitiveHosts) ?? sensitiveHosts
        inAppBrowserNotices = try c.decodeIfPresent(Bool.self, forKey: .inAppBrowserNotices) ?? inAppBrowserNotices
        siteGroups = try c.decodeIfPresent([String: Bool].self, forKey: .siteGroups) ?? siteGroups
        sensitiveExceptions = try c.decodeIfPresent([String].self, forKey: .sensitiveExceptions) ?? sensitiveExceptions
        actionAlerts = try c.decodeIfPresent([String: Bool].self, forKey: .actionAlerts) ?? actionAlerts
    }

    public static func matches(host: String?, in list: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return list.contains { h in
            let x = h.lowercased().trimmingCharacters(in: .whitespaces)
            return !x.isEmpty && (host == x || host.hasSuffix("." + x))
        }
    }

    public func isSensitive(host: String?) -> Bool { sensitiveGroup(host: host) != nil }

    public func groupEnabled(_ id: String) -> Bool { siteGroups[id] ?? SiteGroups.group(id)?.defaultOn ?? false }

    public func actionEnabled(_ id: String) -> Bool { actionAlerts[id] ?? true }

    /// The name of the list that makes this host sensitive: your own list, or a built-in group that is on.
    public func sensitiveGroup(host: String?) -> String? {
        if Self.matches(host: host, in: sensitiveHosts) { return SiteGroups.customName }
        if Self.matches(host: host, in: sensitiveExceptions) { return nil }
        guard let m = SiteGroups.match(host: host), groupEnabled(m.group.id) else { return nil }
        return m.group.name
    }

    public static func load(from url: URL = LedgerPaths.settingsURL) -> LedgerSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(LedgerSettings.self, from: data) else { return LedgerSettings() }
        return s
    }

    public func save(to url: URL = LedgerPaths.settingsURL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: url, options: .atomic) }
    }

    public func isExcluded(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return excludedHosts.contains { h in
            let x = h.lowercased().trimmingCharacters(in: .whitespaces)
            return !x.isEmpty && (host == x || host.hasSuffix("." + x))
        }
    }

    public func isPaused(now: Double) -> Bool { (pausedUntil ?? 0) > now }
}
