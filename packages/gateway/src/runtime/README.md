# gateway/runtime

## Purpose

Session compaction policy on top of Pi's canonical settings and lifecycle.

## Owns

`compaction-policy.ts`: settings precedence, operation-bound policy, provider 413
classification and the `tron-compaction-policy` descriptor/extension.

## Contract

`compactionPolicyModule` supplies the extension at its existing registration
position. Its SessionContext compaction port reads the live policy, checks the
operation's stop fence, and publishes changes. The descriptor does not capture a
policy at Gateway startup. `CompactionOperationPolicy` retains the concrete
session and settings authority; the host sees only `restore` and `capture`.

## Invariants

- Restore at session start; check stop before capture, then publish, synchronously.
- No new store or settings schema. Pi remains the session and compaction owner.
- Oversized-request classification retains non-overflow provider errors unchanged.

## Entry points

`CompactionOperationPolicy`, `compactionPolicyModule`, `compactionPolicyExtension`.

## Signals

Compaction diagnostics are owned by [gateway/run](../sessions/README.md#signals).

## Verify

```bash
scripts/tron test gateway src/runtime/compaction-policy.integration.test.ts \
  src/sessions/run.lock.integration.test.ts
```

## Not here

Run admission and cancellation: [gateway/run](../sessions/README.md).
