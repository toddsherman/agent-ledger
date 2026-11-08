# Changelog

Release notes for the Agent Ledger Mac app. Each `## <version>` section becomes that release's
Sparkle update notes.

## 0.1.0

First release.

- Records what Claude Code and Codex do in your everyday Chrome: navigation, clicks, typing, field before/after values, form submits, mutating requests and on-page status messages. No screenshots.
- Says who did what: Identified (the agent reported the operation), Likely (inferred), Likely you (physical input), Mixed, or Unknown, with the reasons for each label.
- Ordinary browsing stays in memory and never reaches disk; only agent sessions are recorded.
- Logging-only hooks for Claude Code and Codex, installed from Settings or `ledgerctl`.
- Ledger window with Changes, Timeline and Evidence views, corrections, and JSONL/Markdown export.
- Append-only, hash-chained local ledger (`ledgerctl verify`).
- Signed with Developer ID, notarized, and updated with Sparkle.
