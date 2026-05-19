# Module Primitive Ownership And Policy Boundary Phase

## Current Checkpoint

The resource/UI ownership split is complete:

- `engine/resources/mod.rs` is now a small facade with stable re-exports;
- resource substrate types, built-in definitions, generic validation, version
  hashing, fixed-catalog `ui_surface` validation, and store implementations
  each have focused files;
- stored generated-UI validation and action-submission checks live in
  `engine/primitives/ui/validation.rs`;
- resource/materialization tests live in `engine/tests/resource_kernel.rs`;
- static gates prevent resource definitions, UI-surface validation, and
  generated-UI action validation from drifting back into mixed owners;
- the maturity scorecard baseline is now `90/100`.

The next highest-value blocker is the parent module primitive. `module.rs`
still owns package lifecycle dispatch, source trust, source approvals,
signature verification, policy decisions, conformance, health, integrity,
recovery, activation orchestration, and shared helper glue. Runtime cleanup,
trust review, and scheduled trust audits have already been split; the remaining
goal is to reduce module policy ownership without adding behavior.

## Objective

Simplify and harden the module primitive by moving stabilized source-trust and
health/integrity/recovery concerns into focused submodules while preserving all
public capability ids, request/response schemas, output contracts, idempotency,
generated UI actions, storage generation, resource kinds, and operator behavior.

This phase is a refactor/proof checkpoint. It must not add package tables,
policy tables, trust tables, conformance tables, health tables, status caches,
dynamic UI catalogs, marketplace flow, remote fetch, remote key discovery,
`control::act`, iOS policy, compatibility aliases, or a second worker-spawn path.

## Proposed Ownership Split

### 1. Source Trust Boundary

Create `engine/primitives/module/source_trust.rs` for source and trust-root
policy that is already stable:

- `module::verify_source`;
- `module::approve_source`;
- `module::revoke_source_approval`;
- `module::policy_decide`;
- `module::register_source`;
- `module::verify_signature`;
- `module::audit_policy`;
- `module::record_policy_audit`;
- `module::reconcile_trust`;
- `module::inspect_trust`;
- `module::renew_trust_root`;
- `module::rotate_signature_key`;
- `module::expire_trust_decision`;
- `module::enforce_revocation`;
- source/trust helper structs, digest/signature checks, trust graph traversal,
  effective trust calculation, and policy diagnostics.

The parent `module.rs` should remain the registration/dispatch and package
lifecycle coordinator. Source-trust code may compose existing resource, grant,
invocation, and generated-UI helpers, but it must not create a policy state
plane or action multiplexer.

### 2. Health And Integrity Boundary

Create `engine/primitives/module/health_integrity.rs` for package runtime
evidence checks that are already represented as resources:

- `module::check_health`;
- `module::verify_integrity`;
- `module::recover_activation` coordination that is not already runtime
  cleanup-owned;
- health policy parsing;
- invoke-function health validation;
- integrity diagnostics over package/config/activation/grant/worker state;
- evidence payload shaping and redaction for health/integrity results.

Keep activation runtime cleanup helpers in `activation_runtime.rs`. The new
health/integrity boundary may call those helpers for recovery cleanup, but it
must not reimplement grant revocation, volatile worker disconnect, local process
spawn/kill, or activation runtime diagnostics.

### 3. Parent Module Role

After the split, `module.rs` should own only:

- public function registration and dispatch;
- package/config/activation entrypoints;
- activation/upgrade/rollback orchestration;
- shared resource/grant/invocation helper glue that is genuinely cross-cutting;
- submodule imports and re-exports needed by host/control/UI projections.

No behavior broadening is allowed. If a helper has unclear ownership, keep it in
the parent and document why rather than creating a new abstraction.

## Tests And Static Gates

Write characterization/static tests first:

- source-trust capability ids, request schemas, response shapes, output
  contracts, and generated UI action behavior remain unchanged;
- health, integrity, and recovery capability ids and resource-backed evidence
  behavior remain unchanged;
- source-trust helper implementations live in `source_trust.rs`, not
  `module.rs`;
- health/integrity helper implementations live in `health_integrity.rs`, not
  `module.rs`;
- activation runtime helpers stay in `activation_runtime.rs`;
- parent `module.rs` remains dispatch/orchestration, not a second policy plane;
- no direct process spawn/kill appears in any module submodule except canonical
  worker/sandbox lifecycle composition;
- no package/source/policy/trust/audit/health/status tables appear;
- no `control::act`, dynamic UI catalog, module action multiplexer, raw-scope
  authorization, fallback manifest field, compatibility alias, or iOS policy
  path appears.

Run focused tests after each split:

- `cargo test module_ --lib -- --nocapture`;
- `cargo test generated_ui --lib -- --nocapture`;
- `cargo test --test threat_model_invariants -- --nocapture`;
- any existing local-process activation integration test if touched helpers
  affect recovery or health;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

## Acceptance Criteria

- Public behavior is unchanged.
- Module source-trust and health/integrity code has clear file ownership.
- The parent module file becomes easier to scan and reason about.
- Static gates prevent helper drift back into the parent module.
- Resource/evidence/grant/invocation substrate remains the only durable truth.
- Docs, scorecard, cleanup audit, and `~/LEDGER.jsonl` are updated in the same
  checkpoint.

## Out Of Scope

- New package trust features.
- Signature algorithm expansion.
- Remote marketplace, remote package fetch, or remote key discovery.
- New resource kinds or storage generation changes.
- iOS renderer or DTO changes.
- Control-plane mutation shortcuts.
- Retention deletion/archive execution.
