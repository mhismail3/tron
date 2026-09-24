# Observability foundation

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-24, L-16
- **Goal:** Every Tron process records the right signals automatically, in a known place, at a meaningful level, so a failure can be diagnosed in one pass from what was already recorded.

Follow the [plan protocol](README.md#protocol) to claim tasks and hand off.

## Goal and constraints

Nobody should have to reproduce a failure or start a capture before it can be
diagnosed. When an incident exposes a missing signal, adding it is a small,
routine change.

- **Lightweight:** no measurable effect on Gateway event-loop latency, iOS
  scrolling or typing, or Mac app responsiveness.
- **No new frameworks or services:** no OpenTelemetry, remote shipping, SQLite
  log store or uploader. The design is files, in-memory debug buffers, one
  export path and one collector.
- **No compatibility shims:** readers of the logs (the iOS log RPC, `recent()`,
  export) move to the new format in the same change.
- **No new log UI:** the iOS Gateway Logs screen already has warning and error
  filter pills. The only UI change is replacing Diagnostic Capture with one
  export action (L-3).
- **Operational safety:** never rebuild, restart, promote or roll back the
  Gateway, or reinstall the Mac app; prepare artifacts and report the exact
  user action. Probe candidate payloads only in an isolated home on a
  non-default port. Run script tests with the pinned Node from `.node-version`.

**Coordination:** the [simplification program](2026-09-23-simplification-program.md)
leaves the code this plan replaces to this plan. This plan should leave that
code smaller than it found it.

## Context

### Motivating incidents

- **2026-09-23 rebuild rollback.** A new Gateway build crashed in 0.3 s with
  `ERR_MODULE_NOT_FOUND` before its logger opened. The launcher's rollback
  message went to a discarded stderr, and the deploy helper reported only "no
  coherent replacement payload identity". Diagnosis took about an hour of
  manual correlation.
- **2026-09-22/23 stuck drains.** The deciding evidence was
  `gateway.restart-drain.waiting` lines. With about 2 hours of retention, the
  previous day's evidence was already gone.

### Current state (inspected 2026-09-23)

| Component | What exists | Gaps that matter |
| --- | --- | --- |
| Gateway `transport/logger.ts` | JSONL at `~/.tron/logs/gateway.jsonl`; levels info, warning, error; redaction and a 2 KB message cap; `appendFileSync` + `statSync` per record; 1 MB file + one rotation; a 1,000-record memory tail served to iOS; every record mirrored to stdout/stderr | **Noise:** of 3,443 records over about 3 hours, 1,202 were `rpc.request`, 1,187 successful `rpc.completed`, and about 714 connection lines from the Mac app's local `system.info` probes. **Retention:** about 2 hours. **Misleveled:** expected `busy` backpressure logs as error. **Missing fields:** no `sessionId`, `connectionId`, `commandId`, `runtimeEpoch` or structured error. **Silent startup:** anything thrown before the logger exists is lost |
| C launcher | `fprintf(stderr, …)` | The LaunchAgent has no `StandardErrorPath`, so rollback and fallback messages are discarded |
| Deploy helper | `update-progress.json`, `deployment-state.json` | No phase timeline; failure causes are inferred from timeouts |
| Mac app | 14 `NSLog` calls | No file log; observer, LaunchAgent and update-flow transitions go unrecorded |
| iOS | `DiagnosticCapture.swift`: user-started capture (300 s default, 600 s cap, 2,000 events, 480 KB). `GatewayLogsSettingsView` has Start/Stop/Export Capture buttons, a share button and warning/error filter pills | **Records only after you press start.** **Export regression (`3de94a570`):** export used to upload to the Gateway and copy the path; now it prepares a local file and needs a second tap on a `ShareLink` |
| Gateway export store | `transport/diagnostic-export.ts`: `/tmp/tron-diagnostics`, 512 KB cap, keeps 10 | In `/tmp` (cleared on reboot) and separate from every other log |

### Gateway source rebuild measurements (2026-09-23)

Measured read-only against the live 585 MB, 32,330-file payload; no Gateway
was rebuilt or restarted for these numbers. Only `app/dist` (6.9 MB) changes
in a source rebuild; `app/node_modules` (316 MB) and `runtime` (268 MB) are
carried over unchanged.

| Step in `scripts/gateway-payload-deploy.mjs` | Cost | Runs per source rebuild |
| --- | --- | --- |
| Node `payloadFingerprint` (sequential reads) | 5.4–6.3 s | About 8 |
| Launcher `--fingerprint` (C) | 1.5–3.6 s | 1, at launch |
| `fs.cp` of the payload | 10.6 s, about 594 MB written | 2 |
| Permission walk (mutable or immutable) | 1.9 s | 2 |
| `tsc` | 4.5 s | 1 |

The 11:12 UTC rebuild took about 2 min 40 s: about 63 s to compile and stage,
about 40 s of promotion checks before the restart request, and 46 s from
`gateway.stopping` to `gateway.listening`. Across four restarts, stop to
`gateway.bound` took 7.6–25.5 s and bound to the first startup phase took
10–26 s with no records in between. Eight retained versions hold about
4.7 GB. The 08:22 UTC rebuild waited more than 7 minutes on
`terminal-receipt-persistence=8` until the Gateway was sent SIGTERM.

## Plan rules

### Level policy

The level answers "who needs to look, and when". Only debug stays out of files:
it lives in a bounded in-memory buffer that exports include.

| Level | Meaning | Persisted | Examples |
| --- | --- | --- | --- |
| error | Something failed that a user sees, work was lost, or an invariant broke. Someone should look | Yes | Startup fatal, shutdown failed, permanent persistence write failure, unexpected RPC server fault, deploy rolled back |
| warning | Degraded or abnormal but handled: retries, fallbacks, bounds hit, slow operations over a named threshold, notable rejections | Yes | Event-loop delay, `busy` backpressure, slow `session.list`, drain stalled, artifact rejected |
| info | Lifecycle and state transitions, one line per boundary; enough to reconstruct a timeline | Yes | `gateway.started`, `connection.opened` for devices, `session.open.prepared`, `deploy.committed`, drain progress |
| debug | Per-request detail useful only while diagnosing | No, memory buffer only | Fast successful `rpc.completed`, handshake internals, Mac local probe connections |

- The level is fixed per event in code and listed in the event catalog; there
  are no runtime log-level settings.
- Every threshold that promotes an event is a named constant with a one-line
  reason, next to the emitting code. A slow success is warning only past it.
- A caller's mistake (invalid request, unauthorized) is warning. An expected
  transient state (warming up, busy) is info or warning, never error.

### Starting level for each Gateway event

Counts are from 3,443 records in `~/.tron/logs/gateway.jsonl` on 2026-09-23.
Applying this table removes about 3,100 of them (about 90%) from disk.

| Event today | Count · level today | New treatment |
| --- | --- | --- |
| `rpc.request` | 1,202 · info | Delete; `rpc.completed` already carries method, requestID, outcome and duration |
| `rpc.completed`, success under slow threshold | 1,187 · info | debug |
| `rpc.completed`, success over slow threshold | 53 · warning | warning; threshold becomes a named constant, per method where needed |
| `rpc.completed`, failure | 4 · warning | warning |
| `rpc.error` code `busy` | 9 · error | warning (expected backpressure) |
| `rpc.error`, other server faults | 3 · error | error with a structured `error` field |
| `connection.admitted` + `connection.handshake` | 525 · info | Merge into one `connection.opened`; debug for local Mac probes, info for devices |
| `connection.closed` | 267 · info | debug for local probes, info for devices; keep close code, duration and frame counters |
| `connection.rejected` during warmup | 54 · warning | info with reason; warning for auth or capacity rejections |
| `session.open.prepared`, `session.stage` | 68 · info/warning | info for open; stages debug under threshold, warning over it |
| `gateway.event-loop-delay` | 18 · warning | Unchanged |
| `gateway.restart-drain.waiting` | 29 · info | info, emitted when blockers change and on the existing interval |
| Lifecycle (bound, listening, stopping, startup-phase, restart) | 27 · info | Unchanged |
| `gateway.shutdown-cleanup-expired`, `gateway.shutdown-failed` | 1 · warning, 1 · error | Unchanged |
| `extension.artifact-rejected` | 4 · warning | Unchanged |

The Mac app's per-probe WebSocket connections could also be reduced at the
source; that belongs to the simplification program.

### Where logs live

Every Mac-side process writes automatically under `~/.tron/logs/`; the iOS app
writes to its own container. One writer per file, and no two processes rotate
the same file.

| Process | Persisted stream | Debug buffer | Owns rotation |
| --- | --- | --- | --- |
| Gateway | `~/.tron/logs/gateway.jsonl` | In process, bounded | Gateway logger |
| Deploy helper and C launcher | `~/.tron/logs/deploy.jsonl` | None | Deploy helper, at operation start |
| Gateway out-of-band output (node aborts, launcher messages) | `~/.tron/logs/gateway-stderr.log` via LaunchAgent `StandardErrorPath` | n/a | Mac app startup maintenance, truncating above a named cap |
| Mac app and native host | `~/.tron/logs/mac.jsonl` | In process, bounded | Mac app logger |
| iOS app | Container `Library/Caches/Logs/app.jsonl` (info and above) | In process, bounded | iOS logger |
| iOS exports received by the Gateway | `~/.tron/logs/device-exports/` | n/a | Gateway export store, count and size capped |

Swift components may also mirror warning and above to `os.Logger` (subsystems
`com.tron.mac`, `com.tron.mobile`) so crash reports and sysdiagnose carry
context. The JSONL file stays the canonical place.

### Retention budgets (decided by the user, 2026-09-23)

| Stream | Total cap | Expected history |
| --- | --- | --- |
| Gateway `gateway.jsonl` | 40 MB (8 × 5 MB segments) | About 5–6 weeks at the measured 1 MB/day on a busy day with these levels |
| iOS on-device log | 10 MB | Measured after L-3 |

- Implement these as named constants whose comment says they are the user's
  chosen caps.
- `deploy.jsonl` and `mac.jsonl` are low-volume; each gets its own named cap
  sized from a day's measurement, well under the Gateway's.
- After L-2 and L-3, record one day's measured volume in the event catalog.
  Change a cap only if it holds less than 14 days on the Mac or 7 days on iOS.

### Record format (all streams)

One JSON object per line; the Swift writers emit the same shape.

```jsonc
{
  "timestamp": "2026-09-23T08:29:47.436Z",
  "level": "error" | "warning" | "info" | "debug",
  "event": "gateway.fatal-startup",      // stable dotted name, required
  "source": "lifecycle",                  // component or category
  "message": "…",                         // redacted, bounded
  "process": "gateway" | "deploy" | "launcher" | "mac" | "ios",
  "runtimeEpoch": "…", "payloadVersion": "…",          // stamped once per process by the writer
  "sessionId": "…", "connectionId": "…", "commandId": "…", "requestID": "…",
  "durationMs": 12, "outcome": "success", "code": "busy",
  "error": { "name": "Error", "code": "ERR_MODULE_NOT_FOUND", "message": "…", "stack": "…" }
}
```

- The writer stamps process identity, not each call site.
- Error, stack and message bounds are named constants.
- iOS adds `appVersion`, `build` and `lifecycleGeneration` once per launch, in
  an `app.started` record.
- **Privacy:** never log message content, prompts, tool output, file contents,
  tokens, credentials or full device identifiers. Identity appears only as a
  stable hash. Redaction runs at the write boundary for every stream.

### Tests

Each task lists its focused tests. There are no end-to-end log-scraping suites
and no real-time waits: inject clocks and intervals.

## Tasks

Rows are in priority order. L-1b, L-1d and L-4 need a Mac app build that the
user reinstalls manually, so batch them for one reinstall.

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| L-0 | Done | Payload import containment | none | planning session, 2026-09-23 |
| L-1a | Done | Gateway startup-fatal record | none | observability-L-1a session, 2026-09-23 |
| L-1c | Done | Deploy timeline and real failure cause | L-1a | observability session, 2026-09-24 |
| L-2 | Done | Gateway levels, debug buffer, retention, record format | none | observability-L-2 session, 2026-09-24 |
| L-3 | Ready | iOS always-on recording replaces Diagnostic Capture; one-tap export | L-2 | |
| L-1b | Ready | Launcher records | none | |
| L-1d | Ready | Out-of-band stderr capture | L-2 | |
| L-4 | Ready | Mac app file logging | L-2 | |
| L-5 | Ready | `scripts/tron diagnose` collector | L-1c, L-2 | |
| L-6 | Ready | Event catalog and the incident rule | L-2 | |
| L-7 | Ready | Stall cause in event-loop-delay records | L-2 | |
| L-8 | Needs scoping | Gateway idle heap growth | none | |
| L-9 | Needs scoping | Phone handling of a stalled or unreachable but live Gateway (proposal for the user) | L-7, L-10 | |
| L-10 | Ready | iOS connect-failure records say whether the socket ever opened, and on which interface | none | |
| L-15 | Ready | Startup timing: stop to bound and bound to first startup phase | L-2 | |
| L-16 | Done | Restart drain hangs on terminal-receipt persistence | none | observability session, 2026-09-24 |
| L-17 | Needs approval | Judge a drain stalled by its oldest blocker without progress, not by any change in the blocker set | L-16 | |
| L-18 | Needs approval | Decide whether a restart drain proceeds when only unresolved (blocked) persistence owners remain | L-16 | |
| L-11 | Ready | Remove duplicate payload validations within one deploy run | none | |
| L-12 | Ready | Faster Node payload fingerprint with identical output | none | |
| L-13 | Ready | Stage source payloads in the store and rename instead of copying twice | L-11 | |
| L-14 | Needs scoping | APFS clone copies and payload retention count | L-13 | |

## Task details

### L-1a — Gateway startup-fatal record

- Move the body of `packages/gateway/src/index.ts` into
  `packages/gateway/src/gateway-main.ts`.
- `index.ts` becomes a small shim that runs `await import("./gateway-main.js")`
  in `try`. On failure it synchronously appends `gateway.fatal-startup` (with
  `error`, epoch and version) to `gateway.jsonl`, then exits non-zero.
- The entrypoint path is unchanged, so the launcher and validator contracts
  stay as they are.
- The shim imports only `node:fs`, `node:path` and the small pure `tronHome`
  resolver from `config.ts`.
- **Test:** spawn node on a fixture whose import throws and assert exactly one
  record, in under 1 s.

### L-1c — Deploy timeline and real failure cause

- `scripts/gateway-payload-deploy.mjs` appends `deploy.*` phase records with
  `commandId` and `durationMs`.
- When a replacement fails, it reads a bounded tail of `deploy.jsonl` and
  `gateway.jsonl` for the candidate's `launcher.candidate-rolled-back` or
  `gateway.fatal-startup` record and puts that cause in `update-progress.json`.
  The app then says "New build crashed at startup: ERR_MODULE_NOT_FOUND …".
- **Tests:** cause extraction from fixture logs, and the generic message when
  nothing matches.
- **Acceptance:** with a fixture that bypasses L-0's check, the reported deploy
  error names `ERR_MODULE_NOT_FOUND` and the file.
- **Rollout:** takes effect from the second rebuild after it lands, because each
  rebuild runs the currently running build's deploy helper.

### L-2 — Gateway levels, debug buffer, retention, record format

- **Levels:** add debug to `LogRecord["level"]` and apply the starting table.
  Delete `rpc.request`. Merge admitted and handshake into `connection.opened`,
  and classify local Mac probe connections as debug.
- **Debug buffer:** debug records go only into the in-memory tail, whose bound
  grows via a named constant sized by bytes and count. `recent()` and the iOS
  log RPC serve info and above; the diagnostic export includes the debug buffer.
- **Retention:** 8 × 5 MB numbered segments. Track size in memory instead of
  calling `statSync` per record; keep synchronous append unless measurement
  shows event-loop cost.
- **Record format:** add the fields; thread `sessionId`, `connectionId` and
  `commandId` through call sites that interpolate them into `message` today;
  log a structured `error` at existing failure `catch` sites; emit
  `gateway.started` with identity once per process.
- **Tests (`logger.test.ts`):** record format, error bounds, segment rotation
  under budget, debug excluded from the file but present in the export.
- **Doc:** the logging section of `packages/gateway/README.md`.

### L-3 — iOS always-on recording and one-tap export

- **Remove:** the Start/Stop/Export Capture controls and capture state in
  `GatewayLogsSettingsView`; the `DiagnosticCaptureCoordinator` start, stop and
  duration machinery and its state and revision on `AppModel`; the
  capture-only tests; the two-step prepare-then-`ShareLink` flow
  (`PreparedDiagnosticShare`).
- **Keep:** the Gateway log list, detail view and filter pills; copy visible
  logs; performance signposts; the existing event fields
  (`DiagnosticCaptureEvent` becomes the record format).
- **Add one `AppLog` recorder:**
    - Always on, with a bounded in-memory buffer (named count and byte caps)
      holding all levels.
    - Info and above are also appended to the container file in batches,
      flushed on a named interval, on backgrounding and on any error, so the
      trail survives a relaunch or crash.
    - It records connection state changes (with the Gateway-assigned connection
      ID from hello), recovery attempt number and delay, snapshot, sync and
      session-open failures with code, foreground and background, Gateway epoch
      changes, pairing results, and signpost-measured operations over named
      thresholds.
    - Per-RPC completions are debug. Nothing per frame, token or render.
- **One export action, one tap ("Export Diagnostics"):**
    1. When the Gateway is connected and advertises `diagnostic-export`, upload
       the bundle (device records, app and OS version, the last Gateway log tail
       the app holds). The Gateway writes it under `~/.tron/logs/device-exports/`
       as `<device-hash>-<timestamp>.jsonl` and returns the path. The app copies
       the path to the clipboard and shows "Diagnostics saved on Mac · path
       copied", as before `3de94a570`.
    2. When disconnected, or the upload fails, present the share sheet in the
       same tap using a lazily exported `Transferable` file.
- **Gateway side:** move `transport/diagnostic-export.ts` storage from
  `/tmp/tron-diagnostics` to `~/.tron/logs/device-exports/`, keeping its size
  cap, count retention and private-permission checks.
- **Performance:** appends go to a preallocated ring owned by one actor; disk
  writes are batched off the main actor. Verify with the existing chat
  performance signposts and baseline tests.
- **Tests:** buffer bounds and eviction; info records survive a simulated
  relaunch; export uploads when connected and shares when disconnected or on
  upload failure; the Gateway stores exports under the new directory with its
  caps.
- **Docs:** replace the Diagnostic Capture instructions in
  `packages/ios-app/docs/development.md` and `packages/ios-app/docs/events.md`;
  update the export contract in `packages/gateway/README.md`.

### L-1b — Launcher records

- `packages/mac-app/scripts/tron-gateway-launcher.c` appends single-line records
  (`O_APPEND`, one `write`) to `deploy.jsonl`: `launcher.candidate-launched`,
  `launcher.candidate-rolled-back` (candidate and restored versions),
  `launcher.bundled-fallback`, `launcher.selection-rejected`.
- **Test:** extend the rollback case in
  `packages/mac-app/scripts/test-tron-gateway-launcher.sh`.

### L-1d — Out-of-band stderr capture

- Add `StandardErrorPath` to the `com.tron.server` LaunchAgent plist.
- Stop `GatewayLogger` mirroring to stdout/stderr when
  `TRON_GATEWAY_SUPERVISED=1`.
- Mac startup maintenance truncates `gateway-stderr.log` above a named cap.

### L-4 — Mac app file logging

- One small `TronLog` writer appends JSONL to `~/.tron/logs/mac.jsonl` in the
  shared format, with a bounded debug buffer and segment rotation. It may
  mirror warning and above to `os.Logger`.
- Replace all 14 `NSLog` calls.
- Record observer state changes (old, new and why), LaunchAgent register,
  unregister and kickstart outcomes, update-flow UI states with `commandId`,
  wizard step outcomes, and app start with version and build.
- **Test:** one focused test of the writer's bounds and rotation.

### L-5 — `scripts/tron diagnose`

- A read-only command, `scripts/tron diagnose` with `--since` (default 2h) and
  `--out`, writes one redacted bundle: every `~/.tron/logs` stream within the
  window plus the newest device exports; payload selection and progress JSON;
  launchd spawn and exit events for `com.tron.server` from `/usr/bin/log show`;
  `/health`; Tron processes with their payload versions; the output of
  `scripts/tron mac verify`; and Tailscale's view of each paired peer (current
  path, direct or relay, and endpoint) plus the Tailscale network-extension log
  lines for path changes within the window.
