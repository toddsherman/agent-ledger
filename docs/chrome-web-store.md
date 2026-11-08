# Chrome Web Store submission

This page has everything the developer dashboard asks for, ready to paste. Build the upload with:

```bash
scripts/package-extension.sh
```

It writes `dist/agent-ledger-chrome-<version>.zip` and removes the development `key` from the manifest, because the store assigns the item's ID.

## One-time setup

1. Register at https://chrome.google.com/webstore/devconsole. The fee is $5, once.
2. Click **New item** and upload the zip. Saving a draft creates the item and its **ID**.
3. Add the ID to `LedgerPaths.extensionIDs` (in `mac/Sources/LedgerCore/LedgerPaths.swift`) so the Mac app's native host accepts the listed extension, and ship that change in an app update.
4. Optional: to give the unpacked development build the same ID as the store item, copy the item's public key (**Package** tab → **View public key**) into the `key` field of `extension/manifest.json`.

## Store listing tab

- **Name:** Agent Ledger
- **Summary** (under 132 characters): Keeps a local, independently observed record of what AI agents like Claude Code and Codex do in Chrome.
- **Category:** Developer Tools
- **Language:** English
- **Homepage:** https://github.com/toddsherman/agent-ledger
- **Support URL:** https://github.com/toddsherman/agent-ledger/issues

**Description:**

> Agent Ledger keeps a record, on your Mac, of what AI agents such as Claude Code and Codex do in your everyday Chrome. The record comes from what the browser actually observes, not from the agents' own summaries.
>
> When an agent works in a tab, Agent Ledger records:
> - navigation
> - clicks
> - typing
> - each field's value before and after a change
> - form submits
> - the requests that change data, with their status codes
> - on-page messages such as "Saved"
>
> Each action is labeled with who did it (Identified, Likely, Likely you, Mixed, or Unknown actor) and why. That makes it easy to see what an agent changed, what you corrected, and which conclusions remain uncertain.
>
> Privacy by design:
> - Everything stays on your Mac. Nothing is sent to the developer or any server.
> - Ordinary browsing is kept in memory for a few minutes and never written to disk. Only agent sessions are recorded.
> - Passwords, card numbers, one-time codes and hidden fields are never captured. Secret-looking values are redacted.
> - No screenshots, no analytics, no accounts.
>
> **Requires the free Agent Ledger Mac app** (macOS 14 or later), which stores and displays the record: https://github.com/toddsherman/agent-ledger/releases/latest

**Graphics:**

- **Store icon:** `extension/icons/icon128.png`
- **Small promo tile** (440×280): `docs/store-assets/promo-tile-440x280.png`
- **Screenshots:** upload these four 1280×800 files, in order:
  1. `docs/store-assets/screenshot-1-1280x800.png`: "See exactly what an agent changed" (Claude Code session, Changes view).
  2. `docs/store-assets/screenshot-2-1280x800.png`: "Your own edits are labeled as yours".
  3. `docs/store-assets/screenshot-3-1280x800.png`: "Works with Codex too".
  4. `docs/store-assets/screenshot-4-1280x800.png`: "Agent reports and browser observations, side by side" (Timeline view).

  **How they're made:** they're real captures of the Ledger window, taken from a demo copy of the ledger that holds only the mock-CMS test sessions, with neutral task labels and no personal text. To regenerate them:
  1. Run the app with `AGENT_LEDGER_HOME=<demo dir> AGENT_LEDGER_NO_REGISTER=1`. The flag stops a demo instance from changing Chrome's native host registration.
  2. Open a view with a link, e.g. `open "agentledger://ledger?session=<id>&tab=changes"`.
  3. Capture it with `ledgerctl snapshot <file>.png`, run with the same `AGENT_LEDGER_HOME`.
  4. Run `swift mac/scripts/frame-screenshots.swift <captures dir>`.

## Privacy practices tab

**Single purpose:**

> Record, locally on the user's Mac, what AI agents (such as Claude Code and Codex) do in the browser, so the user can review what was changed and by whom.

**Permission justifications:**

| Permission | Justification |
| --- | --- |
| `tabs` | Read tab URLs and titles to know which tab an agent is using and to describe navigation in the record. |
| `tabGroups` | AI agents put the tabs they control in named tab groups; group membership helps tell which agent is using a tab. |
| `webNavigation` | Record page navigations in tabs an agent is using, and detect pages the extension can't observe. |
| `debugger` | Used only to call `chrome.debugger.getTargets()`, which reports whether a debugger is attached to a tab. Agents attach a debugger to control tabs, so this is how agent control is detected. The extension never attaches a debugger and never sends debugger commands. |
| `downloads` | Record downloads started during an agent session, including which extension started them. |
| `management` | Detect whether known AI agent extensions (Claude, ChatGPT/Codex) are installed and enabled. No other extension data is used. |
| `nativeMessaging` | Send observations to the Agent Ledger Mac app on the same computer, which stores the record. Required: nothing is stored or sent anywhere else. |
| `storage` | Remember which tabs are being recorded if the background worker restarts. |
| `alarms` | Keep the connection to the Mac app alive and reconnect it after interruptions. |
| `webRequest` | Record request method, status and timing (no bodies) for tabs an agent is using, so the record shows which actions changed data. |
| `scripting` | Inject the page observer into tabs that were already open when the extension was installed or an agent started using them. |
| Host permission `<all_urls>` | Agents can work on any site the user visits; the page observer must be able to run in whichever tab an agent uses. Outside agent sessions nothing is recorded. |

**Remote code:** No. All code is in the package.

**Data usage:**

- **Collected:** web history, user activity and website content. All of it is processed and stored only on the user's own device; none of it is transmitted to the developer.
- **Certify:**
  - Data is not sold to third parties.
  - Data is not used or transferred for purposes unrelated to the single purpose.
  - Data is not used for creditworthiness or lending.

**Privacy policy URL:** https://github.com/toddsherman/agent-ledger/blob/main/PRIVACY.md

## Distribution tab

- **Visibility:** **Unlisted.** Only people with the link can install it, and you can switch to Public later without the ID changing.
- **Regions:** all.

## Updating

1. Bump `version` in `extension/manifest.json`.
2. Run `scripts/package-extension.sh`.
3. Upload the zip on the item's **Package** tab and submit for review.

Store review can take from hours to a few days. The `debugger` permission tends to get closer review.
