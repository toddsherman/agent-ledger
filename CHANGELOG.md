# Changelog

Release notes for the Agent Ledger Mac app. Each `## <version>` section becomes that release's
Sparkle update notes.

## 0.2.1

- Fixed: after the app was restarted automatically (at login, after an update, or after it stopped), clicking its menu bar icon did nothing.

## 0.2.0

- The app installs itself in /Applications and is restarted if it stops.
- A Summary for each session: where the agent went, what it read, the scripts it ran, what changed (or "No changes observed"), and how far the record can be trusted. Exports include it.
- Background requests such as telemetry pings are no longer listed as changes, and activity the page did by itself is labeled "Page", not "Unknown actor".
- A notification when a session ends, with a one-line result. Sessions can be marked reviewed.
- The recorder tells you when it has been interfered with: hooks removed, the extension disconnected while Chrome runs, the app stopped unexpectedly, or the ledger file changed by another program.
- A daily self-test of the path from hook to ledger, and a notice when an agent updates to a version that hasn't been seen before.
- After each session the recorder compares its record with the agent's own log and says how many browser calls the hooks reported. It reads tool calls only, never the agent's messages.
- Alerts (notifications only; nothing is ever blocked): a change on a site you've marked sensitive, a script that could change one, the recorder stopping during a session, and an agent reaching the browser a new way. List sensitive sites in Settings → Alerts.
- Each export comes with a proof file. `ledgerctl verify-proof <file>` checks that the session's events are as recorded and that none was removed between them.
- `ledgerctl head` prints the ledger's last hash, to keep somewhere outside the Mac.
- Reads of the ledger through `ledgerctl` are recorded, and events sent by a program that isn't part of Agent Ledger are marked.
- Field changes made by script are now recorded. When an agent fills a field from script (Playwright `fill`, Claude's `form_input`) or picks an option without focusing the field, the page fires no change event. The ledger used to miss the change or lose the old value.
- Codex tabs are bound sooner: from the tab ID Codex names in its code, and from the tab URL right after the app restarts.
- A new Codex conversation can take over a tab that an earlier, now idle Codex session was using.
- More accurate reasons for Codex attributions: a Codex call that never reported finishing no longer counts as "in progress" for a minute.
- The Chrome extension reloads itself when the app installs updated extension files.
- Password managers' own announcements (such as 1Password's menu notice) are no longer recorded as page messages.
- Records more of the ways agents reach Chrome:
  - shell commands that open URLs in Chrome, send it AppleScript, start it, use its debugging port, or read its profile files (only those commands are kept, never their output)
  - browser-automation tools such as Playwright and Chrome DevTools
  - computer use aimed at Chrome
  - separate Chrome processes that an agent starts, linked to that agent's session
- Warns in the menu when remote debugging is on in your Chrome, when an agent-started browser is running, and when incognito windows aren't recorded.
- Claude Code hooks installed by 0.1.0 are updated automatically to the new coverage. A backup of the settings file is kept.
- Physical input now counts as yours only if Chrome was already in front when you pressed the key or clicked. Typing in another app just before an agent brings Chrome forward no longer makes the agent's action "Mixed".

## 0.1.0

First release.

- Records what Claude Code and Codex do in your everyday Chrome: navigation, clicks, typing, field before/after values, form submits, mutating requests and on-page status messages. No screenshots.
- Says who did what: Identified (the agent reported the operation), Likely (inferred), Likely you (physical input), Mixed, or Unknown, with the reasons for each label.
- Ordinary browsing stays in memory and never reaches disk; only agent sessions are recorded.
- Logging-only hooks for Claude Code and Codex, installed from Settings or `ledgerctl`.
- Ledger window with Changes, Timeline and Evidence views, corrections, and JSONL/Markdown export.
- Append-only, hash-chained local ledger (`ledgerctl verify`).
- Signed with Developer ID, notarized, and updated with Sparkle.