- Call `/usr/bin/log` explicitly, because zsh's `log` builtin shadows it. Share
  one redaction rule set with the writers.
- **Test:** one fixture-home run asserting the sections exist and a planted
  token is redacted.
- **Docs:** `CONTRIBUTING.md` and `scripts/tron --help`.

### L-6 — Event catalog and incident rule

- Create a new `observability.md` in `packages/gateway/docs/` holding the level
  policy, stream locations and owners, retention budgets and measured volumes,
  privacy rules, and the catalog table (event, level, owner, emitted when, key
  fields, added because). Link it from the Mac and iOS docs.
- Add one rule to `AGENTS.md` under Validation: when closing an incident, name
  the signal that would have diagnosed it in one step. If it was missing, add
  it at the right level, with its test and catalog row, in the same change.

### L-7 — Stall cause in event-loop-delay records

- On 2026-09-23 the live Gateway stalled 6–36 s at a time with zero
  connections. Heap used swung between about 130 and 525 MB while RSS was
  80–250 MB, and host swap was 22.35 of 23.55 GB used. The current record
  cannot say whether a stall came from garbage collection, host paging or the
  Gateway's own synchronous work.
- Add to `gateway.event-loop-delay`: garbage-collection pause time and count
  since the previous record (from `perf_hooks` `gc` performance entries),
  event-loop utilization, and host memory pressure and swap used, sampled
  cheaply at record time only.
