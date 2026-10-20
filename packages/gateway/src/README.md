# gateway/foundation

## Purpose

The Gateway's process-wide foundations: where its state lives (Tron home, agent
home, Gateway config), version identity, shared errors, and the one scheduler for
recurring background work. Every other module under `src/` has its own manifest;
`scripts/tron docs modules packages/gateway` maps them.

## Owns

`tron-home.ts`, `config.ts`, `version.ts`, `errors.ts`, `background-work.ts`
(`backgroundWork`) and the Tron-home environment policy.

## Contract

### State layout

- **Agent home** (Pi's canonical home) is `<tronHome>/agent`: `~/.tron/agent` for
  Stable, `~/.tron-dev/agent` for the isolated Debug supervisor. An absolute
  `PI_CODING_AGENT_DIR` is the only override (the Debug supervisor strips it); the
  retired `TRON_AGENT_DIR_NAME` is rejected. Canonical JSONL, settings, credentials,
  packages, resources, retries and compaction stay there. The retired `~/.pi/agent`
  is never read, migrated or deleted. Stable and Debug never share these stores.
- **Gateway state** is `<TRON_DATA_DIR|~/$TRON_HOME_NAME|~/.tron>/gateway/`.
  `gateway.json` is an exact-shape document (16 KiB max, 256-byte machine ID, 1 KiB
  name); unsafe, malformed or oversized files fail startup without rekeying. The old
  version-1 shape with a valid `defaultWorkspace` is normalized under the config lock
  by removing only that field; unknown shapes are never rewritten.
- Owner-only regular non-symlink files: `local-auth.json` (local wrapper credential,
  0600), `devices.json` (hashed mobile devices), `enrollment.json` (current
  invitation: ten minutes, one use), `notifications.json`
  ([notifications](notifications/README.md)). Malformed credentials fail closed.
- The physical-machine group ID lives at the one shared path
  `~/.tron/internal/machine-group-id` for both Stable and Debug, used only for
  connection grouping; while the retired `~/.tron-machine-group-id` exists, startup
  refuses rather than mint a second identity.
- The internal workspace is the sibling `<tronHome>/workspace`
  ([workspace](workspace/README.md)). Delegated provider artifacts live under
  `<tronHome>/internal/subagents/` ([internal-workspace.md](../docs/internal-workspace.md#delegated-provider-root)).
- Uploads are transient and bounded; prompt attachments stay session-owned until
  canonical deletion. Upload expiry, Automation timestamps and catalog windows use the
  host wall clock; upload and Automation IDs use the platform cryptographic UUID.

### Process environment

A supervised payload validates its immutable `node` and `pi` command aliases
(`src/runtime/node-command-environment.ts`) before model services or packages load:
exact relative targets inside `TRON_GATEWAY_PAYLOAD_ROOT`, resolving to the running
Node and the payload's Pi CLI. Stable uses those commands; Debug keeps a valid
developer Node first. Invalid aliases fail startup rather than fall back to Homebrew,
NVM or a user shim. PATH then gains `/opt/homebrew/bin` last so shells find `git-lfs`.

### Background work

`backgroundWork` (started by `gateway-main.ts` once the listener serves) decides when
recurring work runs. Jobs take turns one slice at a time, yielding with
`setImmediate`. A due slice waits while a request competes for the loop
(`requestsCompetingForLoop()` in `transport/request-span.ts`; receipt-backed off-loop
mutations do not count) or while loop-delay p99 is at or above
`BACKGROUND_PAUSE_P99_MS`, re-checking every `BACKGROUND_PAUSE_RECHECK_MS`. A long
slice awaits `backgroundWork.yieldToLoop()` between batches. A rejecting slice is
reported and never stops the scheduler. `register({ name, intervalMs, slice })`
returns the function that unregisters exactly that registration. Jobs: the session
catalog's periodic reconcile (its startup and watcher passes yield the same way),
command-receipt pruning, and attachment/display-artifact maintenance.

## Invariants

- Nothing in a request path prunes, walks or reconciles; an admission may force one
  exact pass at its own capacity boundary.
- Each owner keeps its own bounds; the scheduler decides only when a slice starts.

## Entry points

`resolveTronHome` (`tron-home.ts`), `loadConfig` (`config.ts`),
`backgroundWork.register`.

## Signals

Also the rows of `src/` modules that have no README yet: process lifecycle
(`gateway-main.ts`, `index.ts`, `lifecycle/`), `episodic/`, `client/` and `integrations/`.

| Signal | Level | Meaning |
|---|---|---|
| `background.slice` | debug; warning on failure | One background slice ran: `step` (the job), `outcome`, `durationMs`, `counts.waitedMs` past its due time, `error`; a failure is retried only by the next slice |
| `background.backlog` | warning | A job starved past `BACKGROUND_BACKLOG_WARNING_MS` (5 min) while the scheduler was paused: `step`, `reason` (`requests-in-flight`, `event-loop-p99`), `counts`; once per spell |
| `gateway.fatal-startup` | error | Loading the module graph or startup threw before the logger existed (`index.ts`): `error`, `runtimeEpoch`, `payloadVersion` |
| `gateway.started` | info | The first record of a process: `durationMs` since process start; pid, Node version and revision in the message |
| `gateway.startup-step` | info | Each startup checkpoint: `step`, `durationMs` |
| `gateway.startup-budget` | info; warning past `STARTUP_LISTEN_BUDGET_MS` (5,000 ms, `lifecycle/startup-budget.ts`) | Once, when serving: `durationMs` from process start to listening, the dominant `step`, budget and overrun in the message. A restarting client measures from its own socket close, not this |
| `gateway.stopping` | info | Shutdown began; the reason is in the message |
| `gateway.shutdown-step` | info | Each awaited shutdown operation settled: `step`, `durationMs` |
| `gateway.shutdown-cleanup-expired` | warning | The 2 s cleanup grace ended with owned work outstanding (count in the message) |
| `gateway.shutdown-failed` | error | Shutdown itself threw: `error` |
| `gateway.stop-completion.failed` | error | Publishing the intentional-stop receipt failed after every owner settled; the exit stays 0 so launchd does not relaunch |
| `gateway.stopped` | info; warning for a non-zero exit code | The last record before exit: `pid`, `code`, `durationMs` (shutdown time) |
| `gateway.exit-stalled` | warning | A non-zero exit after a completed shutdown had not ended the process within `EXIT_STALL_GRACE_MS` (5,000 ms); the detached watcher (`lifecycle/exit-after-shutdown.ts`) then SIGKILLs that PID: `pid`, `code`, `durationMs` |
| `gateway.restart-drain` | info | The restart was scheduled and the drain began |
| `gateway.restart-drain.waiting` | info | Every 15 s while draining, at each stall decision and at an immediate restart: the blockers (`sessionId`, `category`, `method`, `state`, `ageMs`, `progressAt`) in the message |
| `gateway.restart-drain.stalled` | warning | The oldest blocker made no progress for `DRAIN_STALL_LIMIT_MS` (180 s), or an immediate restart was requested: its category, method and age |
| `gateway.restart-drain.unresolved-owner` | error | Every remaining blocker is a suspect `terminal-receipt-persistence` owner, so the restart proceeds; one record per owner with `sessionId` |
| `gateway.restart-drain.completed` | info | The drain reached zero blockers |
| `gateway.restart-drain-failed` | error | The drain promise rejected: `error` |
| `gateway.stop-drain` | info | The stop receipt settled and the process owner began waiting |
| `gateway.stop-drain.completed` | info | No accepted-work blockers remain; cleanup begins |
| `gateway.stop-drain.failed` | error | The stop wait rejected or the final snapshot could not prove completion; the Gateway keeps running with admission closed |
| `process.uncaught-exception` | error | An uncaught exception reached the process: `error`, before `gateway.stopped` |
| `process.unhandled-rejection` | error | An unhandled rejection reached the process: `error` |
| `episodic.source-invalidated` | info | A context edit or navigation changed an ingested message, or open-time recovery found nodes depending on a revoked one; their summaries were revoked: `counts.invalidated`, `generation` |
| `episodic.source-read-retried` | warning | A canonical-source parse failed while the source changed or its final snapshot was unprovable; the cursor waits for the next update; fixed message only |
| `episodic.node-blocked` | warning | A compactor call, canonical read or store append blocked the memory and stopped its pump: `reason` (`permanent-failure`, `retries-exhausted`, `usage-limit`, `source-unavailable`). Every Home activation re-arms once and `home.resumeMemory` at once, so a recurring record means the cause persists |
| `episodic.store-recovered` | warning | Loading the store discarded a torn trailing record: `counts.bytes` |
| `episodic.store-refused` | error | The store is unreadable (`reason` `invalid-store`, `unsafe-store`); the memory is refused, never rebuilt |
| Terminal `[Tron disconnected; reconnecting…] reason=…` and `[Tron resync required: reason=event-gap …]` | terminal stderr | `client/terminal-chat.ts`: one reason per reconnect (`disconnected`, `resync-required`, `event-gap`, `command-recovery`) and an event-gap record (topic, expected and received sequence) before resynchronizing; no tokens, IDs, paths or payloads |
| `connection.legacy-jev-retired` | info | The first accepted connection write after load removed persisted unsupported `knowledge.jev` instances (`integrations/connection-owner.ts`), once after the retirement persists: sorted `instanceIds` |

## Verify

```bash
scripts/tron verify --module gateway/foundation
```

## Not here

- Startup order and shutdown steps: `gateway-main.ts` and `index.ts`; streams and
  levels: [observability](../docs/observability.md).
- Diagnostic bundles: [Gateway README](../README.md#diagnostic-bundle).
