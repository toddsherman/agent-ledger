import Foundation

/// The ways an agent can reach Chrome, beyond the agents' own Chrome extensions.
///
/// - `extension`: Claude in Chrome or Codex's ChatGPT extension (tab-level evidence).
/// - `automation`: an MCP browser-automation tool (Playwright, Chrome DevTools, Browser MCP, …),
///   which usually drives a separate browser the extension can't see.
/// - `shell`: a shell command that opens URLs in Chrome, scripts it with AppleScript, starts
///   Chrome with automation flags, talks to its debugging port, or reads its profile files.
/// - `computer-use`: screen-level control aimed at Chrome.
public enum BrowserRoute {
    public static let extensionRoute = "extension"
    public static let automation = "automation"
    public static let shell = "shell"
    public static let computerUse = "computer-use"

    static let automationWords = ["playwright", "puppeteer", "devtools", "browser", "selenium", "chrome",
                                  "stagehand", "browserbase", "hyperbrowser", "webdriver"]

    /// Route for a tool name before looking at its input (nil: not a browser route by name).
    public static func byName(agent: HookAgent, toolName: String) -> String? {
        let name = toolName.lowercased()
        if name.contains("claude-in-chrome") || name.contains("claude_in_chrome") { return extensionRoute }
        if agent == .codex && name.contains("cua_repl") { return extensionRoute }
        if name.contains("computer-use") || name.contains("computer_use") { return computerUse }
        if name.hasPrefix("mcp__"), automationWords.contains(where: { name.contains($0) }) { return automation }
        return nil
    }

    /// Codex ends a browser task with a REPL call that carries only a summary and runs no code.
    public static func isClosingCall(agent: HookAgent, toolName: String, input: JSONValue?) -> Bool {
        guard agent == .codex, toolName.lowercased().contains("cua_repl"), let o = input?.objectValue else { return false }
        return o["code"] == nil && o["completion_summary"] != nil
    }

    static let shellToolWords = ["bash", "shell", "exec", "command", "terminal"]

    /// The shell script in a tool input, for tools that run shell commands.
    public static func shellCommand(toolName: String, input: JSONValue?) -> String? {
        let name = toolName.lowercased()
        guard shellToolWords.contains(where: { name.contains($0) }), let o = input?.objectValue else { return nil }
        if let s = (o["command"] ?? o["cmd"])?.stringValue { return s }
        if let parts = (o["command"] ?? o["cmd"])?.arrayValue?.compactMap({ $0.stringValue }), !parts.isEmpty {
            // ["bash", "-lc", "<script>"] carries the script as its last element.
            if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent),
               parts[1].hasPrefix("-"), parts[1].contains("c") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    /// Whether a computer-use input targets Chrome: true or false when it names apps, nil when
    /// it acts on the whole screen (the frontmost app decides).
    public static func computerUseTargetsChrome(_ input: JSONValue?) -> Bool? {
        guard let o = input?.objectValue else { return nil }
        var named: [String] = []
        for key in ["app", "application", "bundle_id", "bundleId", "apps", "applications", "name"] {
            if let s = o[key]?.stringValue { named.append(s) }
            if let a = o[key]?.arrayValue {
                for v in a {
                    if let s = v.stringValue { named.append(s) }
                    if let s = (v["name"] ?? v["bundleId"] ?? v["bundle_id"])?.stringValue { named.append(s) }
                }
            }
        }
        guard !named.isEmpty else { return nil }
        return named.contains { isChromeName($0) }
    }

    static func isChromeName(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("google chrome") || l.hasPrefix("com.google.chrome") || l == "chrome" || l.contains("chromium")
    }

    /// Minimal computer-use input: what it did and where, never typed text.
    public static func computerUseSummary(_ input: JSONValue?) -> JSONValue {
        guard let o = input?.objectValue else { return .null }
        var out: [String: JSONValue] = [:]
        for key in ["action", "app", "application", "bundle_id", "apps", "coordinate", "key", "scroll_direction"] {
            if let v = o[key] { out[key] = Redactor.sanitize(v) }
        }
        if let t = o["text"]?.stringValue { out["textLength"] = .number(Double(t.count)) }
        return .object(out)
    }
}

/// What a shell command does to Chrome, from a light parse of the command line.
public struct ShellFinding: Equatable, Sendable {
    public var kinds: [String] = []
    public var urls: [String] = []
    public var flags: [String] = []
    public var isEmpty: Bool { kinds.isEmpty }
}

public enum ShellAnalyzer {
    static let chromeBinaries: Set<String> = ["google chrome", "google chrome canary", "google chrome beta", "google chrome dev",
                                              "google chrome for testing", "chromium", "chrome", "google-chrome",
                                              "google-chrome-stable", "chrome-headless-shell", "chromium-browser"]
    static let automationPrograms: Set<String> = ["playwright", "puppeteer", "chromedriver", "agent-browser", "browser-use",
                                                  "chrome-devtools-mcp", "selenium-server", "webdriver-manager"]
    static let runners: Set<String> = ["npx", "pnpx", "bunx", "node", "deno", "bun", "python", "python3", "uv", "uvx",
                                       "pnpm", "yarn", "npm", "pip", "pip3", "pipx"]
    static let automationArgs = ["playwright", "puppeteer", "chrome-devtools-mcp", "selenium", "browser-use", "agent-browser",
                                 "@browserbasehq"]
    static let httpClients: Set<String> = ["curl", "wget", "http", "https", "websocat", "xh"]
    static let wrappers: Set<String> = ["sudo", "exec", "time", "nohup", "command", "builtin", "nice", "caffeinate", "env",
                                        "arch", "xcrun"]
    static let profileMarkers = ["/application support/google/chrome", "/application support/chromium",
                                 "/application support/google/chrome canary", "/google/chrome/default", "devtoolsactiveport"]
    static let debugMarkers = [":9222", "/json/version", "/json/list", "/devtools/browser", "/devtools/page", "devtoolsactiveport"]
    static let chromeMention = try! NSRegularExpression(
        pattern: "google chrome|com\\.google\\.chrome|application\\(['\"]chrome|\"chrome\"|chromium", options: [.caseInsensitive])