- **Test:** the record carries these fields when a delay is detected; no
  real-time waits.

### L-8 — Gateway idle heap growth

- Scoping first: find what allocates several hundred MB of heap with no
  connections (candidates: catalog warmup, session search indexing, knowledge
  status). Use a heap snapshot or allocation sampling in an isolated home on a
  copy of real data, never against the live Gateway. Output a fix task with its
  acceptance measurement.

### L-9 — Phone handling of a stalled but live Gateway

- Today the iPhone app treats a pong missing for about 8 s as a dead
  connection, so any Gateway stall longer than about 10 s becomes a reconnect.
  A stalled but live Gateway is indistinguishable from a dead network.
- The proposal must cover the 2026-09-23 17:33–17:35 UTC incident: a healthy
  Gateway was unreachable for about 2.5 minutes because Tailscale kept a dead
  direct path to the phone before falling back to its relay. The phone showed
  Reconnecting and repeated "unavailable" toasts throughout.
- Scoping produces a proposal with the trade-off (faster dead-network
  detection versus fewer spurious reconnects) for the user to decide. This
  changes user-visible behavior, so no change ships without approval.

### L-10 — iOS connect-failure records

- On 2026-09-23 the phone logged every failed reconnect as
  `hello-send … reason=timeout`. That record cannot say whether the WebSocket
  ever opened, so "never reached the Mac" (a network path failure) looked the
  same as "the Mac did not answer". Diagnosis needed the Gateway log and the
  Mac's Tailscale log side by side.
