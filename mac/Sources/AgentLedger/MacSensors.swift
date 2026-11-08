import AppKit
import CoreGraphics
import Security
import LedgerCore

/// Mac-level context: agent browser helpers, the frontmost app, and the times of physical
/// clicks and key presses. Key contents are never read; only "a key went down at time T".
final class MacSensors {
    var emit: ([LedgerEvent]) -> Void = { _ in }
    var onInput: (HumanInputKind, Double) -> Void = { _, _ in }
    var onFrontmost: (String, Double) -> Void = { _, _ in }

    private var helpers: [Int32: (agent: String, startedAt: Double)] = [:]
    private var lastInput: [HumanInputKind: Double] = [:]
    private var scanTimer: DispatchSourceTimer?
    private var inputTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "agentledger.sensors")
    private var seq = 0
    private let inst = "mac-\(Int(nowMs()))"

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.onFrontmost(app.bundleIdentifier ?? app.localizedName ?? "?", nowMs())
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            onFrontmost(app.bundleIdentifier ?? "?", nowMs())
        }

        let scan = DispatchSource.makeTimerSource(queue: queue)
        scan.schedule(deadline: .now(), repeating: 2.0)
        scan.setEventHandler { [weak self] in self?.scanHelpers() }
        scan.resume()
        scanTimer = scan

        let input = DispatchSource.makeTimerSource(queue: queue)
        input.schedule(deadline: .now(), repeating: .milliseconds(150))
        input.setEventHandler { [weak self] in self?.sampleInput() }
        input.resume()
        inputTimer = input
    }

    private func event(_ cat: String, _ p: JSONValue) -> LedgerEvent {
        seq += 1
        return LedgerEvent(src: "mac.sensor", inst: inst, seq: seq, t: nowMs(), kind: EventKind.context, cat: cat, p: p)
    }

    // MARK: Input timing

    private func sampleInput() {
        let now = nowMs()
        let sources: [(HumanInputKind, CGEventType)] = [(.mouseDown, .leftMouseDown), (.mouseDown, .rightMouseDown), (.keyDown, .keyDown)]
        for (kind, type) in sources {
            let secs = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            guard secs.isFinite, secs >= 0, secs < 86_400 else { continue }
            let t = now - secs * 1000
            if t - (lastInput[kind] ?? 0) > 30 {
                // Skip the first sample (it reflects activity before launch).
                if lastInput[kind] != nil { onInput(kind, t) }
                lastInput[kind] = t
            }
        }
    }

    // MARK: Helper processes

    static func classify(path: String, args: [String]) -> String? {
        if path.hasSuffix("/ChatGPT for Chrome") { return "codex" }
        if args.contains("--chrome-native-host") && (path.contains("/claude/versions/") || path.hasSuffix("/claude")) {
            return "claude-code"
        }
        return nil
    }

    static func signing(pid: Int32) -> (team: String?, identifier: String?) {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return (nil, nil) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, nil) }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String, dict[kSecCodeInfoIdentifier as String] as? String)
    }

    private func scanHelpers() {
        var seen: Set<Int32> = []
        var out: [LedgerEvent] = []
        for pid in Processes.allPIDs() {
            guard let path = Processes.path(of: pid) else { continue }
            let cheap = path.hasSuffix("/ChatGPT for Chrome") || path.contains("/claude/versions/") || path.hasSuffix("/claude")
            guard cheap else { continue }
            if helpers[pid] != nil { seen.insert(pid); continue }
            guard let snap = Processes.snapshot(pid), let agent = Self.classify(path: snap.path, args: snap.args) else { continue }
            seen.insert(pid)
            helpers[pid] = (agent, snap.startedAt)
            let sig = Self.signing(pid: pid)
            let parentPath = Processes.path(of: snap.ppid) ?? ""
            out.append(event("helper.started", [
                "agent": .string(agent), "pid": .number(Double(pid)), "ppid": .number(Double(snap.ppid)),
                "path": .string(snap.path), "processStartedAt": .number(snap.startedAt),
                "parent": .string((parentPath as NSString).lastPathComponent),
                "teamId": sig.team.map { .string($0) } ?? .null, "signingId": sig.identifier.map { .string($0) } ?? .null,
            ]))
        }
        for (pid, info) in helpers where !seen.contains(pid) {
            helpers[pid] = nil
            out.append(event("helper.stopped", ["agent": .string(info.agent), "pid": .number(Double(pid)),
                                                "processStartedAt": .number(info.startedAt)]))
        }
        if !out.isEmpty { emit(out) }
    }
}
