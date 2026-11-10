import Foundation
import ServiceManagement
import LedgerCore

/// Registers the launchd agent inside the app bundle that starts Agent Ledger at login and
/// restarts it if it stops. macOS lists it under Login Items, where you can turn it off.
enum KeepRunning {
    private static var service: SMAppService { SMAppService.agent(plistName: LedgerPaths.keepAlivePlistName) }

    /// Only an installed copy registers itself; a build folder copy would point launchd at a
    /// path that the next build deletes.
    static var installed: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(LedgerPaths.keepAlivePlistName)").path)
    }

    static var statusText: String {
        guard bundled else { return "not available in this build" }
        guard installed else { return "available once the app is in the Applications folder" }
        switch service.status {
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval in System Settings → Login Items"
        case .notRegistered: return "off"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Returns an error message, or nil.
    @discardableResult
    static func apply(enabled: Bool) -> String? {
        guard bundled, installed else { return nil }
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            return nil
        } catch { return "Could not \(enabled ? "turn on" : "turn off") start at login: \(error.localizedDescription)" }
    }
}
