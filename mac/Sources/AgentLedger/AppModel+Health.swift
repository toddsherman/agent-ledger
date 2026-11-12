import AppKit
import LedgerCore

/// "Never stop silently": the checks that notice when the recorder stopped, lost a piece it
/// depends on, or had its ledger changed, plus the agent-log comparison and alerts.
extension AppModel {
    struct PreviousRun {
        var heartbeat: Double?
        var quitAt: Double?
    }

    /// What the last run left behind. Read before the quit marker is cleared.
    static func previousRun() -> PreviousRun {
        let status = (try? Data(contentsOf: LedgerPaths.statusURL)).flatMap { JSONValue.parse($0) }
        return PreviousRun(heartbeat: status?["writtenAt"]?.doubleValue, quitAt: KeepAlive.quitMarkerTime())
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    // MARK: Reporting (correlator queue)

    func report(_ n: HealthNotice, at t: Double = nowMs()) {
        let sessions = correlator.recordHealth(kind: n.kind, cat: n.cat, p: n.payload, at: t, degrade: n.degrade)
        lastSummaryKey = ""
        if n.notify, !n.title.isEmpty, correlator.settings.alertNotices {
            notifier.post(title: n.title, body: n.body, session: sessions.first, tab: "timeline",
                          id: "\(n.cat)-\(Int(t / 1000))", sound: true)
        }
        publishWarnings()
    }

    func publishWarnings() {
        let list = health.warnings.sorted { $0.key < $1.key }.map(\.value)
        DispatchQueue.main.async { if self.warnings != list { self.warnings = list } }
    }

    // MARK: Launch

    func startupChecks(_ previous: PreviousRun) {
        let now = nowMs()
        let binaryChanged = (try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? ""))?[.modificationDate] as? Date
        if let f = RecorderStop.decide(lastHeartbeat: previous.heartbeat, quitMarkerAt: previous.quitAt, bootAt: KeepAlive.bootTimeMs(),
                                       binaryChangedAt: binaryChanged.map { $0.timeIntervalSince1970 * 1000 },
                                       lastVersion: try? store.meta("app.version"), version: Self.appVersion, now: now) {
            report(RecorderStop.notice(f), at: now)
        }
        try? store.setMeta("app.version", Self.appVersion)

        if let check = store.openingCheck, let n = HealthMonitor.notice(opening: check) {
            health.setWarning("ledger", n.body)
            report(n, at: now)
        }
        // Hooks that are installed now are expected from here on; removing them outside the app is a gap.
        for agent in [HookAgent.claude, .codex] where (try? store.meta(Self.hooksKey(agent))) == nil && HookInstaller.isInstalled(agent: agent) {
            try? store.setMeta(Self.hooksKey(agent), "1")
        }
        checkChain()
        checkVersions()
        healthTick()
    }

    static func hooksKey(_ agent: HookAgent) -> String { "health.hooks.\(agent.agentName)" }

    /// Called when you install or remove hooks in Settings, so a removal you made isn't reported.
    func setHooksExpected(_ agent: HookAgent, _ expected: Bool) {
        queue.async { try? self.store.setMeta(Self.hooksKey(agent), expected ? "1" : "0"); self.healthTick() }
    }

    // MARK: Every minute

    func healthTick() {
        let now = nowMs()
        var expected: [String: Bool] = [:], present: [String: Bool] = [:]
        for agent in [HookAgent.claude, .codex] {
            expected[agent.agentName] = (try? store.meta(Self.hooksKey(agent))) == "1"
            present[agent.agentName] = HookInstaller.isInstalled(agent: agent)
        }
        let chrome = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        let inputs = HealthMonitor.Inputs(now: now, hooksExpected: expected, hooksPresent: present,
                                          hookBinaryOK: FileManager.default.isExecutableFile(atPath: Self.hookBinary),
                                          chromeRunning: chrome,
                                          extensionConnected: correlator.status(now: now).extensionConnected)
        for n in health.evaluate(inputs) { report(n, at: now) }
        DispatchQueue.main.async { if self.chromeRunning != chrome { self.chromeRunning = chrome } }

        let live = store.liveCheck()
        if let n = HealthMonitor.notice(live: live) {
            health.setWarning("ledger", n.body)
            report(n, at: now)
            store.acceptCurrentState()
        }
        publishWarnings()
    }

