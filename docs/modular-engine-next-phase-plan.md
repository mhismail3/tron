# Package Trust Review, Simulation, And Scheduled Audit Phase

## Current Checkpoint

The module package substrate now supports local trust operations without adding a
new persistence plane:

- source registrations, trust roots, approvals, revocations, renewals,
  rotations, expirations, policy audits, reconciliations, conformance checks,
  health checks, integrity checks, and recovery records are `decision` or
  `evidence` resources plus typed links;
- `module::inspect_trust` exposes bounded dependency graphs for package trust
  targets;
- `module::renew_trust_root`, `module::rotate_signature_key`, and
  `module::expire_trust_decision` make key lifecycle changes explicit and
  auditable;
- `module::enforce_revocation` is the only trust-operation capability that
  mutates live activation authority, and it composes canonical
  `module::disable` or `module::quarantine` child invocations;
- `module::activate`, `module::upgrade`, and `module::rollback` still resolve
  package source policy before grant derivation or worker spawn/bind;
- control projections and generated UI surfaces advertise only canonical stored
  actions.

The invariant remains unchanged: no package/source/policy/conformance/trust
tables, no marketplace, no remote fetch, no remote key discovery, no dynamic UI
catalog, no `control::act`, no iOS policy, no compatibility alias, and no second
worker-spawn path.

## Next Phase Objective

Move from per-target trust operations to operator-grade trust review and
simulation. The engine should be able to answer, without mutating state:

- what would happen if this trust root expires, is renewed, is revoked, or is
  replaced;
- which packages, activations, grants, workers, generated UI surfaces, and
  pending actions would be affected;
- which remediation action is safe, required, optional, or blocked;
- what evidence is missing before activation, upgrade, rollback, or revocation
  enforcement can proceed.

Any persisted output from this phase remains bounded `evidence`. Projections and
iOS caches stay rebuildable and read-only.

## Proposed Capabilities

- `module::simulate_trust_change`
  - Pure read.
  - Inputs: target decision/package/activation, proposed operation
    (`expire`, `renew`, `rotate`, `revoke`, `enforce_disable`,
    `enforce_quarantine`), proposed bounds, and optional activation ids.
  - Returns allow/deny/blocked, affected refs, policy deltas, grant deltas,
    missing prerequisites, stale generated UI refs, and recommended canonical
    actions.

- `module::record_trust_review`
  - Resource-backed, idempotent.
  - Persists a bounded review or simulation as `evidence` linked to affected
    trust decisions, packages, activations, grants, and workers.
  - It never changes trust status or live authority.

- `module::schedule_trust_audit`
  - Resource-backed, idempotent.
  - Records an operator decision describing a rebuildable scheduled audit policy
    for a scope. Execution still uses the existing queue/invocation substrate;
    there is no trust-audit table.
  - Initial schedules should be limited to daily or weekly fixed wall-clock
    checks.

- `module::run_scheduled_trust_audit`
  - Resource-backed, idempotent.
  - Derives due audit work from active schedule decisions, runs the same policy
    audit/reconciliation/simulation path, and writes bounded `evidence`.

## Security Rules

- Simulation cannot mint grants, approve trust, modify decisions, stop workers,
  or rewrite resources.
- Scheduled audit decisions cannot authorize activation or enforcement; they
  only authorize periodic evidence creation within the caller's grant ceiling.
- A scheduled audit must fail closed if its grant, scope, selectors, or target
  revisions are stale or revoked.
- Generated UI must show simulations as read-only evidence until the operator
  submits a stored canonical mutation such as `module::renew_trust_root`,
  `module::expire_trust_decision`, `module::enforce_revocation`,
  `module::disable`, `module::quarantine`, `module::rollback`, or
  `module::upgrade`.
- Raw secrets remain forbidden in review evidence, simulation diagnostics,
  generated UI, logs, and iOS cache.

## Test Plan

- Simulations explain renewal, rotation, expiry, revocation, disable, and
  quarantine scenarios without writing state.
- Simulations reject broader proposed selectors, grant ceilings, file roots,
  network policy, trust ceilings, expiry, or scope than the caller grant permits.
- Recorded reviews write bounded evidence and required links, and replay
  idempotently.
- Scheduled audit decisions validate scope, cadence, selectors, authority, and
  idempotency without creating a table.
- Scheduled runs derive work from decisions, produce evidence, and do not mutate
  live activation authority.
- Control/generated UI expose simulation and review actions as canonical stored
  actions; stale action submissions fail before target execution.
- Static gates continue to forbid trust tables, remote fetch/discovery,
  marketplace symbols, dynamic UI catalogs, `control::act`, iOS policy,
  raw-scope authorization, direct module process spawn/kill, compatibility
  aliases, fallback manifest fields, and package action multiplexers.

## Verification

- Targeted Rust tests for trust simulation, review evidence, scheduled audit
  decisions, scheduled audit runs, generated UI actions, and static gates.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if server DTOs or
  Engine Console view state change.
- Update README, architecture docs, module docs, and `~/LEDGER.jsonl`.
