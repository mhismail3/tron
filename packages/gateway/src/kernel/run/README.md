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

- `request-pipeline.ts`: per-runtime request settings scope and provider-option
  replacement, live conversion/preparation and ordered stream-policy composition.

## Contract

`RuntimeSlot` installs bounded tool cancellation on its Pi session and owns one
`DirectBashProcessOwner`. The process owner exposes the existing bash definition,
active-process state and joined abort operation; it does not own prompt admission.
Ownership is declared by [`gateway/run`](../../run.module.json).

## Invariants

Abort signals and grace periods, tool text, output and environment filtering remain
identical to Pi-backed Gateway execution. Cleanup targets only the owned process tree.

## Entry points

`RuntimeSlot` in [`sessions`](../../sessions/README.md) installs these
primitives. `direct-bash-process-owner.integration.test.ts` exercises real shells,
detached descendants, timeout, Stop and environment boundaries.

## Signals

Existing aborted/timed-out command errors and bounded-tool cancellation results;
no additional logging or persisted state.

## Verify

```bash
scripts/tron test gateway src/kernel/run/direct-bash-process-owner.integration.test.ts src/kernel/run/run-markers.lock.integration.test.ts src/kernel/run/run.store.lock.integration.test.ts
scripts/tron verify --module gateway/run
```

## Not here

Prompt admission, canonical Pi appends, profiles, queue and compaction remain with
`RuntimeSlot`; delegated worker lifecycle is separate.
