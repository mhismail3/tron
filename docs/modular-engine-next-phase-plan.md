# Operator Projection Consequence And Deferred Domain Output Audit Phase

## Current Checkpoint

The grant, manifest, resource-ref, and generated UI hardening checkpoint is
complete:

- focused grant-authority tests prove child grant narrowing and failed prepare
  behavior across grant dimensions;
- package manifest tests reject duplicate declared function ids, raw
  secret-like values, unsafe local-process command refs, and unsupported
  local-process visibility before package persistence;
- resource-kernel tests reject malformed/wrong-kind `resourceRefs` without
  recording produced refs;
- generated UI action tests reject invalid input and stale target revisions
  before child invocation;
- static gates keep the proof cases in their owning test modules;
- the maturity scorecard baseline is now `95/100`.

## Objective

Close the next maturity gap by making operator projections explain consequences
and by auditing deferred domain outputs that still predate the collapsed
resource substrate.

This phase should remain proof-driven. It must not add public capability ids,
request/response schemas, storage generation, resource kinds, generated UI
catalogs, iOS policy, compatibility readers, fallback DTOs, package/source/
policy/trust/audit tables, or alternate worker-spawn paths.

## Implementation Plan

### 1. Operator Projection Consequence Tests

Add targeted tests for `control::inspect`, `module::inspect_package`,
`module::inspect_trust`, `ui::validate_surface`, and generated target surfaces
that prove stale/rejected actions explain:

- target function/resource/grant revision that caused staleness;
- required canonical next action;
- whether the action is safe, approval-gated, or high-risk;
- which resource/evidence/grant/worker refs support the recommendation;
- why the server rejected a submitted action.

Keep this projection-only. Do not add `control::act`, local iOS policy, status
tables, or cached operator state.

### 2. Deferred Domain Durable Output Audit

Build a proof map for the remaining high-scrutiny domains listed in the cleanup
audit: notifications, prompt library, AgentControl/source-change sheets,
browser/display/device, transcription, and voice notes.

For each domain, classify current durable output as:

- already resource-backed;
- ephemeral/projection-only;
- still event/session-store backed and acceptable for the thin chat harness;
- remove candidate;
- convert-to-resource candidate.

Back each decision with route/capability registration, caller, DTO, test, or
docs evidence. Remove only when proof shows the path is unreachable, duplicated,
or architecture-violating.

### 3. Static Gates And Absence Proof

Add static/absence gates for any retired domain output or product-shell state
removed in this phase. Preserve existing gates forbidding raw-scope
authorization, dynamic UI catalogs, `control::act`, compatibility aliases,
fallback manifest fields, module action multiplexers, package/source/policy/
trust/audit tables, and direct module process spawn/kill.

### 4. Documentation And Scorecard

Update the cleanup audit with the domain-output proof map and any removal or
defer decisions. Update the maturity scorecard only after tests pass; target
movement is `95/100` to `97/100` if operator projection consequence coverage and
at least one deferred domain-output audit/removal are completed with proof.

## Verification

Run focused Rust tests for control projections, generated UI validation,
module package/trust inspection, and any touched domain. Finish with:

- `cargo test generated_ui --lib -- --nocapture`;
- `cargo test module_ --lib -- --nocapture`;
- targeted domain tests for audited/removed domains;
- `cargo test --test threat_model_invariants -- --nocapture`;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

Run iOS `xcodegen generate` and targeted Engine Console/source-guard tests only
if Swift/project files change.

## Out Of Scope

- New package trust features or signature algorithms.
- Remote package distribution, marketplace install, or remote key discovery.
- Control-plane mutation shortcuts.
- iOS policy or local action construction.
- Storage deletion/archive execution.