- Record, per failed connect: whether the transport opened (and how long it
  took), the stage reached, and the interface used. Use the existing connection
  records; add fields, not a new stream.
- **Test:** a transport that never opens and one that opens but never answers
  hello produce distinguishable records.

### L-15 — Startup timing

- Two restart windows have no records today: stop to `gateway.bound`
  (7.6–25.5 s) and `gateway.bound` to the first `gateway.startup-phase`
  (10–26 s). The second covers `knowledgeStore.upgradeStorage()` and
  `sessions.initialize()` in `packages/gateway/src/gateway-main.ts`; the
  `timedStage` calls in `packages/gateway/src/sessions/runtime-registry.ts`
  only log slow stages and logged none.
- Record, in the L-2 format, the old process's exit (with shutdown duration),
  the launcher's validation duration (with L-1b), process start to module
  load complete, and each step between `gateway.bound` and
  `gateway.listening`, each with `durationMs`.
- Then find and fix the dominant cost, or add a task naming it. A CPU profile
  may be taken only during a user-initiated restart or in an isolated home.
- **Acceptance:** one restart's records account for at least 90% of stop to
  `gateway.listening`.

### L-16 — Restart drain hang

- Scoping first. On 2026-09-23 at 08:22 UTC a source rebuild's restart waited
  over 7 minutes with 8 operations in `terminal-receipt-persistence` and never
  drained; SIGTERM then hit the shutdown cleanup grace with 4 owned operations
  outstanding. Rebuilds with no active sessions drained in about 0.1 s.
