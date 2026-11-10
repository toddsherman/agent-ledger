import Foundation
import CryptoKit

public struct SessionRecord: Identifiable, Sendable, Equatable {
    public var id: String
    /// `claude-code`, `codex`, or `unknown`.
    public var agent: String
    public var runtimeSession: String?
    /// `possible`, `recording`, `inactive`, `ended`.
    public var state: String
    public var startedAt: Double
    public var lastActivityAt: Double
    public var endedAt: Double?
    public var taskLabel: String?
    public var labelSource: String?
    public var startReason: String
    /// `identified`, `likely`, `unknown`, `mixed` — how the session's agent was named.
    public var attribution: String
    /// `ok` or `degraded`.
    public var coverage: String
    public var detectorVersion: String

    public init(id: String, agent: String, runtimeSession: String?, state: String, startedAt: Double,
                lastActivityAt: Double, endedAt: Double? = nil, taskLabel: String? = nil,
                labelSource: String? = nil, startReason: String, attribution: String,
                coverage: String = "ok", detectorVersion: String) {
        self.id = id; self.agent = agent; self.runtimeSession = runtimeSession; self.state = state
        self.startedAt = startedAt; self.lastActivityAt = lastActivityAt; self.endedAt = endedAt
        self.taskLabel = taskLabel; self.labelSource = labelSource; self.startReason = startReason
        self.attribution = attribution; self.coverage = coverage; self.detectorVersion = detectorVersion
    }
}

public struct SessionSummary: Sendable, Identifiable, Equatable {
    public var session: SessionRecord
    public var eventCount: Int
    public var tabCount: Int
    public var hosts: [String]
    public var gapCount: Int
    public var changeCount: Int
    public var id: String { session.id }
}

public struct Attribution: Sendable, Equatable {
    public var eventId: Int64
    public var sessionId: String?
    /// `agent:claude-code`, `agent:codex`, `human`, `unknown`, `mixed`.
    public var actor: String
    /// `identified`, `likely`, `unknown`, `mixed`.
    public var label: String
    /// What the evidence identifies: `runtime-session`, `operation`, `extension`, `inference`.
    public var scope: String?
    public var reasons: [String]
    public var detectorVersion: String
    public var createdAt: Double

    public init(eventId: Int64, sessionId: String?, actor: String, label: String, scope: String?,
                reasons: [String], detectorVersion: String, createdAt: Double) {
        self.eventId = eventId; self.sessionId = sessionId; self.actor = actor; self.label = label
        self.scope = scope; self.reasons = reasons; self.detectorVersion = detectorVersion; self.createdAt = createdAt
    }
}

public struct Correction: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var sessionId: String?
    public var eventId: Int64?
    public var fromT: Double?
    public var toT: Double?
    /// `this-was-me`, `wrong-agent`, `include-tab`, `exclude`, `stop-recording`, `label`.
    public var action: String
    public var note: String?
    public var createdAt: Double
}

public struct ChainVerification: Sendable {
    public var ok: Bool
    public var checked: Int
    public var firstBadEventId: Int64?
}

/// The local evidence store. Raw events are append-only and hash-chained; inferences and
/// corrections live in separate tables and never modify raw events.
public final class LedgerStore: @unchecked Sendable {
    public let db: SQLiteDB
    private let lock = NSRecursiveLock()
    private var lastHash: String = ""

    public static let genesisHash = String(repeating: "0", count: 64)

    /// What the anchor file said about the ledger when it was opened (nil without an anchor file).
    public private(set) var openingCheck: AnchorCheck?
    private let anchorURL: URL?
    private let fileURL: URL
    private let openedInode: UInt64?

    /// `anchorURL`: a small file holding the last event's ID and hash, rewritten on every append.
    /// Only the app passes it; read-only tools leave it nil.
    public init(url: URL, anchorURL: URL? = nil) throws {
        db = try SQLiteDB(path: url.path)
        fileURL = url
        self.anchorURL = anchorURL
        openedInode = Self.inode(url)
        try migrate()
        lastHash = try loadLastHash()
        if let anchorURL {
            openingCheck = try checkAnchor(Anchor.read(anchorURL))
            writeAnchor()
        }
    }