    public static func analyze(_ command: String) -> ShellFinding {
        var f = ShellFinding()
        func add(_ k: String) { if !f.kinds.contains(k) { f.kinds.append(k) } }
        func flag(_ k: String) { if !f.flags.contains(k) { f.flags.append(k) } }
        // AppleScript fed through a heredoc still counts (the whole command is searched), but
        // other heredoc bodies are data, not commands (a script writing docs about Chrome).
        let mentionsChrome = chromeMention.firstMatch(in: command, range: NSRange(location: 0, length: (command as NSString).length)) != nil

        for seg in segments(stripHeredocs(command)) {
            if seg.contains(where: { w in let l = w.lowercased(); return profileMarkers.contains { l.contains($0) } }) {
                add("profile-data")
            }
            let words = stripWrappers(seg)
            guard let first = words.first else { continue }
            let program = (first as NSString).lastPathComponent.lowercased()
            let args = Array(words.dropFirst())
            let lowerArgs = args.map { $0.lowercased() }

            if program == "open" {
                let urls = args.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                var app: String?
                for (i, a) in args.enumerated() where (a == "-a" || a == "-b") && i + 1 < args.count { app = args[i + 1] }
                // No -a/-b means the default browser; another named app isn't Chrome.
                let chromeApp = app.map(ShellAnalyzer.isChromeApp) ?? true
                if chromeApp && (!urls.isEmpty || app != nil) {
                    add("open-url")
                    f.urls += urls
                }
            }
            if program == "osascript" && mentionsChrome { add("applescript") }
            let launches = chromeBinaries.contains(program) || first.contains(".app/Contents/MacOS/Google Chrome") ||
                first.contains(".app/Contents/MacOS/Chromium")
            if launches {
                add("launch-chrome")
                f.urls += args.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            }
            if automationPrograms.contains(program) ||
                (runners.contains(program) && lowerArgs.contains(where: { a in automationArgs.contains { a.contains($0) } })) {
                add("automation-tool")
            }
            if program == "chrome-cli" { add("chrome-cli") }
            if httpClients.contains(program), lowerArgs.contains(where: { a in debugMarkers.contains { a.contains($0) } }) {
                add("remote-debugging")
            }
            // Chrome's own flags count only where Chrome is being started (directly, or with
            // `open -a "Google Chrome" --args …`).
            for a in lowerArgs where launches || (program == "open" && f.kinds.contains("open-url")) {
                if a.hasPrefix("--remote-debugging-port") || a.hasPrefix("--remote-debugging-pipe") { add("remote-debugging"); flag("remote-debugging") }
                if a.hasPrefix("--user-data-dir") { flag("user-data-dir") }
                if a.hasPrefix("--headless") { flag("headless") }
                if a == "--incognito" { flag("incognito") }
            }
        }
        if f.kinds.contains("applescript"), command.range(of: "incognito", options: .caseInsensitive) != nil { flag("incognito") }
        var seen: Set<String> = []
        f.urls = f.urls.map { Redactor.url($0) }.filter { seen.insert($0).inserted }
        return f
    }