- Find why those receipts did not settle and whether the drain has a bound
  and a visible reason. Any change to how long accepted work is waited for is
  a user-visible behavior change and needs the user's approval.

### L-17 — Stall judged per blocker (needs the user's approval)

- Today the drain is "stalled" only after 180 s with no change at all in its
  blocker fingerprint (`DRAIN_STALL_LIMIT_MS` in `gateway-main.ts`). Any
  admission, settlement or progress of any blocker resets it, so a drain with
  one permanently stuck entry plus unrelated activity (subagents finishing,
  new receipts) never stalls. This matches the 2026-09-23 08:22 incident,
  which waited over 7 minutes without the stall firing.
- Proposal: stall when the oldest blocker has made no progress for the
  limit, regardless of other churn. This shortens how long accepted work is
  waited for in that case, so it ships only with the user's approval.

### L-18 — Unresolved persistence owners (needs the user's approval)

- A canonical write that stays uncertain past its 20 s retry window
  (`retryDurableWrite` in `runtime-slot.ts`) and a failed extension receipt
  keep their `terminal-receipt-persistence` work entry for the life of the
  process by design: nothing may claim the write resolved. The slot already
  reports those writes as `suspect`, but the work entry still blocks the drain,
  so only the stall bound or Restart Now ends it. A restart and recovery is
  the documented way to resolve them.
