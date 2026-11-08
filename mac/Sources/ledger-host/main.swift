import Foundation
import Darwin
import LedgerCore

// Chrome native messaging host for the Agent Ledger extension.
//
// Chrome starts this process when the extension calls connectNative(), with the caller's
// origin as an argument. It relays extension messages to the app's Unix socket and app
// commands back to the extension. When the app is down, only events from armed tabs, gaps
// and health events are spooled to disk; ordinary browsing metadata is dropped.

signal(SIGPIPE, SIG_IGN)

let callerOrigin = CommandLine.arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") } ?? "unknown"
let stdoutLock = NSLock()
let stateLock = NSLock()

var client: SocketClient?
var appDownSince: Double?
var droppedWhileDown = 0
var lastHello: Data?
var hostSeq = 0
let hostInst = "host-\(getpid())-\(Int(nowMs()))"

func writeFrame(_ json: Data) {
    stdoutLock.lock(); defer { stdoutLock.unlock() }
    var len = UInt32(json.count).littleEndian
    let header = Data(bytes: &len, count: 4)
    FileHandle.standardOutput.write(header + json)
}

func sendStatus(_ connected: Bool) {
    let msg: JSONValue = ["type": "status", "app": .bool(connected)]
    writeFrame(msg.canonicalData())
}

func hostEvent(kind: String, cat: String, p: JSONValue) -> LedgerEvent {
    hostSeq += 1
    return LedgerEvent(src: "host", inst: hostInst, seq: hostSeq, t: nowMs(), kind: kind, cat: cat, p: p)
}

func helloLine() -> Data {
    WireMessage(type: "hello", role: "host", pid: Int(getpid()), ext: callerOrigin).line()
}

/// Connects (or reconnects) to the app. Must be called with stateLock held.
func ensureConnectedLocked() -> SocketClient? {
    if let c = client { return c }
    let c = SocketClient()
    guard c.connect(timeoutMs: 300), c.send(helloLine()) else { return nil }
    client = c
    if let hello = lastHello { _ = c.send(hello) }
    if let since = appDownSince {
        let gap = hostEvent(kind: EventKind.gap, cat: "gap.app_down",
                            p: ["from": .number(since), "to": .number(nowMs()),
                                "droppedUnarmedEvents": .number(Double(droppedWhileDown))])
        _ = c.send(WireMessage(type: "events", events: [gap]).line())
        appDownSince = nil
        droppedWhileDown = 0
    }
    sendStatus(true)
    startReader(c)
    return c
}

func markDisconnectedLocked() {
    client?.close()
    client = nil
    if appDownSince == nil { appDownSince = nowMs(); sendStatus(false) }
}

func startReader(_ c: SocketClient) {
    Thread.detachNewThread {
        while let lines = c.readLines() {
            for line in lines { writeFrame(line) }
        }
        stateLock.lock()
        if client === c { markDisconnectedLocked() }
        stateLock.unlock()
    }
}

func spoolFiltered(_ data: Data) {
    guard let msg = try? JSONDecoder().decode(WireMessage.self, from: data), let events = msg.events else { return }
    let keep = events.filter { $0.rec == true || $0.kind == EventKind.gap || $0.kind == EventKind.sensorHealth }
    droppedWhileDown += events.count - keep.count
    if !keep.isEmpty {
        LedgerPaths.ensureDirectories()
        Spool.append(role: "host", line: WireMessage(type: "events", events: keep).line())
    }
}

func handleExtensionMessage(_ data: Data) {
    guard let value = JSONValue.parse(data), let type = value["type"]?.stringValue else { return }
    var line = data
    line.append(0x0A)
    stateLock.lock(); defer { stateLock.unlock() }
    switch type {
    case "hello":
        var p = value.objectValue ?? [:]
        p["callerOrigin"] = .string(callerOrigin)
        p["hostPid"] = .number(Double(getpid()))
        let e = hostEvent(kind: EventKind.sensorHealth, cat: "health.extension_hello", p: .object(p))
        let helloEvents = WireMessage(type: "events", events: [e]).line()
        lastHello = helloEvents
        if let c = client {
            if !c.send(helloEvents) { markDisconnectedLocked() }
        } else if ensureConnectedLocked() == nil {
            // ensureConnectedLocked sends lastHello itself when it connects.
            markDisconnectedLocked()
            sendStatus(false)
        }
    case "events":
        if let c = ensureConnectedLocked(), c.send(line) { return }
        markDisconnectedLocked()
        spoolFiltered(data)
    case "ping":
        writeFrame((["type": "pong", "app": .bool(client != nil)] as JSONValue).canonicalData())
    default:
        break
    }
}

// Periodically retry the app connection while it's down.
Thread.detachNewThread {
    while true {
        sleep(2)
        stateLock.lock()
        if client == nil { _ = ensureConnectedLocked() }
        stateLock.unlock()
    }
}

// Main loop: read native messaging frames from Chrome.
let maxFrame = 16 * 1024 * 1024
func readExact(_ count: Int) -> Data? {
    var out = Data(capacity: count)
    var buf = [UInt8](repeating: 0, count: min(count, 65536))
    while out.count < count {
        let n = read(STDIN_FILENO, &buf, min(buf.count, count - out.count))
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        out.append(buf, count: n)
    }
    return out
}

while let header = readExact(4) {
    let len = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    guard len > 0, len <= maxFrame, let body = readExact(len) else { break }
    handleExtensionMessage(body)
}

// Chrome closed the port.
stateLock.lock()
if let c = client {
    let e = hostEvent(kind: EventKind.sensorHealth, cat: "health.extension_disconnected", p: ["callerOrigin": .string(callerOrigin)])
    _ = c.send(WireMessage(type: "events", events: [e]).line())
    c.close()
}
stateLock.unlock()
exit(0)