    static func isChromeApp(_ s: String) -> Bool { BrowserRoute.isChromeName(s) }

    static let heredocStart = try! NSRegularExpression(pattern: "(?<!<)<<(?!<)-?\\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\\1")

    /// Removes heredoc bodies (the lines after `<<EOF` up to the `EOF` line).
    static func stripHeredocs(_ s: String) -> String {
        var out: [Substring] = []
        var delimiters: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if let d = delimiters.first {
                if line.trimmingCharacters(in: .whitespaces) == d { delimiters.removeFirst() }
                continue
            }
            out.append(line)
            let str = String(line)
            let ns = str as NSString
            for m in heredocStart.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
                delimiters.append(ns.substring(with: m.range(at: 2)))
            }
        }
        return out.joined(separator: "\n")
    }

    static func stripWrappers(_ words: [String]) -> [String] {
        var i = 0
        while i < words.count {
            let w = words[i]
            let base = (w as NSString).lastPathComponent.lowercased()
            if w.contains("="), !w.hasPrefix("-"), let eq = w.firstIndex(of: "="), w[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                i += 1; continue // VAR=value
            }
            if wrappers.contains(base) {
                i += 1
                // Skip the wrapper's own options (env -i, sudo -u user, arch -arm64).
                while i < words.count, words[i].hasPrefix("-") {
                    let opt = words[i]; i += 1
                    if ["-u", "-g"].contains(opt), i < words.count { i += 1 }
                }
                continue
            }
            if base == "timeout", i + 1 < words.count { i += 2; continue }
            break
        }
        return Array(words.dropFirst(i))
    }

    /// Splits a command line into simple commands (words), honoring quotes and escapes.
    /// Not a full shell parser: enough to find which programs run with which arguments.
    public static func segments(_ s: String) -> [[String]] {
        var out: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var single = false, double = false, escape = false
        func endWord() { if inWord { words.append(word); word = ""; inWord = false } }
        func endSegment() { endWord(); if !words.isEmpty { out.append(words); words = [] } }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if escape { word.append(c); inWord = true; escape = false; i += 1; continue }
            if single {
                if c == "'" { single = false } else { word.append(c) }
                i += 1; continue
            }
            if double {
                if c == "\\", i + 1 < chars.count, ["\"", "\\", "$", "`"].contains(chars[i + 1]) { word.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { double = false } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                    endSegment(); i += 2; continue
                } else { word.append(c) }
                i += 1; continue
            }
            switch c {
            case "\\": escape = true; inWord = true
            case "'": single = true; inWord = true
            case "\"": double = true; inWord = true
            case " ", "\t": endWord()
            case "\n", ";", "|", "&", "(", ")", "`": endSegment()
            case "$" where i + 1 < chars.count && chars[i + 1] == "(": endSegment(); i += 1
            default: word.append(c); inWord = true
            }
            i += 1
        }
        endSegment()
        return out
    }
}

