# Run execution

## Purpose

Gateway-owned execution primitives layered on Pi's session loop.

## Owns

- `run-operations.ts`: shared run state, peer lifetimes, public admission/queue/Stop/
  compaction routes, configuration/idle admission gates and actual model/thinking/context/tools/bash algorithms.
- `run-events.ts`: agent, compaction and retry transitions, exact foreground/receipt
  settlement and successor fencing on the same run authority.
- `run-runtime.ts`: abstract native frame contract; settings provenance stays opaque.
- `bounded-tool-cancellation.ts`: per-call abort controllers, bounded cancellation
  settlement and rejection of late results.
- `direct-bash-process-owner.ts`: foreground shell process trees, timeout and abort
  cleanup, output settlement and private-environment filtering.

- `invocation-receipts.ts` and `context-delivery-receipts.ts`: canonical receipt
  parsing, folding, owned terminal facts and canonical inbox delivery; persisted bytes remain stable.
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
  final-run notification, exact terminal observers and held task/wake dispatch.
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

`RuntimeSlot` extends the kernel's `RunOperations`: one actual runtime object, not a
binding DTO or forwarded run algorithm. Peer owners read that authority directly;
there are no per-owner context interfaces, accessor/callback bundles or binding factories.
The native frame supplies SDK resources, physical publication and full Home policy/
identity effects. No run state is copied into it. Per-attempt observer registration
retains its raw promises and one live queue-decision callback, never a rebuilt context.
`RuntimeSlot` installs bounded tool cancellation on its Pi session and owns one
`DirectBashProcessOwner`. The process owner exposes the existing bash definition,
active-process state and joined abort operation; it does not own prompt admission.
`compactionPolicyModule` retains its registration position. Its live SessionContext
compaction port checks Stop before capture and publishes synchronously; policy restore
runs at session start. Settings resolution is injected from the admin settings
owner; compaction keeps operation capture, validation failures and budget
application, not an independent layer resolver. Pi remains canonical for files
and compaction execution.
Ownership is declared by [`gateway/run`](../../run.module.json).

## Invariants

Abort signals and grace periods, tool text, output and environment filtering remain
identical to Pi-backed Gateway execution. Cleanup targets only the owned process tree.
Oversized-request classification retains non-overflow provider errors unchanged.
A delegated task's root run marker belongs to task settlement, not to any one
successful reply. Attention still commits each reply, but never stamps that root
marker with a reply completion: notices and report reminders can continue the
same invocation. The dispatcher acknowledges the root marker after the immutable
result; independently owned wake turns retain ordinary completion stamping.

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
scripts/tron verify --module gateway/run
```

## Not here

Canonical Pi resource binding/publication and profiles remain with the concrete native
frame; delegated worker lifecycle is separate. Durable attention is owned by its store,
not by a second run-state authority.
