# True Modularity Boundary Evidence Manifest

Status: **active**
Current score: **80/100**
Branch: `codex/primitive-engine-teardown`

This manifest records evidence for the True Modularity Boundary campaign. Each
checkpoint must update the scorecard row, evidence row, open-loop state, and
verification commands before the checkpoint commit.

## Checkpoints

| ID | Status | Change | Verification | Open loops | Commit |
|---|---|---|---|---|---|
| TMB-0 | passed_after_fix | Created the formal scorecard, evidence manifest, README links, and `true_modularity_boundary_invariants` integration target. | First run: `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` exits red after compiling: 11 tests run, 2 passed, 9 failed. | TMB-1 through TMB-10 remain open. | `0247d57c1` |
| TMB-1 | passed_after_fix | Added the Markdown inventory and machine-readable TSV with 929 tracked Rust/Swift source rows, seven boundary classes, owner labels, dependency-direction rules, and the allowed composition-root list. | `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants boundary_inventory_covers_tracked_sources -- --nocapture` passes. Full target remains red on later implementation phases. | TMB-2 through TMB-10 remain open. | `b24e417e8` |
| TMB-2 | passed_after_fix | Added `domains::model::responder` as the model-output black-box API, replaced agent/runtime provider dependencies with `ModelResponderFactory`, made provider implementations crate-private, removed broad provider re-exports, deleted `turn_runner/provider.rs`, removed noncanonical reasoning parser spellings, and moved canonical token accounting to `domains::model::tokens`. | `cargo check --manifest-path packages/agent/Cargo.toml`; `cargo test --manifest-path packages/agent/Cargo.toml --lib model -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --lib turn_runner -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants agent_loop_uses_model_responder_boundary -- --nocapture` all pass. Full TMB target remains red by design: 11 tests run, 4 passed, 7 failed (`provider_internals_do_not_escape_model_domain`, `engine_facade_is_the_only_cross_module_engine_api`, `state_stores_are_owner_private`, `transport_is_adapter_only`, `ios_ui_uses_repositories_not_engine_transport`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-3 through TMB-10 remain open. Model-provider dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | `99d076cb9` |
| TMB-3 | passed_after_fix | Narrowed engine facade ownership by making engine submodules crate-private, re-exporting required runtime metadata constants and `ExternalWorkerInvoker` through `engine/mod.rs`, and replacing non-engine imports of `engine::invocation`, `engine::kernel`, and `engine::runtime` internals with facade imports. | `cargo check --manifest-path packages/agent/Cargo.toml` and `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants engine_facade_is_the_only_cross_module_engine_api -- --nocapture` pass. Full target remains red by design: 11 tests run, 5 passed, 6 failed (`provider_internals_do_not_escape_model_domain`, `state_stores_are_owner_private`, `transport_is_adapter_only`, `ios_ui_uses_repositories_not_engine_transport`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-4 through TMB-10 remain open. Model-provider dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | `62937b20f` |
| TMB-4 | passed_after_fix | Hardened domain worker boundaries by making `domains::registration::register_domain_workers_for_context` crate-private behind `transport::runtime::setup::register_server_domains_for_context` and extending the invariant to reject public worker-module constructors, non-central registration callers, and runtime/transport/app imports of domain handlers, services, deps, or operations. | `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants domain_workers_expose_contracts_not_services -- --nocapture` passes. Full target remains red by design: 11 tests run, 5 passed, 6 failed (`provider_internals_do_not_escape_model_domain`, `state_stores_are_owner_private`, `transport_is_adapter_only`, `ios_ui_uses_repositories_not_engine_transport`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-5 through TMB-10 remain open. The full pass count did not increase because the TMB-4 guard was already green before this checkpoint; the completed work strengthened it and narrowed visibility. Model-provider dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | `a5e22e219` |
| TMB-5 | passed_after_fix | Encapsulated state/storage access by removing the raw `EventStore::pool()` escape, moving log-table ingestion and recent-log queries into typed event-store methods, changing deep health to query through `EventStore`, replacing blob/latest-event direct repository calls with event-store methods, routing settings/auth loader consumers through narrow facades, removing concrete engine store re-exports from the engine facade, and tightening the static guard around storage-owner and composition-root prefixes. | `cargo check --manifest-path packages/agent/Cargo.toml`; `cargo test --manifest-path packages/agent/Cargo.toml --lib list_recent_logs_applies_trace_and_session_scope -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution execute_log_recent_exposes_bounded_session_trace_logs -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants state_stores_are_owner_private -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` all ran. Targeted guard and focused tests pass. Full target remains red by design: 11 tests run, 6 passed, 5 failed (`provider_internals_do_not_escape_model_domain`, `transport_is_adapter_only`, `ios_ui_uses_repositories_not_engine_transport`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-6 through TMB-10 remain open. Provider and engine dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | `d440a216e` |
| TMB-6 | passed_after_fix | Made transport adapter-only by replacing `EngineStreamEventPump`'s direct `TurnAccumulatorMap` dependency with the shared `TronEventObserver` contract, implemented the observer in the agent-owned accumulator module, and updated stream-pump tests to use a no-op observer. | `cargo check --manifest-path packages/agent/Cargo.toml`; `cargo test --manifest-path packages/agent/Cargo.toml --lib pump_publishes_runtime_events_to_engine_streams_once -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants transport_is_adapter_only -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` all ran. Targeted guard and focused stream-pump test pass. Full target remains red by design: 11 tests run, 7 passed, 4 failed (`provider_internals_do_not_escape_model_domain`, `ios_ui_uses_repositories_not_engine_transport`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-7 through TMB-10 remain open. Provider and engine dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | `addf273ca` |
| TMB-7 | passed_after_fix | Black-boxed iOS Engine access by routing SwiftUI/session code through `ChatSessionServices` and protocol repositories, adding connection/live-event/settings/auth/message repository contracts, translating settings/auth wire DTOs into snapshots and mutations at the engine repository boundary, moving settings reload through repositories, and updating provider/settings/onboarding tests plus architecture docs. | `cd packages/ios-app && xcodegen generate`; `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ModelPickerStateTests -only-testing:TronMobileTests/SessionSwitchingTests`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants ios_ui_uses_repositories_not_engine_transport -- --nocapture`; `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` all ran. Targeted iOS tests and tightened iOS guard pass. Full target remains red by design: 11 tests run, 8 passed, 3 failed (`provider_internals_do_not_escape_model_domain`, `boundary_errors_do_not_leak_impl_errors`, `final_modularity_closeout_is_complete`). | TMB-8 through TMB-10 remain open. Provider and engine dead-code warnings remain visible and are carried into later cleanup; no `allow` attributes were added. | checkpoint commit |
| TMB-8 | open | Boundary-local error contracts are not complete yet. | Pending. | Implementation-detail error leakage still needs static enforcement. | pending |
| TMB-9 | open | Final docs are not complete yet. | Pending. | README, Rust module docs, iOS docs, and inventory finalization remain open. | pending |
| TMB-10 | open | Final closeout is not complete yet. | Pending. | Full CI and adversarial closeout remain open. | pending |

## TMB-0 Red Proof

The first invariant run is intentionally red. It must prove the harness observes
the current architecture instead of only checking that files exist.

Observed leak categories at harness creation:

- Rust agent loop imports `domains::model::providers` directly instead of a
  model-owned responder boundary.
- Provider factory and provider health types cross into server and agent
  dependency bundles.
- Engine, domain worker, state/store, transport, iOS Engine access, and boundary
  error rules are not yet fully inventoried or guarded.
- Observed failing guards on the first red run:
  `boundary_inventory_covers_tracked_sources`,
  `agent_loop_uses_model_responder_boundary`,
  `provider_internals_do_not_escape_model_domain`,
  `engine_facade_is_the_only_cross_module_engine_api`,
  `state_stores_are_owner_private`, `transport_is_adapter_only`,
  `ios_ui_uses_repositories_not_engine_transport`,
  `boundary_errors_do_not_leak_impl_errors`, and
  `final_modularity_closeout_is_complete`.
- After TMB-1, `boundary_inventory_covers_tracked_sources` passes; the full
  target remains red with 3 passed and 8 failed tests, matching the open
  implementation and closeout rows.
- After TMB-2, `agent_loop_uses_model_responder_boundary` passes. Provider
  implementations are crate-private, the agent loop no longer imports
  `domains::model::providers`, and remaining full-target failures belong to
  TMB-3 through TMB-10. The full target now reports 4 passed and 7 failed
  guards.
- After TMB-3, `engine_facade_is_the_only_cross_module_engine_api` passes.
  Engine implementation modules are crate-private and non-engine callers use
  facade re-exports for runtime metadata constants and external worker
  invocation.
- After TMB-4, `domain_workers_expose_contracts_not_services` passes. Domain
  worker registration is crate-private behind transport runtime setup, worker
  module constructors are not public, and runtime/transport/app code cannot
  import domain handler, service, deps, or operation internals.
- After TMB-5, `state_stores_are_owner_private` passes. Non-owner code no
  longer opens event-store pools or log SQL directly, log storage lives behind
  typed event-store methods, and the guard permits only documented storage
  owners, shared observability/storage, central error mapping, engine storage
  owners, and bootstrap composition roots.
- After TMB-6, `transport_is_adapter_only` passes. Transport no longer imports
  agent loop accumulator internals; runtime event fanout goes through the shared
  `TronEventObserver` contract while accumulator state remains owned by the
  agent domain.
- After TMB-7, `ios_ui_uses_repositories_not_engine_transport` passes.
  SwiftUI/session layers consume repository protocols and view models instead
  of concrete engine transport; settings/auth wire DTOs are translated into
  repository snapshots and mutations at the engine-owned adapter boundary.

The red run is evidence for TMB-0 only. Later checkpoints must remove these
active leak descriptions once the corresponding implementation phase is closed.
