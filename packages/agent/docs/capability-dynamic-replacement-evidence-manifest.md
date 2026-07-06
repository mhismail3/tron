# Capability Dynamic Replacement Evidence Manifest

Status: **foundational runtime route complete**

This manifest records the source-backed evidence for the first dynamic
replacement slice. The slice adds governed route records and a scoped
`git_status` route seam that resolves an active route, verifies lifecycle and
runtime refs, projects supervised module-runtime provider-safe output, and
fails closed when the replacement boundary is unsafe. It does not claim full
autonomous self-update across every operation.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/registry.rs` |
| Operation dispatcher | `packages/agent/src/domains/capability/operations/dispatch.rs` |
| Git route seam | `packages/agent/src/domains/capability/operations/git.rs` |
| Provider schema fields | `packages/agent/src/domains/capability/capability_binding_contract.rs` |
| Capability contract guidance | `packages/agent/src/domains/capability/contract.rs` |
| Route service | `packages/agent/src/domains/capability_binding/route.rs` |
| Module runtime projection boundary | `packages/agent/src/domains/module_runtime/service.rs` |
| Route authority | `packages/agent/src/domains/capability_binding/authority.rs` |
| Cockpit route projection | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| Route resource definitions | `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |
| Grant authorization | `packages/agent/src/engine/authority/grants/authorization.rs` |
| iOS cockpit DTOs | `packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+CapabilityCockpit.swift` |
| iOS cockpit state | `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` |
| iOS cockpit UI | `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift`; `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift` |
| Modularity inventory | `packages/agent/docs/capability-modularity-inventory.tsv` |
| Canonical README | `README.md` |

## Evidence

| Claim | Evidence |
|---|---|
| Route operations are provider-visible only through `capability::execute`. | Registry and dispatch add `capability_replacement_candidate_*`, `capability_route_binding_*`, `capability_route_activate`, `capability_route_disable`, `capability_route_rollback`, and `capability_route_event_*` operations. |
| Route operations are governance-locked, not adapter-replaceable. | `operation_binding_metadata` and `capability-modularity-inventory.tsv` classify all replacement/route operations as `capability_binding` / `governance_locked`. |
| Kernel and governance operations remain non-routable. | The route service accepts only the first target operation, `git_status`, and the modularity invariants reject binding/rollback seams for locked rows. |
| Candidate records are bounded and provider-safe. | `route.rs` validates unsafe payloads, bounded text/tokens/refs, exact target metadata, route authority, rollback controls, idempotency, exact current accepted `capability_shadow_trial_evidence` resource/version proof, and `networkPolicy: none`. |
| Activation is explicit and approval-backed. | `capability_route_activate` requires a ready binding, exact expected binding version, accepted shadow-evidence proof captured by the binding, approval refs, rollback/disable controls, exact selectors, and `networkPolicy: none`. |
| Route lookup is exact-scope and fail-closed. | `active_route_for_git_status` derives trusted session/workspace scope, lists active route activations in that scope, verifies binding/candidate refs against the activation/binding expected current versions plus accepted current shadow evidence, skips terminal route events, and returns no route when scope cannot be derived. |
| Routed invocation evidence is durable. | `emit_routed_invocation_event` records a `capability_route_event` resource with route version, activation refs, trace/replay refs, idempotency, and side-effect proof. |
| Active routes use a supervised module-runtime projection boundary. | `git_status` dispatch calls `execute_routed_git_status` when `active_route_for_git_status` returns a route; route execution calls `module_runtime::service::project_provider_safe_adapter_output`, requires exact lifecycle/runtime version refs, lifecycle runtime authorization, `networkPolicy: none`, supervised-envelope proof, and a bounded `git_status` projection. |
| Active routes fail closed instead of silently falling back. | A rejected supervised projection emits a `failed_closed` `capability_route_event` and returns an errored `git_status route failed closed` result with `moduleAdapterInvoked: true`, `builtInProjectionUsed: false`, and no built-in success projection. Stale referenced route records emit a `failed_closed` lookup event before returning the stale-record error. |
| Cockpit visibility reflects route truth without local fabrication. | `capability_binding::cockpit_overview` now scans candidate, binding, activation, route-event, and rollback resources; projects active route count, route-event count, routed invocations, failed-closed/disabled/rolled-back state, rollback records, terminal controls, and safe state labels; and iOS renders those server-owned route facts in operation cards and drill-down details without raw ids. |
| Minimal-engine guardrails hold. | Route records forbid package-manager, network, deploy, dependency restore, dispatch-table mutation, raw paths/commands/logs/code/file contents, raw grant IDs, raw authority IDs, and repo-managed skills. |

## Validation Commands

Focused validation for this slice:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo check --manifest-path packages/agent/Cargo.toml
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_dynamic_replacement_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_records_candidate_binding_activation_disable_and_rollback_for_git_status -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::active_route_rejects_unsafe_adapter_projection_without_builtin_fallback -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_lookup_rejects_stale_binding_or_candidate_current_versions -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::route_candidate_rejects_fabricated_or_stale_shadow_evidence -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-cockpit-route cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::cockpit_overview -- --quiet
scripts/personal-info-guard.sh
git diff --check
git diff --cached --check
```

## Practical Live-Test Boundary

The first governed runtime route is complete for read-only `git_status`.
Additional operation breadth should now be driven by live Tron stress tests and
focused follow-up slices, not by another foundation scorecard. Write operations,
network adapters, package-manager behavior, dependency restoration, and
production deployment remain intentionally outside this route until separate
governed trials prove their contracts.
