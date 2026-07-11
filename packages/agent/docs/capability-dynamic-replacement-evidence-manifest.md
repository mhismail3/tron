# Capability Dynamic Replacement Evidence Manifest

Status: **foundational runtime route complete**

This manifest records the source-backed evidence for the first dynamic
replacement slice. The slice adds governed route records and a scoped
`git_status` route seam that resolves an active route, verifies lifecycle and
runtime refs, projects supervised module-runtime provider-safe output, and
fails closed when the replacement boundary is unsafe. Engine Cockpit also
projects server-owned route-story cards so route changes, failures, and
rollback availability are visible before operation-level drill-down. It does not claim full
autonomous self-update across every operation.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Operation dispatcher | `packages/agent/src/domains/capability/operations/dispatch.rs` |
| Git route seam | `packages/agent/src/domains/capability/operations/git.rs` |
| Provider schema fields | `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Capability contract guidance | `packages/agent/src/domains/capability/contract.rs` |
| Route service | `packages/agent/src/domains/capability_binding/route.rs` |
| Module runtime projection boundary | `packages/agent/src/domains/module_runtime/service.rs` |
| Route authority | `packages/agent/src/domains/capability_binding/authority.rs` |
| Cockpit route projection | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| Route resource definitions | `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |
| Grant authorization | `packages/agent/src/engine/authority/grants/authorization.rs` |
| iOS cockpit DTOs | `packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+CapabilityCockpit.swift` |
| iOS cockpit state | `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` |
| iOS cockpit UI | `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift`; `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift`; `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift` |
| Modularity inventory | `packages/agent/docs/capability-modularity-inventory.tsv` |
| Canonical README | `README.md` |

## Evidence

| Claim | Evidence |
|---|---|
| Route operations are provider-visible only through `capability::execute`. | Registry and dispatch add `capability_replacement_candidate_*`, `capability_route_binding_*`, `capability_route_activate`, `capability_route_disable`, `capability_route_rollback`, and `capability_route_event_*` operations. |
| Route operations are governance-locked, not adapter-replaceable. | `operation_binding_metadata` and `capability-modularity-inventory.tsv` classify all replacement/route operations as `capability_binding` / `governance_locked`. |
| Kernel and governance operations remain non-routable. | The route service accepts only the first target operation, `git_status`, and the modularity invariants reject binding/rollback seams for locked rows. |
| Candidate records are bounded and provider-safe. | `route.rs` validates unsafe payloads, bounded text/tokens/refs, exact target metadata, route authority, rollback controls, idempotency, exact current accepted `capability_shadow_trial_evidence` resource/version proof, exact lifecycle/runtime resource selectors, current lifecycle/runtime versions, the supervised module-runtime projection boundary, and `networkPolicy: none`. |
| Candidate lifecycle/runtime refs can come from the governed module path. | `capability_binding::tests::route_candidate_accepts_refs_created_by_module_lifecycle_and_runtime_operations` seeds the install-decision prerequisite, records and approves a `module_lifecycle_state` through `module_lifecycle_request`/`module_lifecycle_decision`, records a `module_runtime_state` through `module_runtime_request`, and proves `capability_replacement_candidate_record` accepts those current refs only after runtime projection-boundary validation. |
| Activation is explicit and approval-backed. | `capability_route_activate` requires a ready binding, exact expected binding version, accepted shadow-evidence proof captured by the binding, approval refs, rollback/disable controls, exact selectors, and `networkPolicy: none`. |
| The first route lifecycle is agent-facing. | `capability_binding::tests::capability_execute_dispatch_controls_full_route_lifecycle` records the candidate, records the route binding, activates the route, disables it, and rolls it back through `capability::execute`, proving the workflow is reachable through the same single tool surface Tron uses. |
| The shadow trial workflow is agent-facing. | `capability_binding::tests::capability_execute_dispatch_controls_shadow_trial_workflow` records the shadow-trial request, records the decision, records the run, and inspects accepted evidence through `capability::execute`, proving the pre-activation trial path is reachable through the same single tool surface Tron uses. |
| Route lookup is exact-scope and fail-closed. | `active_route_for_git_status` derives trusted session/workspace scope, lists active route activations in that scope, verifies binding/candidate refs against the activation/binding expected current versions plus accepted current shadow evidence, skips terminal route events, rejects multiple active `git_status` routes in the same scope instead of choosing by timestamp, and returns no route when scope cannot be derived. |
| The first route works through the model-facing dispatcher. | `capability_binding::tests::capability_execute_dispatch_routes_git_status_through_active_replacement` activates a scoped `git_status` projection route and invokes `{"operation":"git_status"}` through `capability::execute`, proving the dispatcher revalidates and replays accepted shadow evidence with `acceptedProjectionReplayed: true`, `routeExecutionMode: supervised_shadow_projection_replay`, `candidateProjectionSource: accepted_shadow_trial_evidence`, `liveModuleCodeExecutionSupported: false`, `liveModuleCodeExecuted: false`, `builtInProjectionUsed: false`, route event evidence, and no raw resource/version/idempotency leakage. |
| Routed invocation evidence is durable. | `emit_routed_invocation_event` records a `capability_route_event` resource with route version, activation refs, trace/replay refs, idempotency, and side-effect proof. |
| Active routes use a supervised shadow-projection replay boundary. | `git_status` dispatch calls `execute_routed_git_status` when `active_route_for_git_status` returns a route; route execution calls `module_runtime::service::validate_accepted_shadow_projection`, requires exact lifecycle/runtime version refs, lifecycle runtime authorization, `networkPolicy: none`, supervised-envelope proof, accepted shadow-trial evidence as the projection source, `liveModuleCodeExecutionSupported: false`, `liveModuleCodeExecuted: false`, and a bounded `git_status` projection. |
| Active routes fail closed instead of silently substituting built-in success. | A rejected accepted-shadow projection emits a `failed_closed` `capability_route_event` and returns an errored `git_status route failed closed` result with `projectionBoundaryEvaluated: true`, `acceptedProjectionReplayed: false`, `builtInProjectionUsed: false`, and no built-in success projection. Stale referenced route records emit a `failed_closed` lookup event before returning the stale-record error. |
| Cockpit visibility reflects route truth without local fabrication. | `capability_binding::cockpit_overview` now scans candidate, binding, activation, route-event, rollback, and scoped shadow-evidence resources; projects active route count, route-event count, routed invocations, failed-closed/disabled/rolled-back state, rollback records, terminal controls, safe state labels, and bounded `routeStories`; broad overview rows omit raw refs, while targeted operation rows can return bounded exact shadow-evidence inspect payloads so Tron can inspect evidence without guessing unsupported list operations. The provider-visible `capability_binding_cockpit_overview` wrapper keeps broad UI projections intact but compacts exact `targetOperation` responses into a model-facing packet with one target row, agent path, counts, scoped evidence refs, and projection proof so provider replay is not dominated by UI inventory JSON. |
| Shadow-trial schemas are exact enough for model-native use. | `catalog_inspect` now names the required top-level fields for `capability_shadow_trial_decision_record` and `capability_shadow_trial_run_record`, including request/decision resource refs, expected current version ids, decision enum, rationale, and bounded `git_status` built-in/candidate projections. `catalog_search` exposes those metadata-write operations as contextual future steps in shadow-readiness plans without listing them as read-only recommendations. |
| Minimal-engine guardrails hold. | Route records forbid package-manager, network, deploy, dependency restore, dispatch-table mutation, raw paths/commands/logs/code/file contents, raw grant IDs, raw authority IDs, and repo-managed skills. |