- Decide whether a drain whose only remaining blockers are such unresolved
  owners proceeds (logging each at error) instead of waiting for the stall
  bound. This changes how long accepted work is waited for.

### L-11 — Duplicate payload validations

- In `scripts/gateway-payload-deploy.mjs` one source rebuild runs a full
  `validatePayload` or `payloadFingerprint` about 8 times. Remove only
  repeats inside one run with no copy, rename or process boundary between
  them: the `validatePayload` directly after computing the new fingerprint;
  the recovery validation when it names the same selection already validated
  as the build base; and `preflightPayload`'s validation when `promote` just
  validated the same root.
- Keep every check after a copy, the launcher's check and the post-restart
  check. Do not weaken any fingerprint or signature check (see the staged
  update controls plan).
- **Tests:** in `scripts/gateway-payload-deploy.test.mjs`, count fingerprint
  computations per source build and promotion; a tampered file after a copy
  is still rejected.
- **Acceptance:** about 15–20 s less before the restart request, measured
  with L-1c's phase records.

### L-12 — Faster payload fingerprint

- `payloadFingerprint` reads and hashes 32k files one at a time (5.4–6.3 s);
  the launcher computes the same value in 1.5–3.6 s. Read with bounded
  concurrency, or call the launcher's `--fingerprint` mode, and keep one
  owner for the algorithm.
- The output must stay byte-identical to
  `packages/mac-app/scripts/hash-gateway-payload.sh` and
  `packages/mac-app/scripts/tron-gateway-launcher.c`.
- **Tests:** equality across all three on a fixture payload, including
  symlinks and control-byte rejection.

### L-13 — One payload copy per source rebuild

- `buildSourcePayload` copies the active payload to `tmpdir()`, then copies
  the finished tree again into the store (10.6 s each). Stage in a private
  directory under the channel root that retention cannot see, and `rename`
  it into `versions/`.
- **Tests:** a crash mid-staging leaves no visible version and a later run
  removes the private directory; concurrent retention never deletes it.
- **Acceptance:** one full copy per source rebuild.

### L-14 — Clone copies and retention

- Node's default copy writes about 594 MB per copy; `fs.cp` with
  `COPYFILE_FICLONE` measured about zero added disk and the same time. Use
  clones where the store is on APFS.
- `MAX_RETAINED_VERSIONS` is 8 (about 4.7 GB without clones). Propose a count
  for the user to decide; do not change it without approval.

## Handoff log

### L-0 · Done · 2026-09-23 · planning session

- Result: runtime connection constants replaced an import of a repository fixture, and `validatePayload` now rejects compiled imports that are not shipped in `app/`.
- Evidence: the new deploy test fails without the check and passes with it; a fresh compile in an isolated home reached `gateway.listening`; the fixed build deployed and ran.
- Changes: `1919394af`.
- Tasks added: L-1a through L-6. The plan started as a shared Claude Doc and moved here the same day when the plans folder was created.
- For the next agent: start with L-1a, then L-1c.

### L-1a · Done · 2026-09-23 · observability-L-1a session

