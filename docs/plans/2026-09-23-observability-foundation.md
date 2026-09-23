# Observability foundation

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, L-0
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
| L-1a | Claimed | Gateway startup-fatal record | none | observability-L-1a session, 2026-09-23 |
| L-1c | Ready | Deploy timeline and real failure cause | L-1a | |
| L-2 | Ready | Gateway levels, debug buffer, retention, record format | none | |
| L-3 | Ready | iOS always-on recording replaces Diagnostic Capture; one-tap export | L-2 | |
| L-1b | Ready | Launcher records | none | |
| L-1d | Ready | Out-of-band stderr capture | L-2 | |
| L-4 | Ready | Mac app file logging | L-2 | |
| L-5 | Ready | `scripts/tron diagnose` collector | L-1c, L-2 | |
| L-6 | Ready | Event catalog and the incident rule | L-2 | |

## Task details

### L-1a — Gateway startup-fatal record

- Move the body of `packages/gateway/src/index.ts` into a new
  `gateway-main.ts` in `packages/gateway/src/`.
- `index.ts` becomes a small shim. It installs `uncaughtException` and
  `unhandledRejection` handlers and runs `await import("./gateway-main.js")` in
  `try`. On failure it synchronously appends `gateway.fatal-startup` (with
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
  `/health`; Tron processes with their payload versions; and the output of
  `scripts/tron mac verify`.
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

## Handoff log

### L-0 · Done · 2026-09-23 · planning session

- Result: runtime connection constants replaced an import of a repository fixture, and `validatePayload` now rejects compiled imports that are not shipped in `app/`.
- Evidence: the new deploy test fails without the check and passes with it; a fresh compile in an isolated home reached `gateway.listening`; the fixed build deployed and ran.
- Changes: `1919394af`.
- Tasks added: L-1a through L-6. The plan started as a shared Claude Doc and moved here the same day when the plans folder was created.
- For the next agent: start with L-1a, then L-1c.
