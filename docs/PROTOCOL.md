# Agent Ledger protocol (v1)

Every observation travels as one **event envelope**. The extension, the native host
(`ledger-host`), the hook CLI (`ledger-hook`) and the app's own sensors all produce the
same shape, so the app can store and correlate them uniformly.

## Event envelope

```json
{
  "v": 1,
  "src": "ext.sw",
  "inst": "sw-1731000000000-ab12",
  "seq": 42,
  "t": 1731000000123.5,
  "kind": "context",
  "cat": "tab.updated",
  "tab": 123, "win": 4, "frame": 0, "doc": "8F2A…", "url": "https://example.com/a?token=[redacted]",
  "rec": false,
  "p": { }
}
```

| Field | Meaning |
| --- | --- |
| `v` | Protocol version. |
| `src` | Source sensor: `ext.sw`, `ext.content`, `mac.sensor`, `hook.claude`, `hook.codex`, `app`. |
| `inst` | Source instance. A new value means the sensor restarted (used to detect gaps). |
| `seq` | Monotonic per `inst`. A jump means lost events. |
| `t` | Observation time at the sensor, Unix epoch **milliseconds**. The app adds `received_at`. |
| `kind` | Evidence class, see below. |
| `cat` | Category, dot-separated (`tab.created`, `ui.click`, `tool.pre`, …). |
| `tab`/`win`/`frame`/`doc`/`url` | Browser identity, when known. `url` is already redacted. |
| `rec` | Set by the extension: `true` when the tab was armed for recording when observed. |
| `pre` | `true` when the event came from a prebuffer flush (observed before arming). |
| `p` | Category-specific payload. |

### Evidence kinds

| `kind` | Meaning | Examples |
| --- | --- | --- |
| `runtime_intent` | What the agent runtime says it was asked or intends. | `turn.prompt` |
| `attempted_op` | The runtime reports it is starting an operation. | `tool.pre` |
| `runtime_report` | The runtime reports a result or lifecycle change. | `tool.post`, `tool.failure`, `turn.stop`, `session.start`, `session.end` |
| `observed_effect` | Independently observed browser activity. | `nav.committed`, `ui.click`, `field.change`, `net.request`, `page.alert` |
| `context` | State that helps correlation but is not an action. | `tab.created`, `group.updated`, `debugger.attached`, `helper.started` |
| `gap` | The recorder knows it missed or could not observe something. | `gap.sw_restart`, `gap.page_inaccessible`, `gap.app_down` |
| `sensor_health` | Sensor status. | `health.heartbeat`, `health.extension_hello` |

Inferences (sessions, actor attributions) and user corrections are **not** events; the app
stores them in their own tables and never rewrites raw events.

## Transport

### Extension ↔ `ledger-host` (Chrome native messaging)

Frames are a 4-byte little-endian length followed by UTF-8 JSON. Host → Chrome messages
must stay under 1 MB.

Extension → host:

```json
{"type":"hello","ext":"odfiimhaencobkjndlcohhcjbehmejmf","ver":"0.1.0","inst":"sw-…","browser":"Chrome/157…","profileHint":"…"}
{"type":"events","events":[ <envelope>, … ]}
```

Host → extension (relayed from the app):

```json
{"type":"arm","tab":123,"session":"S-…","policy":{"values":true,"prebufferMs":120000}}
{"type":"disarm","tab":123,"session":"S-…"}
{"type":"policy","policy":{ … }}
{"type":"ping"}
```

### `ledger-host` / `ledger-hook` ↔ app (Unix socket)

`~/Library/Application Support/AgentLedger/ingest.sock`, newline-delimited JSON.

```json
{"type":"hello","role":"host","pid":123,"ext":"odfi…"}
{"type":"hello","role":"hook","pid":456,"agent":"claude"}
{"type":"events","events":[ … ]}
```

The app sends extension commands (above) back to `host` connections only.

If the socket is unavailable, producers append `{"type":"events",…}` lines to
`~/Library/Application Support/AgentLedger/spool/<role>-<pid>.jsonl`. The app replays and
deletes spool files at launch and every 30 s. The host spools only events with `rec: true`,
gaps and health events, so ordinary browsing never lands on disk while the app is down.

## Hook mapping

`ledger-hook --agent claude|codex` reads the hook JSON from stdin, always exits 0, and
writes nothing to stdout.

| Hook event | `kind` / `cat` |
| --- | --- |
| `SessionStart` | `runtime_report` / `session.start` |
| `UserPromptSubmit` | `runtime_intent` / `turn.prompt` (prompt truncated to 500 chars) |
| `PreToolUse` | `attempted_op` / `tool.pre` |
| `PostToolUse` | `runtime_report` / `tool.post` |
| `PostToolUseFailure` | `runtime_report` / `tool.failure` |
| `Stop` | `runtime_report` / `turn.stop` |
| `SessionEnd` | `runtime_report` / `session.end` |

Payload `p`: `agent`, `session`, `turn` (Codex), `toolUseId`, `tool`, `input`
(strings truncated, secrets redacted), `result` (summary only: `isError`, sizes, first 500
chars of text, never images), `cwd`, `ppid`, `browser` (true when the call is a browser
operation), and `tabId` when the input names one.
