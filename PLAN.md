# Agent Ledger: Stage 2 browser-agent recorder

Working name "Agent Ledger" (easy to rename). Built in `/Volumes/RAID4/Projects/chrome extension` (a new git repo).

## Context

`browser-agent-recorder-brief.md` describes a user-owned record of what AI agents do in Chrome. The record comes from the recorder's own observations, not from the agents' summaries, and it states plainly when it isn't sure who did something. Todd chose to go straight to a **usable Stage 2 recorder**, skipping the feasibility spike:

- **Components:** a Chrome extension plus a Mac menu bar app.
- **Agents:** Claude Code (through the Claude in Chrome extension) first, and it must also work for Codex.
- **Hooks:** logging-only hooks are in scope, as ground truth labeled "runtime-reported."
- **Scope:** runs in his everyday Chrome profile. Outside agent sessions it keeps metadata only.
- **Capture:** no screenshots. Text logs rich enough for retrospectives and audits.
- **Review:** in a window opened from the menu bar.
- **Proof task:** an agent edits something on a signed-in site, in a tab that was already open.

**What I found on this Mac** (it shapes the design):

| Item | Claude | Codex |
| --- | --- | --- |
| Chrome extension ID | `fcoeoabgfenejglbffodgkkbkcdhcgfn` | `hehggadaopoacecdllhhajmbjkdcmajg`, `odlomjlbamekndcpllcnffbgeohgkmjh` |
| Native helper | `~/.claude/chrome/chrome-native-host`, which runs `…/claude/versions/<v> --chrome-native-host` | `~/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome` |
| Helper behavior | Starts per connection | Connects persistently: running since Nov 6, so it is idle context, not activity |
| Browser tools | MCP tools `mcp__claude-in-chrome__*` take a `tabId` argument, so tool-call hooks can attribute actions per tab | Run through a Node REPL (`agent.browsers…`) |
| Tab groups | Collects its tabs into a group per session | Names its group with `browser.nameSession("🔎 …")`; can claim an existing tab without grouping it (`claimTab`) |
| Hooks | Claude Code 2.1.316: `PreToolUse`/`PostToolUse` carry `session_id`, `tool_use_id`, `tool_input`, and support `async: true` | `~/.codex/hooks.json` supports the same events with `session_id`, `turn_id`, `tool_use_id`, `async: true`. Whether its browser calls reach the hooks (inside the Node REPL) is **not documented**, so I'll verify it empirically |

- **Existing hooks to preserve:** Orca hooks already live in both `~/.claude/settings.json` and `~/.codex/hooks.json`. The installer must merge into these files, never replace them.
- **Toolchain:** Xcode 27, Swift 6.4, Node 26, Chrome 157.

## Architecture

```
Chrome (everyday profile)
  Agent Ledger extension (MV3)
    service worker: tabs, groups, navigation, debugger polling, downloads, management, webRequest
    content script: interaction and change capture; armed only in recorded tabs
        │  native messaging (stdio)
        ▼
  ledger-host (Swift CLI; Chrome starts it)
        │  Unix socket ~/Library/Application Support/AgentLedger/ingest.sock
        │  (falls back to a spool file if the app isn't running)
        ▼
Agent Ledger.app (SwiftUI menu bar app; owns the database)
    ingest → raw event store (SQLite, append-only, hash-chained)
    Mac sensors: helper processes, frontmost app, seconds since last HID input
    correlation engine → sessions, tab bindings, actor attributions with reasons, gaps
    menu bar status + Ledger window (timeline, changes, corrections, export)
        ▲
  ledger-hook (Swift CLI), called by Claude Code and Codex hooks as an async, never-blocking hook
```

### Repo layout
- `mac/Package.swift` has these targets:
  - `LedgerCore` (library): models, SQLite store, ingest server, correlation, redaction, export
  - `AgentLedger` (the app)
  - `ledger-host`
  - `ledger-hook`
  - `LedgerCoreTests`
- `mac/scripts/build-app.sh`: runs `swift build -c release`, assembles `Agent Ledger.app` (with `LSUIElement`), puts `ledger-host` and `ledger-hook` in `Contents/Helpers`, and ad-hoc signs it.
- `extension/`: plain-JS MV3 extension (no build step), loaded unpacked.
  - `manifest.json` includes a `key`, which pins the extension ID so the native host manifest's `allowed_origins` matches it.
  - `background/`: `sensors.js`, `capture-controller.js`, `native-port.js`, `prebuffer.js`
  - `content/capture.js`
  - `lib/`: `describe-element.js`, `redact.js`
- `extension/test/`: `node --test` tests for the pure modules (element descriptions, redaction).
- `testbed/`: a local test site with a ground-truth diagnostic page and a **mock CMS** (log in, edit a record, save toast, POST API). A tiny server runs it, so the signed-in edit can be tested repeatably before trying a real site.
- `docs/PROTOCOL.md`: the event message schema shared by the extension, host, and hook.
- `docs/COMPATIBILITY.md`: one row per tested agent, version, and control-path combination.

