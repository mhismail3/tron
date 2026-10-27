# gateway/run

## Purpose

The session run kernel: one live Pi runtime per canonical session, serialized
mutations, prompt admission, run markers, invocation receipts and terminal
settlement. Other session modules have their own manifests here; projection lives in
[`kernel/projection`](../kernel/projection/README.md);
`scripts/tron docs modules packages/gateway/src/sessions` lists them.

## Owns

[`kernel/session/runtime-registry.ts`](../kernel/session/runtime-registry.ts) (`RuntimeRegistry`),
[`kernel/run/runtime-slot.ts`](../kernel/run/runtime-slot.ts) (actual native frame extending `RunOperations`),
[`kernel/run`](../kernel/run/README.md) receipts, markers, per-operation work, held/SDK queues, serialized queue edits, serialized prompt admission/completion, SDK run transitions, manual compaction, durable terminals/observers, attention, task waits, write fences and cancellation;
`restart-drain.ts`
and the rest of `../run.module.json`. State: Gateway-owned
bounded run markers and command receipts; Pi owns JSONL. Host recipes are fixed per runtime; append policies resolve recorded identity live.
Shared deadline bookkeeping lives in `../util/recency-deadlines.ts`; activity owners keep their own partitions and tombstones.

## Contract

- **Canonical JSONL is authoritative.** The Gateway is sole live owner of invocation, operation and activity identity.
  `receipt-fields.ts` owns shared text/origin/time bounds; each receipt family retains its grammar.
  Bounded `tron.chat-invocation.v1` records persist causal start, terminal and binding facts in the same
  branch, never enter model context; plain prompt bodies stay only in their user entries.
- **Terminal receipts** are decided only at final `agent_settled` or at transfer to a
  distinct follow-up or extension operation, never at a response completion
  (compaction and same-owner continuation may still run, and Stop stays
  authoritative there). The per-operation record owns its start cursor and terminal
  attribution; at transfer the predecessor's exact completion is captured first, so a
  later follow-up failure cannot swallow an earlier success. A canonical successful
  reply starts its durable attention settlement at once; `RunPersistence` owns its pending-write join and unresolved durable-write fence.
- **Ordering.** The always-loaded `tron-invocation-settlement` module's awaited
  admission hooks join pending terminal receipt writes before the next operation's
  admitted input, but not attention I/O. SDK between-turn entries (a tool-loadout
  message, say) may fall on either side of a receipt; consumers infer nothing from
  that order.
- **Stop.** `RunAbortOwner` owns intent/recovery; a failed Stop (`Foreground work did not stop`) withdraws its interruption
  intent, so a later natural completion is `completed`; an actual SDK abort settles
  as interrupted. Every tool call runs under its own abort controller, and two
  seconds after cancellation a call that ignores its signal resolves as an error
  naming the abandoned tool; its late result is discarded. Built-in bash kills its
  process group on abort.
- **Session-replacing extension commands** (`ctx.switchSession`, `ctx.newSession`,
  `ctx.fork`) settle `completed` in the origin at `beforeSessionInvalidate`; nothing
  more is written under the replacement. Rows a fork inherits project as settled in
  the origin (`settledInOriginSession: true`), never staged; stored receipts are never
  rewritten. Input policy owns delivery; the run retains its sole writer, exact input proof and terminal receipt before inbox settlement.
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

Knowledge is constructed and supplied by composition, never installed on or read
through the registry.

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

- Run admission, queue/Stop/compaction and configuration/bash algorithms: kernel `RunOperations`,
  inherited by `RuntimeSlot` with native SDK/resources/publication; acquisition/eviction: `RuntimeRegistry`.
- Owned dispatch for Automations and Home tasks: kernel/delegation `DelegationOperations` over
  `RuntimeRegistry`'s leases, recovery evidence and marker acknowledgement (opt-in 24-hour deadline).
