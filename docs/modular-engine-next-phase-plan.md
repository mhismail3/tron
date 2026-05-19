# Package Source Distribution, Trust Roots, And Policy Audit Phase

## Current Checkpoint

The module runtime now has resource-native package trust and conformance:

- `worker_package` payloads are normalized with source trust, approval,
  conformance, and policy diagnostic fields;
- `module::verify_source` records source evidence and CAS-updates package source
  trust state;
- `module::approve_source` and `module::revoke_source_approval` create and
  update scoped operator `decision` resources;
- `module::policy_decide` explains allow/deny policy from package source
  evidence, approval decisions, conformance refs, scope, and requested child
  grants;
- `module::run_conformance` records bounded package/config/activation evidence;
- `module::activate`, `module::upgrade`, and `module::rollback` enforce source
  policy before deriving grants or spawning/binding workers;
- local unsigned `local_process` packages require verified source evidence plus
  an unexpired scoped source approval decision before activation;
- signature-bearing local packages fail closed until local trust roots and
  `module::verify_signature` exist;
- control and generated UI projections advertise source verification,
  conformance, and source approval actions as canonical capability targets.

This checkpoint still has no package tables, source tables, health tables,
policy tables, conformance tables, marketplace, dynamic UI catalog,
`control::act`, compatibility reader, client-side policy, or second worker
spawn path.

## Next Phase Summary

The next phase should move from "local digest-pinned packages can be approved"
to "package sources and trust roots are inspectable, revocable, and auditable
over time." Keep the same durable truth: resources, grants, invocations,
worker/catalog records, queues/leases, generated UI resources, evidence, and
decisions. Do not introduce package/source/policy tables or a marketplace.

## First-Principles Objective

A plug-and-play engine needs an answer for every package authority decision:

- Which source introduced this package manifest and bytes?
- Which local trust root, operator decision, or signature evidence allowed that
  source?
- Which packages and activations depend on a trust root or source decision?
- What becomes stale or unsafe when trust is revoked?
- Can an operator audit policy decisions without relying on hidden runtime
  state or an iOS-local cache?

## Planned Capabilities

- `module::register_source`
  - Resource-backed and idempotent.
  - Registers a local package source descriptor as a `decision`/`evidence`
    backed trust assertion, not a table.
  - Supports only local file/digest sources and local key refs in this phase.

- `module::verify_signature`
  - Resource-backed and idempotent.
  - Verifies package signatures against registered local trust roots or key refs.
  - Produces `evidence`; never fetches remote keys or package bytes.

- `module::audit_policy`
  - Pure read by default, with an optional resource-backed evidence mode.
  - Replays package source, approval, conformance, grant, activation, health,
    and revocation records to explain why a package is allowed, denied, stale,
    or quarantine-recommended.

- `module::reconcile_trust`
  - Resource-backed and idempotent.
  - Finds packages/activations affected by revoked source approvals, expired
    decisions, failed signature checks, or stale conformance.
  - Produces evidence and canonical recommendations only; it does not disable,
    quarantine, upgrade, or spawn workers.

## Policy Rules

- Trust roots are local resources/decisions with bounded scope and expiry.
- Remote package discovery, marketplace install, remote key discovery, and
  automatic trust promotion remain out of scope.
- Revoking a trust root or source approval makes dependent packages and
  activations stale through projections and evidence; explicit
  `module::quarantine`, `module::disable`, `module::upgrade`, or
  `module::rollback` remains the mutation path.
- Package source, signature, conformance, and policy audit evidence must be
  bounded, redacted, and linked to affected package/config/activation resources.
- Generated UI may advertise audit/reconcile actions, but `ui::submit_action`
  remains the only UI action gateway and must revalidate target revisions,
  grants, idempotency, and schemas.

## Test Plan

- Source registration rejects raw secrets, unsupported remote sources, invalid
  local paths, hash drift, malformed key refs, broader-than-caller trust scopes,
  and missing idempotency.
- Signature verification accepts only locally registered key refs and rejects
  unknown keys, mismatched digests, stale package versions, raw secret material,
  and unsupported algorithms.
- Policy audit reconstructs allow/deny/stale/quarantine recommendations from
  resource, grant, invocation, decision, and evidence history without any
  module-specific table.
- Trust reconciliation marks affected packages/activations stale via evidence
  and available canonical actions without stopping workers or changing grants.
- Static gates forbid package/source/policy/conformance tables, remote package
  fetches, dynamic UI catalogs, `control::act`, local iOS policy, raw-scope
  authorization, compatibility aliases, and direct process spawn/kill from
  `module::*`.

## Verification

- Targeted Rust tests for source registration, signature verification, policy
  audit, trust reconciliation, generated UI actions, and static gates.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if DTOs/views or
  project files change.
- Update README, architecture docs, progressive module/runtime docs, and
  `~/LEDGER.jsonl`.