## Evidence model

These are SQLite tables in `~/Library/Application Support/AgentLedger/ledger.sqlite` (WAL mode):

- **`events`**: raw observations. Append-only: triggers reject UPDATE, and DELETE is allowed only through retention purge. Each row has:
  - `id` and `source` (extension.sw, extension.content, mac.sensor, hook.claude, hook.codex)
  - `kind`: one of `runtime_intent`, `attempted_op`, `observed_effect`, `context`, `gap`, `sensor_health`
  - `category`
  - `observed_at` (time at the sensor), `received_at`, and a per-source sequence number
  - browser instance, tab, frame, and document IDs
  - `payload` (JSON)
  - `prev_hash` and `hash`. The hash chain exposes casual edits only. It does not stop a local process with write access, and the UI will say so.
- **`sessions`**: the agent product, runtime session ID (when hooks supply it), state, start and end, task label, and coverage status.
- **`session_tabs`**: binds a tab or document to a session over a time interval, with the binding's evidence.
- **`attributions`**: an inferred actor for an event or time span. Label is Identified (with scope), Likely, Unknown actor, or Mixed, plus reasons and the detector version. A revised inference adds a row; it never rewrites one.
- **`corrections`**: user actions ("This was me", "Wrong agent", "Include this tab", "Exclude"). These are stored separately from what was observed.

## Capture policy

**Outside sessions (everyday browsing):**
- Tab, group, navigation, and debugger metadata is kept in an in-memory **rolling prebuffer (default 10 min)**, not on disk.
- Only detector decisions persist (for example, "possible session, not started: reasons…"). That allows measuring false starts without building a durable browsing history.

**Inside recorded tabs** (text only, no screenshots):
- **Navigation:** full URLs with sensitive query keys redacted (token, code, key, sig, auth…), SPA history changes, title changes, document boundaries.
- **Interactions:** click, input or change, submit, key category (Enter/Esc/Tab), scroll (throttled), focus, paste (the event only, never clipboard contents). Each comes with an element description: role, accessible name, tag, id/name, a short selector path, and a text snippet of at most 80 characters.
- **Field values for audits:** before → after on change, and each field's value at submit.
  - Never captured: password, credit card, or one-time-code fields (by type or autocomplete).
  - Values that look like secrets (keys, JWTs, card numbers, SSN-like patterns) are redacted.
  - Values are truncated at 2 KB.
  - A setting can turn value capture off, globally or per site.
- **Outcome evidence:** text from `role=alert/status`/`aria-live` regions (e.g. a "Saved" toast), validation messages, and a summary of DOM mutation counts.
- **Network metadata:** method, redacted URL, status, type, timing, initiator. No bodies. POST/PUT/PATCH/DELETE requests are marked as consequential-change candidates. Downloads include `byExtensionId`.
- **Hooks:** the tool name, its input (for Claude, the browser tool and its args, including `tabId`), result status, and timing.
  - The prompt that started a turn is held in memory. It persists as the session's task label (truncated to 500 characters) only if that session then touches the browser. A setting turns this off.
  - Codex hook events that are not browser-related are dropped without being stored.

## Detection and attribution

**Signals:**
- **Claude, strongest:** a `PreToolUse`/`PostToolUse` hook for `mcp__claude-in-chrome__*` that names a `tabId`. This yields **Identified (Claude Code runtime session `<id>`)** for that tab during the call's window.
- **Codex:** hook events for its browser path, if they turn out to fire (verified in milestone 5). If they do, they get the same treatment as Claude's. If not, Codex is detected passively:
  - the Codex helper is connected, and
  - a tab's debugger state changes from detached to attached (polled every second via `chrome.debugger.getTargets()`, which reads state without attaching), or
  - the tab joins a group Codex named, or
  - interactions occur that aren't explained by a Claude hook call.

  Together these give **Likely (Codex)**.
- **Helper processes:** the Mac app scans processes every 2 seconds for the two helpers, recording PID plus start time, the parent Chrome, and the code-signing identity.
- **Human context:** frontmost app (`NSWorkspace`) and seconds since the last HID input (`CGEventSourceSecondsSinceLastEventType`; needs no Input Monitoring permission).
  - An interaction that happens while Chrome is frontmost, with real input in the preceding ~1 s and no agent tool call open on that tab, is labeled **Likely you**.
  - If agent and human evidence overlap, the label is **Mixed**.

**Session lifecycle:** idle → possible → recording → inactive → ended, with a separate "coverage degraded" flag.
- **Start recording on:**
  - any hook tool call that targets a tab, or
  - passive evidence that is corroborated (a debugger attach plus a connected agent helper, on the same tab).