- Notifications use call-time kernel hooks; the slot owns presence, waiting episodes and failure diagnostics.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `attention-pending` reason on `rpc.error`; `session_operation_busy`; `catalog_not_ready`; `rpc.error` / `session_configuration_*` | warning RPC reasons | Prompt admission waits on an exact completion's unsettled attention (`operationId`, `ageMs`); a model, delete or archive mutation blocked by real session work; a read before the catalog owner published its first cut (retryable); a model/thinking/context command refused by parent configuration policy (`running`, `queued`, `settling`, `mutation`, `interaction`, `unavailable`) |
| `runtime.loaded`; `runtime.evicted`; `runtime.dispose-timeout`; `canonical-ownership-persistence-retrying`; `canonical-ownership-persistence-blocked`; `terminal-receipt-persistence-failed`; `recent-model-record-failed` | info; dispose timeout and persistence codes warn | A runtime went live or stopped (`reason`, `transcriptBytes`, `estimatedHeapBytes`, `overBudget`); a 5 s disposal grace overran; persistence diagnostics whose event is the code, with `sessionId` (a blocked ownership write leaves the slot `suspect`) |
| `Foreground work did not stop` (`conflict`, retryable); `Interrupted by <Home \| the maintainer>: this <tool> call was cancelled`; `Tool <name> did not stop within 2000 ms of cancellation`; `session.stop-steering-continuation` | RPC error and canonical tool results; continuation info | A refused Stop is not interruption proof; an interrupt or abandoned tool shows at its call in the transcript (`home-task-tool.e2e.test.ts`); Stop re-admitted accepted queued steering: steer count and `outcome` |
| `session.compaction.completed`; `session.compaction.manual-adopted`; `codemode.execution.completed`; `sessions.archive.persist-failed`; `sessions.archive.auto-unarchived`; `extension.artifact-rejected`; `extension.discovery-truncated`; `extensionPresentation.diagnostics` with `semantic.<operation>` | info; failures, rejections and truncation warn; a failed compaction is error | Compaction end (`operationId`, `reason`, `outcome`) or adoption of a queued manual request; top-level codemode outcome, nested count, `complete`; archive store failure or auto-unarchive (no session ID); a rejected extension artifact (`reason`); a discovery pass stopped at a budget (`counts`); a void extension callback rejection in the snapshot |
| `catalog-index.failure`; `catalog.reconciled`; `catalog.changed`; `catalog.watcher-reset`; `session-search.warm`; `session-search.warm-failed`; `session-search.index-unavailable`; `session-search.helper-unavailable` | info; `catalog.changed` debug; failures, incomplete reconciles and resets warn | Session catalog (`step`, `outcome`, `trigger`, `counts` added/removed/modified/unproven, watcher `reason`) and search warm-up (`counts` reused/parsed sessions), index or embedding-helper unavailability |
| `rpc.error` / managed pi-subagents entry refusal; `pi-subagents.user-package-ignored`; `pi-subagents.agent-definition-invalid`; `The subagent tool is reserved`; `managed pi-subagents installed closure mismatch` / `install receipt mismatch`; `managed pi-subagents requires PI_SUBAGENTS_TEMP_ROOT bound to this Tron home's delegated artifact root before loading`; `managed pi-subagents unavailable` / `managed pi-subagents is not installed` | warnings and admission conflicts; closure mismatch fails startup | Managed provider admission (`managed-subagents.ts`): malformed `pi.extensions` entries, ignored user declarations (`counts.declarations`), invalid agent definitions (`counts.definitions`), a foreign claim on the `subagent` tool, tampered bytes or receipt, an unbound delegated temp root, no installed build; refuse, never repair in place |
| Native subagent `processActivities[].model` and counters; Native subagent `processActivities[].childSessionRef`; `tron.chat-invocation.v1` internal subagent wake; `session.extensionError` / `subagent-wake-admission-failed`; `tron.context-delivery.v4` managed producer origin | snapshot fields and canonical receipts; no log stream | Delegated attribution: a workflow row missing a model its child has means an incomplete host join; shared refs for resumed edges are not ambiguity; `source=subagentWake` with `origin.kind=subagent` marks a provider wake; a wake refused by prompt admission is reported, never replayed; `origin.owner` proves a managed producer, and only a wake binding yields `delivery=triggeredTurn` |

## Verify

```bash
scripts/tron verify --module gateway/run
scripts/tron test gateway src/sessions/runtime-registry.integration.test.ts \
  src/sessions/runtime-tool-loadout.integration.test.ts
```

Also `src/transport/session-archive.integration.test.ts` (session-replacing commands, fork
rows). Locks: `run.lock`, `run.store.lock`, `run-markers.lock` (`.integration.test.ts`).

## Not here

- Wire contracts: [transport](../transport/README.md). Projection rules:
  [`kernel/projection`](../kernel/projection/README.md). Delegated activity:
  [delegated activity](../kernel/delegation/delegated-activity.md).
- Settings applied through the slot: [admin](../admin/README.md). Home:
  [home](../modules/home/README.md). Terminal alerts: [notifications](../notifications/README.md).
- SDK upgrades and the behavior trace: [Pi SDK maintenance](../../docs/pi-sdk-maintenance.md).
