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
    /// Sites where any real change raises an alert.
    public var sensitiveHosts: [String] = []

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
    }

    public static func matches(host: String?, in list: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return list.contains { h in
            let x = h.lowercased().trimmingCharacters(in: .whitespaces)
            return !x.isEmpty && (host == x || host.hasSuffix("." + x))
        }
    }

    public func isSensitive(host: String?) -> Bool { Self.matches(host: host, in: sensitiveHosts) }

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