## Validation Commands

Focused validation for this slice:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo check --manifest-path packages/agent/Cargo.toml
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_dynamic_replacement_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::capability_execute_dispatch_controls_shadow_trial_workflow -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::capability_execute_dispatch_controls_full_route_lifecycle -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::capability_execute_dispatch_routes_git_status_through_active_replacement -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::active_route_lookup_rejects_multiple_active_routes_in_scope -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_records_candidate_binding_activation_disable_and_rollback_for_git_status -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::active_route_rejects_unsafe_adapter_projection_without_builtin_fallback -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_lookup_rejects_stale_binding_or_candidate_current_versions -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_candidate_accepts_refs_created_by_module_lifecycle_and_runtime_operations -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_candidate_rejects_stale_or_unauthorized_runtime_contract_refs -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_candidate_rejects_fabricated_or_stale_shadow_evidence -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-cockpit-route cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::cockpit_overview -- --quiet
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/WorkerLifecycleDTOTests
scripts/personal-info-guard.sh
git diff --check
git diff --cached --check
```

Latest focused validation result:

```text
cargo test --manifest-path packages/agent/Cargo.toml cockpit_overview_projects_operation_ownership_binding_shadow_and_rollback_without_raw_leakage -- --nocapture
result: passed; the broad cockpit row returned no shadow-evidence refs, and the targeted git_status row returned the exact capability_shadow_trial_evidence_inspect payload.

cargo test --manifest-path packages/agent/Cargo.toml catalog_inspect_projects_shadow_trial_record_required_fields -- --nocapture
result: passed; shadow-trial decision/run schemas expose exact required resource/version/projection fields.

cargo test --manifest-path packages/agent/Cargo.toml catalog_search_returns_agent_readiness_plan_for_multi_intent_queries -- --nocapture
result: passed; replacement readiness search starts at targeted cockpit, keeps contextual shadow write schemas out of read-only matches, and preserves unsupported-list recovery guidance.

cargo test --manifest-path packages/agent/Cargo.toml cockpit_overview_content_names_targeted_operation -- --nocapture
result: passed; targeted cockpit content reports scoped evidence/count state and tells the agent not to search unsupported shadow list operations.

cargo test --manifest-path packages/agent/Cargo.toml cockpit_overview_result_details_compacts_targeted_projection -- --nocapture
result: passed; targeted execute details omit heavy UI families/route stories/full operation arrays while preserving the exact target row, agent path, and projection policy.

cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
result: passed.

cargo check --manifest-path packages/agent/Cargo.toml
result: passed.

cargo test --manifest-path packages/agent/Cargo.toml --test capability_dynamic_replacement_invariants -- --nocapture
result: passed; 6 passed, 0 failed.

cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
result: passed; 9 passed, 0 failed.
```

## Practical Live-Test Boundary

The first governed runtime route is complete for read-only `git_status`.
Additional operation breadth should now be driven by live Tron stress tests and
focused follow-up slices, not by another foundation scorecard. Write operations,
network adapters, package-manager behavior, dependency restoration, and
production deployment remain intentionally outside this route until separate
governed trials prove their contracts.
