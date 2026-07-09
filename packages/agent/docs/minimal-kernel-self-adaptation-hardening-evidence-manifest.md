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
| Capability catalog projections | `packages/agent/src/domains/capability/operations/catalog.rs` |
| Model capability runtime grants | `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs` |
| Provider request composition boundary | `packages/agent/src/domains/model/responder/mod.rs`; `packages/agent/src/domains/model/providers/shared/provider.rs`; `packages/agent/src/domains/model/providers/openai/provider/mod.rs`; `packages/agent/src/domains/model/providers/kimi/provider.rs` |
| Memory prompt context projection | `packages/agent/src/domains/memory/prompt_trace.rs` |
| Durable jobs domain | `packages/agent/src/domains/jobs/mod.rs`; `packages/agent/src/domains/jobs/service.rs` |
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
| Cockpit readiness inspection has concrete read authority. | `capability_binding_cockpit_overview` now derives a read-only runtime grant with explicit capability-binding, route, shadow-trial, and replacement-candidate resource kinds plus the session selector. This keeps the model-facing readiness surface from failing before dispatch with an empty `allowedResourceKinds` grant while preserving `networkPolicy: none`, no `agent_state`, and no write scope. |
| Capability-pool metadata matches runtime grants. | `capability::pool` now advertises the same route, shadow-trial, replacement-candidate, and binding resource selectors that the model capability runtime grant derives for cockpit, route, replacement, and shadow-trial operations. Shadow-trial provider-visible record/inspect operations also derive explicit capability-binding/resource read-write or read-only grants before dispatch, so future governed shadow workflows do not fail on hidden empty resource-kind authority. |
| Provider requests exclude server-owned correlation ids. | The model responder no longer derives provider prompt-cache fields from session ids, and the unused prompt-cache option was removed from the provider abstraction and OpenAI/Kimi request builders. Memory prompt composition keeps durable trace and decision resource ids in server custody while projecting only recorded/not-recorded facts. Focused tests assert that provider request envelopes and memory prompt text contain neither the session id nor prompt-trace/decision resource ids. |
| Trace evidence contracts are inspectable before invocation. | `catalog_inspect` for `execute::trace_list` and `execute::trace_get` now projects closed provider-visible request schemas plus the provider-safe trace record output schema. `trace_list` requires only `operation` and allows only optional `limit`/`traceId`; `trace_get` requires only `operation`/`traceRecordId`; both reject invented selector/scope fields. The output contract includes trusted current-session scoping guidance, safe engine ref semantics, status summaries, request/result hashes, per-record projection/redaction proof booleans, and the explicit list of raw provider invocation ids, grant ids, idempotency keys, paths, commands, logs, and file contents that are not projected. Live-session hardening also makes whole-session trace proof explicitly terminal or qualified: agents must call `trace_list` after the operations being audited, or say it only covers records visible at projection time. Final answers must say provider transcript tool-call ids may still be visible in provider message history for protocol threading, while provider-safe trace projections exclude raw trace `providerInvocationId` fields; agents must not report transcript call ids as absent when only trace projection safety was checked. |
| Durable job workflows are schema-led and projection-safe. | `catalog_inspect` now projects closed operation-specific schemas for `job_start`, `job_status`, `job_list`, `job_log`, `job_cancel`, `job_cleanup`, and `process_run`, including required payload fields, bounds, and idempotency/projection guidance. Public `job_status` and `job_list` return redacted lifecycle/output-ref projections without raw commands, canonical working directories, authority/grant ids, raw idempotency keys, stdout, stderr, or raw job/output payloads; `job_log` remains the explicit bounded stdout/stderr preview surface. |
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
cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_inspect_projects_trace_output_record_schema -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_inspect_projects_closed_job_operation_contracts -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_inspect_projects_closed_process_run_contract -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib job_start_completes_and_records_bounded_output -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib extract_result_content_projects_trace_projection_proof_for_agent -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib capability_binding_cockpit_overview_runtime_grant_authorizes_governance_projection_kinds -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib capability_cockpit_and_route_usage_advertise_full_governance_selectors -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib capability_shadow_trial_usage_advertises_exact_trial_selectors -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib capability_shadow_trial_runtime_grants_authorize_exact_trial_kinds -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib provider_backed_request_audit_uses_stream_options_and_exact_payload -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --lib prompt_trace_records_audit_without_private_memory_content -- --nocapture
scripts/personal-info-guard.sh
git diff --check
git diff --cached --check
```

Latest retained-scorecard closeout result: passed, 100/100.
