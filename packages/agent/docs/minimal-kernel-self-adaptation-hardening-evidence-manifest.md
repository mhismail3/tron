# Minimal Kernel Self-Adaptation Hardening Evidence Manifest

Status: **complete**

This manifest records the capstone evidence that the minimal kernel,
replacement proof contract, context policy contract, dynamic route behavior, and
cockpit visibility are source-backed. It intentionally does not introduce new
runtime behavior.

## Reviewed Source Files

| Area | File |
|---|---|
| Capability registry and operation ownership | `packages/agent/src/domains/capability/operations/registry.rs` |
| Capability dispatcher | `packages/agent/src/domains/capability/operations/dispatch.rs` |
| First route seam | `packages/agent/src/domains/capability/operations/git.rs` |
| Capability binding domain docs | `packages/agent/src/domains/capability_binding/mod.rs` |
| Capability route service | `packages/agent/src/domains/capability_binding/route.rs` |
| Capability binding validation | `packages/agent/src/domains/capability_binding/validation.rs` |
| Shadow trial service | `packages/agent/src/domains/capability_binding/shadow_trial.rs` |
| Cockpit route projection | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| Context control domain docs | `packages/agent/src/domains/context_control/mod.rs` |
| Context control service | `packages/agent/src/domains/context_control/service.rs` |
| Context policy resource definitions | `packages/agent/src/engine/durability/resources/context_control_definitions.rs` |
| Module runtime projection boundary | `packages/agent/src/domains/module_runtime/service.rs` |
| Engine authority | `packages/agent/src/engine/authority/mod.rs` |
| Grant authorization | `packages/agent/src/engine/authority/grants/authorization.rs` |
| Resource custody | `packages/agent/src/engine/durability/resources/mod.rs` |
| Session event log | `packages/agent/src/domains/session/event_store/mod.rs` |
| Redaction | `packages/agent/src/shared/foundation/redaction.rs` |
| Catalog discovery | `packages/agent/src/domains/catalog_discovery/mod.rs` |
| Transport boundary | `packages/agent/src/transport/engine/mod.rs` |
| iOS cockpit state/UI | `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift`; `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift` |
| Canonical README | `README.md` |

## Evidence

| Claim | Evidence |
|---|---|
| The capstone adds no new runtime surface. | No new `capability::execute` operations or worker functions are introduced; the static invariant rejects `minimal_kernel_*` and `self_adaptation_*` operation names. |
| Minimal kernel ownership is explicit. | Capability modularity scorecard and inventory classify `kernel_locked`, `governance_locked`, `record_plane`, `adapter_replaceable`, and `module_owned` operations, and source invariants lock authority, resource custody, redaction, trace/replay/catalog, transport, event log, and module governance. |
| Replacement is contractual and verifiable. | `capability_binding::route` requires current shadow evidence, exact candidate/binding versions, exact selectors, lifecycle/runtime refs, supervised runtime projection, route events, rollback/disable controls, and fail-closed behavior; completed shadow-trial projections reject missing or placeholder evidence. |
| Context policy is not best effort. | `context_control` owns survivor/exclusion records and complete bounded policy snapshots; policy summaries retain provider-safe target refs, list/snapshot projections fail closed instead of truncating active policy custody, and tests cover exact authority, safe refs, reasons, overflow failure, replay, and no raw local paths. |
| Compaction replacement is scoped to the summarizer. | Context-control docs and modularity invariants state that the summarizer strategy is replaceable, while snapshot/action/epoch/policy custody remains server-owned. |
| User visibility is server-owned. | `capability_binding::cockpit_overview` projects route stories, operation state, route events, failed-closed/disabled/rolled-back state, and rollback controls from scoped resources; iOS renders those facts without raw IDs. |
| Agent-native zero-evidence paths are terminal. | `catalog_search` now points shadow/readiness queries to one targeted cockpit inspection, keeps adapter invocation/schema inspection out of the actionable readiness match list, and targeted `capability_binding_cockpit_overview` rows tell the model to answer immediately when no scoped evidence refs, shadow runs, route bindings, or route events exist. The evidence inspector remains exposed only when an exact evidence resource id is returned. |
| The foundation is honest. | Dynamic replacement scorecard states the first route target is read-only `git_status` and does not claim arbitrary live module-code execution or full autonomous self-update across all operations. |

## Validation Commands

Focused validation for this capstone:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml --test minimal_kernel_self_adaptation_hardening_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml --test capability_dynamic_replacement_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml context_control::tests::context_policy -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::shadow_trial_rejects_completed_projection_without_concrete_evidence -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-minimal-kernel cargo test --manifest-path packages/agent/Cargo.toml capability_binding::tests::capability_execute_dispatch_routes_git_status_through_active_replacement -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_search_returns_agent_readiness_plan_for_multi_intent_queries -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib cockpit_overview_filters_exact_operation_and_returns_agent_native_path -- --nocapture
scripts/personal-info-guard.sh
git diff --check
git diff --cached --check
```

Latest retained-scorecard closeout result: passed, 100/100.
