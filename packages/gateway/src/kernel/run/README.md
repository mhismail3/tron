# Run execution

## Purpose

Gateway-owned execution primitives layered on Pi's session loop.

The K1 native Registry (`../session/runtime-registry.ts`) implements `SessionOperations` directly: one canonical
map/construction/mutation authority, shared synchronous `liveRuntime` read and
mutex-ordered `orderedRuntime` read. Profile modules supply domain recipes over
those operations; no Registry-produced Home provider exists. The actual K2 frame is
`runtime-slot.ts`; the runtime pair retains the `gateway/run` logical owner.
Worker binding/control is K5-owned, separate from physical native ownership.
Its control identity and shared diagnostics are K5 contracts (`worker-contract.ts`),
not dependencies on a module's dispatcher. K5's `WorkerSettlement` owns task-end waiters
and bounded joins; native activity/canonical publications wake that same owner. Provider
control execution is K5-owned; native admission and canonical receipt ordering remain here.
K5 owns the canonical worker-attribution map; native catalog/attention batching
keeps its original publication/acknowledgement order and reads that single index.
The registry composes one real K5 DelegationOperations shared by Home/automations;
its single native interruption operation preserves K2 abort-reason identity and
capture/steer/abort ordering. Home has no native control I/O binding.
K5 owns worker report/budget/reminder finish-turn policy and resumed-worker
lease/bind/failure-release orchestration. Native pipeline installation passes the
same frame, SDK runtime object and captured report owner, without copied state or
an early diagnostic-sink read. The existing K5 `OwnedTurnOwner` holds the single live
worker binding and validates/rebinds it in the actual native lane. Creation seeds that
owner once; every native reader uses it directly. Native SDK rebuild and publication
remain backend I/O, with no Slot bind route or Registry worker-resume wrapper.
Home uses the actual SessionOperations
for canonical worker reads, leases and mutation ordering, with no duplicate worker input.
K5 owns cold artifact proof; Native supplies the admitted resource input, not a proof wrapper.
K5 also owns canonical subagent settlement. Its runtime port reads the actual
native canonical/activity/controller projections and work owner, then calls native
canonical append; no Slot settlement wrapper or duplicate token index exists.
Worker steering packets and Stop/Interrupt identity fences are K5-owned as well; the
former Slot-specific control methods are absent. Generic per-tool interruption stays Run-owned.
The frame composes one K5 `OwnedTurnOwner`: its sole observer map and held-task
continuation state replace native held-turn ownership. Admission and disposal address
that owner directly; canonical terminal classification/receipt and SDK abort I/O stay
native. The Slot has no task-cancellation forwarding route.
Ordinary extension registration reads the composition-configured order on the
actual K3 host; native frames do not select product modules or keep another list.

## Owns

- `../session/runtime-registry.ts`: actual K1 runtime membership, acquisition,
  mutation lanes, eviction and disposal; catalog parsing has its separate owner.
- `runtime-slot.ts`: actual K2 Pi/native frame, extending the same `RunOperations`.

- `run-operations.ts`: shared run state, peer lifetimes, public admission/queue/Stop/
  compaction routes, configuration/idle admission gates and actual model/thinking/context/tools/bash algorithms.
- `run-events.ts`: agent, compaction and retry transitions, exact foreground/receipt
  settlement and successor fencing on the same run authority.
- `run-runtime.ts`: native frame contract and canonical SDK readers; settings provenance stays opaque.
  Selected-branch projections include the header; worker state and sealed task evidence remain file-wide.
  Native SDK reconstruction, canonical evidence and physical publication stay with the concrete frame;
  the single K5 owned-turn authority holds worker binding and live task state.
- `bounded-tool-cancellation.ts`: per-call abort controllers, bounded cancellation
  settlement and rejection of late results.
- `direct-bash-process-owner.ts`: foreground shell process trees, timeout and abort
  cleanup, output settlement and private-environment filtering.