    // MARK: Daily

    func dailyChecks() {
        checkChain()
        checkVersions()
        runSelfTest()
    }

    func checkChain() {
        guard let v = try? store.verifyChain(), let n = HealthMonitor.notice(chain: v) else { return }
        // Report a broken chain once per break, not every day.
        let key = "\(v.firstBadEventId ?? -1)"
        guard (try? store.meta("health.chain.reported")) != key else { health.setWarning("ledger", n.body); publishWarnings(); return }
        try? store.setMeta("health.chain.reported", key)
        health.setWarning("ledger", n.body)
        report(n)
    }

    func checkVersions() {
        var now: [VersionWatch.Component] = []
        if let v = VersionWatch.claudeCodeVersion() { now.append(.init(key: "claude-code", name: "Claude Code", version: v)) }
        if let v = VersionWatch.codexVersion() { now.append(.init(key: "codex", name: "Codex", version: v)) }
        let seenText = (try? store.meta("versions.seen")) ?? nil
        var seen: [String: String] = [:]
        if let o = seenText.flatMap({ JSONValue.parse(Data($0.utf8)) })?.objectValue {
            for (k, v) in o { seen[k] = v.stringValue }
        }
        let d = VersionWatch.diff(seen: seen, now: now)
        for (c, from) in d.changes {
            report(HealthNotice(kind: EventKind.context, cat: "version.changed",
                                payload: ["what": .string(c.name), "key": .string(c.key), "from": .string(from), "to": .string(c.version)],
                                title: "", body: "", notify: false, degrade: false))
        }
        if d.seen != seen {
            let obj = JSONValue.object(d.seen.mapValues { .string($0) })
            try? store.setMeta("versions.seen", String(decoding: obj.canonicalData(), as: UTF8.self))
        }
        // Pieces an agent update can move. Reported when the list changes.
        let problems = VersionWatch.dependencyProblems().joined(separator: "; ")
        if problems != ((try? store.meta("health.deps")) ?? nil ?? "") {
            try? store.setMeta("health.deps", problems)
            if !problems.isEmpty {
                report(HealthNotice(cat: "gap.dependency_changed", payload: ["detail": .string(problems)],
                                    title: "An agent update moved something Agent Ledger depends on",
                                    body: problems + ". Sessions may be missed or mislabeled until Agent Ledger is updated."))
            }
        }
        health.setWarning("deps", problems.isEmpty ? nil : problems)
        publishWarnings()
    }

    // MARK: Self-test

