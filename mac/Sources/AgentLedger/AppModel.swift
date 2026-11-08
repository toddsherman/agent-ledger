import AppKit
import Combine
import LedgerCore

/// Owns the store, ingest server, correlator and sensors, and publishes state for the UI.
final class AppModel: ObservableObject {
    @Published var status = LiveStatus()
    @Published var summaries: [SessionSummary] = []
    @Published var settings: LedgerSettings
    @Published var message: String?
    @Published var hooksInstalled: [HookAgent: Bool] = [:]
    @Published var hostRegisteredPath: String?
    @Published var dataVersion = 0
    /// Set by agentledger://ledger?session=<id>&tab=changes|timeline|evidence links.
    @Published var deepLink: DeepLink?

    struct DeepLink: Equatable {
        var session: String?
        var tab: String?
        var nonce = UUID()
    }

    func handle(url: URL) {
        guard url.scheme == "agentledger" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        deepLink = DeepLink(session: items.first { $0.name == "session" }?.value,
                            tab: items.first { $0.name == "tab" }?.value)
    }

    let store: LedgerStore
    let correlator: Correlator
    private let server = IngestServer()
    private let sensors = MacSensors()
    private let queue = DispatchQueue(label: "agentledger.correlator")
    private var timers: [DispatchSourceTimer] = []
    private var lastSummaryKey = ""

    static func makeStore() -> LedgerStore {
        LedgerPaths.ensureDirectories()
        do { return try LedgerStore(url: LedgerPaths.databaseURL) }
        catch { fatalError("Agent Ledger could not open its database: \(error)") }
    }

    init() {
        store = Self.makeStore()
        let s = LedgerSettings.load()
        settings = s
        correlator = Correlator(store: store, settings: s)
        installHelperBinaries()
        let server = self.server
        correlator.sendCommand = { cmd, peer in
            var line = cmd.canonicalData()
            line.append(0x0A)
            if let peer, server.send(to: peer, line) { return }
            server.broadcast(role: "host", line)
        }
        server.onLine = { [weak self] peer, line in self?.queue.async { self?.handle(peer: peer, line: line) } }
        server.onDisconnect = { [weak self] peer in
            guard peer.role == "host" else { return }
            self?.queue.async { self?.publish() }
        }
        do { try server.start() } catch { message = "Could not open the ingest socket: \(error)" }

        sensors.emit = { [weak self] events in self?.queue.async { self?.correlator.ingest(events, receivedAt: nowMs()) } }
        sensors.onInput = { [weak self] kind, t in self?.queue.async { self?.correlator.noteHumanInput(kind, at: t) } }
        sensors.onFrontmost = { [weak self] bundle, t in self?.queue.async { self?.correlator.noteFrontmost(bundleId: bundle, at: t) } }
        sensors.start()

        queue.async { [weak self] in
            guard let self else { return }
            self.correlator.restoreLiveSessions(now: nowMs())
            self.drainSpool()
            self.purgeIfNeeded()
            self.publish()
        }
        every(1.0) { [weak self] in
            guard let self else { return }
            self.correlator.tick(now: nowMs())
            self.publish()
        }
        every(30.0) { [weak self] in self?.drainSpool() }
        every(6 * 3600) { [weak self] in self?.purgeIfNeeded() }
        registerHostIfNeeded()
        refreshIntegrations()
    }

