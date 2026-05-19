# Activation Runtime Ownership And Stress Soak Phase

## Current Checkpoint

The activation runtime cleanup slice is implemented without adding a new durable
plane:

- local-process activation still launches only through canonical `worker::spawn`;
- spawn failure, missing registration, over-broad registration, persistence
  failure, and manual recovery failure are covered by deterministic tests;
- post-spawn failures revoke derived grants and stop spawned workers through
  canonical lifecycle capabilities before returning;
- `module::recover_activation` records `manual_recovery_required` evidence when
  cleanup cannot be proven complete;
- `module::inspect_package` reports cleanup/recovery status, leaked grant refs,
  leaked worker refs, latest recovery evidence refs, and canonical next actions;
- static gates cover the activation runtime diagnostic path and continue to
  forbid direct process spawn/kill, package/source/policy/trust/audit/health/
  cleanup tables, `control::act`, raw-scope authorization, compatibility paths,
  dynamic UI catalogs, and module action multiplexers;
- the maturity scorecard baseline is now `82/100`.

The invariant remains unchanged: resources, resource versions, links, grants,
invocations, worker/catalog records, queues/leases, decisions, evidence, and
generated UI resources are the only durable substrate.

## Next Phase Objective

Make activation runtime ownership easier to reason about and prove the cleanup
path under longer-running stress. The goal is to improve code comprehensibility
without weakening the newly hardened activation behavior.

## Proposed Changes

- Split the stabilized activation runtime diagnostics and cleanup helpers out of
  `engine/primitives/module.rs` into a focused module-primitive submodule.
- Keep public function ids, schemas, output contracts, idempotency keys,
  generated UI actions, and storage generation unchanged.
- Add a deterministic queue-backoff stress test for activation/health/recovery
  retry paths, proving retries do not duplicate grants, workers, activation
  versions, evidence resources, or child invocations.
- Add a bounded local-process soak test that exercises activate, health,
  disable, recover, and re-activate cycles through the real `worker::spawn`
  implementation where practical.
- Keep diagnostics projection-only; any mutation must remain a canonical
  `module::*`, `worker::*`, `grant::*`, or `ui::*` capability.
- Continue proof-driven cleanup of deferred domain/iOS product-shell surfaces
  only when call graph, route, DTO, navigation, and test evidence proves they
  are removable.

## Test Plan

- Activation runtime submodule static gates prove cleanup helpers no longer live
  directly in the parent module file.
- Queue retry tests cover transient activation and health failures under
  existing queue backoff and idempotency.
- Soak tests prove repeated activation/disable/recovery cycles leave no active
  leaked grant or volatile worker.
- Generated UI and control tests continue to expose only canonical recovery,
  disable, quarantine, check-health, verify-integrity, and refresh actions.
- Static gates continue to forbid package/source/policy/trust/audit/health/
  cleanup tables, dynamic UI catalogs, `control::act`, raw-scope authorization,
  direct module process spawn/kill, fallback manifest fields, compatibility
  aliases, iOS local policy, and module action multiplexers.

## Verification

- Targeted Rust tests for activation runtime ownership, queue retries, local
  process soak, generated UI action staleness, and static gates.
- `cargo test module_ --lib -- --nocapture`.
- `cargo test generated_ui --lib -- --nocapture`.
- Targeted `cargo test module_package_activation_gates_stay_on --test threat_model_invariants -- --nocapture`.
- `scripts/tron ci fmt check clippy test`.
- `git diff --check`.
- iOS `xcodegen generate` and targeted `xcodebuild test` only if Swift DTOs or
  Engine Console state change.
