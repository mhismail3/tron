# Trust Audit Reliability, Retention, And Operator Readiness Phase

## Current Checkpoint

The module package substrate now supports operator-grade trust review without
adding a new persistence plane:

- `module::simulate_trust_change` explains renewal, rotation, expiry,
  revocation, source approval, reconciliation, and revocation-enforcement
  scenarios without mutating resources, grants, workers, queues, decisions, or
  evidence.
- `module::record_trust_review` recomputes the review server-side and stores
  bounded `evidence` linked to affected package and activation resources.
- `module::schedule_trust_audit` stores daily or weekly fixed wall-clock audit
  schedules as `decision` resources.
- `module::run_scheduled_trust_audit` writes bounded audit `evidence` for due
  schedule decisions, and the module runtime monitor enqueues due audits through
  the existing module queue.
- Control projections and generated UI surfaces advertise only canonical stored
  actions.

The invariant remains unchanged: no package/source/policy/conformance/trust/
audit tables, no marketplace, no remote fetch, no remote key discovery, no
dynamic UI catalog, no `control::act`, no iOS policy, no compatibility alias,
and no second worker-spawn path.

## Next Phase Objective

Harden trust audit operations for long-running use. The engine should make
scheduled audit behavior explainable across restarts, retries, missed windows,
operator review, retention cleanup, and generated UI action staleness without
adding durable scheduler or policy tables.

## Proposed Changes

- Add a pure read `module::trust_audit_status` projection for schedule
  decisions, latest evidence, due bucket, last queued bucket, missed buckets,
  affected refs, stale action refs, and retention warnings.
- Add `module::record_trust_audit_retention` as resource-backed evidence that
  records which old review/audit evidence is eligible for archival under
  existing resource retention policy. It must not delete bytes or rewrite
  history.
- Harden due-bucket calculation with explicit missed-window behavior:
  enqueue at most one current bucket per schedule tick, surface missed buckets
  as evidence/status, and never backfill mutation work without an explicit
  operator action.
- Extend generated package/trust/audit surfaces to show latest audit status,
  missed windows, stale schedules, and canonical actions for refresh, simulate,
  record review, run audit, expire schedule, reconcile, enforce, disable, and
  quarantine.
- Add manual-readiness docs for the full local package trust lifecycle:
  register source, verify signature/source, approve unsigned package, activate,
  simulate trust change, schedule audit, run audit, expire/revoke trust,
  enforce revocation, disable/quarantine, and verify cleanup.

## Test Plan

- Trust audit status returns only rebuildable projections from resources,
  evidence, decisions, queue items, grants, workers, and invocations.
- Missed-window scenarios produce status/evidence and do not enqueue backfill
  mutation work automatically.
- Duplicate due buckets remain idempotent across queue retries and completed
  queue records.
- Retention review marks eligible evidence only; it does not delete resources,
  rewrite versions, stop workers, revoke grants, or change activation lifecycle.
- Generated UI surfaces expose status and canonical stored actions without
  inlining large evidence bodies or action templates.
- Static gates continue to forbid trust/audit tables, remote fetch/discovery,
  marketplace symbols, dynamic UI catalogs, `control::act`, iOS policy,
  raw-scope authorization, direct module process spawn/kill, compatibility
  aliases, fallback manifest fields, and module action multiplexers.

## Verification

- Targeted Rust tests for audit status, missed windows, retention review,
  generated UI actions, queue idempotency, and static gates.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if Swift DTOs or
  Engine Console view state change.
- Update README, architecture docs, module docs, manual testing docs, and
  `~/LEDGER.jsonl`.
