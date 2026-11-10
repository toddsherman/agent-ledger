# Agent Ledger

Agent Ledger keeps a local record of what AI agents (Claude Code, Codex) do in your everyday Chrome. The record comes from the recorder's own observations, not from the agents' summaries. It says who did what, and it says so when it isn't sure.

- **Chrome extension** (`extension/`): watches tab, group, navigation and debugger-attachment metadata. In tabs an agent is using, it also captures clicks, typing, field before/after values, submits, mutating requests and on-page status messages. No screenshots.
- **Mac menu bar app** (`mac/`): owns the local SQLite ledger. It correlates browser events with agent hook reports and Mac context (agent helper processes, the frontmost app, the timing of physical clicks and key presses). It shows sessions in a review window and exports JSONL plus a Markdown retrospective.
- **Logging-only hooks** for Claude Code and Codex: report browser tool calls as "runtime-reported" evidence. They run in the background, always exit 0, and can't block or change anything.

The design rationale is in [PLAN.md](PLAN.md) and the original brief is [browser-agent-recorder-brief.md](browser-agent-recorder-brief.md). The wire format is in [docs/PROTOCOL.md](docs/PROTOCOL.md), and tested agent configurations are in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Install

1. **Download the Mac app.** Get the latest `Agent-Ledger-<version>.dmg` from [Releases](https://github.com/toddsherman/agent-ledger/releases/latest), open it, and drag Agent Ledger to Applications.
   - It's signed with Developer ID and notarized.
   - It updates itself with Sparkle: Settings → Data → Updates, or **Check for Updates…** in the menu bar panel.
   - On launch it registers its Chrome native host. It also installs its helpers to `~/Library/Application Support/AgentLedger/bin/` and a copy of the extension to `…/AgentLedger/extension/`.
2. **Install the Chrome extension** from the Chrome Web Store (unlisted link coming once it's approved). Until then, load it unpacked:
   1. Open `chrome://extensions` and turn on **Developer mode**. Leave it on.
   2. Click **Load unpacked**.
   3. In the file picker press Cmd+Shift+G, paste `~/Library/Application Support/AgentLedger/extension`, and choose it.
3. **Turn on agent hooks** (optional, recommended). Use Settings → Integrations, or the command line:
   ```bash
   ~/Library/Application\ Support/AgentLedger/bin/ledgerctl install-hooks claude
   ~/Library/Application\ Support/AgentLedger/bin/ledgerctl install-hooks codex
   ```
   - The hooks go after any existing ones, and the file is backed up before every change.
   - Claude Code picks them up in new sessions.
   - Codex asks you to trust them once.
4. **Pin the toolbar icon** and check the badge:
   - Nothing on the icon means connected.
   - An orange `!` means the extension can't reach the app; hover over the icon for the reason.
   - `REC` marks a tab that is being recorded.

## What gets recorded

- **Outside agent sessions:** tab and navigation metadata stays in memory for 10 minutes (configurable) and is never written to disk. Only the detector's start/no-start decisions are saved, without URLs.
- **Inside agent sessions:**
  - Navigation (URLs with tokens redacted)
  - Clicks, focus, typing, key categories and pastes, with element descriptions
  - Field values before and after a change
  - Form submits, with every field's value
  - Mutating requests and their status codes
  - `role=status`/`alert` text, such as "Saved" toasts
  - Downloads
  - The agent's own tool-call reports
- **Other ways agents reach Chrome** (recorded whenever they happen):
  - shell commands that open a URL in Chrome, send it AppleScript, start it, use its debugging port, or read its profile files (the command only, never its output)
  - browser-automation tools such as Playwright or Chrome DevTools MCP
  - computer use aimed at Chrome
  - separate Chrome processes an agent starts, with their debugging port and profile folder
  - remote debugging turned on in your own Chrome
- **Never captured:**
  - Password, card, one-time-code and hidden fields
  - Clipboard contents
  - Request and response bodies
  - Screenshots
- **Redaction:** secret-looking values (keys, JWTs, card numbers, SSNs) are redacted and values are cut at 2 KB. Value capture can be turned off, and sites can be excluded.
- **Task labels:** the prompt that started a session's browser work becomes its label (500 characters max).
- **Tamper evidence:** the ledger is append-only and hash-chained (`ledgerctl verify`). That exposes casual edits, but it can't stop a process that rewrites the whole file. Each export comes with a proof file (`ledgerctl verify-proof`), and `ledgerctl head` prints the last hash so you can keep a copy somewhere else.

## Attribution labels

| Label | Meaning |
| --- | --- |
| **Identified** | The agent's hook reported an operation on this tab at that moment. |
| **Likely <agent>** | Inferred, for example a debugger attached to a tab bound to that agent's session. |
| **Likely you** | A physical click or key press within about 1.5 s, while Chrome was frontmost and the page focused. |
| **Mixed** | Agent operation and physical input overlapped. |
| **Unknown actor** | Nothing matched. |
| **Page script** | The event was synthesized by the page (`isTrusted=false`) with no agent operation covering it. |

Corrections ("This was me", "Wrong agent", "Confirm agent did this") go in a separate table. Raw evidence is never rewritten.

## Command line

```bash
ledgerctl status | sessions | export <session-id> | report <session-id> | reconcile <session-id>
ledgerctl verify | verify-proof <file.proof.jsonl> | head
ledgerctl install-host | uninstall-host
ledgerctl install-hooks <claude|codex> | uninstall-hooks <claude|codex>
```

Exports go to `~/Library/Application Support/AgentLedger/exports/`.

## Uninstall

```bash
CTL=~/Library/Application\ Support/AgentLedger/bin/ledgerctl
"$CTL" uninstall-hooks claude
"$CTL" uninstall-hooks codex
"$CTL" uninstall-host
```

Then remove the extension in `chrome://extensions`, quit the app, and delete `~/Library/Application Support/AgentLedger`.

## Releasing

**Mac app:**

1. Run `mac/scripts/bump-version.sh <version>`.
2. Add a `## <version>` section to `CHANGELOG.md` and commit.
3. Run `mac/scripts/release.sh --publish`. It builds, signs with Developer ID, notarizes and staples the app and the DMG, writes an EdDSA-signed Sparkle `appcast.xml`, and creates the GitHub release.

The script needs:
- the `security-monitor-notary` notarytool keychain profile
- the `agent-ledger` Sparkle key in the login keychain

**Chrome extension:**

1. Bump `version` in `extension/manifest.json`.
2. Run `scripts/package-extension.sh`.
3. Upload the zip in the Chrome Web Store dashboard. Listing text and permission justifications are in [docs/chrome-web-store.md](docs/chrome-web-store.md).

## Development

To build the app from source, run `mac/scripts/build-app.sh` and then `open "mac/dist/Agent Ledger.app"`. The app is signed with the Developer ID identity when it's in your keychain, and ad hoc otherwise. Sparkle runs only when the app is launched from its bundle.

```bash
cd mac && swift test
node --test extension/test
node testbed/server.mjs
```

- `swift test` runs the Swift unit tests.
- `node --test extension/test` runs the extension tests, including the shared redaction fixtures.
- `node testbed/server.mjs` starts the diagnostic page and mock CMS at http://localhost:4399. On that origin only, the content script writes the recorder's status to `document.documentElement.dataset.agentLedger`.
- `node scripts/e2e/check.mjs --since -10m --expect codex` checks every save the testbed received in that window against the ledger: the request, the submitted values, the field changes and the toast. With `--expect`, it also checks that each one is attributed to the expected agent. Use `--expect 1:claude-code,2:codex` to give an agent per record. It also lists sessions, failed requests, gaps and detector decisions, and runs the hash-chain check.

When the app launches with updated extension files, it copies them to `~/Library/Application Support/AgentLedger/extension` and asks the connected extension to reload. You don't need to click Reload in `chrome://extensions`.

For throwaway data, set `AGENT_LEDGER_HOME` to a **short** path (Unix socket paths are limited to 104 bytes), for example `<repo>/.smoke`.