- **When recording starts:** the extension arms the content script for that tab and pulls the tab's prebuffer into the session (metadata only).
- **Pauses and ending:**
  - A settling period (90 s) bridges agent thinking, reloads, and reconnects.
  - A session ends on the agent's `Stop`/`SessionEnd` hook, or after the inactivity timeout.
  - A stale group or an idle helper alone never keeps a session recording.

**Gaps become visible records:** content script disconnected, page the extension can't access (chrome://, Web Store), service worker restart, app not running (spooled), permission missing, debugger polling not permitted.

## Menu bar app

- **Menu:**
  - Status icon (idle, recording, degraded).
  - Active sessions, showing agent, tabs, and duration.
  - Controls: Stop recording, "That was me" (last N minutes), Pause recording for 1 hour.
  - Open Ledger.
  - Health: extension connected, hooks installed, helpers seen.
- **Ledger window (SwiftUI):**
  - **Session list:** agent, task label, sites, start time and duration, attribution, coverage.
  - **Session detail:**
    - A timeline per tab and document. Each row has an actor chip and a disclosure that explains why that actor was named.
    - A **Changes** summary: submits, field before → after, mutating requests and their statuses, outcome toasts, downloads.
    - Gaps shown inline.
    - Filters.
    - Correction actions.
    - Task label editing.
  - **Export:** JSONL of raw events and attributions, plus a Markdown retrospective report.
- **Settings:**
  - Retention (default 90 days) and prebuffer length.
  - Value capture and the prompt-as-task-label option.
  - Site exclusions.
  - **Install/Uninstall hooks:**
    - Merges entries into `~/.claude/settings.json` and `~/.codex/hooks.json`, backing each file up first and keeping the Orca hooks.
    - Hook settings: matcher `mcp__claude-in-chrome__.*` plus session events, `async: true`, exit 0, no stdout.
  - **Install native host:** writes `com.agentledger.host.json` into Chrome's `NativeMessagingHosts` folder.

## Build order

1. **Core:** repo and git init, `PROTOCOL.md`, `LedgerCore` (store, hash chain, ingest socket, spool replay, redaction), `ledger-hook`, unit tests.
2. **Extension and host:**
   - `ledger-host` and the native host manifest installer.
   - Extension service-worker sensors (tabs, groups, navigation, debugger polling, downloads, management), a native port with reconnect, and the prebuffer.
   - Check that the events land in SQLite.
3. **In-session capture:** content-script capture, element descriptions, value redaction, network metadata, arm/disarm control from the app, gap reporting.
4. **Correlation:** Mac sensors (helpers, focus, idle), the session state machine, Claude hook binding by `tabId`, passive Codex rules, human and mixed labels.
5. **Codex verification:** install hooks, run a Codex Chrome task, record which tool names and inputs actually arrive, then finish the Codex adapter. Record the results in `COMPATIBILITY.md`.
6. **App UI:** menu, Ledger window, corrections, export, settings, hook and host installers.
7. **Testbed and end to end:** the diagnostic page and mock CMS, then the full verification below.

## Verification

- **Unit tests:** `swift test` for the store's append-only rule and hash chain, spool replay, the correlation rules (using recorded event fixtures), hook-payload parsing, and redaction. `node --test extension/test` for element descriptions and redaction.
- **Claude, end to end (I drive it from this session):**
  1. Build and launch the app.
  2. Todd loads the unpacked extension once (`chrome://extensions` → Developer mode). Install the host and hooks from the app.
  3. Open the mock CMS in an existing tab and sign in.
  4. Use the `claude-in-chrome` tools to edit a record and save it.
  5. Confirm the Ledger shows:
     - a session named for the Claude Code runtime with the correct tab
     - field before → after
     - the submit
     - the POST and its 200
     - the "Saved" toast text
     - **Likely you** on Todd's manual sign-in
     - no durable record of other browsing
- **Codex, end to end (Todd runs a Codex Chrome task):** have it claim the existing mock CMS tab and make an edit. Confirm the attribution is Identified (if hooks fire) or Likely, with the reasons listed.
- **Failure checks:** quit the app mid-session (the spool replays and a gap appears), reload the extension, open a chrome:// page, make an edit with DevTools open (it must not be called an agent), and use autofill or the password manager (no false start).
- **Real site:** an agent edits a field on a real signed-in site in an already-open tab. Todd picks the site.

## Deferred (not in this build)

Screenshots and DOM replay, reading Chrome's debugging banner through Accessibility (a later identity signal), event-tap input source PIDs, outcome verification, cloud sync and sharing, strong tamper resistance, incognito, and other browsers and agents.

## Risks to check early (milestone 2)

- Confirm that an open native-messaging port keeps the MV3 service worker alive in Chrome 157. Fallback: an `alarms` heartbeat, with gap markers for the downtime.
- Confirm that the `debugger` permission lets `getTargets()` report Claude's and Codex's attachments without our extension attaching to anything.
- Confirm that writing into Chrome's `NativeMessagingHosts` folder doesn't trigger the macOS "data from other apps" prompt that stalled my shell earlier. If it does, Todd approves it once.
