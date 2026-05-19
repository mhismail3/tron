# Package Trust Operations, Key Rotation, And Revocation Enforcement Phase

## Current Checkpoint

Package activation is now explainable from substrate truth:

- `module::register_source` records local digest-source decisions, local
  Ed25519 trust-root decisions, and source/trust revocations as resource-backed
  `decision` plus `evidence` records.
- `module::verify_signature` verifies signed local packages against registered
  local trust roots using `tron.module.package_manifest.v1\n{packageDigest}`;
  successful verification CAS-updates `worker_package` trust fields and returns
  canonical `resourceRefs`.
- `module::audit_policy` reconstructs allow/deny policy from resources,
  decisions, evidence, grants, activations, health, and revocations without
  writing state.
- `module::record_policy_audit` persists the same bounded audit as `evidence`.
- `module::reconcile_trust` writes stale-trust evidence and recommendations for
  affected packages/activations without disabling, quarantining, killing
  workers, revoking grants, or repairing bytes.
- `module::activate`, `module::upgrade`, and `module::rollback` run the shared
  source-policy resolver before grant derivation or worker spawn/bind.
- Control projections and generated UI surfaces advertise trust-root,
  signature, policy audit, audit recording, and reconciliation actions as stored
  canonical capability actions.

The checkpoint still has no package/source/policy/conformance tables, remote
package fetch, remote key discovery, marketplace, dynamic UI catalog,
`control::act`, iOS policy, compatibility alias, or second worker-spawn path.

## Next Phase Objective

Move from "trust decisions are recorded and auditable" to "trust operations are
safe over time." The engine should help an operator rotate keys, renew/expire
trust, inspect dependency impact, and choose explicit remediation actions while
preserving the same durable substrate: resources, resource versions, decisions,
evidence, grants, invocations, worker/catalog records, queues/leases, and
generated UI resources.

## First-Principles Questions

- Which packages and active workers depend on each trust root or source
  decision?
- What exact evidence must be refreshed before a package remains activatable?
- How does an operator rotate a trust root without hidden global mutation?
- When trust is revoked, what authority is merely stale versus actively unsafe?
- Which actions are recommendations, and which actions actually revoke grants or
  stop workers?
- How do generated operator surfaces stay deterministic and non-authoritative?

## Proposed Capabilities

- `module::inspect_trust`
  - Pure read.
  - Inspects one trust-root/source/approval/revocation decision and returns
    dependent package refs, activation refs, evidence refs, expiry, revocation
    state, and canonical available actions.

- `module::renew_trust_root`
  - Resource-backed and idempotent.
  - Creates a new trust-root `decision` with explicit supersedes links; it does
    not mutate the previous decision in place.
  - Rejects broader selectors, trust ceiling, grant ceiling, file roots,
    network policy, expiry, or scope than the caller grant permits.

- `module::rotate_signature_key`
  - Resource-backed and idempotent.
  - Records rotation intent and evidence linking old and new trust-root
    decisions. It does not re-sign package bytes or invent signature evidence.

- `module::expire_trust_decision`
  - Resource-backed lifecycle update.
  - Marks a trust/source decision expired and records evidence; dependent
    packages and activations become stale through projections/reconciliation.

- `module::enforce_revocation`
  - Resource-backed and idempotent.
  - Explicit operator mutation that can disable/quarantine affected activations
    by composing canonical `module::disable` or `module::quarantine`.
  - Requires approval for live authority changes and never multiplexes arbitrary
    actions.

## Policy Rules

- Trust renewal and rotation create new decisions and links; they never rewrite
  historical trust evidence.
- Revocation evidence alone does not stop workers. Only explicit canonical
  disable/quarantine/rollback/upgrade capabilities change live authority.
- Every trust operation must be replayable from resources, decisions, evidence,
  grants, invocations, and worker/catalog state.
- Generated UI may surface recommendations and stored actions, but server-side
  policy remains final through `ui::submit_action` and target capability
  validation.
- No remote key discovery, remote package fetch, marketplace, dynamic catalog,
  table-backed trust cache, client-side policy, fallback reader, or compatibility
  alias is introduced.

## Test Plan

- Trust inspection returns complete bounded dependency graphs for trust roots,
  source registrations, approvals, revocations, packages, and activations.
- Renewing a trust root creates a new decision, links it with `supersedes`, and
  rejects broader scope or authority than the caller grant allows.
- Rotation evidence links old and new trust roots without fabricating signature
  verification for existing packages.
- Expiring a trust decision makes dependent package policy audits deny or stale
  without deleting package bytes or stopping workers.
- Enforcing revocation composes canonical disable/quarantine paths, requires
  approval for live authority, revokes grants through grant capabilities, and is
  idempotent.
- Generated UI exposes only stored canonical actions and stale submissions fail
  before target execution.
- Static gates continue to forbid package/source/policy/conformance tables,
  remote fetches, dynamic UI catalogs, `control::act`, iOS policy, raw-scope
  authorization, direct process spawn/kill from `module::*`, compatibility
  aliases, and fallback manifest fields.

## Verification

- Targeted Rust tests for trust inspection, renewal, rotation, expiry,
  revocation enforcement, generated UI actions, and static gates.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if server DTOs or
  Engine Console view state change.
- Update README, architecture docs, module docs, and `~/LEDGER.jsonl`.
