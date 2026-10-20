# gateway/run

## Purpose

The session run kernel: one live Pi runtime per canonical session, serialized
mutations, prompt admission, run markers, invocation receipts and terminal
settlement. The other `src/sessions/` modules (catalog, projection, delegation,
extension activity, resources, session search) have their own manifests here;
`scripts/tron docs modules packages/gateway/src/sessions` lists them.

## Owns

`runtime-registry.ts` (`RuntimeRegistry`), `runtime-slot.ts` (`RuntimeSlot`),
`invocation-receipts.ts`, `run-markers.ts`, `owned-session-dispatch.ts`,
`bounded-tool-cancellation.ts`, `semantic-ui-broker.ts`, `restart-drain.ts`,
`gateway-work-registry.ts` and the rest of `run.module.json`. State: Gateway-owned
bounded run markers and command receipts; Pi's canonical JSONL stays Pi's.

## Contract

- **Canonical JSONL is authoritative.** The Gateway is the sole live owner of
  invocation, operation and activity identity. Bounded `tron.chat-invocation.v1`
  records persist causal start, terminal and binding facts in the same branch and
  never enter model context; plain prompt bodies stay only in their user entries.
- **Terminal receipts** are decided only at final `agent_settled` or at transfer to a
  distinct follow-up or extension operation, never at a response completion
  (compaction and same-owner continuation may still run, and Stop stays
  authoritative there). The per-operation record owns its start cursor and terminal
  attribution; at transfer the predecessor's exact completion is captured first, so a
  later follow-up failure cannot swallow an earlier success. A canonical successful
  reply starts its durable attention settlement at once.
- **Ordering.** The always-loaded `tron-invocation-settlement` module's awaited
  admission hooks join pending terminal receipt writes before the next operation's
  admitted input, but not attention I/O. SDK between-turn entries (a tool-loadout
  message, say) may fall on either side of a receipt; consumers infer nothing from
  that order.
- **Stop.** A failed Stop (`Foreground work did not stop`) withdraws its interruption
  intent, so a later natural completion is `completed`; an actual SDK abort settles
  as interrupted. Every tool call runs under its own abort controller, and two
  seconds after cancellation a call that ignores its signal resolves as an error
  naming the abandoned tool; its late result is discarded. Built-in bash kills its
  process group on abort.
- **Session-replacing extension commands** (`ctx.switchSession`, `ctx.newSession`,
  `ctx.fork`) settle `completed` in the origin at `beforeSessionInvalidate`; nothing
  more is written under the replacement. Rows a fork inherits project as settled in
  the origin (`settledInOriginSession: true`), never staged; stored receipts are never
  rewritten.
- **Transcript.** Order is canonical branch order. The projection separates inbound
  context, agent output and invocations, ambient status and hidden state;
  `custom_message` is model input, `custom`/`appendEntry` extension state. Producer
  attribution is exact only at a Gateway-owned boundary; unknown stays unknown.
  Projections are bounded by count and bytes, and malformed recognized data fails
  closed to an authoritative resync. Live and cold reads both use
  `projectTranscriptPage`/`projectTranscriptPageAfter`.
- **Pi boundary.** Pi owns nested execution: nested calls stay children of their
  parent result. Codemode's `image()` save label stays in JSONL and the model result
  but is hidden from every client projection (`visibleToolResultContent`). A new
  session materializes at its first user or assistant message; receipts appended
  before it flush with that message.
- **Tool loadout.** A chat's tool loadout lives only in its transcript
  (`toolsAdded`/`toolsRemoved`). Every runtime built for an existing transcript (cold
  open, reopen, restart, fork, restore) applies it; only a transcript that declares
  none gets `defaultTools`.

## Invariants

