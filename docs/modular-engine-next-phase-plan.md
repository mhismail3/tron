# Package Trust, Policy Hardening, And Runtime Conformance Phase

## Current Checkpoint

The module runtime now has the substrate needed for safe local execution and
operator recovery:

- package lifecycle resources: `worker_package`, `module_config`, and
  `activation_record`;
- canonical lifecycle capabilities: `module::register_package`,
  `module::inspect_package`, `module::configure`, `module::activate`,
  `module::disable`, `module::upgrade`, `module::rollback`,
  `module::quarantine`, `module::check_health`, `module::verify_integrity`,
  and `module::recover_activation`;
- digest-pinned `local_process` activation through child `worker::spawn`, with
  manifest-declared materialized executable refs, expected functions, file
  roots, network policy, visibility, timeout, and child grant bounds;
- activation records that carry spawn lineage/result, health evidence refs,
  health child invocations, integrity diagnostics, worker lifecycle, recovery
  metadata, supersedes, and rollback target fields;
- scheduled health checks derived from active activation resources and enqueued
  through the existing `module` queue, with no health table;
- recovery that reconstructs partial or unsafe activation truth from invocation,
  grant, worker, and resource records, then revokes leaked grants and disconnects
  volatile workers without spawning replacements;
- control/generated UI projections that expose health, integrity, recovery, and
  module lifecycle actions as canonical capability targets;
- an end-to-end local-process integration test that activates a real
  `/engine/workers` process, runs health through the live worker, disables it
  through `sandbox::stop_spawned_worker`, and verifies no volatile worker remains
  registered.

This checkpoint still has no package tables, health tables, marketplace,
dynamic UI catalog, `control::act`, compatibility reader, client-side policy, or
second worker-spawn path.

## Next Phase Summary

The next phase should turn package execution from "digest-pinned local packages
can run safely" into "operators and agents can trust why a package is allowed to
run." The work is package source trust, runtime policy hardening, and conformance
evidence. It should keep the same durable truth: resources, grants, invocations,
worker/catalog records, queues/leases, and generated UI resources.

This phase must not add a package marketplace, package tables, health tables,
dynamic component catalogs, a control mutation multiplexer, local iOS policy, or
compatibility paths.

## First-Principles Objective

A plug-and-play engine has to answer these questions before a package receives
authority:

- What bytes are being executed, and are those bytes exactly the bytes the
  operator approved?
- Who or what source asserted the package manifest, and what trust tier does
  that source justify?
- What policy allows this package to run in this scope with this grant?
- Does the runtime behavior match the manifest after activation?
- Can the operator inspect all evidence without trusting hidden process state or
  client-local decisions?

The target state:

- source provenance is explicit and machine-checked before package registration;
- every package gets a bounded trust tier from verifiable evidence, not from a
  manifest string alone;
- runtime conformance tests prove declared capabilities, output contracts,
  risk/effect classes, redaction, health behavior, file roots, and network
  policy before activation is considered trustworthy;
- package policy violations produce evidence resources and quarantine/disable
  recommendations, not silent repairs;
- generated operator surfaces show package source, trust, conformance, health,
  integrity, and recovery state using refs/previews only.

## Non-Goals

- No remote marketplace or package discovery service.
- No storage generation bump unless an unsafe active schema incompatibility is
  discovered.
- No package, health, conformance, or policy tables.
- No dynamic third-party UI catalogs.
- No `control::act` or package action multiplexer.
- No client-side package/grant/policy decisions.
- No fallback manifest fields, aliases, retired route readers, or old DTO
  acceptance paths.

## Resource Model

Use existing resource kinds and add only resource type definitions if the current
schemas cannot represent the evidence cleanly.

- `worker_package`
  - Add source-trust fields to the payload contract: `sourceRef`,
    `sourceDigest`, `sourceTrustTier`, `signature`, `signatureKeyRef`,
    `signatureVerification`, `operatorApprovalRef`, and `conformanceEvidenceRef`.
  - Keep local unsigned packages as `local_digest_pinned`; they require explicit
    operator authority and approval evidence.

- `evidence`
  - Use for signature verification, digest verification, conformance run output,
    policy decisions, network/file-root observations, and quarantine reasons.
  - Store bounded diagnostics and redacted previews only.

- `decision`
  - Use for operator/package policy decisions such as "approved local package
    source for scope X until expiry Y" or "quarantine because conformance failed."

- `ui_surface`
  - Continue using generated surfaces for package trust and conformance views.
  - Do not store full package files, command output, payload templates, or raw
    secrets in surfaces.

## Capability Additions

Add explicit capabilities under the existing `module` primitive. Each mutation
must be idempotent and resource-backed.

- `module::verify_source`
  - Verifies package source refs, materialized file hashes, package digest,
    optional signature material, source trust tier, and operator approval refs.
  - Produces `evidence`; updates package diagnostics through CAS only when the
    target is a `worker_package`.
  - Does not fetch remote package bytes in this phase.

- `module::run_conformance`
  - Executes a bounded conformance plan against a registered package/config or
    active activation.
  - Verifies declared functions, schemas, effect/risk classes, output contracts,
    idempotency metadata, redaction, health mode, grant bounds, file roots, and
    network policy.
  - Produces `evidence` and links it to package/config/activation resources.
  - May invoke read-only package functions under the activation grant; mutating
    probes require declared scratch resources and explicit operator approval.

