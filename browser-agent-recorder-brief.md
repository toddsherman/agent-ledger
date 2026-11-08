# Browser Agent Recorder Goals Approaches and Open Questions

**Working brief · November 7, 2026 · For Todd Sherman**

Build a user-owned record of what AI agents do in the browser, with reliable session detection, independently observed evidence, and honest attribution. The initial setting is Todd’s Mac and Chrome, with Claude and Codex as the first compatibility targets.

The selected direction is an independent browser-agent activity recorder. A Chrome extension with a Mac companion is the leading implementation candidate. Automatic detection is important, but the product must also handle existing tabs, background work, human intervention, multiple agents, and incomplete observations.

The central distinction is **agent-reported intent → attempted operation → observed browser activity → verified outcome**. Those are different kinds of evidence. A click on Submit does not establish that the intended record was saved.

This brief preserves the goals, candidate approaches, technical limits, experiments, and unresolved decisions. Priorities and proposed defaults below are recommendations for testing, not implementation commitments.

# Goals and product context

## Goals established in the discussion

- Create a useful product related to AI agents operating on the web.
- Monitor other agents and keep a record independently of their conversational summaries.
- Detect when an agent is using Chrome with high confidence, including implicit signals available to a Mac app.
- Understand which activity belongs to an agent, a person, or an unresolved combination.
- Build robustness across realistic control methods, rather than relying on one visual convention such as a tab group.
- Understand competing products and the remaining opportunity before committing to a build.

The first user is someone who already delegates browser work to multiple agents and wants to answer: What happened? Where did it happen? What changed? What did I have to correct? How much of this record can I trust?

## Relationship to Todd’s projects