- `invocation-receipts.ts` and `context-delivery-receipts.ts`: canonical receipt
  parsing, folding, owned terminal facts and canonical inbox delivery; persisted bytes remain stable.
  Settings wakes bind the actual admitted input and use `gateway:settings` attribution.
  Home selects outcomes through its bounded, cancellable input envelope for both user
  turns and wakes; the native before-agent-start hook selects only ordinary requesters.
  A wake captures its actual request-policy cancellation cell and epoch before
  asynchronous selection. Native Stop and retirement invalidate that same logical
  lifetime across physical frame replacement; lane and SDK-send cuts reject stale
  preparation. Ordinary sessions retain their physical cancellation lifetime.
  Ordinary outcome acknowledgement requires the bounded canonical reader's durable
  file-and-directory proof; failed proof defers without refusing the prompt.
  Root supplies its actual settings instances directly to Home and installs the
  same owners in Registry; there is no public Registry settings read detour.
  Root starts expiry after initialization/observer setup. Registry disposal joins
  that installed engine before releasing shared stores or Home's workspace.
- `run-markers.ts`: durable per-operation crash/interruption evidence.
- `run-persistence.ts`: sole pending-receipt join and durable-write fence, bounded
  retry/retention, conflicts and actual SDK stop/diagnostic cuts through the native frame.
- `gateway-work-registry.ts`: bounded admission/drain tokens and joined settlement.
- `run-work-owner.ts`: exact per-operation handles, retirement and marker-before-token
  orphan repair, with live retained-owner rechecks after persistence.

- `compaction-policy.ts`: operation-bound settings budgets, signal-fenced summary
  generation, provider 413 classification and the `tron-compaction-policy` descriptor.
- `run-abort-owner.ts`: foreground cancellation intent, exact settlement and accepted
  Stop steering recovery, with live SDK/queue ownership rechecks across awaits.
- `run-queue-owner.ts`: SDK queue identities, reconciliation, pending admission and shared
  revision/ordinal clock, retaining exact work owners across Pi callback gaps.
- `queue-commands.ts`: serialized clear/replace, receipt settlement, resource validation
  and shared text/resource/queue bounds; public run ports return its promises directly.
- `held-prompt-queue.ts`: accepted compaction/Stop-time input and its ordered deferred
  admission, edit/removal and flush lifetime; `queue-input.ts` owns shared input types/bounds.
- `completion-facts.ts` / `run-attention.ts`: canonical completion evidence,
  runtime ownership lane, full settlement/reconciliation and rebind scope.
- `run-terminal.ts`: operation observation and the bounded presentation latch,
  final-run notification and canonical terminal classification. K5 owns held task/wake dispatch.
  A waiting episode is claimed before notification admission suspends, so overlapping
  terminals share it; failed admission releases only its still-current episode.
- `run-invocations.ts`: live invocation/failure state, canonical terminal dedupe,
  exact Stop attribution, transferred joins and bounded origin-command handoff.
- `manual-compaction.ts`: manual admission/claim, deferred receipt, lane handoff,
  SDK execution, automatic adoption and exact cancellation/settlement lifetime.
- `prompt-admission.ts` and `prompt-input.ts`: serialized ordinary admission,
  exact SDK disposition, resource/intent preparation and opaque caller fences.
- `prompt-attempt.ts`: each SDK prompt/command promise, admission finalization and
  no-agent/command settlement, preserving live successor ownership across receipt I/O.
- `request-pipeline.ts`: per-runtime request settings scope and provider-option
  replacement, live conversion/preparation and ordered stream-policy composition.

## Contract

The native registry retains runtime membership. `runtimeEntries()` supplies a disposable,
insertion-ordered read snapshot; domain catalogs select and format that view outside the
registry. It is not a second runtime owner or membership cache. `retireIdleRuntime`
keeps physical retirement and exact resource checks native; Home supplies its uncertain-
publication selection, eligibility and refusal policy over those operations.