    static func inode(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    public struct Anchor: Equatable, Sendable {
        public var id: Int64
        public var hash: String
        public var at: Double
        public init(id: Int64, hash: String, at: Double) { self.id = id; self.hash = hash; self.at = at }

        public static func read(_ url: URL) -> Anchor? {
            guard let d = try? Data(contentsOf: url), let j = JSONValue.parse(d), let h = j["hash"]?.stringValue,
                  let id = j["id"]?.doubleValue else { return nil }
            return Anchor(id: Int64(id), hash: h, at: j["at"]?.doubleValue ?? 0)
        }
    }

    public enum AnchorCheck: Equatable, Sendable {
        case ok
        /// No anchor file yet (first run of a version that keeps one).
        case noAnchor
        /// The event the anchor names is gone, or its hash differs.
        case removedOrChanged(anchorId: Int64, lastId: Int64)
        /// Events were appended while the app wasn't running.
        case addedOutside(count: Int, firstId: Int64)

        public var changed: Bool { self != .ok && self != .noAnchor }
    }

    func checkAnchor(_ a: Anchor?) throws -> AnchorCheck {
        guard let a else { return .noAnchor }
        let last = try db.query("SELECT id FROM events ORDER BY id DESC LIMIT 1").first?.int64("id") ?? 0
        if a.id == 0 {
            // The ledger was empty; anything present now was added outside the app.
        } else if let row = try db.query("SELECT hash FROM events WHERE id = ?", [.int(a.id)]).first {
            if row.string("hash") != a.hash { return .removedOrChanged(anchorId: a.id, lastId: last) }
        } else {
            // A retention purge can remove the anchored event; the chain anchor then carries its hash.
            let purged = try db.query("SELECT value FROM meta WHERE key = 'chain_anchor'").first?.string("value")
            if !(last == 0 && purged == a.hash) { return .removedOrChanged(anchorId: a.id, lastId: last) }
        }
        // The app writes the anchor right after each append; a crash in between leaves at most one batch.
        let later = try db.query("SELECT id, received_at FROM events WHERE id > ? ORDER BY id", [.int(a.id)])
        let outside = later.filter { ($0.double("received_at") ?? 0) > a.at + 2000 }
        if let first = outside.first?.int64("id") { return .addedOutside(count: outside.count, firstId: first) }
        return .ok
    }

    private func writeAnchor() {
        guard let anchorURL else { return }
        let id = (try? db.query("SELECT id FROM events ORDER BY id DESC LIMIT 1").first?.int64("id")) ?? nil
        let j: JSONValue = ["id": .number(Double(id ?? 0)), "hash": .string(lastHash), "at": .number(nowMs())]
        try? j.canonicalData().write(to: anchorURL, options: .atomic)
    }

    public enum LiveCheck: Equatable, Sendable { case ok, fileReplaced, tailChanged }

    /// Cheap check while running: the database file is still the one opened, and its newest
    /// event is the one this process wrote last.
    public func liveCheck() -> LiveCheck {
        locked {
            if let openedInode, Self.inode(fileURL) != openedInode { return .fileReplaced }
            if let h = try? loadLastHash(), h != lastHash { return .tailChanged }
            return .ok
        }
    }

    /// Accepts the ledger as it is now (after a change was reported), so one change is reported once.
    public func acceptCurrentState() {
        locked {
            if let h = try? loadLastHash() { lastHash = h }
            writeAnchor()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func migrate() throws {
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          src TEXT NOT NULL, inst TEXT, seq INTEGER,
          observed_at REAL NOT NULL, received_at REAL NOT NULL,
          kind TEXT NOT NULL, cat TEXT NOT NULL,
          tab INTEGER, win INTEGER, frame INTEGER, doc TEXT, url TEXT,
          rec INTEGER, pre INTEGER,
          payload TEXT,
          prev_hash TEXT NOT NULL, hash TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_time ON events(observed_at);
        CREATE INDEX IF NOT EXISTS events_tab ON events(tab, observed_at);
        CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
          BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS events_guarded_delete BEFORE DELETE ON events
          WHEN (SELECT value FROM meta WHERE key = 'purge_in_progress') IS NULL
          BEGIN SELECT RAISE(ABORT, 'events can only be removed by retention purge'); END;

        CREATE TABLE IF NOT EXISTS sessions(
          id TEXT PRIMARY KEY, agent TEXT NOT NULL, runtime_session TEXT,
          state TEXT NOT NULL, started_at REAL NOT NULL, last_activity_at REAL NOT NULL, ended_at REAL,
          task_label TEXT, label_source TEXT, start_reason TEXT NOT NULL,
          attribution TEXT NOT NULL, coverage TEXT NOT NULL DEFAULT 'ok', detector_version TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sessions_started ON sessions(started_at);
        CREATE TABLE IF NOT EXISTS session_tabs(
          session_id TEXT NOT NULL, tab INTEGER NOT NULL, bound_at REAL NOT NULL, unbound_at REAL,
          evidence TEXT, PRIMARY KEY(session_id, tab, bound_at)
        );
        CREATE TABLE IF NOT EXISTS session_events(
          session_id TEXT NOT NULL, event_id INTEGER NOT NULL, PRIMARY KEY(session_id, event_id)
        );
        CREATE INDEX IF NOT EXISTS session_events_event ON session_events(event_id);
        CREATE TABLE IF NOT EXISTS attributions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, event_id INTEGER NOT NULL, session_id TEXT,
          actor TEXT NOT NULL, label TEXT NOT NULL, scope TEXT, reasons TEXT NOT NULL,
          detector_version TEXT NOT NULL, created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS attributions_event ON attributions(event_id);
        CREATE TABLE IF NOT EXISTS corrections(
          id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_id INTEGER,
          from_t REAL, to_t REAL, action TEXT NOT NULL, note TEXT, created_at REAL NOT NULL
        );
        """)
        try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1')")
    }

    private func loadLastHash() throws -> String {
        if let row = try db.query("SELECT hash FROM events ORDER BY id DESC LIMIT 1").first,
           let h = row.string("hash") { return h }
        if let anchor = try db.query("SELECT value FROM meta WHERE key = 'chain_anchor'").first?.string("value") {
            return anchor
        }
        return Self.genesisHash
    }

    // MARK: Events

    static func fmt(_ d: Double) -> String { String(format: "%.3f", d) }

    static func hashMaterial(prev: String, src: String, inst: String?, seq: Int?, observedAt: Double,
                             receivedAt: Double, kind: String, cat: String, tab: Int?, win: Int?, frame: Int?,
                             doc: String?, url: String?, rec: Bool?, pre: Bool?, payload: String?) -> String {
        return hashFields(prev: prev, src: src, inst: inst, seq: seq, observedAt: observedAt, receivedAt: receivedAt,
                          kind: kind, cat: cat, tab: tab, win: win, frame: frame, doc: doc, url: url, rec: rec,
                          pre: pre, payload: payload).joined(separator: "\u{1f}")
    }

    static func hashFields(prev: String, src: String, inst: String?, seq: Int?, observedAt: Double,
                           receivedAt: Double, kind: String, cat: String, tab: Int?, win: Int?, frame: Int?,
                           doc: String?, url: String?, rec: Bool?, pre: Bool?, payload: String?) -> [String] {
        func s(_ x: Any?) -> String { x.map { "\($0)" } ?? "" }
        return [prev, src, s(inst), s(seq), fmt(observedAt), fmt(receivedAt), kind, cat, s(tab), s(win), s(frame),
                s(doc), s(url), rec.map { $0 ? "1" : "0" } ?? "", pre.map { $0 ? "1" : "0" } ?? "", s(payload)]
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Appends events in one transaction and returns their row IDs, in order.
    @discardableResult
    public func append(_ events: [LedgerEvent], receivedAt: Double = nowMs()) throws -> [Int64] {
        guard !events.isEmpty else { return [] }
        defer { appended() }
        return try locked {
            try db.transaction {
                let stmt = try db.prepare("""
                INSERT INTO events(src, inst, seq, observed_at, received_at, kind, cat, tab, win, frame, doc, url,
                                   rec, pre, payload, prev_hash, hash)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
                var ids: [Int64] = []
                var prev = lastHash
                for e in events {
                    let payload = e.p.map { $0.canonicalString() }
                    let material = Self.hashMaterial(prev: prev, src: e.src, inst: e.inst, seq: e.seq,
                                                     observedAt: e.t, receivedAt: receivedAt, kind: e.kind,
                                                     cat: e.cat, tab: e.tab, win: e.win, frame: e.frame,
                                                     doc: e.doc, url: e.url, rec: e.rec, pre: e.pre,
                                                     payload: payload)
                    let hash = Self.sha256(material)
                    try stmt.run([.text(e.src), .opt(e.inst), .opt(e.seq), .double(e.t), .double(receivedAt),
                                  .text(e.kind), .text(e.cat), .opt(e.tab), .opt(e.win), .opt(e.frame),
                                  .opt(e.doc), .opt(e.url), .opt(e.rec), .opt(e.pre), .opt(payload),
                                  .text(prev), .text(hash)])
                    ids.append(db.lastInsertRowID)
                    prev = hash
                }
                lastHash = prev
                return ids
            }
        }
    }

    private func appended() { locked { writeAnchor() } }

    static func decodeEvent(_ r: Row) -> StoredEvent {
        var e = LedgerEvent(src: r.string("src") ?? "?", inst: r.string("inst"), seq: r.int("seq"),
                            t: r.double("observed_at") ?? 0, kind: r.string("kind") ?? "?",
                            cat: r.string("cat") ?? "?", tab: r.int("tab"), win: r.int("win"),
                            frame: r.int("frame"), doc: r.string("doc"), url: r.string("url"),
                            rec: r.bool("rec"), pre: r.bool("pre"),
                            p: r.string("payload").flatMap { JSONValue.parse(Data($0.utf8)) })
        e.v = 1
        return StoredEvent(id: r.int64("id") ?? 0, event: e, receivedAt: r.double("received_at") ?? 0,
                           hash: r.string("hash") ?? "")
    }

    public func events(forSession id: String) throws -> [StoredEvent] {
        try locked {
            try db.query("""
            SELECT e.* FROM events e JOIN session_events se ON se.event_id = e.id
            WHERE se.session_id = ? ORDER BY e.observed_at, e.id
            """, [.text(id)]).map(Self.decodeEvent)
        }
    }

    /// Events from one source in a time range (ms), oldest first.
    public func events(from: Double, to: Double, src: String) throws -> [StoredEvent] {
        try locked {
            try db.query("SELECT * FROM events WHERE observed_at >= ? AND observed_at <= ? AND src = ? ORDER BY id",
                         [.double(from), .double(to), .text(src)]).map(Self.decodeEvent)
        }
    }

    public func recentEvents(limit: Int = 200, kinds: [String]? = nil) throws -> [StoredEvent] {
        try locked {
            if let kinds, !kinds.isEmpty {
                let marks = kinds.map { _ in "?" }.joined(separator: ",")
                return try db.query("SELECT * FROM events WHERE kind IN (\(marks)) ORDER BY id DESC LIMIT ?",
                                    kinds.map { .text($0) } + [.int(Int64(limit))]).map(Self.decodeEvent)
            }
            return try db.query("SELECT * FROM events ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])
                .map(Self.decodeEvent)
        }
    }

    public func eventCount() throws -> Int {
        try locked { try db.query("SELECT COUNT(*) AS n FROM events").first?.int("n") ?? 0 }
    }

    /// Recomputes the hash chain. Detects edits made without recomputing every later hash;
    /// it cannot stop a process that can rewrite the whole file.
    public func verifyChain() throws -> ChainVerification {
        try locked {
            var prev = try db.query("SELECT value FROM meta WHERE key = 'chain_anchor'").first?.string("value")
                ?? Self.genesisHash
            var checked = 0
            for r in try db.query("SELECT * FROM events ORDER BY id") {
                let material = Self.hashMaterial(
                    prev: prev, src: r.string("src") ?? "", inst: r.string("inst"), seq: r.int("seq"),
                    observedAt: r.double("observed_at") ?? 0, receivedAt: r.double("received_at") ?? 0,
                    kind: r.string("kind") ?? "", cat: r.string("cat") ?? "", tab: r.int("tab"), win: r.int("win"),
                    frame: r.int("frame"), doc: r.string("doc"), url: r.string("url"), rec: r.bool("rec"),
                    pre: r.bool("pre"), payload: r.string("payload"))
                let expected = Self.sha256(material)
                if r.string("prev_hash") != prev || r.string("hash") != expected {
                    return ChainVerification(ok: false, checked: checked, firstBadEventId: r.int64("id"))
                }
                prev = expected
                checked += 1
            }
            return ChainVerification(ok: true, checked: checked, firstBadEventId: nil)
        }
    }

    /// Retention purge: removes events (and their inference rows) older than `cutoff` ms and
    /// re-anchors the chain at the last removed hash.
    @discardableResult
    public func purge(olderThan cutoff: Double) throws -> Int {
        try locked {
            try db.transaction {
                guard let last = try db.query("SELECT id, hash FROM events WHERE observed_at < ? ORDER BY id DESC LIMIT 1",
                                              [.double(cutoff)]).first,
                      let lastId = last.int64("id"), let lastHashRemoved = last.string("hash") else { return 0 }
                // Only purge a contiguous prefix so the chain stays verifiable.
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('purge_in_progress', '1')")
                try db.run("DELETE FROM attributions WHERE event_id <= ?", [.int(lastId)])
                try db.run("DELETE FROM session_events WHERE event_id <= ?", [.int(lastId)])
                try db.run("DELETE FROM events WHERE id <= ?", [.int(lastId)])
                let n = db.changes
                try db.run("DELETE FROM meta WHERE key = 'purge_in_progress'")
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('chain_anchor', ?)", [.text(lastHashRemoved)])
                try db.run("DELETE FROM sessions WHERE ended_at IS NOT NULL AND ended_at < ? AND id NOT IN (SELECT DISTINCT session_id FROM session_events)",
                           [.double(cutoff)])
                return n
            }
        }
    }

    // MARK: Sessions

    public func upsertSession(_ s: SessionRecord) throws {
        try locked {
            try db.run("""
            INSERT INTO sessions(id, agent, runtime_session, state, started_at, last_activity_at, ended_at, task_label,
                                 label_source, start_reason, attribution, coverage, detector_version)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET agent=excluded.agent, runtime_session=excluded.runtime_session,
              state=excluded.state, last_activity_at=excluded.last_activity_at, ended_at=excluded.ended_at,
              task_label=excluded.task_label, label_source=excluded.label_source, attribution=excluded.attribution,
              coverage=excluded.coverage, detector_version=excluded.detector_version
            """, [.text(s.id), .text(s.agent), .opt(s.runtimeSession), .text(s.state), .double(s.startedAt),
                  .double(s.lastActivityAt), .opt(s.endedAt), .opt(s.taskLabel), .opt(s.labelSource),
                  .text(s.startReason), .text(s.attribution), .text(s.coverage), .text(s.detectorVersion)])
        }
    }

    static func decodeSession(_ r: Row) -> SessionRecord {
        SessionRecord(id: r.string("id") ?? "", agent: r.string("agent") ?? "unknown",
                      runtimeSession: r.string("runtime_session"), state: r.string("state") ?? "ended",
                      startedAt: r.double("started_at") ?? 0, lastActivityAt: r.double("last_activity_at") ?? 0,
                      endedAt: r.double("ended_at"), taskLabel: r.string("task_label"),
                      labelSource: r.string("label_source"), startReason: r.string("start_reason") ?? "",
                      attribution: r.string("attribution") ?? "unknown", coverage: r.string("coverage") ?? "ok",
                      detectorVersion: r.string("detector_version") ?? "")
    }

    public func session(id: String) throws -> SessionRecord? {
        try locked { try db.query("SELECT * FROM sessions WHERE id = ?", [.text(id)]).first.map(Self.decodeSession) }
    }

    public func sessions(limit: Int = 500) throws -> [SessionRecord] {
        try locked {
            try db.query("SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))])
                .map(Self.decodeSession)
        }
    }

    public func sessionSummaries(limit: Int = 500) throws -> [SessionSummary] {
        try locked {
            let sessions = try self.sessions(limit: limit)
            return try sessions.map { s in
                let counts = try db.query("""
                SELECT COUNT(*) AS n,
                  SUM(CASE WHEN e.kind = 'gap' THEN 1 ELSE 0 END) AS gaps,
                  SUM(CASE WHEN e.cat IN ('field.change','form.submit','net.request','download.created','page.alert','edit.change')
                       AND (e.cat != 'net.request' OR json_extract(e.payload, '$.mutating') = 1) THEN 1 ELSE 0 END) AS changes
                FROM events e JOIN session_events se ON se.event_id = e.id WHERE se.session_id = ?
                """, [.text(s.id)]).first
                let tabs = try db.query("SELECT COUNT(DISTINCT tab) AS n FROM session_tabs WHERE session_id = ?",
                                        [.text(s.id)]).first?.int("n") ?? 0
                let urls = try db.query("""
                SELECT DISTINCT e.url FROM events e JOIN session_events se ON se.event_id = e.id
                WHERE se.session_id = ? AND e.url IS NOT NULL AND e.cat IN ('nav.committed','tab.updated','nav.history')
                LIMIT 50
                """, [.text(s.id)]).compactMap { $0.string("url") }
                var hosts: [String] = []
                for u in urls {
                    if let h = URL(string: u)?.host, !hosts.contains(h) { hosts.append(h) }
                }
                return SessionSummary(session: s, eventCount: counts?.int("n") ?? 0, tabCount: tabs, hosts: hosts,
                                      gapCount: counts?.int("gaps") ?? 0, changeCount: counts?.int("changes") ?? 0)
            }
        }
    }

    public func bindTab(session: String, tab: Int, at: Double, evidence: String) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO session_tabs(session_id, tab, bound_at, evidence) VALUES(?,?,?,?)",
                       [.text(session), .int(Int64(tab)), .double(at), .text(evidence)])
        }
    }

    public func unbindTab(session: String, tab: Int, at: Double) throws {
        try locked {
            try db.run("UPDATE session_tabs SET unbound_at = ? WHERE session_id = ? AND tab = ? AND unbound_at IS NULL",
                       [.double(at), .text(session), .int(Int64(tab))])
        }
    }

    public func sessionTabs(session: String) throws -> [(tab: Int, boundAt: Double, unboundAt: Double?, evidence: String?)] {
        try locked {
            try db.query("SELECT * FROM session_tabs WHERE session_id = ? ORDER BY bound_at", [.text(session)]).map {
                (tab: $0.int("tab") ?? -1, boundAt: $0.double("bound_at") ?? 0, unboundAt: $0.double("unbound_at"),
                 evidence: $0.string("evidence"))
            }
        }
    }

    public func link(session: String, eventIds: [Int64]) throws {
        guard !eventIds.isEmpty else { return }
        try locked {
            try db.transaction {
                let stmt = try db.prepare("INSERT OR IGNORE INTO session_events(session_id, event_id) VALUES(?,?)")
                for id in eventIds { try stmt.run([.text(session), .int(id)]) }
            }
        }
    }

    // MARK: Attributions and corrections

    public func addAttributions(_ items: [Attribution]) throws {
        guard !items.isEmpty else { return }
        try locked {
            try db.transaction {
                let stmt = try db.prepare("""
                INSERT INTO attributions(event_id, session_id, actor, label, scope, reasons, detector_version, created_at)
                VALUES(?,?,?,?,?,?,?,?)
                """)
                for a in items {
                    let reasons = JSONValue.array(a.reasons.map { .string($0) }).canonicalString()
                    try stmt.run([.int(a.eventId), .opt(a.sessionId), .text(a.actor), .text(a.label), .opt(a.scope),
                                  .text(reasons), .text(a.detectorVersion), .double(a.createdAt)])
                }
            }
        }
    }

    /// Latest attribution per event for a session's events.
    public func latestAttributions(session: String) throws -> [Int64: Attribution] {
        try locked {
            var out: [Int64: Attribution] = [:]
            for r in try db.query("""
            SELECT a.* FROM attributions a JOIN session_events se ON se.event_id = a.event_id
            WHERE se.session_id = ? ORDER BY a.id
            """, [.text(session)]) {
                let reasons = r.string("reasons").flatMap { JSONValue.parse(Data($0.utf8))?.arrayValue }?
                    .compactMap { $0.stringValue } ?? []
                let a = Attribution(eventId: r.int64("event_id") ?? 0, sessionId: r.string("session_id"),
                                    actor: r.string("actor") ?? "unknown", label: r.string("label") ?? "unknown",
                                    scope: r.string("scope"), reasons: reasons,
                                    detectorVersion: r.string("detector_version") ?? "",
                                    createdAt: r.double("created_at") ?? 0)
                out[a.eventId] = a
            }
            return out
        }
    }

    @discardableResult
    public func addCorrection(session: String?, eventId: Int64?, fromT: Double?, toT: Double?, action: String,
                              note: String?) throws -> Int64 {
        try locked {
            try db.run("INSERT INTO corrections(session_id, event_id, from_t, to_t, action, note, created_at) VALUES(?,?,?,?,?,?,?)",
                       [.opt(session), eventId.map { .int($0) } ?? .null, .opt(fromT), .opt(toT), .text(action),
                        .opt(note), .double(nowMs())])
            return db.lastInsertRowID
        }
    }

    public func corrections(session: String) throws -> [Correction] {
        try locked {
            try db.query("SELECT * FROM corrections WHERE session_id = ? ORDER BY id", [.text(session)]).map {
                Correction(id: $0.int64("id") ?? 0, sessionId: $0.string("session_id"), eventId: $0.int64("event_id"),
                           fromT: $0.double("from_t"), toT: $0.double("to_t"), action: $0.string("action") ?? "",
                           note: $0.string("note"), createdAt: $0.double("created_at") ?? 0)
            }
        }
    }

    public func meta(_ key: String) throws -> String? {
        try locked { try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value") }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try locked { try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)]) }
    }
}

extension LedgerStore {
    public struct ProofRow {
        public var id: Int64
        public var prev: String
        public var hash: String
        /// The hashed fields after the previous hash; nil for events outside the session.
        public var material: [String]?
    }

    /// Every event between the session's first and last, in ledger order.
    public func proofRows(session id: String) throws -> [ProofRow] {
        try locked {
            guard let range = try db.query("""
                SELECT MIN(event_id) AS a, MAX(event_id) AS b FROM session_events WHERE session_id = ?
                """, [.text(id)]).first, let a = range.int64("a"), let b = range.int64("b") else { return [] }
            return try db.query("""
                SELECT e.*, (SELECT 1 FROM session_events se WHERE se.event_id = e.id AND se.session_id = ?) AS mine
                FROM events e WHERE e.id >= ? AND e.id <= ? ORDER BY e.id
                """, [.text(id), .int(a), .int(b)]).map { r in
                var material: [String]?
                if r.int("mine") == 1 {
                    let full = Self.hashFields(
                        prev: "", src: r.string("src") ?? "", inst: r.string("inst"), seq: r.int("seq"),
                        observedAt: r.double("observed_at") ?? 0, receivedAt: r.double("received_at") ?? 0,
                        kind: r.string("kind") ?? "", cat: r.string("cat") ?? "", tab: r.int("tab"), win: r.int("win"),
                        frame: r.int("frame"), doc: r.string("doc"), url: r.string("url"), rec: r.bool("rec"),
                        pre: r.bool("pre"), payload: r.string("payload"))
                    material = Array(full.dropFirst())
                }
                return ProofRow(id: r.int64("id") ?? 0, prev: r.string("prev_hash") ?? "", hash: r.string("hash") ?? "",
                                material: material)
            }
        }
    }

    /// The last event's ID and hash: the value to keep somewhere outside this Mac.
    public func chainHead() throws -> (id: Int64, hash: String) {
        try locked {
            guard let r = try db.query("SELECT id, hash FROM events ORDER BY id DESC LIMIT 1").first else { return (0, Self.genesisHash) }
            return (r.int64("id") ?? 0, r.string("hash") ?? "")
        }
    }
}
