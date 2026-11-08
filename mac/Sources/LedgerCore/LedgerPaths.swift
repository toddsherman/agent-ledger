import Foundation

public enum LedgerPaths {
    public static let nativeHostName = "com.agentledger.host"
    /// Extension IDs allowed to talk to the native host: the unpacked development build (pinned by
    /// the manifest key) and, once listed, the Chrome Web Store item.
    public static let extensionIDs = ["odfiimhaencobkjndlcohhcjbehmejmf"]
    public static var extensionID: String { extensionIDs[0] }

    /// `AGENT_LEDGER_HOME` overrides the support directory (used by tests and the testbed).
    public static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_LEDGER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentLedger", isDirectory: true)
    }

    public static var socketPath: String { supportDir.appendingPathComponent("ingest.sock").path }
    public static var spoolDir: URL { supportDir.appendingPathComponent("spool", isDirectory: true) }
    public static var databaseURL: URL { supportDir.appendingPathComponent("ledger.sqlite") }
    public static var settingsURL: URL { supportDir.appendingPathComponent("settings.json") }
    public static var exportsDir: URL { supportDir.appendingPathComponent("exports", isDirectory: true) }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for dir in [supportDir, spoolDir] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch { return false }
        }
        return true
    }
}