- Result: `packages/gateway/src/index.ts` is now a small entrypoint that imports `gateway-main.ts` and, when loading or startup fails, appends one `gateway.fatal-startup` record (error with one level of cause, runtime epoch, payload version) to `gateway.jsonl` and exits 1.
- Evidence: focused tests (`index.test.ts`, `config.test.ts`, `logger.test.ts`) pass 32/32 in under 1 s; negative control: removing the record call fails `index.test.ts`. Compiled build with `dist/transport/connection-policy.js` deleted, run in an isolated home: exit 1 and one record naming `<payload>/dist/transport/connection-policy.js` with `ERR_MODULE_NOT_FOUND`. Unmodified compiled build in an isolated home reached `gateway.listening`, wrote no fatal record and stopped cleanly on SIGTERM. Compiled `index.js` is 2,943 bytes, above the 1,024-byte entrypoint minimum the launcher, deploy helper and Swift validator enforce. The full Gateway suite was started but stopped before finishing: running it on the Mac that hosts the live Gateway raised the load average to about 15 and stalled the live Gateway's event loop for 22–35 s, dropping phone connections. It has not been run on this change.
- Changes: branch `observability/L-1a`.
- Tasks added: none.
- Deviations: the shim installs no global `uncaughtException`/`unhandledRejection` handlers, because `gateway-main.ts` already installs them once running and errors before that reject the import the shim awaits. `resolveTronHome` moved from `config.ts` into `packages/gateway/src/tron-home.ts` so the shim avoids `config.ts`'s third-party imports; `boundedMessage` is now exported from the logger for reuse. Payload and home path prefixes are shortened before redaction, because the standard redaction replaces whole `/Users/...` paths and would hide the failing file. One level of `cause` is recorded because wrapped startup errors carry their root reason there.
- For the next agent: run the full Gateway suite only when the live Gateway is idle or on another machine; focused owner tests are the default. L-1c can now read `gateway.fatal-startup` records for the candidate's `runtimeEpoch` or `payloadVersion`. Keep the entrypoint above 1,024 bytes; the installed launcher enforces that minimum.

### L-2 · Done · 2026-09-24 · observability-L-2 session

- Result: `GatewayLogger` has four levels. Debug stays in a bounded memory buffer (4,000 records or 2 MB) that `system.logs.export` appends to the exported snapshot; info and above persist to eight 5 MB numbered segments with in-memory size tracking. Records carry writer-stamped `process`, `runtimeEpoch` and `payloadVersion`, correlation fields (`sessionId`, `connectionId`, `commandId`) and a bounded, redacted structured `error`. `gateway.started` is recorded once per process. The starting level table is applied to the events that exist.
- Evidence: `npx vitest run src/transport src/admin src/index.test.ts src/config.test.ts` with Node 22.22.0: 41 files, 360/360. `npm run build` clean. New `logger.test.ts` (7) covers record format, structured error bounds, debug excluded from file and tail, debug buffer count/byte eviction, 8 × 5 MB rotation (~48 MB written, 40 MB kept, oldest gone) and tail restore from the newest segments. Negative controls: persisting debug fails the debug test; disabling rotation fails the rotation test. The full Gateway suite was not run (live Gateway on this Mac; see L-1a).
- Changes: this commit (`logger.ts`, `server.ts`, `gateway-main.ts`, `gateway-service.ts`, `diagnostic-export.ts`, `index.ts`, tests, Gateway README logging section).
- Tasks added: none.
- Kept on purpose: synchronous append (no measurement showed event-loop cost). Stdout/stderr mirroring stays until L-1d. `diagnostic-export` storage stays in `/tmp/tron-diagnostics`; L-3 moves it. `GlobalProviderResources` diagnostics still interpolate error text into messages; they are not `catch`-site faults of the transport and were left for the event catalog pass (L-6).
- Deviations: `rpc.request` no longer existed on `main`, and fast successful `rpc.completed` was already omitted rather than info, so those rows became "record fast successes at debug". Fast successful `session.stage` records were omitted before; they are now debug. `connection.admitted` is deleted; `connection.opened` is emitted at hello with the admission-to-hello duration. `rpc.error` is warning for every `GatewayError` code except `internal`, not only `busy`, per the level policy that caller mistakes are warnings. `describeError` moved from `index.ts` into the logger so the entrypoint and writer share one bound.
- For the next agent: the running Gateway adopts this only after the user rebuilds it. L-1d, L-3, L-4, L-6, L-7 and L-15 are unblocked. L-6 should record one day's measured volume once a rebuilt Gateway has run for a day.

### L-1c · Done · 2026-09-24 · observability session

