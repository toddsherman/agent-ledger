# Compatibility record

There is one row per tested combination. "Detected via" says which evidence started the session and named the actor.

| Date | Agent and client | Browser path | Chrome | Recorder | Detected via | Result |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-07 | Claude Code 2.1.316 (desktop app session) | Claude in Chrome extension 1.0.105, native host `claude --chrome-native-host` | 157.0.8103.39 | 0.1.0 | Hooks (`mcp__claude-in-chrome__*`, with `tabId` in the input) | ✅ Session started on the first browser tool call; the tab was bound by `tabId`. See the observations below |
| 2026-11-07 | Codex in the ChatGPT app (26.1103.x, GPT-6 Astra) | ChatGPT extension 1.26.1102.11740, native host `ChatGPT for Chrome`, MCP tool `mcp__cua_repl__js` | 157.0.8103.39 | 0.1.0 | Hooks (`PreToolUse`/`PostToolUse` for `mcp__cua_repl__js`; `code` matched `cua.`), with the tab bound by its debugger attaching during the call | ✅ Existing-tab edit recorded; effects labeled **Likely Codex** (session-level; Codex inputs carry no tab ID) |
| 2026-11-07 | Codex CLI 0.167.0 (`codex exec`) | Same plugin config | 157.0.8103.39 | 0.1.0 | Hooks | ⚠️ The CLI can't reach Chrome ("browser access host is unavailable"); only the app hosts the Chrome bridge. The session and browser calls were still recorded, with no tab |
| 2026-11-08 | Claude Code 2.1.317 (desktop app session) | Shell: `open <url>` from the `Bash` tool | 157.0.8103.39 | 0.1.0+ (unreleased) | Hooks (`Bash` matcher, picked up by the already-running session) | ✅ The command, the tab it opened, and its navigation (**Likely Claude Code**) |
| 2026-11-08 | Codex CLI 0.167.0 (`codex exec`, `danger-full-access`) | Shell: `open <url>`, then a headless Chrome with `--user-data-dir` and `--remote-debugging-port` | 157.0.8103.39 | 0.1.0+ (unreleased) | Hooks (`Bash` with `command`) plus the process scan | ✅ One session: the `open` command, the tab it opened (**Likely Codex**), and the separate Chrome (linked by process ancestry, with its port and profile folder) |

## Claude Code observations (2026-11-07, mock CMS)

- **Tool coverage:** these tools arrived through `PreToolUse`/`PostToolUse`: `tabs_context_mcp`, `navigate`, `javascript_tool`, `find`, `read_page` and `browser_batch`. Inputs inside a batch carry `tabId`, and each is bound per tab.
- **Hook timing:** hooks run `async`. The hook events were received before the content-script effects they caused, but attribution still waits 2.5 s in case a report is late.
- **Typed input:** `computer` `type`/`triple_click`/`left_click` produce `isTrusted=true` page events, like real input.
- **Programmatic input:** `form_input` produces `isTrusted=false` input events. Hook coverage still labels them Identified, and the reasons note "synthesized".
- **Read-only operations:** `find`, `read_page` and `javascript_tool` leave no browser effect. They appear only as runtime reports. This is the documented coverage limit for read-only work.
- **Record matched the server:** the edit of record 1 recorded the title, summary, status and featured fields before → after, the form submit with every field (password "not captured"), `POST /cms/api/record/1 → 200`, and the "Saved …" status toast. Everything was Identified as Claude Code, and the server's own log matched.
- **Your edit in the same tab:** focus, typing and key events were labeled "Likely you" from physical click and key timing. The Save click was first mislabeled Unknown because Chrome's focus state was read after you switched apps. Fixed by keeping window focus as a timeline. **Re-run live:** your click, change and submit on record 2 were all "Likely you".
- **Effects of an action:** a request or status message within 3 s of an attributed action on the same tab now inherits that action's actor (Likely, with the reason). Effects wait for earlier actions still being attributed, because the browser can report the request before the click that caused it. This is unit-tested and not yet observed live for a human submit.
- **App down mid-session:** quitting the app during a session spooled only the recorded tab's events and the hooks' events. After relaunch they were replayed, attributed correctly, and marked with `gap.app_restarted` and `gap.app_down`. The hash chain verified.
- **Unrelated tabs:** never written to disk.

## Codex observations (2026-11-07, mock CMS)

- **Tool path:** all Chrome work goes through one MCP tool, `mcp__cua_repl__js`, with input `{code, title}`. A closing call carries `{completion_summary}` and is correctly classified as non-browser.
- **Claiming a tab:** the code claims existing tabs with `cua.getTab({url}, {browser: "chrome"})`. The recorder binds an open tab when its URL appears in the call, or when its debugger attaches within 5 s of a Codex browser call. Here the debugger rule fired first.
- **Hook events:** PreToolUse and PostToolUse both fired in the app run; in the CLI run only PreToolUse fired for the failed calls. `UserPromptSubmit` gives the task label; the app may rewrite URLs in the prompt as Markdown links.
- **SessionEnd:** Codex runs SessionEnd synchronously even when marked async, and shows an error line for it. The installer no longer marks Codex's SessionEnd/Interrupt hooks async. Re-trusting those two entries in Codex is needed after a reinstall.
- **What was recorded:** the Summary field before → after, the submit with all 5 fields, `POST /cms/api/record/2 → 200`, and the "Saved" toast. All were Likely Codex, and the server's log matched.

