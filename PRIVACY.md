# Agent Ledger privacy policy

_Last updated: November 7, 2026_

Agent Ledger is a Chrome extension and a companion Mac app. Together they keep a record, on your own Mac, of what AI agents such as Claude Code and Codex do in your browser.

## Summary

- **Everything stays on your Mac.** The extension sends data only to the Agent Ledger app on the same computer, through Chrome's native messaging. Neither the extension nor the app sends any of it to the developer or to any other server.
- **No accounts, analytics, ads or tracking.**
- **Ordinary browsing isn't recorded.** Outside an AI agent's session, tab and navigation metadata is kept in memory for a few minutes (10 by default) and then discarded. It is never written to disk.
- **Nothing is sold or shared.**

## What the extension observes

When an AI agent is using a tab, that tab is recorded. The Mac app decides when this happens, from the agent's own tool-call reports or from the agent controlling the tab. In a recorded tab the extension observes:

- **Navigation:** pages visited, with tokens and other sensitive URL parameters redacted.
- **Interactions:** clicks, focus, typing (as events, not keystrokes), key categories (such as Enter and Escape) and pastes (length only, never clipboard contents), each with a short description of the page element involved.
- **Field values:** before and after a change, and at form submission, for ordinary fields. Password, credit-card, one-time-code and hidden fields are never read. Values that look like secrets (API keys, tokens, card numbers, ID numbers) are redacted. Values are cut at 2 KB. You can turn value capture off, or exclude sites, in the Mac app.
- **Network requests:** method, address (redacted), status code and timing for page loads and changes. No request or response bodies.
- **Page messages:** status, alert and dialog text, such as "Saved".
- **Downloads:** file name, type and which extension started them.

In every tab, the extension also watches tab, tab-group, window and navigation events, whether a debugger is attached to a tab, and which known AI agent extensions are installed. It uses these to detect when an agent starts working. Outside a recorded session this information stays in memory and expires.

The extension never takes screenshots, and never reads cookies, saved passwords, browsing history or bookmarks.

## Where data is stored

Recorded sessions are stored in a local database at `~/Library/Application Support/AgentLedger/` on your Mac. It is append-only and hash-chained so that edits are detectable. Sessions are deleted after the retention period you choose (90 days by default). You can delete everything at any time by removing that folder.

Exports (JSONL and Markdown) are written only when you ask, to a folder on your Mac.

## Agent hooks

If you choose to install them, Agent Ledger adds logging-only hooks to Claude Code and Codex. They report each browser tool call, and the prompt that started the session (truncated to 500 characters), to the local app. They never block or change what the agent does, and they send nothing off your Mac.

## Updates

The Mac app checks GitHub, at most once a day, for a signed update (Sparkle). That request contains the app version and standard HTTP information. No recorded data is included.

## Contact

Questions or concerns: open an issue at https://github.com/toddsherman/agent-ledger/issues.
