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

| Signal | Level | Meaning |
|---|---|---|
| `background.slice` | debug; warning on failure | One background slice ran; `step` names the job |
| `background.backlog` | warning | A job starved past `BACKGROUND_BACKLOG_WARNING_MS`; once per spell |

## Verify

```bash
scripts/tron verify --module gateway/foundation
```

## Not here

- Startup order, `gateway.fatal-startup` and shutdown steps: `gateway-main.ts`,
  `index.ts` and [observability](../docs/observability.md).
- Diagnostic bundles: [Gateway README](../README.md#diagnostic-bundle).
