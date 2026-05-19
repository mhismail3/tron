# Runtime Stress, Recovery, And Cleanup-Leak Hardening Phase

## Current Checkpoint

The trust-audit reliability slice is implemented without adding a new durable
plane:

- `module::trust_audit_status` is a pure read projection over schedule
  decisions, queue items, audit evidence, affected refs, missed windows, and
  retention warnings.
- `module::record_trust_audit_retention` writes bounded advisory `evidence` for
  old audit evidence and does not delete bytes, archive resources, revoke
  grants, stop workers, or mutate schedules.
- `module::schedule_trust_audit` stores `retentionPolicy.reviewAfterDays` in the
  schedule decision metadata.
- `module::expire_trust_decision` can archive `module_trust_audit_schedule`
  decisions through the canonical trust-decision expiry path.
- Host trust-audit enqueue uses module-owned due-bucket and completed-evidence
  helpers, queues at most the current bucket, skips queued/completed buckets,
  and never backfills missed buckets automatically.
- Control and generated UI expose schedule status, run, retention review, and
  expiry through canonical stored actions.
- The maturity scorecard baseline is now `77/100`.

The invariant remains unchanged: no package/source/policy/conformance/trust/
audit tables, no marketplace, no remote fetch, no remote key discovery, no
dynamic UI catalog, no `control::act`, no iOS policy, no compatibility alias,
and no second worker-spawn path.

## Next Phase Objective

Harden runtime reliability under repeated retries, interrupted local-process
workers, worker-registration timeouts, leaked grants/workers, missed maintenance
ticks, and cleanup failures. The target is to make package execution safe under
stress before adding more package distribution or UI functionality.

## Proposed Changes

- Add deterministic stress tests for local-process activation, health checks,
  disable/quarantine, queue retries, and recovery using actual `worker::spawn`
  paths where practical.
- Strengthen activation cleanup evidence when spawn, health, grant derivation,
  worker registration, or post-spawn validation fails.
- Add projection-only diagnostics for leaked grants/workers after interrupted
  activation and recovery; any mutation must remain `module::recover_activation`,
  `module::disable`, or `module::quarantine`.
- Harden queue idempotency and retry behavior for module activation, health,
  scheduled audits, and trust review actions under duplicate submissions.
- Continue splitting stable module/runtime code only where ownership becomes
  clearer and no public behavior changes.

## Test Plan

- Repeated activation/disable/quarantine cycles leave no active leaked grant or
  volatile worker.
- Failed spawn, delayed registration, bad capability registration, health
  timeout, and cleanup failure produce bounded evidence and inspectable
  activation records.
- Duplicate queue retries replay or reject idempotently without duplicate
  workers, grants, invocations, resource versions, or evidence resources.
- Recovery reconstructs interrupted activations from substrate truth and never
  spawns replacements or upgrades packages.
- Static gates continue to forbid package/source/policy/trust/audit tables,
  dynamic UI catalogs, `control::act`, raw-scope authorization, direct module
  process spawn/kill, fallback manifest fields, compatibility aliases, iOS
  local policy, and module action multiplexers.

## Verification

- Targeted Rust tests for module runtime stress, cleanup leakage, recovery,
  queue retries, generated UI action staleness, and static gates.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if Swift DTOs or
  Engine Console view state change.
- Update README, architecture docs, cleanup audit, scorecard, module docs, and
  `~/LEDGER.jsonl`.
