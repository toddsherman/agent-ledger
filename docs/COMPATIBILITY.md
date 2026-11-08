# Compatibility record

There is one row per tested combination. "Detected via" says which evidence started the session and named the actor.

| Date | Agent and client | Browser path | Chrome | Recorder | Detected via | Result |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-07 | Claude Code 2.1.316 (desktop app session) | Claude in Chrome extension 1.0.105, native host `claude --chrome-native-host` | 157.0.8103.39 | 0.1.0 | Hooks (`mcp__claude-in-chrome__*`, with `tabId` in the input) | ✅ Session started on the first browser tool call; the tab was bound by `tabId`. See the observations below |
| 2026-11-07 | Codex in the ChatGPT app (26.1103.x, GPT-6 Astra) | ChatGPT extension 1.26.1102.11740, native host `ChatGPT for Chrome`, MCP tool `mcp__cua_repl__js` | 157.0.8103.39 | 0.1.0 | Hooks (`PreToolUse`/`PostToolUse` for `mcp__cua_repl__js`; `code` matched `cua.`), with the tab bound by its debugger attaching during the call | ✅ Existing-tab edit recorded; effects labeled **Likely Codex** (session-level; Codex inputs carry no tab ID) |
| 2026-11-07 | Codex CLI 0.167.0 (`codex exec`) | Same plugin config | 157.0.8103.39 | 0.1.0 | Hooks | ⚠️ The CLI can't reach Chrome ("browser access host is unavailable"); only the app hosts the Chrome bridge. The session and browser calls were still recorded, with no tab |

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

## Known limits

- **Codex attribution:** Codex's hook inputs carry no tab IDs, so its effects are "Likely Codex" (session-level), not "Identified". Without hooks it falls back to passive signals (helper connected, debugger attached, tab group named with an emoji).
- **Passive detection with two helpers connected:** both helpers stay connected, so a debugger attachment that Claude's hooks didn't report is attributed to the other agent only when Claude hooks are known to be active. Otherwise it is "Unknown agent".
- **DevTools false start:** checked live. DevTools attached a debugger while both helpers were connected, and the detector recorded "not started" after 60 s without corroboration. Gap notices from such tentative sessions now stay in memory.
- **Task labels:** labels come from `UserPromptSubmit`, which also fires for messages sent mid-turn, so a session that starts mid-conversation can be labeled with a short reply. Labels can be edited in the Ledger window.
