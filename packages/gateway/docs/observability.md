# Observability

This file is the single owner of what Tron records and where it goes: the level
policy, every stream with its writer and rotation owner, the retention budgets
and the measured volume, the privacy rules, and the event catalog. Other
documents link here instead of restating these facts.

Two things stay with their owners. The Gateway README owns the reader contracts
(`system.logs` and the `system.logs.export` request and `{ path, exportedAt }`
response), and its [Diagnostic bundle](../README.md#diagnostic-bundle) section
owns how one bundle is collected for an incident.

## Level policy

The level answers "who needs to look, and when". Only debug stays out of files:
it lives in a bounded in-memory buffer that exports include.

| Level | Meaning | Persisted | Examples |
| --- | --- | --- | --- |
| error | Something failed that a user sees, work was lost, or an invariant broke. Someone should look | Yes | `gateway.fatal-startup`, `gateway.shutdown-failed`, `process.uncaught-exception`, `connection.write-error`, `launcher.candidate-rolled-back` |
| warning | Degraded or abnormal but handled: retries, fallbacks, bounds hit, slow operations over a named threshold, notable rejections | Yes | `gateway.event-loop-delay`, `connection.capacity`, `gateway.restart-drain.stalled`, `extension.artifact-rejected` |
| info | Lifecycle and state transitions, one line per boundary; enough to reconstruct a timeline | Yes | `gateway.started`, `connection.opened` for a paired device, `session.open.prepared`, `deploy.ready`, drain progress |
| debug | Per-request detail useful only while diagnosing | No, memory buffer only | fast successful `rpc.completed`, session stages under the slow bound, connection open and close for the Mac app's local probes |

- The level is fixed per event in code and listed in the catalog below; there
  are no runtime log-level settings. A level varies only with a named threshold
  or a condition the catalog states: a success past `SLOW_RPC_WARNING_MS`, a
  local probe connection, a deploy state in its failed set, the call site that
  raised `runtime.diagnostic`.
- Every threshold that promotes an event is a named constant with a one-line
  reason, next to the emitting code. A slow success is warning only past it.
- A caller's mistake (invalid request, unauthorized) is warning. An expected
  transient state (warming up, busy) is info or warning, never error.
- Debug never reaches disk on any stream. It exists so a diagnostic export can
  carry the detail of the minutes before a failure.

## Streams

One writer per file, and no two processes rotate the same file. Everything on
the Mac is under `~/.tron/logs/`; the phone writes inside its own container.
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
| `mac.jsonl` | Mac app `TronLog`, `packages/mac-app/Sources/Support/TronLog.swift` | Mac app logger | Four 1 MiB segments (`mac.jsonl`, `.1` … `.3`); debug kept in a 1,000-record / 1 MiB memory buffer. Warning and error are also mirrored to `os.Logger` (subsystem `com.tron.mac`) so a sysdiagnose carries them |
| `Library/Caches/Logs/app.jsonl` (iOS container) | iOS `AppLog` actor, `packages/ios-app/Sources/Support/AppLog.swift` | iOS `AppLog` | 10 MiB total across `app.jsonl` and one prior segment of half each; info and above only, batched and flushed every 5 s, when the batch reaches the memory-ring bound, on backgrounding and on any error; a 2,000-record / 512 KiB memory ring holds every level |
| iOS incident store (the container's `UserDefaults` key `tron.diagnostics.incidents.v1`) | `IOSClientDiagnosticStore`, `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | The store actor | 96 records, 96 KiB, 7 days; the first cause of each of the 8 newest incidents is reserved alongside the newest window. It holds catalog, connection, client-work, lifecycle and MetricKit records; `AppLog` is the always-on timeline and does not duplicate them |
| `device-exports/` | Gateway export store, `packages/gateway/src/transport/diagnostic-export.ts`, written by `system.logs.export` | Gateway export store | One bundle is at most 512 KiB plus a 1 MB debug section; the newest 10 bundles are kept; the directory is 0700 and each file 0600 |

The phone's performance signposts are `OSSignposter` (`com.tron.mobile`) and are
not a log stream. No stream is shipped off the machine.

## Retention budgets and measured volume

| Stream | Cap | Expected history |
| --- | --- | --- |
| `gateway.jsonl` | 40 MB (8 × 5 MB; the user's chosen cap) | Months at the measured volume below |
| `deploy.jsonl` | 1 MB + one 1 MB segment | Hundreds of deployments; a source rebuild writes about a dozen records (about 3 KB) |
| `gateway-stderr.log` | 1 MiB, emptied | Rare launcher and Node abort text; a day's output is normally zero bytes |
| `mac.jsonl` | 4 MB (4 × 1 MiB) | Several days of lifecycle transitions. **Not yet measured:** the build that writes this stream is not installed on this Mac |
| `Library/Caches/Logs/app.jsonl` | 10 MiB (the user's chosen cap) | **Not yet measured:** the build that writes this stream is not installed on the phone |
| iOS incident store | 96 KiB, 7 days | Bounded incident history, independent of the app log's cap |
| `device-exports/` | 10 bundles | The newest exports; older ones are deleted at write time |

Measured volume (2026-09-24, the first day a rebuilt Gateway ran with the level
policy): **187 records, 77,022 bytes, in 6.0 h** (10:20–16:21 UTC), a normal day
with no incident. That is about 750 records and **about 300 KB/day**, so the
40 MB budget holds roughly four months and the 1,000-record client tail covers
more than a day.

The Mac and iOS volume figures above are deliberately unset. Both writers ship
in builds the user has not installed, so any number now would be invented. When a
day of each stream exists, record it here and change a cap only if it holds less
than 14 days on the Mac or 7 days on the phone.

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

One row per event: `event | level | owner (file) | emitted when | key fields |
added because`. Every row cites the file that emits it, as a repository-relative
path; where the record is raised from a different module than the writer, the
owner cell names that module too.

Conventions used in the rows:

- **Dynamic names.** An event name built at runtime is written as its pattern.
  `deploy.<state>` on the deploy helper, `auth.login.<outcome>` on the Gateway
  and `operation.<name>` on the phone are the only three; each pattern's values
  are listed in its row.
- **Levels with a condition.** A row whose level changes says which side of the
  threshold or condition it is on. `SLOW_RPC_WARNING_MS` (1,000 ms) and
  `SLOW_SESSION_STAGE_MS` (1,000 ms) are the named slow bounds; iOS uses
  `AppLog.slowOperationThresholdMilliseconds` (250 ms).
- **`added because`.** For events that predate this catalog the column states the
  requirement the signal protects, not a commit history.

### Gateway — `~/.tron/logs/gateway.jsonl`

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `gateway.fatal-startup` | error | `packages/gateway/src/index.ts` | loading the Gateway module graph or startup throws before the logger exists | `error` (one wrapped cause), `runtimeEpoch`, `payloadVersion` | The 2026-09-23 rebuild crashed in 0.3 s with `ERR_MODULE_NOT_FOUND` and wrote nothing |
| `gateway.started` | info | `packages/gateway/src/gateway-main.ts` | once per process, as the first record | `durationMs` since process start; pid, Node version and source revision in the message | A restart had no record at process start, so stop → listening could not be measured |
| `gateway.startup-step` | info | `packages/gateway/src/gateway-main.ts` | at each startup checkpoint | `step`, `durationMs` | Stop → bound (7.6–25.5 s) and bound → listening (10–26 s) had no records at all |
| `gateway.bound` | info | `packages/gateway/src/transport/server.ts` | the listener binds, before warmup | — | Bounds the warmup window with `gateway.listening` |
| `gateway.startup-phase` | info | `packages/gateway/src/transport/server.ts` | `setStartupPhase` names the phase warmup is in | phase in the message | Makes the phase `/health` reports during 503 warmup readable from the log |
| `gateway.listening` | info | `packages/gateway/src/transport/server.ts` | warmup finished and the Gateway is ready | host and port in the message | The end of the restart window; the first startup step follows it |
| `gateway.stopping` | info | `packages/gateway/src/gateway-main.ts` | shutdown begins; the triggering reason is in the message | — | Separates a planned stop from a crash |
| `gateway.shutdown-step` | info | `packages/gateway/src/gateway-main.ts` | each awaited shutdown operation settles | `step`, `durationMs` | A forced exit after transport close named no owner for the remaining shutdown time |
| `gateway.stopped` | info, or warning when the exit code is non-zero | `packages/gateway/src/gateway-main.ts` | the process's last record, before exit | `code`, `durationMs` (shutdown time) | The old process's exit and shutdown duration were not recorded, so a restart's gap was unexplained |
| `gateway.transport-closing` | info | `packages/gateway/src/transport/server.ts` | `finishClose` begins retiring sockets | — | Distinguishes transport retirement from process stop |
| `gateway.shutdown-cleanup-expired` | warning | `packages/gateway/src/gateway-main.ts` | the 2 s cleanup grace ended with owned work outstanding | outstanding count in the message | A SIGTERM shutdown can end with accepted work still owned; the bound has to be visible |
| `gateway.shutdown-failed` | error | `packages/gateway/src/gateway-main.ts` | shutdown itself throws | `error` | Separates a failed shutdown from a clean non-zero exit |
| `gateway.restart.requested` | info | `packages/gateway/src/transport/gateway-service.ts` | an authenticated client requests a restart | active-session count in the message | The drain's start had no record, so its wait time could not be bounded |
| `gateway.restart-drain` | info | `packages/gateway/src/gateway-main.ts` | the restart is scheduled and the drain begins | — | Same: the start of the wait |
| `gateway.restart-drain.waiting` | info | `packages/gateway/src/gateway-main.ts` | every 15 s while draining, at each stall decision and at an immediate restart | the blocker list — `sessionId`, `category`, `method`, `state`, `ageMs`, `progressAt` when available — in the message | The deciding evidence for the 2026-09-22/23 stuck drains had rotated away; the record now names each executing request's method and progress signal |
| `gateway.restart-drain.stalled` | warning | `packages/gateway/src/gateway-main.ts` | the oldest blocker makes no progress for `DRAIN_STALL_LIMIT_MS` (180 s), or an immediate restart request | oldest blocker category, method and age in the message; immediate restart logs its blocker list | A stuck oldest owner must be diagnosable despite unrelated blocker churn |
| `gateway.restart-drain.unresolved-owner` | error | `packages/gateway/src/gateway-main.ts` | every remaining blocker is a suspect `terminal-receipt-persistence` owner, so the restart proceeds without waiting for the stall bound | `sessionId`; category in the message; one record per owner, with no content | Unresolved canonical writes and failed extension receipts remain authoritative blockers but restart/recovery is the supported resolution |
| `gateway.restart-drain.completed` | info | `packages/gateway/src/gateway-main.ts` | the drain reached zero blockers | — | Closes the timeline opened by `gateway.restart.requested` |
| `gateway.restart-drain-failed` | error | `packages/gateway/src/gateway-main.ts` | the drain promise rejects | `error` | A rejected drain used to look like an ordinary failed restart |
| `gateway.event-loop-delay` | warning | `packages/gateway/src/transport/server.ts`; evidence owner `packages/gateway/src/transport/stall-diagnostics.ts` | a heartbeat arrives `EVENT_LOOP_DELAY_WARNING_MS` (1,000 ms) or more late | `durationMs`; GC pause count/total/max, event-loop utilization, host free memory, swap used and memory pressure in the message | The 2026-09-23 6–36 s stalls could not say whether GC, host paging or the Gateway's own work caused them |
| `connection.opened` | debug for the Mac app's local probes, info for a paired device | `packages/gateway/src/transport/server.ts` | the first valid hello on an admitted socket | `connectionId`; local/paired, role and admission-to-hello time in the message | Admission and handshake were two info records per probe — about 714 lines in 3 h from local `system.info` polls — and one record now carries both |
| `connection.closed` | debug for a local probe, info for a device | `packages/gateway/src/transport/server.ts` | the socket closes | `connectionId`, `durationMs`; close detail, frame counters and queue ages in the message | A close has to carry why it happened, without the per-probe volume on disk |
| `connection.rejected` | info (with `reason`) while warming up or shutting down; warning for an unauthenticated upgrade | `packages/gateway/src/transport/server.ts` | an upgrade arrives before readiness, or without a valid credential | `reason` (`warming_up` / `shutting_down`) at the info site | Warmup rejections are an expected transient state, but an unauthenticated upgrade is a notable rejection |
| `connection.capacity` | warning | `packages/gateway/src/transport/server.ts` | global or per-identity connection capacity is full | connection counts and limits in the message | A refusal for capacity must be distinguishable from an auth refusal |
| `connection.superseded` | warning | `packages/gateway/src/transport/server.ts` | a newer connection from one device identity displaces older ones | displaced connection ID, its inbound age and the limits, in the message | A device reconnecting while its old socket lingers must not look like a lockout |
| `connection.heartbeat-timeout` | warning | `packages/gateway/src/transport/server.ts` | three complete heartbeat intervals got no response | miss count, inbound and write-progress ages, outbound queue counters in the message | A retired socket must say whether the peer was silent or the writer was stuck |
| `connection.outbound-capacity` | warning | `packages/gateway/src/transport/server.ts` | the connection's outbound queue reaches its frame or byte bound | `connectionId`; queue counts, high-water marks, socket buffer and process pressure in the message | The close is caused by the bound, not by the client, and the counters prove which |
| `connection.write-error` | error | `packages/gateway/src/transport/server.ts` | a socket write fails | `connectionId`, `error`; completed/accepted frame counts in the message | A failed write silently ended a connection before |
| `connection.projection-rejected` | warning when a frame exceeds the limit and is replaced by a bounded preview; error when encoding throws | `packages/gateway/src/transport/server.ts` | an outbound frame cannot be encoded, or exceeds the frame limit | type, topic, byte count and node bounds in the message; never the payload or the exception | A client that loses a projection needs to know whether it was oversized or unencodable |
| `http.connection-capacity` | warning | `packages/gateway/src/transport/server.ts` | a new HTTP socket arrives at the connection limit | connection counts and limits in the message | — |
| `http.request-capacity` | warning | `packages/gateway/src/transport/server.ts` | an HTTP request or an unauthenticated upgrade arrives at admission capacity | capacity snapshot in the message | Distinguishes request pressure from connection pressure |
| `http.authentication-timeout` | warning | `packages/gateway/src/transport/server.ts` | an upgrade socket does not authenticate within the idle deadline | — | A half-closed pre-handshake peer used to disappear without a record |
| `http.upload-cleanup` | warning | `packages/gateway/src/transport/server.ts` | discarding an abandoned upload fails for a reason other than conflict or not-found | — | Cleanup failure leaves owned bytes behind and must be visible |
| `rpc.error` | warning for a `GatewayError` code other than `internal` (a caller mistake); error, with `error`, for an unexpected fault or `internal` | `packages/gateway/src/transport/server.ts` | an RPC handler throws | `method`, `requestID`, `connectionId`, `sessionId`, `commandId`, `code`, `outcome`, `reason`, `error` | Expected `busy` backpressure was logged as error; a caller's mistake is a warning and a server fault keeps its structured `error` |
| `rpc.completed` | debug for a success under `SLOW_RPC_WARNING_MS` (1,000 ms); warning at or above it or on failure | `packages/gateway/src/transport/server.ts` | every RPC finishes | `method`, `requestID`, `connectionId`, `sessionId`, `commandId`, `outcome`, `durationMs` | 1,187 successful completions in 3 h filled the log; only slow or failed completions need to be on disk |
| `session.open.prepared` | info, warning at or above `SLOW_SESSION_OPEN_WARNING_MS` (1,000 ms) | `packages/gateway/src/transport/gateway-service.ts` | a `session.open` read produced its snapshot and lease | `sessionId`, `durationMs`; acquire and snapshot splits in the message | A slow session open was invisible among the other open records |
| `session.stage` | debug for a success under `SLOW_SESSION_STAGE_MS` (1,000 ms); warning at or above it or on failure | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/sessions/runtime-registry.ts` | each timed session stage completes (`catalog-index.*`, `runtime.dispose-timeout`, and the registry's stages) | stage, outcome and `workID`/`scope` in the message | Only slow stages were recorded before, so which stage dominated a slow open could not be read |
| `session.abort.settled` | info | `packages/gateway/src/transport/gateway-service.ts` | `session.abort` settled | `sessionId`; kind and operation in the message | An abort that did settle and one that did not were indistinguishable |
| `session.abort.unsettled` | warning | `packages/gateway/src/transport/gateway-service.ts` | `session.abort` throws | `sessionId`, `error`; kind and operation in the message | An unsettled abort keeps the runtime busy and must be visible |
| `artifacts.session-cleanup-pending` | warning | `packages/gateway/src/transport/gateway-service.ts` | a session was deleted but its owned artifact cleanup rejected | — | Deletion succeeded, so the leftover bytes need their own record |
| `extension.artifact-rejected` | warning | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/sessions/runtime-slot.ts` | an extension lifecycle artifact is rejected | `reason`, opaque `owner` in the message | A rejected artifact is retried; repeated rejection repeated in the log without a bound |
| `knowledge.upgrade-failed` | warning | `packages/gateway/src/gateway-main.ts` | `knowledgeStore.upgradeStorage()` rejects after a Gateway update | `error` | The upgrade is skipped and Knowledge stays unavailable; chat must not be implicated |
| `notification.inbox.read_failed` | warning | `packages/gateway/src/gateway-main.ts` | session notification read state could not be persisted | — | Unread state is retained in memory only, which the operator has to know |
| `process.uncaught-exception` | error | `packages/gateway/src/gateway-main.ts` | an uncaught exception reaches the process | `error` | The process exits non-zero; the reason has to precede `gateway.stopped` |
| `process.unhandled-rejection` | error | `packages/gateway/src/gateway-main.ts` | an unhandled rejection reaches the process | `error` | — |
| `runtime.diagnostic` | error for a resource reload or extension load failure, warning for a per-provider refresh failure | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/admin/global-provider-resources.ts` | global provider or extension resources fail to load or refresh | the failure text in the message | Provider and extension load failures used to be unrecorded startup noise |
| `automation.dispatch-failed` | warning | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/automations/automation-scheduler.ts` | an automation run could not be dispatched | — | A skipped run is not visible in the session transcript |
| `automation.recovery-step` | info | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/automations/automation-service.ts` | each part of automation recovery finishes | `step` (`store`, `reconcile-targets`, `scheduler-recover`), `durationMs`; checked target count and slowest target kind in the message | Automation recovery was 67% of a 23.3 s restart with no reason, and its parts had to sum without double counting the startup steps |
| `session-search.warm` | info | `packages/gateway/src/gateway-main.ts` | session-search warm-up, started after session-registry recovery and before automation recovery, finishes | `durationMs` | The disposable index is rebuilt from canonical sessions on every process start; its duration is separate from startup-step intervals |
| `session-search.warm-failed` | warning | `packages/gateway/src/gateway-main.ts` | the warm-up rejects; lexical search recovers on demand | `error` | The optional index must not fail silently |
| `session-search.index-unavailable` | warning | `packages/gateway/src/gateway-main.ts` | the optional search index cannot open | `error` | Chat stays available; only this capability is lost |
| `session-search.jev-ledger-unavailable` | warning | `packages/gateway/src/gateway-main.ts` | the optional Jev allowance ledger cannot open | `error` | Remote ranking is disabled, not chat |
| `session-search.helper-unavailable` | warning | `packages/gateway/src/gateway-main.ts` | no helper candidate exists, or the signed embedding helper is not admitted | — | Semantic search is unavailable; the reason is not an error, and a missing bundled helper must not be silent |
| `storage.maintenance-failed` | warning | `packages/gateway/src/gateway-main.ts` | the bounded artifact maintenance pass throws and will retry | `error` | A deferred pass is handled; silence would look like success |
| `uploads.storage-pressure` | info when pressure returns to `normal`, warning otherwise | `packages/gateway/src/gateway-main.ts` | a 10-minute maintenance pass changes storage pressure | free bytes and the floor in the message | Attachment storage has a floor, and crossing it must be visible before a write fails |
| `canonical-ownership-persistence-retrying` | warning | `packages/gateway/src/sessions/runtime-slot.ts` | a canonical ownership write is retrying inside `retryDurableWrite` | `sessionId`; the event name is the diagnostic code | An unresolved write silently blocks the drain for the process lifetime |
| `canonical-ownership-persistence-blocked` | warning | `packages/gateway/src/sessions/runtime-slot.ts` | the ownership write's retry window expired | `sessionId` | The slot is `suspect`; nothing may claim the write resolved |
| `terminal-receipt-persistence-failed` | warning | `packages/gateway/src/sessions/runtime-slot.ts` | a terminal receipt was not proven durable | `sessionId` | The 2026-09-23 08:22 drain waited over 7 minutes on receipt persistence with no named owner |
| `session_operation_busy` | warning reason on `rpc.error` | `packages/gateway/src/transport/server.ts`, raised at `packages/gateway/src/sessions/runtime-slot.ts` and `runtime-registry.ts` | model/delete mutation is rejected by real active session work | standard RPC correlation plus reason | The reason distinguishes a true foreground/deletion blocker from self-accounting work or detached child activity |
| `session.compaction.completed` | error for failure, info for success/cancellation | `packages/gateway/src/gateway-main.ts`, raised from `packages/gateway/src/sessions/runtime-slot.ts` | each SDK compaction ends | `sessionId`, `operationId`, `reason`, `outcome`, bounded/redacted `errorMessage` on failure | Failed automatic summaries were silently dropped, so transient retries could not be correlated to session or operation |
| `knowledge-observation-admission-rejected` | warning | `packages/gateway/src/knowledge/knowledge-observation.ts` | prospective knowledge observation cuts are not retained | dropped and queued counts in the message | No durable coverage is claimed when cuts are dropped, so the bounding has to be recorded |
| `auth.login.started` | info | `packages/gateway/src/admin/auth-broker.ts` | a provider login operation is admitted | provider and auth type in the message | An interrupted login must be explainable from the timeline alone |
| `auth.login.recovered` | info | `packages/gateway/src/admin/auth-broker.ts` | an existing login operation is reattached to a new client | provider and auth type in the message | — |
| `auth.login.succeeded` | info | `packages/gateway/src/admin/auth-broker.ts` | the operation retired with a stored credential, or the credential was stored after it ended | provider and auth type in the message | — |
| `auth.login.ended` | warning | `packages/gateway/src/admin/auth-broker.ts` | the operation retired without a stored credential, with its reason | provider, auth type and elapsed seconds in the message | A login that ends without a credential is a caller stop or a timeout, not a success |

One Gateway name is not written as a literal. The `code` passed to the session's
persistence diagnostic is used directly as the event, which is why the three
`canonical-*` and `terminal-receipt-*` rows above are the values of
`event: code` at `packages/gateway/src/gateway-main.ts`.

### Deploy — `~/.tron/logs/deploy.jsonl`

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `deploy.<state>` — states `starting`, `building`, `staging`, `promoting`, `draining`, `ready`, `rollback`, `rolled-back`, `failure` | info, or error when the state is a failed outcome (`failure`, `rollback`, `rolled-back`) | `scripts/gateway-payload-deploy.mjs` | each progress write; one record per state, carrying the duration of the phase it ended | `commandId`, `durationMs` (except the first state), `error` when the state failed | A failed deploy reported only a timeout; there was no phase timeline to attribute the time or the cause |
| `deploy.old-process-exited` | info | `scripts/gateway-payload-deploy.mjs` | the drained process disappears | `commandId`, `durationMs` | The gap between the old process stopping and the replacement relaunching had no record |
| `deploy.finished` | info on success, error otherwise | `scripts/gateway-payload-deploy.mjs` | every terminal path, exactly once | `commandId`, `durationMs`, `outcome`, `error` | One record has to close the timeline even when the operation rolled back |

### Launcher — `~/.tron/logs/deploy.jsonl`

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `launcher.candidate-launched` | info | `packages/mac-app/scripts/tron-gateway-launcher.c` | a pending candidate consumes its single launch attempt | `payloadVersion`, `runtimeEpoch` | The deploy helper needs the candidate's identity to match a crash to the attempt that caused it |
| `launcher.candidate-rolled-back` | error | `packages/mac-app/scripts/tron-gateway-launcher.c` | the candidate did not commit and the previous selection was restored | candidate's `payloadVersion`, its `runtimeEpoch`; restored version in the message | The 2026-09-23 rollback message went to a discarded stderr; this record is now the deploy helper's cause lookup |
| `launcher.bundled-fallback` | warning | `packages/mac-app/scripts/tron-gateway-launcher.c` | an admitted store's selection was refused and the bundled payload runs instead | refused selection's version and fingerprint in the message; the bundled payload's `payloadVersion` and `runtimeEpoch` | The store's selection is not what ran, so the record names both |
| `launcher.selection-rejected` | warning | `packages/mac-app/scripts/tron-gateway-launcher.c` | a pending attempt marker cannot be reconciled with the selection, so nothing launches (exit 75) | claimed version and epoch; the reason in the message | Nothing ran, so this record is the only durable evidence of why |

A healthy launch of a committed selection records nothing: the launcher writes
one record per decision, not per start.

### Mac app — `~/.tron/logs/mac.jsonl`

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `app.started` | info | `packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift` | once per launch | `appVersion`, `build` | The Mac stream needs to identify which build produced a run |
| `app.instance-already-running` | warning | `packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift` | a second wrapper instance starts and hands off | — | The second instance exits; the reason must not look like a crash |
| `app.version-marker` | warning | `packages/mac-app/Sources/App/Lifecycle/MacAppStartupMaintenance.swift` | the recorded app version cannot be written | `outcome` (`failed`) | A failed marker write causes a redundant startup pass |
| `app.font-load` | warning | `packages/mac-app/Sources/Support/Theme/TronFontLoader.swift` | a bundled font is missing or cannot register | `outcome` (`failed`) | A missing resource changes what the user sees |
| `observer.state-changed` | info | `packages/mac-app/Sources/MenuBar/MenuBarController.swift` | the applied Gateway status snapshot changes state | `old`, `new`, `why` | Status became wrong for a reason; the transition needs old, new and why together |
| `launch-agent.register` | info, warning when macOS needs user approval, error for every other failure | `packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift` | each registration attempt and its resulting status | `outcome` (`success`, `requires-approval`, `missing`, `not-registered`, `unknown`, `failed`) | Registration is the installed agent's lifecycle; a missing agent has to be distinguishable from a refused one |
| `launch-agent.unregister` | info on success or when already unregistered, error on failure | `packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift` and `packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift` | each unregister request and its result | `outcome` (`success`, `already-unregistered`, `failed`) | — |
| `launch-agent.kickstart` | info when the command exits 0, error otherwise | `packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift` | each kickstart attempt completes | `outcome`, including `unknown` when the outcome cannot be confirmed | A start that did not take effect used to be invisible |
| `launch-agent.command-start` | warning when the Debug companion refuses to manage the production agent, error otherwise | `packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift` | a command-mode start is rejected or fails | `outcome` (`refused`, `failed`) | A refused Debug action is not a failure of the product |
| `update.ui-state` | info when the flow advances, warning when it settles after a request failure | `packages/mac-app/Sources/MenuBar/Actions/MenuBarActionHandler.swift` | the update flow enters or leaves a UI state | `commandId`, `old`, `new`, `outcome` | The update surface is where a user first sees a problem; the flow needs correlation with the helper |
| `wizard.step` | info | `packages/mac-app/Sources/Wizard/Flow/WizardState.swift` | the onboarding wizard changes step | `old`, `new`, `outcome` | Setup failures had no timeline |
| `wizard.completed` | info | `packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift` | the wizard completed in a mode that does not install the production menu bar | `outcome` (`not-managed`) | Explains a missing menu bar after onboarding |
| `wizard.completion` | error | `packages/mac-app/Sources/Wizard/Flow/WizardView.swift` | the onboarded sentinel cannot be written | `outcome` (`failed`) | Onboarding would repeat; the cause is recorded |

The Mac writer has no debug-level call sites today: every event above is
recorded at info or above.

### iOS — `Library/Caches/Logs/app.jsonl` (`AppLog`)

`AppLog.recordCausal` sets the level explicitly when the caller passes one, and
otherwise derives it: error for `outcome=failure`, warning when the measured
duration is at or above `slowOperationThresholdMilliseconds` (250 ms), else info.

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `app.started` | info | `packages/ios-app/Sources/State/AppModel.swift` | once per launch | app version, build and OS in `details`; `lifecycleGeneration` | Ties a launch to its records and identifies the build that produced them |
| `app.foregrounded` | info | `packages/ios-app/Sources/State/AppModel.swift` | the scene becomes active | — | Connection and recovery behavior differs by scene state, so the transition must be on the timeline |
| `app.backgrounded` | info | `packages/ios-app/Sources/State/AppModel.swift` | the scene becomes inactive; the buffer is flushed immediately | — | Same, and the flush point has to be identifiable after a relaunch |
| `connection.state-changed` | info | `packages/ios-app/Sources/App/TronMobileApp.swift` | every connection state transition | `connectionID`; old state, new state and Gateway runtime epoch in `details` | The user sees this state; the record says which epoch it belonged to |
| `pairing.result` | info on success, warning on failure | `packages/ios-app/Sources/State/AppModel.swift` | a pairing attempt settles | `outcome`; failure `code` in `details` | Pairing failure is the first wall a user hits, and it had no always-on record |
| `session.open.failure` | warning | `packages/ios-app/Sources/State/AppModel.swift` | opening a session fails | `code`, `profileID`, `connectionID`, `lifecycleGeneration` | A failed open is a user-visible failure that used to exist only while a capture was running |
| `session.sync.failure` | warning | `packages/ios-app/Sources/State/AppModel.swift` | a mounted projection cannot resynchronize | `code`, `profileID`, `connectionID`, `lifecycleGeneration` | Same, for the refresh path rather than the open path |
| `opening.failed` | warning | `packages/ios-app/Sources/UI/Chat/ChatView.swift` | the conversation layout did not settle and the open is failed | the settlement reasons in `details` | The view settles on a timer; the reasons have to be captured where they are known |
| `diagnostics.upload-failed` | warning | `packages/ios-app/Sources/State/AppModel.swift` | the export upload fails and the share sheet takes over | `code` | A silent fallback to the share sheet would hide a Gateway-side export failure |
| `operation.<name>` — names are `gatewayConnect`, `sessionOpen`, `sessionSync`, `sessionResync`, `receiptResolution`, `cacheLoad`, `cacheSave`, `chatProjection`, `firstReadyFrame`, `scrollCommandSettle`, `prependSettle`, `terminalAttachReplay`, `configurationSliderExpand`, `configurationSliderCollapse` | warning, or error when the measured operation failed | `packages/ios-app/Sources/Support/AppLog.swift`, raised from `packages/ios-app/Sources/Support/PerformanceSignposts.swift` | a signpost-measured operation ends at or above 250 ms | `durationMs`, `itemCount` (`count`), `outcome` | Performance work needs a shipped record of the boundary that regressed, not a capture someone must start |
| `rpc.completed` | debug, memory only | `packages/ios-app/Sources/Support/AppLog.swift` | every RPC completion | `method`, `requestID`, `outcome`, `code`, `durationMs` | Per-request detail for an export, without writing every RPC to the phone's disk |

### iOS — the incident store (`IOSClientDiagnosticStore`)

| event | level | owner (file) | emitted when | key fields | added because |
| --- | --- | --- | --- | --- | --- |
| `gateway.connection` | info, warning when the handshake outcome is a failure | `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | each handshake stage record: `queue-pressure`, `transport-open`, `hello-send`, `hello-receive`, `liveness`, `transport` | stage, outcome, sequence, client/attempt/connection IDs, `transportOpened`, `transportOpenMs`, `waitedForConnectivity`, `interfaces`, category, reason, close code | A failed reconnect said only `hello-send … reason=timeout`, so "never reached the Mac" and "the Mac did not answer" looked identical |
| `gateway.client-work` | info, warning when the window contains slow work | `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | the event consumer's per-category/phase window is published | category, phase, count, slow count, maximum and total duration, window start | Event-consumer pressure is invisible from the Gateway side |
| `gateway.catalog` | info, or warning/error when the call site marks it | `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | a catalog read or retry is diagnosed | trigger, outcome, connection IDs, generations, `durationMs`, `code`, `reason`, page, revision, retry attempt/budget | The dashboard's read path needed bounded incident history rather than per-read logging |
| `gateway.response.invalid` | error | `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | an `invalid_response` failure is admitted | `code=invalid_response` only | Keeps the typed code at the storage boundary without storing the response |
| `gateway.rpc` | info on success, warning otherwise | `packages/ios-app/Sources/State/GatewayDiagnosticsService.swift` | an RPC diagnostic is admitted into incident history | method, requestID, outcome, `durationMs`, `code` | A failed RPC that produces an incident needs its own row rather than a device-log entry |
| `gateway.lifecycle` | info | `packages/ios-app/Sources/State/AppModel.swift` | an admitted lifecycle event: `scene.foreground`, `scene.background`, `reconnect.scheduled`, `reconnect.attempt`, `reconnect.failure`, `reconnect.delay`, `reconnect.connected`, `reconnect.exhausted`, `reconnect.stopped`, `path.changed`, `detail.tap`, `detail.preparation` | `kind` and the recovery detail in the message; `profileID` | Reconnect history has to survive a relaunch, independently of the always-on app log |
| `ios.metrickit` | info | `packages/ios-app/Sources/Support/IOSMetricKitDiagnostics.swift` | a MetricKit metric or diagnostic payload is recorded | the bounded metric/diagnostic fields in the message | OS-level hangs and termination metrics explain a slow or killed app |

## Getting a diagnostic bundle

Run `scripts/tron diagnose` (default window 2h) and read
[Diagnostic bundle](../README.md#diagnostic-bundle) in the Gateway README for
the command, the bounds and the redaction rules. Its eight sections are `logs`,
`device-exports`, `payload-selection`, `processes`, `launchd`, `tailscale`,
`health` and `mac-verify`. The command is
read-only and its output is the intended starting point for an incident; this
file exists so its content can be interpreted, not so it can be described twice.