- `module::policy_decide`
  - Pure policy evaluation with no side effects beyond optional evidence when
    invoked through a resource-backed wrapper.
  - Inputs are package/config/activation refs, target scope, requested grant, and
    operator intent.
  - Output explains allow/deny/quarantine recommendations and required approvals.

- `module::approve_source`
  - Resource-backed operator decision that approves a local digest-pinned source
    for a specific package digest, scope, trust tier ceiling, grant ceiling, and
    expiry.
  - Never expands package authority; it only records a decision resource that
    `register_package` / `activate` can require.

- `module::revoke_source_approval`
  - Resource-backed decision lifecycle update.
  - Active packages that depend on the revoked decision become integrity-warning
    targets; automatic disable remains explicit policy, not a hidden side effect.

## Policy Rules

- Package manifests are untrusted until `module::verify_source` has produced
  valid evidence and any required `decision` resource exists.
- A manifest-declared trust tier is only a request. The engine computes the
  effective trust tier from provenance, signature evidence, operator decisions,
  digest pinning, and package source policy.
- Local unsigned packages may run only as `local_digest_pinned` with explicit
  approval scoped to package digest, package id/version, scope, grant ceiling,
  file roots, network policy, expiry, and operator actor.
- Package source approval does not imply activation approval. Activation still
  derives a narrower child grant and validates runtime registration.
- Conformance failure does not silently mutate package bytes, config, or grants.
  It produces evidence and available canonical actions such as quarantine,
  disable, rollback, rerun conformance, or refresh UI.
- Revoked source approval makes dependent activations integrity-stale. Recovery
  may clean leaked authority, but replacement remains activate/upgrade/rollback.
- Raw secrets in manifests, source evidence, signatures, conformance output,
  generated UI, logs, or iOS caches are rejected unless represented as
  `secret_ref`/vault handles with redacted previews.

## Runtime Conformance

Conformance should run in bounded phases:

1. Static manifest check: schema, namespace, function ids, idempotency,
   resource-backed outputs, risk/effect, config schema, runtime entrypoint,
   file refs, digest, source approval, and redaction.
2. Grant simulation: requested activation grant is proven narrower than caller
   grant, source policy, package required grants, and target scope.
3. Registration check: spawned or bound worker registers exactly the declared
   functions or a narrower allowed subset when the package explicitly supports
   optional functions.
4. Health check: catalog or invoke-function health produces evidence within
   timeout and redaction bounds.
5. Resource-output check: resource-backed functions return top-level
   `resourceRefs`; read-only functions do not produce durable output.
6. Cleanup check: disable/quarantine/recovery revoke grants and disconnect
   volatile workers through canonical lifecycle APIs.

## Control And Generated UI

Control remains read-only. `control::snapshot` and `control::inspect` should
project:

- package source trust summary;
- latest source verification evidence;
- latest conformance evidence;
- source approval decisions and expiry;
- active activations affected by revoked/stale source decisions;
- available canonical actions for verify source, approve/revoke source,
  run conformance, activate, disable, rollback, quarantine, recover, and refresh
  surface.

Generated surfaces should show bounded evidence previews and refs. Actions must
be stored in `ui_surface` resources, target canonical functions only, include
target revisions, carry idempotency templates for mutations, and be revalidated
by `ui::submit_action`.

## iOS Scope

iOS remains a renderer/action submitter:

- decode added source trust, conformance, approval, and integrity summaries if
  server DTOs expose them;
- render generated surfaces strictly from inspected `ui_surface` resources;
- cache only redacted read-only previews;
- submit only surface id, version id, action id, user input, and idempotency key;
- do not construct package manifests, grants, source approval policy, target
  function ids, command templates, or conformance payloads locally.

## Test Plan

Write failing tests first:

- `module::verify_source` accepts digest-pinned local package refs only when
  file hashes and manifest digest match, and rejects missing refs, hash drift,
  raw secrets, unsupported provenance, stale package versions, or forged trust
  tier.
- `module::approve_source` creates scoped decision resources and refuses broader
  trust/grant/file/network authority than the caller grant allows.
- `module::revoke_source_approval` marks dependent package/activation integrity
  stale through evidence/projections without deleting package bytes.
- `module::run_conformance` catches schema drift, missing output contracts,
  mutating functions without idempotency, over-risk registration, grant
  expansion, health failure, raw secret output, and cleanup leakage.
- Existing `module::activate` requires valid source/conformance evidence where
  package policy demands it and still works for approved built-ins.
- Duplicate source verification, approval, revocation, and conformance keys
  replay existing evidence/decisions without duplicate resource versions.
- Generated package/integrity surfaces advertise only canonical stored actions
  and stale actions fail before target execution.
- Real local-process integration continues to prove activate, health, disable,
  quarantine, and recovery leave no leaked active grants or volatile workers.

Static gates:

- no package/source/conformance/health tables;
- no direct process spawn/kill from `module::*`;
- no public worker creation API except `worker::spawn`;
- no `control::act`;
- no dynamic UI catalog;
- no iOS local package/grant/source policy;
- no raw-scope authorization;
- no compatibility aliases, retired route names, fallback manifest fields, or
  old storage readers.

## Verification

- Targeted Rust tests for source verification, source approval/revocation,
  conformance, activation policy integration, generated UI actions, and local
  process cleanup.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if DTOs/views or
  project files change.
- Update README, architecture docs, progressive module/runtime docs, and
  `~/LEDGER.jsonl`.
