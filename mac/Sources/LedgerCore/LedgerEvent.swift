import Foundation

/// The wire envelope shared by every sensor. See docs/PROTOCOL.md.
public struct LedgerEvent: Codable, Sendable, Equatable {
    public var v: Int?
    public var src: String
    public var inst: String?
    public var seq: Int?
    /// Observation time at the sensor, Unix epoch milliseconds.
    public var t: Double
    public var kind: String
    public var cat: String
    public var tab: Int?
    public var win: Int?
    public var frame: Int?
    public var doc: String?
    public var url: String?
    public var rec: Bool?
    public var pre: Bool?
    public var p: JSONValue?

    public init(src: String, inst: String? = nil, seq: Int? = nil, t: Double, kind: String, cat: String,
                tab: Int? = nil, win: Int? = nil, frame: Int? = nil, doc: String? = nil, url: String? = nil,
                rec: Bool? = nil, pre: Bool? = nil, p: JSONValue? = nil) {
        self.v = 1
        self.src = src; self.inst = inst; self.seq = seq; self.t = t; self.kind = kind; self.cat = cat
        self.tab = tab; self.win = win; self.frame = frame; self.doc = doc; self.url = url
        self.rec = rec; self.pre = pre; self.p = p
    }
}

public enum EventKind {
    public static let runtimeIntent = "runtime_intent"
    public static let attemptedOp = "attempted_op"
    public static let runtimeReport = "runtime_report"
    public static let observedEffect = "observed_effect"
    public static let context = "context"
    public static let gap = "gap"
    public static let sensorHealth = "sensor_health"
}

/// An event as stored, with storage metadata.
public struct StoredEvent: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var event: LedgerEvent
    /// Unix epoch milliseconds when the app received it.
    public var receivedAt: Double
    public var hash: String

    public var observedDate: Date { Date(timeIntervalSince1970: event.t / 1000) }
}

public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// Message framing between producers and the app.
public struct WireMessage: Codable {
    public var type: String
    public var events: [LedgerEvent]?
    public var role: String?
    public var pid: Int?
    public var agent: String?
    public var ext: String?

    public init(type: String, events: [LedgerEvent]? = nil, role: String? = nil, pid: Int? = nil,
                agent: String? = nil, ext: String? = nil) {
        self.type = type; self.events = events; self.role = role; self.pid = pid; self.agent = agent; self.ext = ext
    }

    public func line() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var d = (try? enc.encode(self)) ?? Data()
        d.append(0x0A)
        return d
    }
}
