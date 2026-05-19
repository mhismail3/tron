# Resource Kernel Ownership And Validation Simplification Phase

## Current Checkpoint

The activation runtime ownership slice is complete:

- runtime cleanup helpers live in `engine/primitives/module/activation_runtime.rs`;
- queue-backed local-process activation retries a transient spawn failure without
  duplicate grants, workers, activation versions, evidence resources, or queue
  completion state;
- the real Unix local-process path runs two activate -> health -> disable cycles
  through canonical `worker::spawn` and `sandbox::stop_spawned_worker`;
- static gates prevent runtime helper bodies from drifting back into
  `module.rs`;
- the maturity scorecard baseline is now `86/100`.

The next highest-value blocker is no longer activation cleanup. It is the size
and mixed ownership inside the generic resource kernel and generated-UI
validation surface.

## Objective

Simplify and harden the resource substrate without adding features or storage.
The goal is to make the resource kernel easier to audit from first principles:
type definitions, payload validation, version/blob integrity, links, lifecycle,
and UI-surface validation should each have a clear owner and focused tests.

No public capability ids, schemas, storage generation, resource kinds, iOS
surfaces, compatibility readers, fallback renderers, dynamic UI catalogs, or
new tables change in this phase.

## Proposed Changes

### 1. Build The Resource Ownership Map

- Inventory `engine/resources.rs`, `engine/primitives/resource.rs`,
  `engine/primitives/ui.rs`, resource tests, generated UI tests, docs, and
  static gates.
- Classify each responsibility as type definition, schema validation,
  version/blob integrity, link management, lifecycle/retention, materialization,
  UI-surface validation, control projection, or capability wrapper.
- Record the map in `docs/modular-engine-cleanup-audit.md` before moving code.

### 2. Split Only Stabilized Resource Concerns

Create focused resource-kernel modules only where ownership is clear and tests
already protect behavior. Candidate boundaries:

- `resources/types.rs`: built-in resource type definitions and allowed
  lifecycle/link/versioning declarations.
- `resources/validation.rs`: payload schema validation, lifecycle validation,
  redaction checks, and resource-kind contract checks.
- `resources/versions.rs`: version state, current-version rules, blob/hash
  integrity, damaged/quarantined/discarded handling, and CAS helpers.
- `resources/ui_surface.rs`: fixed-catalog `ui_surface` payload validation,
  component/action bounds, secret checks, expiry checks, and stored-action
  validation helpers.

The parent resource module should remain the store facade and durable substrate
contract, not a second policy plane.

### 3. Preserve Behavior With Characterization Tests

Before moving implementation bodies, add or strengthen tests that prove:

- built-in resource type registrations are unchanged;
- invalid payloads still fail before persistence;
- current versions can only point to available verified versions;
- damaged or missing bytes remain inspectable and are never silently rewritten;
- UI surfaces reject unknown catalogs, unsupported components, oversized
  payloads, raw secrets, stale actions, and client-authored target payloads;
- materialized files and patch proposals still return top-level `resourceRefs`;
- generated UI action submissions still execute only stored canonical actions.

### 4. Add Static Ownership Gates

Extend existing threat-model/static tests:

- resource type definition constants live in the resource type owner;
- UI-surface validation helpers live in the UI-surface validation owner, not in
  a control or iOS path;
- no new resource/control/UI tables exist;
- no fallback renderer, dynamic catalog, compatibility alias, or old DTO reader
  appears;
- no durable output path bypasses `resourceRefs`;
- no mutation lacks idempotency and an output contract.

Use ownership and forbidden-symbol gates, not brittle line-count checks.

### 5. Verification

- `cargo test resource_ --lib -- --nocapture`
- `cargo test generated_ui --lib -- --nocapture`
- targeted `cargo test --test threat_model_invariants -- --nocapture`
- `git diff --check`
- `scripts/tron ci fmt check clippy test`

iOS tests are not expected unless Swift DTOs or project files change.

## Acceptance Criteria

- The resource kernel has fewer mixed-concern files and clearer ownership.
- Public behavior and serialized wire/resource shapes remain stable.
- Static gates prove forbidden state planes and fallback paths did not appear.
- The maturity scorecard can move only when tests and docs prove the split.
- Docs and `~/LEDGER.jsonl` are updated in the same checkpoint.

## Out Of Scope

- New resource kinds.
- Storage generation changes.
- Generated UI catalog expansion.
- iOS renderer changes.
- Control-plane mutation shortcuts.
- Marketplace, remote package fetch, remote key discovery, or compatibility
  readers.
