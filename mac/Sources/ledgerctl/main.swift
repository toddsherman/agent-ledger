import Foundation
import Darwin
import LedgerCore

// Command-line companion for Agent Ledger.
//
//   ledgerctl status
//   ledgerctl install-host | uninstall-host
//   ledgerctl install-hooks claude|codex | uninstall-hooks claude|codex
//   ledgerctl sessions
//   ledgerctl export <session-id>
//   ledgerctl verify

let args = Array(CommandLine.arguments.dropFirst())
let bin = LedgerPaths.supportDir.appendingPathComponent("bin")
let hookBinary = bin.appendingPathComponent("ledger-hook").path
let hostBinary = bin.appendingPathComponent("ledger-host").path

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func agentArg(_ i: Int) -> HookAgent {
    guard args.count > i, let a = HookAgent(rawValue: args[i]) else { fail("expected claude or codex") }
    return a
}
func openStore() -> LedgerStore {
    do { return try LedgerStore(url: LedgerPaths.databaseURL) } catch { fail("cannot open ledger: \(error)") }
}

switch args.first {
case "status":
    print("support dir:      \(LedgerPaths.supportDir.path)")
    print("helpers present:  hook=\(FileManager.default.fileExists(atPath: hookBinary)) host=\(FileManager.default.fileExists(atPath: hostBinary))")
    print("app listening:    \(FileManager.default.fileExists(atPath: LedgerPaths.socketPath))")
    print("native host:      \(NativeHostInstaller.installedPath() ?? "not registered")")
    print("claude hooks:     \(HookInstaller.isInstalled(agent: .claude) ? "installed" : "not installed")")
    print("codex hooks:      \(HookInstaller.isInstalled(agent: .codex) ? "installed" : "not installed")")
    let statusURL = LedgerPaths.supportDir.appendingPathComponent("status.json")
    if let data = try? Data(contentsOf: statusURL), let st = JSONValue.parse(data) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        func clock(_ v: JSONValue?) -> String { v?.doubleValue.map { f.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? "never" }
        print("live (as of \(clock(st["writtenAt"]))): extension \(st["extensionConnected"]?.boolValue == true ? "connected" : "not connected"), last hook claude \(clock(st["lastHookAt"]?["claude-code"])), codex \(clock(st["lastHookAt"]?["codex"]))")
        for s in st["sessions"]?.arrayValue ?? [] {
            print("  live session \(s["id"]?.stringValue ?? "?") \(s["agent"]?.stringValue ?? "?") \(s["state"]?.stringValue ?? "?") tabs=\(s["tabs"]?.arrayValue?.count ?? 0)")
        }
        let hooks = st["recentHooks"]?.arrayValue ?? []
        if !hooks.isEmpty { print("recent hook arrivals (metadata only):") }
        for h in hooks.suffix(25) {
            let keys = h["inputKeys"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: ",") ?? ""
            print("  \(clock(h["t"])) \(h["agent"]?.stringValue ?? "?") \(h["cat"]?.stringValue ?? "?") tool=\(h["tool"]?.stringValue ?? "-") browser=\(h["browser"]?.boolValue == true) tabs=\(h["tabIds"]?.intValue ?? 0) keys=[\(keys)]")
        }
    }
case "install-host":
    guard FileManager.default.fileExists(atPath: hostBinary) else { fail("launch Agent Ledger.app once first (it installs \(hostBinary))") }
    print(try NativeHostInstaller.install(hostBinary: hostBinary).message)
case "uninstall-host":
    print(try NativeHostInstaller.uninstall().message)
case "install-hooks":
    guard FileManager.default.fileExists(atPath: hookBinary) else { fail("launch Agent Ledger.app once first (it installs \(hookBinary))") }
    let r = try HookInstaller.install(agent: agentArg(1), hookBinary: hookBinary)
    print(r.message)
    if let b = r.backup { print("backup: \(b)") }
case "uninstall-hooks":
    let r = try HookInstaller.uninstall(agent: agentArg(1))
    print(r.message)
    if let b = r.backup { print("backup: \(b)") }
case "sessions":
    for s in try openStore().sessionSummaries(limit: 50) {
        let r = s.session
        print("\(r.id)  \(Correlator.displayAgent(r.agent)) [\(r.attribution)] \(r.state)  events=\(s.eventCount) changes=\(s.changeCount) gaps=\(s.gapCount)  \(s.hosts.joined(separator: ","))  \(r.taskLabel ?? "")")
    }
case "export":
    guard args.count > 1 else { fail("usage: ledgerctl export <session-id>") }
    for u in try Exporter.export(store: openStore(), session: args[1]) { print(u.path) }
case "snapshot":
    guard args.count > 1 else { fail("usage: ledgerctl snapshot <out.png>  (the Ledger window must be open)") }
    let out = URL(fileURLWithPath: args[1]).standardizedFileURL
    try? FileManager.default.removeItem(at: out)
    let client = SocketClient()
    guard client.connect() else { fail("Agent Ledger isn't running") }
    let req: JSONValue = ["type": "snapshot", "path": .string(out.path)]
    var line = WireMessage(type: "hello", role: "ctl", pid: Int(getpid())).line()
    line.append(req.canonicalData()); line.append(0x0A)
    _ = client.send(line)
    guard let replies = client.readLines(), let reply = replies.compactMap({ JSONValue.parse($0) }).first(where: { $0["type"]?.stringValue == "snapshot.result" }) else {
        fail("no reply from Agent Ledger")
    }
    if reply["ok"]?.boolValue != true { fail("snapshot failed: \(reply["error"]?.stringValue ?? "unknown")") }
    print(out.path)
case "verify":
    let v = try openStore().verifyChain()
    print(v.ok ? "hash chain intact over \(v.checked) events" : "hash chain broken at event \(v.firstBadEventId ?? -1)")
default:
    print("usage: ledgerctl status | install-host | uninstall-host | install-hooks <claude|codex> | uninstall-hooks <claude|codex> | sessions | export <id> | verify")
}