/// A Chrome-family browser process, from the Mac's process table.
public struct BrowserProcessInfo: Equatable, Sendable {
    public var pid: Int32
    public var app: String
    public var startedAt: Double
    public var userDataDir: String?
    public var profileDirectory: String?
    public var remoteDebugging: String?
    public var headless: Bool
    public var automation: Bool
    /// The first agent among the process's ancestors, and that ancestor's PID.
    public var agent: String?
    public var agentPid: Int32?
    public var ancestry: [String]
    public var ancestorPids: [Int32]

    /// Your normal Chrome (default profile directory, not started by an agent).
    public var isEveryday: Bool { userDataDir == nil && agent == nil && !automation && !headless }

    /// Worth recording: started by an agent, or opened for automation or remote debugging.
    public var isNotable: Bool { agent != nil || automation || headless || remoteDebugging != nil || userDataDir != nil }

    public var payload: JSONValue {
        var p: [String: JSONValue] = [
            "pid": .number(Double(pid)), "app": .string(app), "processStartedAt": .number(startedAt),
            "headless": .bool(headless), "automation": .bool(automation), "everyday": .bool(isEveryday),
            "ancestry": .array(ancestry.map { .string($0) }),
        ]
        if let userDataDir { p["userDataDir"] = .string(userDataDir) }
        if let profileDirectory { p["profileDirectory"] = .string(profileDirectory) }
        if let remoteDebugging { p["remoteDebugging"] = .string(remoteDebugging) }
        if let agent { p["agent"] = .string(agent) }
        if let agentPid { p["agentPid"] = .number(Double(agentPid)) }
        if !ancestorPids.isEmpty { p["ancestorPids"] = .array(ancestorPids.map { .number(Double($0)) }) }
        return .object(p)
    }
}

public enum BrowserProcesses {
    static let mainSuffixes = ["/Google Chrome", "/Google Chrome Canary", "/Google Chrome Beta", "/Google Chrome Dev",
                               "/Google Chrome for Testing", "/Chromium", "/chrome-headless-shell"]

    /// Cheap path test for a Chrome-family browser executable (main or helper).
    public static func isBrowserPath(_ path: String) -> Bool {
        mainSuffixes.contains { path.hasSuffix($0) }
    }

    /// Which agent a process is, from its executable path (nil: not an agent).
    public static func agent(forPath path: String) -> String? {
        let base = (path as NSString).lastPathComponent
        if path.contains("/claude-code/") || path.contains("/claude/versions/") || base == "claude" { return "claude-code" }
        if base == "codex" || path.contains("/Codex Framework.framework/") || path.contains("/ChatGPT.app/") ||
            path.contains("/Codex.app/") { return "codex" }
        return nil
    }

    /// Classifies a browser main process. `ancestors` runs from the parent upwards.
    public static func classify(_ snap: ProcessSnapshot, ancestors: [ProcessSnapshot]) -> BrowserProcessInfo? {
        guard isBrowserPath(snap.path), !snap.args.contains(where: { $0.hasPrefix("--type=") }) else { return nil }
        func value(_ name: String) -> String? {
            for a in snap.args where a.hasPrefix(name + "=") { return String(a.dropFirst(name.count + 1)) }
            return nil
        }
        var remote: String?
        if let port = value("--remote-debugging-port") { remote = "port \(port)" }
        if snap.args.contains("--remote-debugging-pipe") { remote = "pipe" }
        var agent: String?
        var agentPid: Int32?
        for a in ancestors {
            if let ag = Self.agent(forPath: a.path) { agent = ag; agentPid = a.pid; break }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tilde(_ s: String) -> String { s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s }
        return BrowserProcessInfo(
            pid: snap.pid, app: (snap.path as NSString).lastPathComponent, startedAt: snap.startedAt,
            userDataDir: value("--user-data-dir").map(tilde), profileDirectory: value("--profile-directory"),
            remoteDebugging: remote, headless: snap.args.contains { $0.hasPrefix("--headless") },
            automation: snap.args.contains("--enable-automation"), agent: agent, agentPid: agentPid,
            ancestry: ancestors.prefix(6).map { ($0.path as NSString).lastPathComponent },
            ancestorPids: ancestors.prefix(12).map { $0.pid })
    }
}
