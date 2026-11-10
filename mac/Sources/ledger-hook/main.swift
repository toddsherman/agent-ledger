import Foundation
import Darwin
import LedgerCore

// Logging-only hook for Claude Code and Codex.
//
// Contract: never block or alter the agent. Always exit 0, never write to stdout, and give up
// quickly if the app isn't reachable (falling back to the spool directory).
//
// Usage: ledger-hook --agent claude|codex
//        ledger-hook --selftest <nonce>

signal(SIGPIPE, SIG_IGN)

var agent = HookAgent.claude
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--agent"), i + 1 < args.count, let a = HookAgent(rawValue: args[i + 1]) {
    agent = a
}

// Self-test, run by the app (never by an agent's hook): prove this program can reach the app.
// Nothing is spooled, and the exit code says whether it got through.
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    let ping = LedgerEvent(src: "hook.selftest", t: nowMs(), kind: EventKind.sensorHealth, cat: "selftest.ping",
                           p: ["nonce": .string(args[i + 1])])
    let c = SocketClient()
    let ok = c.connect(timeoutMs: 1000) &&
        c.send(WireMessage(type: "hello", role: "hook", pid: Int(getpid()), agent: "selftest").line() +
               WireMessage(type: "events", events: [ping]).line())
    c.close()
    exit(ok ? 0 : 1)
}

// Read stdin with a size cap; hook payloads with tool results can be large.
let limit = 8 * 1024 * 1024
var data = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while data.count < limit {
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n <= 0 { break }
    data.append(buf, count: n)
}

let ppid = getppid()
// Hooks run through a shell; the agent is usually the shell's parent.
var agentPid = ppid
if let parentPath = Processes.path(of: ppid), parentPath.hasSuffix("/sh") || parentPath.hasSuffix("/bash") ||
    parentPath.hasSuffix("/zsh"), let gp = Processes.parentPID(of: ppid), gp > 1 {
    agentPid = gp
}

guard let event = HookTranslator.translate(stdin: data, agent: agent, ppid: ppid, agentPid: agentPid) else { exit(0) }

let hello = WireMessage(type: "hello", role: "hook", pid: Int(getpid()), agent: agent.rawValue).line()
let line = WireMessage(type: "events", events: [event]).line()

let client = SocketClient()
if client.connect(timeoutMs: 250), client.send(hello + line) {
    client.close()
} else {
    LedgerPaths.ensureDirectories()
    Spool.append(role: "hook", line: line)
}
exit(0)
