# Changelog

Release notes for the Agent Ledger Mac app. Each `## <version>` section becomes that release's
Sparkle update notes.

## 0.3.1

- Fixed: the menu bar panel no longer hangs below the menu bar after part of it collapses (for example after "Hide details").
- Sessions where an agent used only its own app's browser no longer raise the "Hooks missed browser calls" notification.
- Codex's built-in browser is now recognised by name in the session summary.

## 0.3.0

- Alerts now work without setup. Ten built-in groups of sites are watched: Financial, Email, Password managers, Accounts and identity, Developer and infrastructure, Shopping and travel, Government, tax and health, Social and publishing, File storage and sharing, and Work chat and messaging. The last two start switched off. Each group has a switch in Settings → Alerts, where you can also see its sites, add your own, and take a site out.
- New alerts on any site: an agent changed a security setting (password, two-factor, recovery details, a new key or token), approved access on a permission screen, submitted a form with card fields, or uploaded a file.
- Each kind of action alert (payments, transfers, security settings, access approvals, sends, posts, sharing, deletes, uploads) has its own switch.
- An alert on a watched site now names the group the site belongs to.
- The menu bar icon and panel now show "Needs attention" when something stops the record from being complete, and tell "Chrome isn't open" apart from "extension not connected".
- Settings apply as you change them; the Save buttons are gone.
- Settings → Integrations gives numbered steps for adding the extension to Chrome, with buttons to copy the folder's path and show the folder.
- Plainer status words (Confirmed, Probable, Agent and you, Unclear; Recording, Idle, Ended; Incomplete record), with an explanation when you point at a label or icon.
- Export and check results now appear in the Ledger window, and old result lines clear themselves.
- The menu bar now shows the Agent Ledger logo, the same one as the Chrome extension. The dot in its corner is grey when idle, red while recording, a pause mark when paused and an orange warning when something needs attention.
- Agent Ledger appears in the Dock while its Ledger or Settings window is open, and Command-Q quits it.
- The menu panel shows a "Finish setup" list until the extension and agent reporting are in place, collapses its health rows to "Everything is working" when they are, and leads with "Review N sessions".
- Settings is regrouped into General, Recording, Alerts, Setup and Storage. Alerts warns when notifications are turned off in System Settings.
- The Ledger window: shorter session header with technical details moved to Evidence, plainer section and filter names, times in your 12- or 24-hour format, "Who did this?" buttons on an opened timeline row, tidier session list, and clearer empty states.
- No notifications when Claude or Codex works only in the browser inside its own app and never in your Chrome. The session is still recorded, and Settings → Alerts has a switch to turn the notifications back on.
- If the record can't be opened at launch, Agent Ledger now says so instead of quitting silently.

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