[Todd.sh](https://todd.sh) includes Shipshape, a Mac utility for keeping development tools patched; GridAlert, which checks ordinary explanations for power outages; Othello Autoresearch and Adventures of Lolo Agent, which investigate agent behavior; and Spec Builder, which turns ideas into specifications. The recorder fits those interests through local tooling, observable evidence, and explicit uncertainty. That connection is a product interpretation, not a requirement to reuse any project’s name or technology.

## Candidate value proposition

A single history of delegated browser work across supported agents, kept on the user’s machine and backed by evidence the user can inspect.

Potential benefits include reviewing unattended tasks, diagnosing failures, understanding consequential changes, preserving human corrections, and comparing an agent’s claims with observed results. The first release should prove that this history is useful before expanding into general outcome verification or policy enforcement.

## Boundaries still to decide

Automatic blocking, universal attribution, continuous recording of all browsing, cloud storage, full video replay, outcome verification, and tamper resistance are not established requirements. Each introduces a separate product and engineering decision.

# What the system must distinguish

## Four questions with separate answers

| Question | Example answer | Required evidence |
| --- | --- | --- |
| Should a session be recorded? | An agent is probably using this tab. | Supported control signals, explicit session selection, or a direct integration. |
| Who caused an event? | Claude Code likely caused this interaction. | Evidence linking an actor and session to this tab and time. |
| What happened? | A form changed and the page navigated. | Independently captured interactions and page state. |
| Did the task succeed? | The expected record exists with the intended values. | A relevant postcondition, preferably checked independently of the initiating action. |

Recording can be justified even when individual events have uncertain attribution. A complete-looking timeline must not imply complete observation.

## Meaning of independent

Three levels deserve separate decisions:

1. **Independent storage:** records live outside the agent’s chat history.
2. **Independent observation:** the recorder captures browser effects separately from the agent’s statements or tool reports.
3. **Resistance to alteration:** the observed agent cannot silently rewrite or erase the record.

The proposed first product emphasizes the first two. Optional hooks and local tool logs can improve attribution while remaining labeled as runtime-reported evidence. They do not replace independent observation.

If resistance to alteration becomes a requirement, specify the threat model. An append-only interface or hash chain can expose some edits, but a process with access to both records and signing material may still alter them. Stronger isolation or external checkpoints would be a separate design.

## Confidence language

Use understandable labels such as **Identified**, **Likely**, **Unknown actor**, and **Mixed activity**. “Identified” should name the scope of the evidence: extension, application, runtime session, or individual operation. Identifying a browser bridge does not identify a model or conversation automatically.

Avoid percentage confidence until the detector is calibrated against labeled examples. Preserve the reasons for each classification and allow the user to correct it without overwriting the original observation.

# Browser control paths and compatibility

A robust implementation should recognize three families of browser control:

| Control path | Examples | Useful observation points |
| --- | --- | --- |
| Browser extension bridge | An agent communicates with an installed Chrome extension. | Extension identity, tab groups, debugger state, native-host connections, hooks. |
| External browser automation | Playwright, ChromeDriver, or direct Chrome DevTools Protocol connections. | Browser launch configuration, process relationships, automation transport, runtime tool records. |
| Mac input and Accessibility | An agent uses desktop input or application accessibility interfaces. | Input source metadata, focus, exposed application state, visible results. |

Chrome DevTools Protocol is abbreviated CDP. Model Context Protocol is abbreviated MCP. These are transports and interfaces; neither inherently proves that an AI agent, rather than conventional automation, is the caller.

## Claude

Claude Code’s documented Chrome integration opens tabs and groups them by session. It can pause for human login or CAPTCHA handling. A group is therefore useful session context, but a person can interact with its tabs and a group can remain after work ends. Claude Code, Claude Desktop, Cowork, and the standalone Chrome experience must be tested as distinct configurations. [Claude Code Chrome integration](https://code.claude.com/docs/en/chrome)

## Codex

The installed Codex Chrome integration guide explicitly supports claiming an existing tab without moving it into an agent group. Group detection therefore cannot cover every supported takeover. The local guide also refers to agent tab groups, so “Codex does not use groups” is not a sound assumption.

Local evidence: `/Applications/ChatGPT.app/Contents/Resources/plugins/openai-bundled/plugins/chrome/docs/tab-claiming-chrome.md`, inspected November 7, 2026. Treat this as an installed-version behavior, not a permanent public API contract.

Codex’s built-in browser and external Chrome are separate observation surfaces. An extension installed in ordinary Chrome cannot be assumed to cover a separate browser environment. [Codex browser documentation](https://learn.chatgpt.com/docs/browser), [Chrome extension documentation](https://learn.chatgpt.com/docs/chrome-extension)

## Compatibility record

Maintain one entry per tested combination of agent product, agent version, browser version, control path, profile, permissions, and recorder version. Include created tabs, claimed existing tabs, background tabs, multiple windows, and read-only operations. Unsupported or newly changed combinations should receive reduced confidence or explicit coverage gaps.

# Browser signals to evaluate

The priorities below describe investigation order. No passive signal should be treated as a universal actor identifier.

| Signal | What it contributes | Limits and proposed treatment |
| --- | --- | --- |
| **Debugger attachment state** | Poll `chrome.debugger.getTargets()` for targets whose `attached` state changes; associate exposed tab IDs. | Requires debugger permission. Indicates a debugger connection, not its owner or current activity. DevTools also qualifies, and polling can miss short connections. Polling does not require attaching. |
| **Named debugging banner** | Read Chrome’s visible extension debugging indicator through Mac Accessibility, with OCR as a possible fallback. | Candidate identity evidence. Browser-wide presentation, lingering state, localization, and concurrent connections require testing. Do not equate the displayed name with every tab’s current controller. |
| **Tab group lifecycle** | Track group creation, names, colors, membership changes, and associated tabs. | No creator-extension identity is exposed by the normal group API. Names can collide or change; existing-tab control may use no group. |
| **Known installed extensions** | Map stable extension IDs, enabled state, and versions to supported agent integrations. | Installation is capability context, not activity. Management permission adds installation burden. |
| **Explicitly attributed downloads** | `DownloadItem.byExtensionId` can identify the initiating extension. | Strong for the specific attributed download. A download triggered through an ordinary webpage click may lack this field. |
| **Navigation and document identity** | Track routes, navigation types, frames, document boundaries, and tab adoption. | Useful for organizing evidence and avoiding accidental cross-tab attribution; does not identify the actor. New tabs may acquire their URL or group after their creation event. |
| **Page interactions and changes** | Observe click, input, submit, scroll, and selected DOM changes in permitted documents. | Captures effects. Websites, scripts, autofill, and users can generate similar changes; some programmatic updates produce no input event. |
| **Permitted request metadata** | Correlate request timing, origin, tab, and frame with a browser effect. | Initiator is generally an origin, not the responsible agent. Visibility restrictions apply; WebSocket handshakes do not expose all message contents. |
| **WebDriver flag** | `navigator.webdriver` can corroborate cooperating automation. | Does not identify AI, product, session, or current action. Absence does not rule out extension or CDP control. |

Sources: [debugger API](https://developer.chrome.com/docs/extensions/reference/api/debugger), [tab groups](https://developer.chrome.com/docs/extensions/reference/api/tabGroups), [tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs), [management](https://developer.chrome.com/docs/extensions/reference/api/management), [downloads](https://developer.chrome.com/docs/extensions/reference/api/downloads#type-DownloadItem), [navigation](https://developer.chrome.com/docs/extensions/reference/api/webNavigation), [requests](https://developer.chrome.com/docs/extensions/reference/api/webRequest), [WebDriver standard](https://w3c.github.io/webdriver/#interface).

Two debugger details matter: `TargetInfo.extensionId` identifies an extension target being debugged, not the owner of a debugger connection. The extension’s debugger events are not a global feed of other extensions’ outgoing commands. A second observer connection must not be assumed to reveal those commands; compatibility with other clients needs testing.

# Mac signals to evaluate

## Stronger attribution and session context

| Signal | Proposed observation | Limits and next test |
| --- | --- | --- |
| **Native messaging host connection** | Associate a known helper with the caller’s extension origin and connection lifetime, where process details are observable. | Chrome passes the caller origin to the host. A persistent connection can be idle; it does not identify a tab or operation. Test exact helper behavior for each integration. |
| **Input source metadata** | Observe OS input events and their reported source process IDs; correlate with browser interactions. | May identify an intermediary helper. CDP can bypass the OS input stream. Source fields are not a cryptographic identity guarantee. |
| **Input timing and focused application** | Compare browser interaction times with input activity and the app receiving keyboard input. | Positive evidence that the person is working elsewhere is useful corroboration. Remote control, accessibility software, virtual devices, and scripts complicate inference. |
| **Agent operational UI** | Observe exposed browser-operation labels, permission prompts, Stop controls, or takeover states through Accessibility. | Validate available elements by version. Generic “working” is weak; observe operational status without needing conversation bodies. |
| **Process identity and lifetime** | Resolve helpers to executable paths and signing identities; retain PID plus lifetime or start time. | Improves identity matching and avoids PID reuse mistakes. Shared or unsigned interpreters may require additional context. A signed executable alone does not establish an action. |
| **Automation launch and transport** | Recognize remote-debugging port/pipe flags, dedicated profiles, browser ancestry, and observable local connection endpoints. | Flags indicate enabled control, not active work. Pipes have no TCP listener; extension control may need neither flag. |

Chrome documents native messaging origins and host lifetime in its [native messaging guide](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging). It documents remote-debugging launch constraints in [Chrome remote debugging](https://developer.chrome.com/blog/remote-debugging-port).

Relevant Apple interfaces include [event source process IDs](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceunixprocessid), [event source state](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid), [foreground application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication), [Accessibility notifications](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h), and [code identity](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)).

## Weaker supporting observations

- **Clipboard changes:** monitor `NSPasteboard.changeCount`, without reading contents, and correlate with paste-like updates. It supplies no writer identity and is noisy around clipboard managers and Universal Clipboard. [Apple clipboard metadata](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
- **Event tap installation:** `CGGetEventTapList` can enumerate taps. An agent-specific change might mark a session, but a tap is an observer or filter, not proof of browser control. [Apple event taps](https://developer.apple.com/documentation/coregraphics/cggeteventtaplist(_:_:_:))
- **Behavioral sequences:** repeated interactions in a background tab, with agent control evidence and activity elsewhere, can strengthen an inference. Speed or regularity alone should have little weight.
- **CPU, generic network traffic, or screenshots appearing on disk:** at most experimental corroboration. These do not reliably establish browser control or agent identity.

Input observation, Accessibility inspection, and screen capture have different macOS permission requirements. Permission availability and actual sensor health must be represented explicitly. Hardware-associated state is not a tamper-proof “human” bit.

# Direct integrations and advanced options

## Optional integrations with supported agents

**Tool-call hooks.** Claude Code and Codex support hooks around supported tool calls. A logging-only adapter could emit session ID, tool-call ID, operation category, available target identifiers, and start/result timestamps to the recorder. Use the runtime’s supported interface and preserve its normal permission decisions. One tool call may contain multiple browser operations; an attempted call does not establish completion.

Claude Code supports matching MCP tools. Codex documents supported local tool paths and exceptions, so coverage of any particular native browser integration must be verified. Neither fact establishes equivalent hook support in every desktop client. [Claude hooks](https://code.claude.com/docs/en/hooks), [Codex hooks and tool coverage](https://learn.chatgpt.com/docs/hooks#tool-coverage)

**Local tool-log adapters.** A Mac companion could watch supported session logs for browser-tool records without changing the agent’s workflow. Claude Code saves messages, tool uses, and results in local JSONL files. Parsing should be versioned, scoped, and resilient to delayed or partial writes. Codex explicitly warns that transcript formats are not stable hook interfaces. Prefer supported hooks when practical, while keeping passive log watching as a candidate. [Claude session storage](https://code.claude.com/docs/en/how-claude-code-works), [Codex transcript caveat](https://learn.chatgpt.com/docs/hooks)

**Explicit session markers.** A user button or authenticated local integration can mark “record this agent session,” attach a session identifier, and identify tabs. This is valuable fallback coverage. A start marker identifies the intended session, not every subsequent actor.

**Instrumented control bridge.** An optional MCP or browser-control adapter operated by the recorder could log requests and results directly. It offers stronger operation attribution within that path, but requires configuration and only covers operations routed through it. Browser effects should still be captured separately.

**Dedicated agent window or profile.** Deliberately scoping work to a selected environment makes capture boundaries clearer. It does not prove who caused each event, and moving to a separate profile can reduce the convenience of existing signed-in tabs.

## Research options with greater installation or maintenance cost

| Option | Possible benefit | Why it should remain optional |
| --- | --- | --- |
| Chromium extension Activity Log | Internal extension API records can include extension identity and arguments. | Private/allowlisted interfaces and diagnostic configuration are not a normal store-extension foundation. Validate current access and exact command coverage. |
| Endpoint Security | Process execution and some IPC events can strengthen helper lineage. | Requires Apple’s special entitlement and additional deployment requirements. Does not provide a universal browser-action feed. |
| Network Extension | Some flow metadata can identify a source application/process. | Chrome traffic usually identifies Chrome; native pipes and in-process activity may be absent. Adds permissions and distribution complexity. |
| Own managed browser or browser fork | More control over instrumentation and session boundaries. | Changes the product from observing ordinary Chrome and introduces substantial maintenance and competition. |

Sources: [Chromium Activity Log implementation](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/extensions/activity_log/activity_log.cc), [API permission restrictions](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_permission_features.json), [Apple Endpoint Security](https://developer.apple.com/documentation/endpointsecurity), [Network Extension flow metadata](https://developer.apple.com/documentation/networkextension/nefilterflow).

Avoid treating `event.isTrusted` as a human detector, page-function monkey-patching as a universal observer of other extensions, or network destinations as proof of agent control. Extension JavaScript worlds are isolated, and browser-generated events are not synonymous with human-generated events. [Content-script isolation](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts), [event trust semantics](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted)

# Proposed architecture and detection behavior

## Components

1. **Chrome observer:** collect permitted browser metadata and selected page evidence, track document boundaries, and report its coverage.
2. **Mac companion:** observe authorized process, input, focus, and application-state signals; run optional agent adapters.
3. **Correlation engine:** associate evidence by browser instance, profile, tab, document, process lifetime, and runtime session.
4. **Capture controller:** apply user scope, confidence rules, buffering, redaction, and retention.
5. **Local evidence store:** preserve observations, runtime reports, inferences, corrections, and gaps as distinguishable records.
6. **Review interface:** show session timelines, consequential changes, attribution reasons, missing coverage, and exports.

A Chrome native-messaging connection between our own extension and companion is a candidate transport. Authenticate the relationship and reject arbitrary webpage requests. Exclude identifiable recorder activity from agent detection.

Debugger-based capture has a specific interference risk: once our recorder attaches, the target’s boolean attached state can remain true even as another client connects or disconnects. There is no owner list to subtract. Avoid persistent observer attachment when detection depends on attachment transitions, or use another detection channel during capture. Test this before selecting a screenshot or diagnostic capture method.

## Combining evidence

Organize signals into identity, control connection, browser effects, human context, and sensor health. Correlate them in time and on the same target. Do not add them as independent votes indiscriminately: a debugger banner and attached state may describe the same connection.

A strong candidate sequence is: a verified helper connects, a tab becomes controlled, the agent app indicates a browser operation, and interactions occur while the person is typing elsewhere. A group name plus an idle installed extension should remain weak.

Use a lower evidence threshold to retain a scoped session than to name the actor of an event. Conflicting evidence should produce mixed or unknown attribution. User activity in one application must not globally suppress agent recording in another.

## Session lifecycle

Candidate states are **idle → possible session → recording → temporarily inactive → ended**, with an independent **coverage degraded** status.

- Start from explicit selection, supported direct evidence, or corroborated passive signals within the permitted scope.
- Maintain a short bounded prebuffer on opted-in tabs so late detection can recover opening activity. Test a metadata-only buffer first; duration remains an experiment.
- Use a settling period around navigation, reconnects, and agent thinking. Do not fragment every brief pause into a new session.
- Do not let a stale group or idle bridge keep unrelated browsing recorded indefinitely.
- Preserve human interventions, sign-ins, and corrections as part of the session.
- Let users mark “This was me,” “Wrong agent,” “Include this tab,” and “Stop recording.”
- Store observation timestamps at the sensor, plus receipt times and ordering information, to avoid confusing transport delay with causal order.

Reading DOM content, taking screenshots, and inspecting accessibility state may leave no visible change. Direct tool or control-session evidence is needed to cover such activity; an empty interaction stream cannot establish inactivity.

# Recording content and the review experience

## Candidate capture levels

| Level | Contents | Intended use and tradeoff |
| --- | --- | --- |
| Session metadata | Time, supported actor identity, scoped tabs, connection evidence, detector version, coverage gaps. | Lowest content exposure; limited reconstruction. |
| Interaction timeline | Navigation, click/type/submit categories, selected element descriptions, scroll and handoff markers. | Useful chronology without storing all entered values. |
| Evidence snapshots | Selected before/after page state or screenshots at meaningful points. | Helps explain consequences; requires redaction and capture-surface decisions. |
| Detailed replay | DOM snapshots and mutations, with separate streams per document; optional video. | Richer review, larger storage and privacy burden, incomplete coverage of some rendering surfaces. |
| Diagnostic evidence | Selected console errors and request metadata or responses. | Useful for failures; requires additional access and careful secret handling. |

The first prototype should compare these levels on real tasks to establish the smallest useful record. Ordinary visible-tab screenshots do not automatically solve background-tab capture. Rich capture methods must be tested for permission requirements and interference with the agent.

## Evidence model

Each record should retain an event ID, observation time, receipt time, source sensor, browser/session identity, tab and document identity, event category, attribution label and reasons, detector version, privacy/redaction state, and references to any captured artifacts.

Use separate categories for runtime-reported intent, attempted operations, observed effects, inferred actor, checked outcomes, user corrections, and observation gaps. Keep summaries linked to the supporting records. A revised inference should not silently rewrite raw evidence.

## Useful review features

- A session list showing agent attribution, sites, duration, recording scope, and coverage.
- A timeline with agent activity, human intervention, idle periods, and gaps.
- Before/after evidence for meaningful changes.
- Search by site, task label, date, actor, or event category.
- A clear explanation of why recording started and why an actor was named.
- A reviewable summary of changes, failures, and unresolved outcomes.
- Local export of structured records plus a readable report; optional redacted evidence bundles.
- Manual task labels and optional linking to an agent session, without requiring full chat ingestion.

DOM replay is a reconstruction, not a video of everything the agent saw. Canvas, WebGL, cross-origin frames, shadow roots, transient assets, and browser UI need explicit coverage decisions. The phrase “what the agent saw” should be reserved for actual captured tool output or a proven equivalent.

# Privacy permissions and record integrity

## Proposed starting defaults

- Keep records on the Mac and make cloud sync, remote model summaries, and sharing explicit later options.
- Limit recording and prebuffering to selected sessions, tabs, or sites. Show when recording is active.
- Exclude passwords and authentication secrets; redact before durable storage where possible.
- Treat URLs, page titles, tool arguments, clipboard contents, and screenshots as potentially sensitive. Metadata is not automatically harmless.
- Collect input timing and source context without creating a systemwide keystroke log.
- Inspect agent operational state without collecting conversation bodies by default.
- Provide pause, exclusions, deletion, retention limits, and export review.
- Make private/incognito browsing support a separate decision, rather than silently extending capture into it.

Sensitive data can appear outside labeled fields or in screenshots. Redaction coverage should be tested and described accurately.

## Permission budget

Use the smallest set of permissions that produces useful coverage. Evaluate Chrome site access, tabs/groups, downloads, management, native messaging, and debugger access separately. On Mac, distinguish Input Monitoring, Accessibility, Screen Recording, and access to protected files. Avoid making special entitlements or private APIs necessary for core functionality.

A permission denied, inaccessible page, disconnected content script, disabled event tap, full disk, or recorder crash should create a visible observation gap. Recovery must preserve what was captured without asserting completeness.

## Trust and storage

Use explicit sender identity and scoped local transport for adapters. Treat web content, tool output, and page text as evidence, never as instructions to the recorder. If AI summaries are added, they should not be able to authorize browser actions or alter the underlying record.

Keep agent-facing access read-only initially. Decide separately whether the user, an observed agent, or an external service may delete or modify records. Optional hashes, signed checkpoints, and isolated storage can improve integrity, but the product must define what adversary those measures protect against.

If using third-party capture libraries or code from existing projects, review licensing, update behavior, and the privacy properties of the actual integration before adoption.

# Validation plan and success measures

## Early experiments

| Experiment | What to test | Decision it informs |
| --- | --- | --- |
| Existing-tab detection | Claude and Codex take an existing ungrouped tab; include background and multi-window cases. | Whether group-independent detection is viable. |
| Read-only work | Read a page, inspect DOM, and take screenshots without changing the page. | Whether supported integrations are required for the coverage promise. |
| Signal timing | Compare helper connection, debugger state, app UI, tool logs/hooks, and first browser event. | Start rules, polling cadence, prebuffer need, and delayed attribution. |
| Human overlap | Work in another app, help with login, correct a form, and share a tab with the agent. | Mixed-actor handling and takeover labels. |
| Multiple agents | Run different agents and multiple sessions of one agent simultaneously. | Session isolation and limits of shared bridges or banners. |
| False positives | DevTools, autofill, password managers, accessibility tools, macros, remote desktop, and ordinary website scripts. | Whether automatic starts can remain selective. |
| Failure injection | Revoke permissions, stop sensors, sleep/wake, restart Chrome, navigate to unsupported pages, and fill storage. | Gap detection, recovery, and record integrity. |
| Record usefulness | Ask someone to reconstruct a task using only the saved record. | Whether metadata, snapshots, or replay justify their cost. |

Use a controlled diagnostic page to establish ground truth for navigation, clicking, typing, paste, scrolling, form submission, tab changes, and read-only operations. Record the tested versions and repeat the relevant suite after integration changes. Add realistic authenticated workflows only after capture scope and redaction are settled.

## Metrics to report separately

- Session recall: how many known agent sessions were detected, including short and read-only sessions.
- False recording starts per hour of ordinary use, plus unintended content captured.
- Detection latency and the fraction of opening operations missed.
- Accuracy of named actor attribution on labeled events, including the fraction left unknown.
- Session fragmentation and unnecessary recording after work ends.
- Coverage gaps detected, undetected losses, and recovery time.
- CPU, memory, battery, disk growth, and browser responsiveness.
- Permission completion and maintenance burden.
- User ability to understand what happened and which conclusions remain uncertain.

No numerical launch threshold has been selected. Define targets from the first measurements and intended audience. A high overall accuracy score can conceal poor recall or overconfident attribution.

## Decision gates

Proceed to a usable recorder when supported APIs and ordinary installation provide worthwhile coverage, false starts are manageable, and the recorded evidence helps reconstruct tasks. If passive detection misses required read-only or existing-tab work, require a supported integration for that configuration or narrow the advertised coverage. If the strongest signals require private interfaces, reconsider the product’s installation model before building a broad consumer experience.

# Suggested implementation sequence

## Stage 1 Detection feasibility

Build a developer sensor console and a diagnostic page. Observe a small set of supported Claude and Codex configurations, focusing on existing tabs. Capture minimal metadata, source health, timestamps, and detector reasons. Compare debugger state, native-host context, local tool logs, and input/focus correlation.

Deliver a compatibility matrix and evidence about missed sessions and false starts. This stage should determine which signals merit ongoing maintenance.

## Stage 2 Useful local recorder

Add explicit session recording, scoped automatic starts, interaction timelines, selected evidence snapshots, privacy controls, gap markers, and local export. Test whether someone can reconstruct a task without the agent’s narrative.

## Stage 3 Better attribution and recovery

Add supported logging-only hooks, versioned passive log adapters, operational UI adapters where valuable, multi-agent handling, human correction markers, buffering, and resilient session boundaries.

## Stage 4 Review and verification

Add consequential-change summaries and a small number of independently checkable outcomes. Evaluate richer replay only where it materially improves review. Keep generated summaries separate from captured evidence.

## Stage 5 Broader coverage

Expand supported agents, browsers, and workflows based on measured demand. Consider instrumented bridges, dedicated profiles, managed deployment, or special-entitlement approaches only where their benefit justifies the cost.

The first technical spike should answer detection feasibility before committing to a polished interface or universal compatibility claim.

# Existing products and differentiation

The market already includes browser controllers, session recorders, agent-oriented debugging tools, and outcome checkers. The opportunity must be validated against these, not inferred from the absence of a familiar incumbent.

| Product | Relevant overlap | Implication for this idea |
| --- | --- | --- |
| [Open Claude in Chrome audit mode](https://github.com/noemica-io/open-claude-in-chrome#auditing-agent-sessions) | Records browser DOM activity across tabs and attributes sessions through its own native-host request IDs. | Close overlap in recorded evidence and replay; its control bridge supplies attribution. Evaluate how much value remains for an observer of other bridges. |
| [Session Recorder by Proofline](https://github.com/prooflinedev/session-recorder-chrome-extension) | Browser activity, screenshots, diagnostics, annotations, exports, and explicit capture gaps for QA. | Generic evidence capture is established. Automatic agent-session detection and everyday delegated-work review need to add value. |
| [Agent Replay](https://github.com/Boe-Ventures/agent-replay) | Local structured recording, replay, comparisons, and agent exports; its extension targets localhost applications. | Strong technical adjacency. Everyday authenticated web workflows and cross-agent detection are candidate distinctions. |
| [Attest](https://chromewebstore.google.com/detail/attest-receipts-for-your/jbfjihdoahhbgdfjkknbboaicdphhpaf) | Checks pasted agent claims against observed Gmail and Calendar evidence. | Direct competition if independent outcome verification becomes central. |
| [BrowserOS neo](https://browseros.com/) | A separate browser for agents with session replay and multiple-agent workflows. | A compelling substitute for users willing to adopt another browser. Ordinary-Chrome compatibility must be worth its attribution limitations. |
| [Browser MCP](https://browsermcp.io/) | Connects agents to existing Chrome sessions, with grouped tabs and handoff. | A potential integration target and a source of stronger session identity if cooperation is possible. |
| [Manus Browser Operator](https://manus.im/blog/manus-browser-operator) | Agent operation inside a local authenticated browser. | Compare built-in review and session controls before positioning an additional observer. |
| [Handoff](https://get-handoff.com/docs/) | Captures page feedback and context for coding agents through MCP. | Adjacent to correction capture and failure diagnosis rather than general session attribution. |

Other categories surfaced during exploration include side-panel agents and workflow automation such as Nanobrowser, HARPA, and Bardeen; demonstration capture such as TeachAnAgent; conversation memory; agent-readiness inspectors; and context handoff tools. These are research categories, not a reason to broaden the first release.

The proposed distinction is **a user-owned ledger for everyday browser work across supported agents, with independently observed effects, explicit attribution uncertainty, and a clear record of human intervention**. This remains a differentiation hypothesis.

## Adjacent features to preserve for later

- Acceptance checks defined before an agent starts.
- Comparison of claimed completion with inspectable results.
- A failure brief containing relevant evidence and unresolved questions.
- Reviewable human corrections that can inform a subsequent run.
- Portable task briefs containing selected tabs, constraints, and freshness markers.
- Regression checks for a repeated workflow.

These extend the recorder into verification, training, or orchestration. They should be justified by use of the core record rather than added automatically.

# Open questions

## Decisions needed before defining the prototype

1. **Coverage promise:** Does “using the browser” include reading DOM, screenshots, accessibility inspection, and background work, or initially only observable interactions?
2. **First configurations:** Which exact Claude and Codex clients, integration paths, browser profiles, and versions should receive named support?
3. **First task:** Which concrete workflow best demonstrates value: web app testing, editing a document, changing a CMS record, entering data, or another task?
4. **Meaning of independence:** Is separate observation and storage enough, or must the recorder resist alteration by an agent with local shell access?
5. **Capture scope:** Should the user select sessions, tabs, sites, or a dedicated window? How much automatic arming is desirable?
6. **Minimum useful evidence:** Is an interaction timeline enough, or are screenshots, page state, and replay essential?
7. **Error tradeoff:** How costly is missing a session compared with accidentally recording ordinary browsing? Should thresholds vary by content sensitivity?
8. **Integration willingness:** Is an optional hook or tool adapter acceptable when passive observation cannot meet the coverage goal?

## Technical questions

9. Can a normal companion reliably observe the relevant helper identities, connection lifetimes, and browser mappings with acceptable permissions?
10. How long do debugger attachments and named banners remain after useful work ends? What happens with concurrent clients?
11. Which agent operational states are exposed through Accessibility, and how stable are they across versions and localization?
12. How quickly do runtime logs reach disk, and which supported tool calls contain trustworthy target identifiers?
13. Can one shared extension or helper distinguish multiple agents and multiple sessions without a direct adapter?
14. Which rich capture methods work on background tabs without changing focus or interfering with the agent?
15. How should cross-origin frames, shadow DOM, canvas, downloads, uploads, browser UI, and inaccessible pages be represented?
16. What polling and buffering strategy meets battery and latency needs? How does extension service-worker suspension affect it?
17. How should browser instances, profiles, tabs, documents, process lifetimes, and sessions be correlated across restarts?
18. What automatic calibration or compatibility checks can detect a broken adapter before it silently misclassifies activity?

## Product and trust questions

19. Is the primary job reassurance, debugging, accountability, a searchable history, or outcome verification?
20. Which consequences should a summary emphasize, and what evidence permits saying a task succeeded?
21. How should the user inspect and correct attribution without adding a burdensome review step?
22. What retention limits, encryption, redaction, exclusions, and deletion controls are appropriate?
23. Should agents receive read-only access to previous records? Who can export, modify, or delete them?
24. Are cloud backup, team sharing, or external AI summaries needed at all?
25. What differentiates this enough from integrated agent replay and existing local recorders to justify another installation?
26. How much ongoing adapter maintenance is sustainable? Should supported integrations be open source?
27. Is Chrome Web Store plus a notarized Mac app sufficient, and what would justify managed deployment or special entitlements?
28. What measured recall, false-start rate, attribution accuracy, and capture completeness are acceptable for launch?

## Current decision record

**Chosen direction:** independent monitoring and logging of agents using the browser, with an emphasis on robust detection and Mac-level signals.

**Leading proposal:** a Chrome extension plus Mac companion, scoped local capture, multiple evidence sources, optional direct integrations, and explicit uncertainty.

**Not yet decided:** product name, exact compatibility targets, first workflow, capture depth, permission budget, launch thresholds, distribution, pricing, and whether outcome verification belongs in the first release.

**Next useful deliverable:** a small, inspectable feasibility prototype and a compatibility report showing which signals actually fire, when they arrive, what they miss, and what ordinary activity falsely triggers them.

