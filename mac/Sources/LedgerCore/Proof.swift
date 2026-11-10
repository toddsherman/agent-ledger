import Foundation

/// A session export that someone else can check without the ledger.
///
/// The file is JSON lines. The first line is a header. Then comes one line for every event in the
/// ledger between the session's first and last event, in ledger order:
/// - the session's own events carry `m`, the 15 fields the hash was computed over, in order:
///   src, inst, seq, observedAt, receivedAt, kind, cat, tab, win, frame, doc, url, rec, pre, payload
/// - events from outside the session carry only their hash, so their content stays private
///
/// Each event's hash is SHA-256 over the previous hash and those fields, joined by U+001F.
/// A passing check shows that the session's events are exactly as recorded and that nothing was
/// removed or inserted between them. It can't show that the whole ledger wasn't rebuilt; for that,
/// compare `head` with a copy of the chain head kept somewhere else (`ledgerctl head`).
public enum Proof {
    public struct Result: Equatable {
        public var ok: Bool
        public var session: String
        public var events: Int
        public var others: Int
        public var firstBadId: Int64?
        public var problem: String?
    }

    public static func bundle(store: LedgerStore, session id: String, now: Double = nowMs()) throws -> Data? {
        let rows = try store.proofRows(session: id)
        guard let first = rows.first, let last = rows.last else { return nil }
        let head = try store.chainHead()
        var out = Data()
        func line(_ v: JSONValue) { out.append(v.canonicalData()); out.append(0x0A) }
        line(["type": "proof", "version": 1, "session": .string(id), "firstId": .number(Double(first.id)),
              "lastId": .number(Double(last.id)), "startPrev": .string(first.prev),
              "head": ["id": .number(Double(head.id)), "hash": .string(head.hash)], "exportedAt": .number(now)])
        for r in rows {
            if let m = r.material {
                line(["id": .number(Double(r.id)), "hash": .string(r.hash), "m": .array(m.map { .string($0) })])
            } else {
                line(["id": .number(Double(r.id)), "hash": .string(r.hash)])
            }
        }
        return out
    }

    public static func verify(_ data: Data) -> Result {
        var res = Result(ok: false, session: "", events: 0, others: 0, firstBadId: nil, problem: nil)
        let lines = data.split(separator: 0x0A).compactMap { JSONValue.parse(Data($0)) }
        guard let h = lines.first, h["type"]?.stringValue == "proof", var prev = h["startPrev"]?.stringValue,
              let firstId = h["firstId"]?.doubleValue, let lastId = h["lastId"]?.doubleValue else {
            res.problem = "not a proof file"; return res
        }
        res.session = h["session"]?.stringValue ?? ""
        var lastSeen: Double = firstId - 1
        for l in lines.dropFirst() {
            guard let idD = l["id"]?.doubleValue, let hash = l["hash"]?.stringValue else {
                res.problem = "unreadable line"; return res
            }
            let id = Int64(idD)
            guard idD > lastSeen else { res.firstBadId = id; res.problem = "events out of order"; return res }
            lastSeen = idD
            if let m = l["m"]?.arrayValue?.compactMap({ $0.stringValue }) {
                guard m.count == 15, LedgerStore.sha256(([prev] + m).joined(separator: "\u{1f}")) == hash else {
                    res.firstBadId = id; res.problem = "event \(id) doesn't match its hash"; return res
                }
                res.events += 1
            } else {
                res.others += 1
            }
            prev = hash
        }
        guard lastSeen == lastId, res.events > 0 else { res.problem = "events are missing from the end"; return res }
        res.ok = true
        return res
    }

    public static func resultText(_ r: Result) -> String {
        guard r.ok else { return "Proof failed: \(r.problem ?? "unknown")" }
        let others = r.others == 0 ? "" : " (\(r.others) events from outside the session are covered by hash only)"
        return "Proof holds for \(r.session): \(r.events) events are as recorded, with nothing removed between them\(others)"
    }
}

/// Whether an ingest connection comes from one of the recorder's own helper programs.
public enum SenderCheck {
    public static func isKnown(path: String?, supportDir: URL = LedgerPaths.supportDir) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["ledger-host", "ledger-hook", "ledgerctl"].contains(url.lastPathComponent) else { return false }
        let dir = url.deletingLastPathComponent().path
        if dir == supportDir.appendingPathComponent("bin").resolvingSymlinksInPath().path { return true }
        return dir.hasSuffix(".app/Contents/Helpers")
    }
}
