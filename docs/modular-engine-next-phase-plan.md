# Grant, Manifest, And UI Action Property Hardening Phase

## Current Checkpoint

The module primitive ownership split is complete:

- source-trust and trust-policy operations live in
  `engine/primitives/module/source_trust.rs`;
- health, integrity, conformance, and recovery entrypoint logic live in
  `engine/primitives/module/health_integrity.rs`;
- activation runtime cleanup, trust review, and scheduled trust audit ownership
  remain in their focused submodules;
- module activation tests are split by source-trust, health/integrity,
  trust-review, and lifecycle/runtime concern;
- static gates prevent these helpers from drifting back into the parent module
  primitive or adding package/source/policy/trust/audit/health tables;
- the maturity scorecard baseline is now `93/100`.

The next highest-value blocker is proof depth rather than another feature. The
engine has the right ownership boundaries, but the remaining risk is malformed
or adversarial inputs around grant selectors, package manifests, resource refs,
secret-like values, and generated UI action templates.

## Objective

Harden the substrate with property/failure-mode tests that prove malformed
grant, manifest, resource, and generated UI inputs fail closed before durable
mutation or handler execution.

This phase is a proof checkpoint. It must not add new public capability ids,
request/response schemas, storage generation, resource kinds, generated UI
catalogs, iOS surfaces, package tables, policy tables, trust tables, audit
tables, compatibility readers, fallback manifest fields, or worker-spawn paths.

## Implementation Plan

### 1. Grant Selector Property Tests

Add focused tests for grant narrowing and resource selector behavior:

- child grants cannot expand allowed capabilities, namespaces, authority labels,
  resource kinds/selectors, file roots, network policy, risk, expiry, approval,
  budget, visibility, or delegation;
- malformed wildcard/selector combinations are rejected or normalized exactly
  once by the grant substrate;
- revoked, expired, subject-mismatched, or stale-revision grants fail before
  handler execution;
- generated UI action submissions cannot widen the stored action grant or target
  selector.

Prefer deterministic table/property cases over broad string scans. Keep
authorization truth in `grant::*`; do not reintroduce raw scope authority.

### 2. Package Manifest And Source Trust Failure Tests

Add negative and boundary tests around `worker_package` manifests:

- malformed declared capabilities, duplicate function ids, namespace escapes,
  missing idempotency, missing output contracts, unsupported risk/effect,
  invalid runtime policies, raw secrets, and bad materialized file refs fail
  before persistence or activation;
- signed local packages reject stale trust roots, expired/rotated-only keys,
  selector mismatches, signature digest drift, unknown key refs, and malformed
  signature bytes;
- unsigned local packages still require current source verification plus scoped
  approval;
- conformance evidence remains evidence-only and never silently repairs package
  or activation resources.

Keep package state resource-native. No package/source/policy/conformance tables
or manifest compatibility aliases are allowed.

### 3. Resource Ref And Durable Output Failure Tests

Strengthen resource/output proof:

- resource refs with wrong kind, wrong version, stale current version, damaged
  bytes, missing blobs, or mismatched content hashes fail output-contract
  validation;
- resource-backed capabilities cannot claim durable output without top-level
  `resourceRefs`;
- materialized-file and patch flows leave prior current versions unchanged on
  hash/CAS failure;
- damaged resources remain inspectable and are not silently rewritten.

This is test/proof hardening only. Do not add a new storage generation or output
audit mode.

### 4. Generated UI Action Template Hardening

Add tests for server-authored `ui_surface` actions:

- stale surface versions, expired actions, unknown target functions, target
  revision drift, invalid user input, missing idempotency for mutating actions,
  unsupported catalog components, raw secrets, and oversized templates fail
  before child invocation;
- stored actions may target only canonical capabilities and may not let iOS
  supply target function ids, payload templates, grants, or policy decisions;
- generated package/trust/activation surfaces expose only bounded previews and
  refs, not large evidence bodies or secrets.

Keep iOS unchanged unless Swift decoding fails; the client remains a thin
renderer/action submitter.

## Tests And Static Gates

Add or strengthen static gates for:

- no raw-scope authorization;
- no package/source/policy/trust/audit/health/status tables;
- no fallback manifest fields or compatibility aliases;
- no dynamic UI catalog or fallback renderer;
- no `control::act` or module action multiplexer;
- no direct process spawn/kill from module code;
- no iOS local grant/package/policy/action-target construction.

Run focused tests first:

- grant/resource selector tests;
- module package/source-trust failure tests;
- generated UI action validation tests;
- resource output-contract tests;
- `cargo test module_ --lib -- --nocapture`;
- `cargo test generated_ui --lib -- --nocapture`;
- `cargo test --test threat_model_invariants -- --nocapture`.

Finish with:

- `git diff --check`;
- `scripts/tron ci fmt check clippy test`;
- iOS `xcodegen generate` and targeted `xcodebuild test` only if Swift or
  project files change.

## Acceptance Criteria

- The scorecard can move from `93/100` only if the new tests catch realistic
  malformed/adversarial inputs and all verification passes.
- No behavior broadening or new persistence is introduced.
- Failure-mode coverage is subsystem-specific and easier to read than broad
  string scans.
- Docs, scorecard, cleanup audit, and `~/LEDGER.jsonl` are updated in the same
  checkpoint.

## Out Of Scope

- New package trust features.
- New signature algorithms.
- Remote package distribution, marketplace install, or remote key discovery.
- Control-plane mutation shortcuts.
- iOS renderer or DTO changes unless forced by existing wire-shape decoding.
- Storage deletion/archive execution.