1. `RuntimeRegistry` owns at most one `RuntimeSlot` per session in this process.
2. A slot serializes its session's mutations; different slots run concurrently.
3. Prompt admission returns an operation ID; client disconnect does not abort it.
4. Subscribe/open is a two-phase baseline barrier owned by transport
   ([transport README](../transport/README.md#invariants)).
5. Reconnect/open returns current state plus a bounded transcript tail, not missed
   events; older pages stay reachable through branch-stable anchors.
6. A run marker exists only for an admitted active operation. Startup projects a
   surviving marker as `interrupted`; prompts are never replayed. A missing terminal
   after an accepted start is `outcomeUnknown`. An admission that fails before any
   run starts restores the phase it took.
7. A foreground snapshot cannot be idle while the runtime streams, nor keep a running
   tool overlay while idle. Detached extension work is extension UI state.
8. Fork and session replacement rekey the same slot and subscription token; a
   pre-commit rekey failure restores the source runtime and removes the fork's files.
9. Idle runtimes are evicted only while not busy and unsubscribed.
10. Administrative restart waits for admitted runs to settle and needs an external
    supervisor; runtime memory never survives replacement.
11. The Gateway is the sole mutable runtime owner. Terminal and mobile surfaces attach
    to it; a second Pi process on the same JSONL is unsupported (no cross-process
    lock). A process lock is held per agent directory and external session directory,
    and `sessionDir` changes need a restart.

**Capacity.** Live parent runtimes default to 128 (`TRON_GATEWAY_MAX_LIVE_RUNTIMES`,
1–1024), reservations included. At capacity the oldest reloadable idle runtimes are
evicted; active work, subscribed sessions, command leases, unpersisted drafts and a
repeated acquisition's own session are protected. A byte budget
(`LIVE_RUNTIME_BYTE_BUDGET`, charging `LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR` × JSONL bytes)
is eviction pressure, never an admission gate: it retires the largest eligible idle
runtimes until the opening fits, retires nothing when that cannot help, and marks an
unfit open `overBudget`. The launcher's `--max-old-space-size` stays the backstop.

**Catalog fence.** A live persisted slot proves catalog membership for attention reads
and writes. A cold open reads only its target (one unchanged canonical claimant, its
stat and header), so unrelated catalog churn cannot fail it. Upload and display orphan
maintenance resolve membership inside their own lanes and keep ownership when they
cannot prove it.

**Tool lineage.** Every tool declaration carries a `toolSegmentId` for one visible
conversation segment; groups publish at the finalized assistant `message_end` with
runtime-only `groupId`/`groupIndex`/`groupCount`/`groupFinalized` before any tool start.
`SessionSnapshot.activeToolSegmentId` names the running segment only during an exact
streaming run. Cold projection derives the same boundaries. Lineage is presentation
metadata, never JSONL, and never implies parallel execution.

## Entry points

- Admission and lanes: `RuntimeSlot` (prompt, steer, follow-up, Stop, rename,
  Chat-layer setters); runtime acquisition and eviction: `RuntimeRegistry`.
- Owned dispatch for Automations and Home tasks: `OwnedSessionDispatch` (shared
  leases, recovery evidence, terminal acknowledgement, opt-in 24-hour deadline).
- Settings, Home and notifications plug in through the slot; see Not here.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `attention-pending` (`rpc.error` reason) | warning | Prompt admission waits on an exact completion's unsettled durable attention; names `operationId` and `ageMs` |
| `runtime.loaded` | info | A runtime went live; `reason`, `transcriptBytes`, `estimatedHeapBytes`, `overBudget` |
| `runtime.evicted` | info | A runtime stopped being live; `reason` (`bytes`, `heap`, `idle`, `capacity`, …) and its bytes |

## Verify

```bash
scripts/tron verify --module gateway/run
scripts/tron test gateway src/sessions/runtime-registry.integration.test.ts \
  src/sessions/runtime-tool-loadout.integration.test.ts
```

`runtime-registry.integration.test.ts` covers follow-up steering receipts, failed Stop
then natural completion, materialization and reopen, and 128 concurrent parent runs;
`src/transport/session-archive.integration.test.ts` covers session-replacing commands
and fork-inherited rows; `src/home/home-task-tool.e2e.test.ts` covers abandoned tools.
Behavior locks: `run.lock.integration.test.ts`, `run.store.lock.integration.test.ts`,
`run-markers.lock.integration.test.ts`.

## Not here

- Wire contracts: [transport](../transport/README.md). Projection rules:
  `projection.ts` (gateway/projection). Delegated activity:
  [delegated-activity.md](../../docs/delegated-activity.md).
- Settings applied through the slot: [admin](../admin/README.md). Home:
  [home](../home/README.md). Terminal alerts: [notifications](../notifications/README.md).
- SDK upgrades and the behavior trace: [Pi SDK maintenance](../../docs/pi-sdk-maintenance.md).
