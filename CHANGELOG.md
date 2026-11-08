# Changelog

Release notes for the Agent Ledger Mac app. Each `## <version>` section becomes that release's
Sparkle update notes.

## Unreleased

- Field changes made by script are now recorded. When an agent fills a field from script (Playwright `fill`, Claude's `form_input`) or picks an option without focusing the field, the page fires no change event. The ledger used to miss the change or lose the old value.
- Codex tabs are bound sooner: from the tab ID Codex names in its code, and from the tab URL right after the app restarts.
- A new Codex conversation can take over a tab that an earlier, now idle Codex session was using.
- More accurate reasons for Codex attributions: a Codex call that never reported finishing no longer counts as "in progress" for a minute.
- The Chrome extension reloads itself when the app installs updated extension files.
- Password managers' own announcements (such as 1Password's menu notice) are no longer recorded as page messages.

## 0.1.0

First release.

- Records what Claude Code and Codex do in your everyday Chrome: navigation, clicks, typing, field before/after values, form submits, mutating requests and on-page status messages. No screenshots.
- Says who did what: Identified (the agent reported the operation), Likely (inferred), Likely you (physical input), Mixed, or Unknown, with the reasons for each label.
- Ordinary browsing stays in memory and never reaches disk; only agent sessions are recorded.
- Logging-only hooks for Claude Code and Codex, installed from Settings or `ledgerctl`.
- Ledger window with Changes, Timeline and Evidence views, corrections, and JSONL/Markdown export.
- Append-only, hash-chained local ledger (`ledgerctl verify`).
- Signed with Developer ID, notarized, and updated with Sparkle.
