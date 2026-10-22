# Run execution

## Purpose

Gateway-owned execution primitives layered on Pi's session loop.

## Owns

- `bounded-tool-cancellation.ts`: per-call abort controllers, bounded cancellation
  settlement and rejection of late results.
- `direct-bash-process-owner.ts`: foreground shell process trees, timeout and abort
  cleanup, output settlement and private-environment filtering.

- `invocation-receipts.ts` and `context-delivery-receipts.ts`: canonical receipt
  parsing, folding and delivery causality; persisted names and bytes remain stable.
- `run-markers.ts`: durable per-operation crash/interruption evidence.
- `run-persistence.ts`: sole pending-receipt join and durable-write fence, bounded
  retry/retention and conflict handling; the slot supplies live Pi stop/diagnostic cuts.
- `gateway-work-registry.ts`: bounded admission/drain tokens and joined settlement.
- `run-work-owner.ts`: exact per-operation handles, retirement and marker-before-token
  orphan repair, with live retained-owner rechecks after persistence.

- `compaction-policy.ts`: operation-bound settings budgets, signal-fenced summary
  generation, provider 413 classification and the `tron-compaction-policy` descriptor.
- `run-abort-owner.ts`: foreground cancellation intent, exact settlement and accepted
  Stop steering recovery, with live SDK/queue ownership rechecks across awaits.
- `run-queue-owner.ts`: SDK queue identities, reconciliation, pending admission and shared
  revision/ordinal clock, retaining exact work owners across Pi callback gaps.
- `held-prompt-queue.ts`: accepted compaction/Stop-time input and its ordered deferred
  admission, edit/removal and flush lifetime; `queue-input.ts` owns shared input types/bounds.
- `request-pipeline.ts`: per-runtime request settings scope and provider-option
  replacement, live conversion/preparation and ordered stream-policy composition.

## Contract

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

## Entry points

`RuntimeSlot` in [`sessions`](../../sessions/README.md) installs these
primitives. `direct-bash-process-owner.integration.test.ts` exercises real shells,
detached descendants, timeout, Stop and environment boundaries.

## Signals

Existing aborted/timed-out command errors and bounded-tool cancellation results;
no additional logging or persisted state. Compaction diagnostics remain with the
[session run owner](../../sessions/README.md#signals).

## Verify

```bash
scripts/tron test gateway src/kernel/run/direct-bash-process-owner.integration.test.ts src/kernel/run/run-markers.lock.integration.test.ts src/kernel/run/run.store.lock.integration.test.ts
scripts/tron test gateway src/kernel/run/compaction-policy.integration.test.ts
scripts/tron verify --module gateway/run
```

## Not here

Prompt admission, canonical Pi appends, profiles, queue commands and compaction orchestration remain with
`RuntimeSlot`; delegated worker lifecycle is separate.
