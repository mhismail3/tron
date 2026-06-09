# True Modularity Boundary Evidence Manifest

Status: **active**
Current score: **5/100**
Branch: `codex/primitive-engine-teardown`

This manifest records evidence for the True Modularity Boundary campaign. Each
checkpoint must update the scorecard row, evidence row, open-loop state, and
verification commands before the checkpoint commit.

## Checkpoints

| ID | Status | Change | Verification | Open loops | Commit |
|---|---|---|---|---|---|
| TMB-0 | passed_after_fix | Created the formal scorecard, evidence manifest, README links, and `true_modularity_boundary_invariants` integration target. | First run: `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` exits red after compiling: 11 tests run, 2 passed, 9 failed. | TMB-1 through TMB-10 remain open. | pending |
| TMB-1 | open | Boundary taxonomy inventory is not complete yet. | Pending. | Inventory coverage and dependency direction rules remain open. | pending |
| TMB-2 | open | Model responder boundary is not complete yet. | Pending. | Agent loop still depends on provider internals. | pending |
| TMB-3 | open | Engine facade narrowing is not complete yet. | Pending. | Engine internals still need inventory-backed exceptions or owner-private visibility. | pending |
| TMB-4 | open | Domain worker boundary hardening is not complete yet. | Pending. | Domain service/internal imports still need cleanup. | pending |
| TMB-5 | open | State and storage encapsulation is not complete yet. | Pending. | Direct backend/store/SQL imports still need cleanup. | pending |
| TMB-6 | open | Transport adapter-only cleanup is not complete yet. | Pending. | Transport/domain dependency direction still needs static enforcement. | pending |
| TMB-7 | open | iOS Engine access black-boxing is not complete yet. | Pending. | SwiftUI/session dependency cleanup remains open. | pending |
| TMB-8 | open | Boundary-local error contracts are not complete yet. | Pending. | Implementation-detail error leakage still needs static enforcement. | pending |
| TMB-9 | open | Final docs are not complete yet. | Pending. | README, Rust module docs, iOS docs, and inventory finalization remain open. | pending |
| TMB-10 | open | Final closeout is not complete yet. | Pending. | Full CI and adversarial closeout remain open. | pending |

## TMB-0 Red Proof

The first invariant run is intentionally red. It must prove the harness observes
the current architecture instead of only checking that files exist.

Expected leak categories at harness creation:

- Rust agent loop imports `domains::model::providers` directly instead of a
  model-owned responder boundary.
- Provider factory and provider health types cross into server and agent
  dependency bundles.
- Engine, domain worker, state/store, transport, iOS Engine access, and boundary
  error rules are not yet fully inventoried or guarded.
- Observed failing guards: `boundary_inventory_covers_tracked_sources`,
  `agent_loop_uses_model_responder_boundary`,
  `provider_internals_do_not_escape_model_domain`,
  `engine_facade_is_the_only_cross_module_engine_api`,
  `state_stores_are_owner_private`, `transport_is_adapter_only`,
  `ios_ui_uses_repositories_not_engine_transport`,
  `boundary_errors_do_not_leak_impl_errors`, and
  `final_modularity_closeout_is_complete`.

The red run is evidence for TMB-0 only. Later checkpoints must remove these
active leak descriptions once the corresponding implementation phase is closed.
