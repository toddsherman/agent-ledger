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

    public init() {}

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