## Automated end-to-end run (2026-11-07 evening)

Claude drove Codex through the ChatGPT app with computer use and drove Claude in Chrome directly. `node scripts/e2e/check.mjs --since <ms> --expect <agent>` compared each run with the testbed's server log (`/__log`).

| Test | Result |
| --- | --- |
| Codex takes over an open tab on the sign-in page, signs in, edits record 3 | ✅ All effects **Likely Codex**; the password was not captured. Revealed the missing-change bugs below |
| Codex opens a new tab and only reads it | ✅ Session recorded and the tab bound through Codex's tab group; no change events. The read itself shows only in Codex's tool reports |
| Codex edits record 2 and triggers a validation error while Claude edits record 1 in another tab | ✅ Record 1 **Identified Claude Code**, record 2 **Likely Codex**; the 422 and "Not saved: Title is required" were recorded |
| App restarted, then Codex immediately takes over a tab by URL | ✅ Tab bound on Codex's first call (after the snapshot-on-connect fix) |
| Script-set fields after the capture fix (Claude `form_input`, Codex `fill`/`selectOption`) | ✅ Correct before → after for every field; script-set values are flagged `noChangeEvent` |
| Installed extension copy out of date at app launch | ✅ The app restored it and the extension reloaded itself once |

**Observations**
- **Codex hooks cover only some Codex actions.** Codex reports its `mcp__cua_repl__js` calls. Its typing and clicks (including Save) go through another input path that fires no hook, and these events are trusted input (`isTrusted=true`). The recorder still labels them **Likely Codex**, because the tab's debugger stays attached and the tab is bound to the session.
- **Codex names tab IDs in its code** (`cua.getTab("1511630265")`). The recorder now binds those tabs as runtime-reported.
- **Codex calls that fail may never post.** A new call from the same Codex session now ends any earlier open call.
- **Script-set values fire no `change` event.** Codex's Playwright `fill` and Claude's `form_input` both set values from script. Neither fires a native `change`. Before the fix, the ledger missed the change or recorded the old value wrong.
- **Restarting the app lost the open-tab state,** which lives only in memory. The app now asks the extension for a snapshot whenever the extension connects.

## Routes beyond the agents' extensions (2026-11-08)

- **Codex shell hooks:** Codex reports shell commands as tool `Bash` with input `{command}` (a string), so the same shell analysis covers Claude Code and Codex.
- **Tab from `open <url>`:** Chrome created the tab about 200 ms after `PreToolUse`. It's bound by timing ("created right after Codex ran a shell command…"), and its navigation is Likely Codex.
- **Shell globbing:** `open http://…?run=2` failed under zsh (`no matches found`) and opened nothing. The ledger correctly showed the attempt with no tab.
- **Nested agents:** this Codex ran inside a Claude Code shell. The browser it started has both agents among its ancestors. Only the nearest agent is credited (a bug found and fixed in this run).
- **Hook upgrade:** relaunching the app updated the 0.1.0 Claude Code hook matcher in `~/.claude/settings.json` and kept a backup. A Claude Code session that was already running picked up the new matcher without a restart.
- **Heredocs:** a Python edit whose heredoc held docs about `--remote-debugging-port` was first recorded as reaching Chrome. Heredoc bodies are now treated as data (AppleScript fed through a heredoc still counts), and Chrome's flags count only on commands that start Chrome.
- **Not yet run live:** AppleScript (it would trigger macOS's Automation prompt), computer use, Playwright or DevTools MCP, the Chrome remote-debugging switch, and Claude in Chrome's side panel. These are unit-tested only.

## Known limits

- **Codex attribution:** Codex's hook payloads have no tab ID field. The code sometimes names one, and the recorder uses it to bind the tab. Most Codex effects come through its unhooked input path, so they stay "Likely Codex" (session-level), not "Identified". Without hooks, the recorder falls back to passive signals: helper connected, debugger attached, tab group named with an emoji.
- **Passive detection with two helpers connected:** both helpers stay connected, so a debugger attachment that Claude's hooks didn't report is attributed to the other agent only when Claude hooks are known to be active. Otherwise it is "Unknown agent".
- **DevTools false start:** checked live. DevTools attached a debugger while both helpers were connected, and the detector recorded "not started" after 60 s without corroboration. Gap notices from such tentative sessions now stay in memory.
- **Task labels:** labels come from `UserPromptSubmit`, which also fires for messages sent mid-turn, so a session that starts mid-conversation can be labeled with a short reply. Labels can be edited in the Ledger window.