- Result: `scripts/gateway-payload-deploy.mjs` appends a per-operation timeline to `~/.tron/logs/deploy.jsonl` (one `deploy.<state>` per progress state carrying the ended phase's `durationMs`, `deploy.old-process-exited` when the drained process disappears, one `deploy.finished` with total and outcome, all with `commandId`), rotated to `.1` above 1 MB at operation start. When a promoted candidate fails after its restart request, `promote` looks up the candidate's own `gateway.fatal-startup` or `launcher.candidate-rolled-back` record (newest 256 KB of `gateway.jsonl` and `deploy.jsonl`, at or after the restart request, matched by `runtimeEpoch` or `payloadVersion`) and leads the error with it, so `update-progress.json` and the app's Deployment error row read "New build crashed at startup: ERR_MODULE_NOT_FOUND: …".
- Evidence: `node --test scripts/gateway-payload-deploy.test.mjs` with Node 22.22.0: 47/47 (five new tests: phase durations with an injected clock and nothing after the terminal state; failure levels per operation and a single close; rotation at and above the cap and a never-throwing unwritable log; cause matching by epoch or version, time window, crash preferred over launcher record, wrapped root cause; bounded tail with partial first line). The existing apply test now asserts the real `applyPayload` failure path writes starting → failure → finished for its command. Negative controls: disconnecting `writeProgress` from the timeline fails the apply test; removing the crash preference fails the cause test. Acceptance: compiled this branch's Gateway, deleted `dist/transport/connection-policy.js`, ran `dist/index.js` in an isolated home (exit 1), and `candidateStartupFailure` on that home returned "New build crashed at startup: ERR_MODULE_NOT_FOUND: Cannot find module '…/dist/transport/connection-policy.js' imported from …/dist/transport/server.js"; a different epoch/version returned nothing.
- Changes: this commit (`gateway-payload-deploy.mjs`, its tests, Gateway README update section).
- Tasks added: none.
- Kept on purpose: the lookup reads only the active `gateway.jsonl`, not rotated segments; a crash from this attempt is written seconds earlier. A user-requested rollback gets its own timeline in which `rollback`/`rolled-back` are info and `rolled-back` is success. The four-line wiring inside `promote`'s catch is not covered by an automated test because `promote` needs a live authenticated listener; it was reviewed by reading and proven through the acceptance run of its lookup.
- Deviations: in the acceptance run the payload root was under `/tmp`, so the recorded path reads `/private<payload>/…` (the process resolved `/private/tmp` while `TRON_GATEWAY_PAYLOAD_ROOT` named `/tmp`). Production payload roots are not symlinked, as L-1a's evidence shows `<payload>/…`.
- For the next agent: the helper that runs a rebuild is the running build's, so this takes effect from the second rebuild after it lands. L-1b's launcher records must carry the candidate's `payloadVersion` (and `runtimeEpoch` when known) for the lookup to match; its message becomes the text after "New build was rolled back by the launcher:". L-5 and L-11 can now read phase durations from `deploy.jsonl`.

### L-16 · Done · 2026-09-24 · observability session

- Result: scoping plus one diagnostic fix. The 2026-09-23 08:22 logs had already rotated away, so that incident's exact blockers cannot be recovered; the findings below are from the code. Receipt-backed RPCs now register their whole execution as a distinct `rpc-mutation` work kind carrying the method and session, and drain blocker summaries, `gateway.restart-drain.waiting` records and the phone's drain row name them ("2 running requests"). The phone also labels `knowledge-observation`, which it previously counted as "other".
- Findings: (1) `terminal-receipt-persistence` was shared by six owners, one of which, `GatewayService.mutation`, spans the entire execution of every receipt-backed RPC. `session.compact`, `session.navigate` (branch summary), `session.bash` and `packages.update` can run for minutes, so "8 terminal-receipt-persistence, settling" could have been eight executing requests shown as completion receipts. (2) The drain bound is the 180 s no-progress stall plus Restart Now (which works since `e142de727`), but any blocker churn resets the stall (L-17). (3) Unresolved canonical writes and failed extension receipts hold their work entry for the process lifetime by design (L-18). (4) The waiting record listed only category, state and age, so no incident could name the owner; it now includes the method for requests.
- Evidence: `npx vitest run src/transport src/admin src/sessions` with Node 22.22.0: 82 files, 979/979, 50 s. New tests: `administrative-drain-snapshot.test.ts` (an executing request is an active `rpc-mutation` blocker with its method and session; receipt persistence stays `settling` without a method) and a `gateway-restart.test.ts` case (a pending `session.rename` is admitted as `rpc-mutation` with method and session). Negative control: restoring the old kind and dropping `method` from summaries fails both. iOS: `scripts/tron-ios-test run --only-testing TronMobileTests/GatewayUpdateControlPlaneTests` 11/11 with the new label assertion.
- Changes: this commit (`gateway-service.ts`, `gateway-work-registry.ts`, `runtime-registry.ts`, `protocol/types.ts`, `gateway-main.ts`, iOS drain labels, tests, Gateway README drain snapshot).
- Tasks added: L-17 and L-18, both needing the user's approval because they change how long accepted work is waited for.
- Kept on purpose: no change to what the drain waits for or for how long. The five in-slot receipt owners keep `terminal-receipt-persistence`; they are receipt or marker persistence.
- For the next agent: the next stuck drain's `gateway.restart-drain.waiting` records (now retained for weeks) name each executing request's method, which should decide whether L-17 or L-18 is the fix that matters.