    private func every(_ seconds: Double, _ body: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: body)
        t.resume()
        timers.append(t)
    }

    // MARK: Ingest (correlator queue)

    private func handle(peer: IngestServer.Peer, line: Data) {
        guard let msg = try? JSONDecoder().decode(WireMessage.self, from: line) else { return }
        switch msg.type {
        case "hello":
            if msg.role == "host" {
                if extensionFilesChanged {
                    extensionFilesChanged = false
                    var line = (["type": "reload", "force": true] as JSONValue).canonicalData()
                    line.append(0x0A)
                    server.send(to: peer.id, line)
                    return
                }
                // A (re)connected extension (or a restarted app): ask for the open tabs, groups and
                // debugger state, which live only in memory, then re-send arm commands.
                var snapshot = (["type": "snapshot"] as JSONValue).canonicalData()
                snapshot.append(0x0A)
                server.send(to: peer.id, snapshot)
                queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.correlator.rearmAll() }
            }
        case "events":
            correlator.ingest(msg.events ?? [], peer: peer.id, receivedAt: nowMs())
        case "snapshot":
            // From ledgerctl (same user only): draw the Ledger window into a PNG.
            if let path = JSONValue.parse(line)?["path"]?.stringValue {
                let server = self.server
                DispatchQueue.main.async {
                    let result = Self.snapshotLedgerWindow(to: URL(fileURLWithPath: path))
                    var reply = (["type": "snapshot.result", "ok": .bool(result == nil),
                                  "error": result.map { .string($0) } ?? .null] as JSONValue).canonicalData()
                    reply.append(0x0A)
                    server.send(to: peer.id, reply)
                }
            }
        default:
            break
        }
    }

    private func drainSpool() {
        let messages = Spool.drain()
        let events = messages.flatMap { $0.events ?? [] }
        if !events.isEmpty { correlator.ingest(events, receivedAt: nowMs()) }
    }

    private func purgeIfNeeded() {
        let cutoff = nowMs() - Double(max(1, correlator.settings.retentionDays)) * 86_400_000
        _ = try? store.purge(olderThan: cutoff)
    }

    private var lastStatusWrite = 0.0

    /// Writes live status to status.json (read by `ledgerctl status`). Metadata only.
    private func writeStatusFile(_ st: LiveStatus) {
        let now = nowMs()
        guard now - lastStatusWrite > 2000 else { return }
        lastStatusWrite = now
        let obj: [String: Any] = [
            "writtenAt": now,
            "extensionConnected": st.extensionConnected,
            "lastExtensionEventAt": st.lastExtensionEventAt ?? NSNull(),
            "helpers": st.helpers,
            "lastHookAt": st.lastHookAt,
            "paused": st.paused,
            "memoryEvents": st.memoryEvents,
            "sessions": st.sessions.map { ["id": $0.id, "agent": $0.agent, "state": $0.state, "tabs": $0.tabs, "attribution": $0.attribution] },
            "recentHooks": st.recentHooks.suffix(40).map { h -> [String: Any] in
                ["t": h.t, "agent": h.agent, "cat": h.cat, "tool": h.tool ?? NSNull(), "browser": h.browser, "tabIds": h.tabIds, "inputKeys": h.inputKeys]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: LedgerPaths.supportDir.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    private func publish() {
        let st = correlator.status(now: nowMs())
        writeStatusFile(st)
        var summaries: [SessionSummary]?
        let count = (try? store.eventCount()) ?? 0
        let key = "\(count)-\(st.sessions.map { $0.id + $0.state }.joined())"
        if key != lastSummaryKey {
            lastSummaryKey = key
            summaries = try? store.sessionSummaries(limit: 500)
        }
        DispatchQueue.main.async {
            if self.status != st { self.status = st }
            if let summaries {
                self.summaries = summaries
                self.dataVersion += 1
            }
        }
    }

    /// Renders the visible Ledger window (an app may always draw its own windows; no Screen
    /// Recording permission involved). Used for store screenshots.
    /// Returns nil on success, otherwise the reason it failed.
    static func snapshotLedgerWindow(to url: URL) -> String? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.width >= 600 && !($0 is NSPanel) }
        guard let window = candidates.first(where: { $0.title == "Agent Ledger" }) ?? candidates.max(by: { $0.frame.width < $1.frame.width }) else {
            return "no visible Ledger window (windows: \(NSApp.windows.map { "\($0.title)|\(Int($0.frame.width))|\($0.isVisible)" }))"
        }
        guard let content = window.contentView else { return "window has no content view" }
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "could not allocate bitmap" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "PNG encoding failed" }
        do { try png.write(to: url, options: .atomic) } catch { return "write failed: \(error.localizedDescription)" }
        return nil
    }

    // MARK: Actions (main thread)

    func stopRecording(_ id: String) {
        queue.async { self.correlator.stopRecording(session: id, now: nowMs()); self.lastSummaryKey = ""; self.publish() }
    }

    func excludeTab(session: String, tab: Int) {
        queue.async { self.correlator.excludeTab(session: session, tab: tab, now: nowMs()); self.publish() }
    }

    func thisWasMe(minutes: Double) {
        queue.async { self.correlator.markThisWasMe(lastMinutes: minutes, now: nowMs()); self.lastSummaryKey = ""; self.publish() }
        message = "Marked the last \(Int(minutes)) minutes of active sessions as your activity."
    }

    func correct(session: String, event: Int64, action: String) {
        queue.async {
            _ = try? self.store.addCorrection(session: session, eventId: event, fromT: nil, toT: nil, action: action, note: nil)
            self.lastSummaryKey = ""
            self.publish()
        }
    }

    func setLabel(session: String, label: String) {
        queue.async {
            guard var s = try? self.store.session(id: session) else { return }
            s.taskLabel = label.isEmpty ? nil : label
            s.labelSource = "user"
            try? self.store.upsertSession(s)
            _ = try? self.store.addCorrection(session: session, eventId: nil, fromT: nil, toT: nil, action: "label", note: label)
            self.lastSummaryKey = ""
            self.publish()
        }
    }

    func pause(hours: Double?) {
        var s = settings
        s.pausedUntil = hours.map { nowMs() + $0 * 3_600_000 }
        apply(s)
        queue.async { self.correlator.pauseChanged(now: nowMs()) }
    }

    func apply(_ s: LedgerSettings) {
        settings = s
        s.save()
        queue.async { self.correlator.settings = s; self.publish() }
    }

    func export(session id: String) {
        queue.async {
            do {
                let urls = try Exporter.export(store: self.store, session: id)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                    self.message = "Exported \(urls.map { $0.lastPathComponent }.joined(separator: " and "))"
                }
            } catch {
                DispatchQueue.main.async { self.message = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

    func verifyIntegrity() {
        queue.async {
            let text: String
            if let v = try? self.store.verifyChain() {
                text = v.ok ? "Hash chain intact over \(v.checked) events." : "Hash chain broken at event \(v.firstBadEventId ?? -1)."
            } else { text = "Integrity check failed to run." }
            DispatchQueue.main.async { self.message = text }
        }
    }

    // MARK: Data access for detail views

    struct SessionDetail {
        var session: SessionRecord
        var events: [StoredEvent]
        var attributions: [Int64: Attribution]
        var corrections: [Correction]
        var tabs: [(tab: Int, boundAt: Double, unboundAt: Double?, evidence: String?)]
    }

    func loadDetail(_ id: String, completion: @escaping (SessionDetail?) -> Void) {
        queue.async {
            guard let s = try? self.store.session(id: id) else { DispatchQueue.main.async { completion(nil) }; return }
            let d = SessionDetail(session: s, events: (try? self.store.events(forSession: id)) ?? [],
                                  attributions: (try? self.store.latestAttributions(session: id)) ?? [:],
                                  corrections: (try? self.store.corrections(session: id)) ?? [],
                                  tabs: (try? self.store.sessionTabs(session: id)) ?? [])
            DispatchQueue.main.async { completion(d) }
        }
    }

    // MARK: Integrations

    static var binDir: URL { LedgerPaths.supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var hookBinary: String { binDir.appendingPathComponent("ledger-hook").path }
    static var hostBinary: String { binDir.appendingPathComponent("ledger-host").path }

    /// Copies the helper binaries to a stable location so hooks and Chrome keep working
    /// wherever the app bundle lives.
    private func installHelperBinaries() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.binDir, withIntermediateDirectories: true)
        let bundleHelpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let siblings = Bundle.main.executableURL?.deletingLastPathComponent()
        for name in ["ledger-hook", "ledger-host", "ledgerctl"] {
            let candidates = [bundleHelpers.appendingPathComponent(name), siblings?.appendingPathComponent(name)].compactMap { $0 }
            guard let src = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            let dst = Self.binDir.appendingPathComponent(name)
            let same = (try? Data(contentsOf: src)) == (try? Data(contentsOf: dst))
            if !same {
                let tmp = dst.appendingPathExtension("new")
                try? fm.removeItem(at: tmp)
                do {
                    try fm.copyItem(at: src, to: tmp)
                    _ = try fm.replaceItemAt(dst, withItemAt: tmp)
                } catch {
                    try? fm.removeItem(at: dst)
                    try? fm.moveItem(at: tmp, to: dst)
                }
                chmod(dst.path, 0o755)
            }
        }
        installExtensionFiles()
    }

    static var extensionDir: URL { LedgerPaths.supportDir.appendingPathComponent("extension", isDirectory: true) }

    /// Copies the bundled Chrome extension to a stable local folder. Chrome loads unpacked
    /// extensions from that folder; external volumes can mount late or need extra macOS
    /// permission, which makes Chrome drop the extension at startup.
    private func installExtensionFiles() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/extension")
        guard fm.fileExists(atPath: src.appendingPathComponent("manifest.json").path) else { return }
        let dst = Self.extensionDir
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let file as URL in walker {
            let rel = String(file.path.dropFirst(src.path.count + 1))
            let target = dst.appendingPathComponent(rel)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if (try? Data(contentsOf: file)) == (try? Data(contentsOf: target)) { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: file, to: target)
            extensionFilesChanged = true
        }
    }

    /// Set when launch copied new extension files; the next connecting extension is asked to
    /// reload so Chrome picks them up without a trip to chrome://extensions.
    private var extensionFilesChanged = false

    func refreshIntegrations() {
        hooksInstalled = [.claude: HookInstaller.isInstalled(agent: .claude), .codex: HookInstaller.isInstalled(agent: .codex)]
        DispatchQueue.global().async {
            let path = NativeHostInstaller.installedPath()
            DispatchQueue.main.async { self.hostRegisteredPath = path }
        }
    }

    func installHooks(_ agent: HookAgent) {
        do {
            let r = try HookInstaller.install(agent: agent, hookBinary: Self.hookBinary)
            message = r.message + (r.backup.map { ". Backup: \(($0 as NSString).lastPathComponent)" } ?? "") +
                (agent == .codex ? ". Codex may ask you to trust the new hooks." : ". New Claude Code sessions will use them.")
        } catch { message = "Hook install failed: \(error.localizedDescription)" }
        refreshIntegrations()
    }

    func uninstallHooks(_ agent: HookAgent) {
        do { message = try HookInstaller.uninstall(agent: agent).message } catch { message = "Hook removal failed: \(error.localizedDescription)" }
        refreshIntegrations()
    }

    /// Keeps Chrome's native host registration pointing at this install, with every known
    /// extension ID. Agent hooks are never installed without the user asking.
    private func registerHostIfNeeded() {
        // AGENT_LEDGER_NO_REGISTER=1 (demo/test instances) leaves Chrome's registration alone.
        if ProcessInfo.processInfo.environment["AGENT_LEDGER_NO_REGISTER"] == "1" { return }
        DispatchQueue.global().async {
            guard NativeHostInstaller.chromeInstalled,
                  FileManager.default.fileExists(atPath: Self.hostBinary),
                  NativeHostInstaller.needsUpdate(hostBinary: Self.hostBinary) else { return }
            _ = try? NativeHostInstaller.install(hostBinary: Self.hostBinary)
            DispatchQueue.main.async { self.refreshIntegrations() }
        }
    }

    func registerHost() {
        DispatchQueue.global().async {
            let text: String
            do { text = try NativeHostInstaller.install(hostBinary: Self.hostBinary).message }
            catch { text = "Native host registration failed: \(error.localizedDescription)" }
            DispatchQueue.main.async { self.message = text; self.refreshIntegrations() }
        }
    }
}