`RuntimeSlot` extends the kernel's `RunOperations`: one actual runtime object, not a
binding DTO or forwarded run algorithm. Peer owners read that authority directly;
there are no per-owner context interfaces, accessor/callback bundles or binding factories.
The native frame supplies SDK resources, physical publication and full Home policy/
identity effects. Explicit model changes ask the live profile’s constraint before SDK
publication; native admission reads its physical-selection metadata. No provider API marker
or Home-specific model refusal lives in the run engine. No run state is copied into it. Per-attempt observer registration
retains its raw promises and one live queue-decision callback, never a rebuilt context.
`RuntimeSlot` installs bounded tool cancellation on its Pi session and owns one
`DirectBashProcessOwner`. The process owner exposes the existing bash definition,
active-process state and joined abort operation; it does not own prompt admission.
`compactionPolicyModule` retains its registration position. Its live SessionContext
compaction port checks Stop before capture and publishes synchronously; policy restore
runs at session start. Settings resolution is injected from the admin settings
I/O owner through K6 admission; compaction keeps operation capture, validation failures and budget
application, not an independent layer resolver. Pi remains canonical for files
and compaction execution.
Branch summaries bypass agent request preparation: native and extension navigation
resolve the branch reserve through K6 immediately before SDK summarization, without
reloading fixed resource/shell settings. The cancellation owner's epoch revokes that
preparation if Stop arrives before the SDK creates its abort controller. Cache-warming mode is captured at chat
construction; changing Global mode does not republish it to an existing SDK manager.
Ownership is declared by [`gateway/run`](../../run.module.json).

## Invariants

Abort signals and grace periods, tool text, output and environment filtering remain
identical to Pi-backed Gateway execution. Cleanup targets only the owned process tree.
Oversized-request classification retains non-overflow provider errors unchanged.
A delegated task's root run marker belongs to operation settlement, not to any
one successful reply. Attention still commits each reply, but never stamps that
root marker with a reply completion: notices and report reminders can continue
the same invocation. Terminal invocation cleanup or the task's final acknowledgement
retires the root marker. Cold task recovery acknowledges any remaining root marker
after the task result is durable, preserving other operations in that session.
Independently owned wake turns retain ordinary completion stamping.

### Bounded lifecycle conformance

`task-lifecycle.reference-model.ts` states quiescent task laws independently of
the run implementation. Its normal-lane `task-lifecycle.conformance.integration.test.ts`
drives real Registry/Pi sessions, durable task/marker stores and a faux provider:
start, steering, tool-interrupt without executing tools, Stop, report, same-session
resume, terminal Stop and observation. Seeded
fast-check commands check each step; a controlled late notice delays the second
real completion stamp until after invocation settlement. The model checks terminal
run release, immutable predecessor result identity and one distinct durable result
wake per operation. It does not prove child-process joining, wake delivery, arbitrary
interleavings, trust, or queue FIFO. Replay generated traces with `TRON_MODEL_SEED`
and the reported `TRON_MODEL_PATH`;
artifacts are written to `packages/gateway/test-results/kernel-run-lifecycle.json`.

## Entry points

`RuntimeSlot` in [`sessions`](../../sessions/README.md) installs these
primitives. `direct-bash-process-owner.integration.test.ts` exercises real shells,
detached descendants, timeout, Stop and environment boundaries.

## Signals

Existing aborted/timed-out command errors and bounded-tool cancellation results;
no additional logging or persisted state. Compaction diagnostics remain with the
[session run owner](../../sessions/README.md#signals).

| Signal | Meaning / diagnosis |
|---|---|
| `terminal-receipt-persistence-failed` | A completion ownership write failed. For a terminal Home task whose socket snapshot still says `running` without an operation, compare its canonical replies and task marker: a root task marker must not own an individual reply completion. `home-task-continuity.e2e.test.ts` reproduces the conflicting-stamp ordering and proves same-session resume. |

## Verify

```bash
scripts/tron test gateway src/kernel/run/direct-bash-process-owner.integration.test.ts src/kernel/run/run-markers.lock.integration.test.ts src/kernel/run/run.store.lock.integration.test.ts
scripts/tron test gateway src/kernel/run/compaction-policy.integration.test.ts
scripts/tron test gateway src/sessions/runtime-control-publication.integration.test.ts
scripts/tron test gateway src/sessions/annotation-only-steer.integration.test.ts
scripts/tron test gateway src/kernel/run/task-lifecycle.conformance.integration.test.ts
scripts/tron verify --module gateway/run
```

## Not here

Canonical Pi resource binding/publication and profiles remain with the concrete native
frame; delegated worker lifecycle is separate. Durable attention is owned by its store,
not by a second run-state authority.
