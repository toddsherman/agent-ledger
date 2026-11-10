import Foundation
import Darwin

/// The keep-alive check run by launchd every 30 seconds (`ledgerctl ensure-running`).
/// It starts the app at login and restarts it if it stops, unless you chose Quit.
public enum KeepAlive {
    public enum Decision: Equatable { case running, userQuit, waiting, launch }

    /// Seconds the app must have been down before it's relaunched. Longer than an update takes
    /// to swap the app bundle, so a relaunch never races Sparkle.
    public static let graceMs = 12_000.0

    public static func bootTimeMs() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }

    public static func appPIDs() -> [Int32] {
        Processes.allPIDs().filter { Processes.path(of: $0)?.hasSuffix(".app/Contents/MacOS/AgentLedger") == true }
    }

    /// Pure decision, so it can be tested without processes or files.
    public static func decide(appRunning: Bool, quitMarkerAt: Double?, bootAt: Double, downSince: Double?, now: Double) -> Decision {
        if appRunning { return .running }
        if let q = quitMarkerAt, q > bootAt { return .userQuit }
        guard let d = downSince, d > bootAt else { return .waiting }
        return now - d >= graceMs ? .launch : .waiting
    }

    public static func quitMarkerTime() -> Double? {
        guard let s = try? String(contentsOf: LedgerPaths.quitMarkerURL, encoding: .utf8) else { return nil }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func markUserQuit(now: Double) {
        try? String(now).write(to: LedgerPaths.quitMarkerURL, atomically: true, encoding: .utf8)
    }

    public static func clearUserQuit() { try? FileManager.default.removeItem(at: LedgerPaths.quitMarkerURL) }

    /// One check. Returns what it decided; on `.launch` it has already asked macOS to open the app.
    @discardableResult
    public static func check(appPath: String, now: Double) -> Decision {
        let stateURL = LedgerPaths.keepAliveStateURL
        let state = (try? Data(contentsOf: stateURL)).flatMap { JSONValue.parse($0) }
        let running = !appPIDs().isEmpty
        let boot = bootTimeMs()
        // The first check after login launches at once: nothing was running before.
        let firstSinceBoot = (state?["checkedAt"]?.doubleValue ?? 0) < boot
        var downSince = running ? nil : (state?["downSince"]?.doubleValue ?? now)
        if !running, firstSinceBoot { downSince = now - graceMs }
        if let d = downSince, d < boot, !firstSinceBoot { downSince = now }
        let decision = decide(appRunning: running, quitMarkerAt: quitMarkerTime(), bootAt: boot, downSince: downSince, now: now)
        var out: [String: JSONValue] = ["checkedAt": .number(now)]
        if let d = downSince, decision != .launch { out["downSince"] = .number(d) }
        if decision == .launch {
            out["lastRelaunchAt"] = .number(now)
            out["downFrom"] = .number(downSince ?? now)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", appPath]
            try? p.run()
            p.waitUntilExit()
        } else if let last = state?["lastRelaunchAt"] { out["lastRelaunchAt"] = last; out["downFrom"] = state?["downFrom"] ?? .null }
        try? JSONValue.object(out).canonicalData().write(to: stateURL, options: .atomic)
        return decision
    }
}