    /// Checks each leg of the recorder end to end: the hook program reaching the app, the
    /// extension answering, and the ledger accepting a write. Runs off the correlator's queue.
    func runSelfTest(manual: Bool = false) {
        let nonce = UUID().uuidString
        DispatchQueue.global(qos: .utility).async {
            var passed: [String] = [], failed: [String] = [], skipped: [String] = []

            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.hookBinary)
            p.arguments = ["--selftest", nonce]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ran = (try? p.run()) != nil
            if ran { p.waitUntilExit() }
            var seen = false
            for _ in 0..<20 where !seen {
                seen = self.queue.sync { self.selfTestNonces.remove(nonce) != nil }
                if !seen { Thread.sleep(forTimeInterval: 0.1) }
            }
            if ran, p.terminationStatus == 0, seen { passed.append("hook program") } else { failed.append("hook program") }

            let before = self.queue.sync { self.correlator.status(now: nowMs()) }
            if before.extensionConnected {
                var line = (["type": "snapshot"] as JSONValue).canonicalData()
                line.append(0x0A)
                self.server.broadcast(role: "host", line)
                var answered = false
                for _ in 0..<30 where !answered {
                    Thread.sleep(forTimeInterval: 0.2)
                    let at = self.queue.sync { self.correlator.status(now: nowMs()).lastExtensionEventAt }
                    answered = (at ?? 0) > (before.lastExtensionEventAt ?? 0)
                }
                if answered { passed.append("extension") } else { failed.append("extension") }
            } else {
                skipped.append("extension (not connected)")
            }

            self.queue.async {
                let countBefore = (try? self.store.eventCount()) ?? -1
                if failed.isEmpty {
                    self.correlator.recordHealth(kind: EventKind.sensorHealth, cat: "selftest.result",
                                                 p: ["checked": .string((passed + ["ledger"]).joined(separator: ", ")),
                                                     "skipped": .string(skipped.joined(separator: ", "))], at: nowMs())
                }
                let wrote = failed.isEmpty ? ((try? self.store.eventCount()) ?? -1) > countBefore : self.store.liveCheck() == .ok
                if wrote { passed.append("ledger") } else { failed.append("ledger") }

                let text: String
                if failed.isEmpty {
                    text = "Self-test passed: " + passed.joined(separator: ", ") + (skipped.isEmpty ? "" : ". Not checked: " + skipped.joined(separator: ", "))
                    self.health.setWarning("selftest", nil)
                } else {
                    text = "Self-test failed: " + failed.joined(separator: ", ")
                    self.health.setWarning("selftest", text + ". Relaunch Agent Ledger; if it keeps failing, reinstall.")
                    self.report(HealthNotice(cat: "gap.selftest_failed", payload: ["failed": .string(failed.joined(separator: ", "))],
                                             title: "Agent Ledger failed its self-test",
                                             body: "Not working: \(failed.joined(separator: ", ")). Agent activity may not be recorded."))
                }
                try? self.store.setMeta("selftest.last", "\(Int(nowMs()))|\(text)")
                self.publishWarnings()
                DispatchQueue.main.async {
                    self.selfTest = text
                    if manual { self.message = text }
                }
            }
        }
    }

    // MARK: Agent logs and alerts (report queue)

    /// Compares a session with the agent's own log and stores the result. Tells you when the hooks missed calls.
    func reconcile(session id: String, notify: Bool) {
        guard let r = try? AgentLogs.run(store: store, session: id) else { return }
        queue.async { self.lastSummaryKey = ""; self.publish() }
        if notify, !r.missing.isEmpty, correlator.settings.alertNotices {
            notifier.post(title: "Hooks missed \(r.missing.count) browser call\(r.missing.count == 1 ? "" : "s")",
                          body: "The agent's own log lists \(r.logged) browser calls; its hooks reported \(r.matched). The missing ones were added from the log.",
                          session: id, tab: "summary", id: "reconcile-\(id)")
        }
    }

    func reconcileNow(session id: String) {
        reportQueue.async {
            self.reconcile(session: id, notify: false)
            let text = (try? self.store.events(forSession: id))?.last { $0.event.cat == "reconcile.result" }
                .map { AgentLogs.resultText($0.event.p) } ?? "This session has no agent log to check against."
            DispatchQueue.main.async { self.message = text; self.dataVersion += 1 }
        }
    }

    func raiseAlerts(session id: String, settings: LedgerSettings) {
        guard let fresh = try? Alerts.raise(store: store, session: id, settings: settings), !fresh.isEmpty else { return }
        queue.async { self.lastSummaryKey = ""; self.publish() }
        guard settings.alertNotices else { return }
        for a in fresh where a.notify {
            notifier.post(title: a.title, body: a.body, session: id, tab: "changes", id: "alert-\(id)-\(a.key)", sound: true)
        }
    }

    /// Live sessions are checked as they go, so an alert arrives while it still matters.
    func checkLiveAlerts() {
        let settings = correlator.settings
        let live = correlator.status(now: nowMs()).sessions.filter { $0.state != "possible" }.map(\.id)
        guard !live.isEmpty else { return }
        reportQueue.async {
            for id in live {
                let key = "\((try? self.store.events(forSession: id).count) ?? 0)"
                if self.alertKeys[id] == key { continue }
                self.alertKeys[id] = key
                self.raiseAlerts(session: id, settings: settings)
            }
        }
    }
}
