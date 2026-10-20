# Observability

This file owns the cross-cutting logging contract: the level policy, every stream with
its writer and rotation owner, the retention budgets, the privacy rules and the
conventions every signal row follows. The rows themselves live in the **Signals**
section of the owning module's README; `scripts/tron docs signals` prints them as one
table ([docs indexes](../../../tools/docs/README.md)). A new signal, including an
incident's one-step diagnosing signal, gets its row there, beside its code.

The Gateway README owns the reader contracts (`system.logs` and `system.logs.export`)
and its [Diagnostic bundle](../README.md#diagnostic-bundle) section owns how one bundle
is collected for an incident.

## Level policy

The level answers "who needs to look, and when". Only debug stays out of files:
it lives in a bounded in-memory buffer that exports include.

| Level | Meaning | Persisted | Examples |
| --- | --- | --- | --- |
| error | Something failed that a user sees, work was lost, or an invariant broke. Someone should look | Yes | `gateway.fatal-startup`, `gateway.shutdown-failed`, `gateway.stop-drain.failed`, `process.uncaught-exception`, `connection.write-error`, `launcher.candidate-rolled-back` |
| warning | Degraded or abnormal but handled: retries, fallbacks, bounds hit, slow operations over a named threshold, notable rejections | Yes | `gateway.event-loop-delay`, `connection.superseded`, `gateway.restart-drain.stalled`, `extension.artifact-rejected` |
| info | Lifecycle and state transitions, one line per boundary; enough to reconstruct a timeline | Yes | `gateway.started`, `connection.opened` for a paired device, `session.compaction.completed`, `deploy.ready`, drain progress |
| debug | Per-request detail useful only while diagnosing | No, memory buffer only | fast successful `rpc.completed` with its stage breakdown, connection open and close for the Mac app's local probes |

- The level is fixed per event in code and listed in its Signals row; there
  are no runtime log-level settings. A level varies only with a named threshold
  or a condition its row states: a success past `SLOW_RPC_WARNING_MS`, a
  local probe connection, a deploy state in its failed set, the call site that
  raised `runtime.diagnostic`.
- Every threshold that promotes an event is a named constant with a one-line
  reason, next to the emitting code. A slow success is warning only past it.
- A caller's mistake (invalid request, unauthorized) is warning. An expected
  transient state (warming up, busy) is info or warning, never error.
- Debug never reaches disk on any Tron-owned stream. It exists so a diagnostic export can
  carry the detail of the minutes before a failure.

## Streams

One writer per file, and no two processes rotate the same file. Tron-owned logs on
the Mac are under `~/.tron/logs/`; the phone writes inside its own container.
`gateway.jsonl` is the canonical Gateway record stream; every other stream is a
bounded projection or a separate writer's own timeline. A supervised Gateway
(`TRON_GATEWAY_SUPERVISED=1`) does not mirror persisted records to stdout or
stderr, because the launcher has already redirected stderr to
`gateway-stderr.log`; an unsupervised foreground run still mirrors them.

| Stream | Writer | Rotation owner | Caps |
| --- | --- | --- | --- |
| `gateway.jsonl` | Gateway logger, `packages/gateway/src/transport/logger.ts` | Gateway logger | Eight 5 MB numbered segments (`gateway.jsonl`, `.1` … `.7`), 40 MB total; size tracked in memory; debug kept in a 4,000-record / 2 MB memory buffer; the newest 1,000 persisted records are served by `system.logs` |
| `deploy.jsonl` | Deploy helper, `scripts/gateway-payload-deploy.mjs`; the C launcher appends its own `launcher.*` records | Deploy helper, once at operation start (`DEPLOY_LOG_MAX_BYTES`) | 1 MB plus one `deploy.jsonl.1`; each launcher record is one `O_APPEND` write of at most 4 KB |
| `gateway-stderr.log` | C launcher, `packages/mac-app/scripts/tron-gateway-launcher.c`, redirects supervised stderr before executing Node | Mac app startup maintenance, `packages/mac-app/Sources/App/Lifecycle/MacAppStartupMaintenance.swift` | Emptied above 1 MiB (`gatewayStderrMaxBytes`). It holds launcher messages and Node aborts only, not the Gateway record stream |
| `mac.jsonl` | Mac app `TronLog`, `packages/mac-app/Sources/Support/TronLog.swift` | Mac app logger | Four 1 MiB segments (`mac.jsonl`, `.1` … `.3`). Warning and error are also mirrored to `os.Logger` (subsystem `com.tron.mac`) so a sysdiagnose carries them |
| `Library/Caches/Logs/app.jsonl` (iOS container) | iOS `AppLog` actor, `packages/ios-app/Core/Support/AppLog.swift` | iOS `AppLog` | 10 MiB total across `app.jsonl` and one prior segment of half each; info and above only, batched and flushed every 5 s, when the batch reaches the memory-ring bound, on backgrounding and on any error; a 2,000-record / 512 KiB memory ring holds every level |
| iOS incident store (the container's `UserDefaults` key `tron.diagnostics.incidents.v1`) | `IOSClientDiagnosticStore`, `packages/ios-app/Core/Support/IOSClientDiagnostics.swift` | The store actor | 96 records, 96 KiB, 7 days; the first cause of each of the 8 newest incidents is reserved alongside the newest window. It holds catalog, connection, client-work, lifecycle and MetricKit records; `AppLog` is the always-on timeline and does not duplicate them |
| `device-exports/` | Gateway export store, `packages/gateway/src/transport/diagnostic-export.ts`, written by `system.logs.export` | Gateway export store | One bundle is at most 512 KiB plus a 1 MB debug section; the phone's payload is 1,000 JSON lines inside that byte bound and keeps its newest records, but first reserves the identifying header plus the retained chat interaction trace (at most 256 records, `ChatInteractionTrace.maximumRecords`), so the byte envelope cannot drop the evidence for chat opening/scroll failures; the newest 10 bundles are kept; the directory is 0700 and each file 0600 |

Mac `TronLog` redacts before applying its 2,000-byte UTF-8 message bound; clipped text
keeps its longest valid scalar prefix. The phone's performance signposts are
`OSSignposter` (`com.tron.mobile`), not a log stream. No stream leaves the machine.

## Test and verification environment preflight

`packages/gateway/src/tron-home-environment-policy.mjs` owns the rule for an inherited
environment that resolves into a Tron home (`~/.tron`, `~/.tron-dev` under both
`os.homedir()` and the account home, or the selected home). A variable whose value
contains a live-home path (standalone, in a list or in a JSON value) is removed so its
owner derives the default; the selectors `TRON_DATA_DIR` and `TRON_HOME_NAME` are refused
(`Gateway tests refuse inherited Tron-home selectors`); `PATH` is never changed. Vitest
(`setupFiles`) and Node test entry points (`node --import`) apply it through
`test-support/tron-home-environment-preflight.mjs`. It is a command-line guard, not a
Gateway log event. Regression: `npm run test:tron-home-environment`; under a failing
shell, `node ./src/tron-home-environment-policy.mjs` prints only the variable names it
would remove. Test-tooling signals are rows of [knowledge](../src/knowledge/README.md#signals)
(connector credentials) and the [iOS package](../../ios-app/README.md#signals).

## Retention budgets

| Stream | Cap | Expected history |
| --- | --- | --- |
| `gateway.jsonl` | 40 MB (8 × 5 MB; the user's chosen cap) | Months |
| `deploy.jsonl` | 1 MB + one 1 MB segment | Hundreds of deployments; a source rebuild writes about a dozen records (about 3 KB) |
| `gateway-stderr.log` | 1 MiB, emptied | Rare launcher and Node abort text; a day's output is normally zero bytes |
| `mac.jsonl` | 4 MB (4 × 1 MiB) | Several days of lifecycle transitions. **Not yet measured:** the build that writes this stream is not installed on this Mac |
| `Library/Caches/Logs/app.jsonl` | 10 MiB (the user's chosen cap) | **Not yet measured:** the build that writes this stream is not installed on the phone |
| iOS incident store | 96 KiB, 7 days | Bounded incident history, independent of the app log's cap |
| `device-exports/` | 10 bundles | The newest exports; older ones are deleted at write time |
| `gateway/settings/approvals.json` (pending settings changes) | 100 open requests, plus at most 400 decided ones until their requester is told | Open requests expire after 24 hours; a decided request is dropped once told, and lives on in the change record |
| `gateway/settings/changes/` (the settings change record) | None: kept forever (settings-model.md decision 12) | One entry per settings key changed, a few hundred bytes each, in segments of 500 entries named in `index.json`; `settings.history` reads one segment per page. Its size on disk is the growth signal. **Not yet measured** |

Change a cap only if it holds less than 14 days on the Mac or 7 days on the phone at
measured volume; measurements are kept in issues, not here.

## Privacy

- Never log message content, prompts, tool output, file contents, tokens,
  credentials, or full device identifiers. Identity appears only as a stable
  hash.
- Redaction runs at the write boundary of every stream:
  `redact` in `packages/gateway/src/transport/logger.ts`, `TronLog.redact` in
  `packages/mac-app/Sources/Support/TronLog.swift`, and the bounded sanitizers
  in the iOS stores. The diagnostic
  collector reuses the Gateway's rule set on every copied line, so raw stream
  text cannot reach a shared bundle.
- Field bounds are named constants. The Gateway bounds a message at 2,000
  bytes, an error message at 1,000, a stack at 4,000 and each diagnostic ID or
  field at 160 characters. The Mac writer bounds a message at 2,000 bytes and a
  field at 160 characters. The phone's `AppLog` truncates each field to 512
  characters; `IOSClientDiagnosticStore` bounds each field in UTF-8 bytes, with
  2,000 for a message.
- The phone records nothing per frame, token or render; per-RPC completions are
  debug and stay in its memory ring.
- Outbound projection failures are recorded without the payload or the
  exception, because either can carry producer content.
- The iOS incident store keeps only structurally admitted records, sanitized by
  an allowlist, and retains the typed event code rather than the response body
  for invalid responses.

## Event catalog

Every signal is one row, `Signal | Level | Meaning`, in its owner's README:

- **Signal** names the event, reason code or message; a runtime-built name is written as
  its pattern (`deploy.<state>`, `home.<outcome>`, `operation.<name>`). A README at its
  budget may list related signals in one row, separated by `;`.
- **Level** states the condition when it varies: `SLOW_RPC_WARNING_MS` (1,000 ms) is the
  Gateway's slow bound and `AppLog.slowOperationThresholdMilliseconds` (250 ms) the
  phone's. A row that is not a log record says where it is read instead.
- **Meaning** says when it is written and its key fields; the emitting code is
  authoritative for the rest.

A module without a README of its own keeps its rows in the nearest owning README until it
has one:

| Rows | README |
| --- | --- |
| Gateway process lifecycle, `episodic`, `client`, `integrations` | [gateway/foundation](../src/README.md#signals) |
| Session catalog, search, delegation and extension activity | [gateway/run](../src/sessions/README.md#signals) |
| Pi SDK and managed-provider updater scripts | [Gateway package](../README.md#signals) |
| Mac app, launcher, payload build, deploy and Mac replacement | [Mac package](../../mac-app/README.md#signals) |
| iOS test tooling (`scripts/`) | [iOS package](../../ios-app/README.md#signals) |

## Getting a diagnostic bundle

Run `scripts/tron diagnose` (default window 2h) and read
[Diagnostic bundle](../README.md#diagnostic-bundle) in the Gateway README for
the command, the bounds and the redaction rules. Its eight sections are `logs`,
`device-exports`, `payload-selection`, `processes`, `launchd`, `tailscale`,
`health` and `mac-verify`. The command is
read-only and its output is the intended starting point for an incident; this
file exists so its content can be interpreted, not so it can be described twice.
