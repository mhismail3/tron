# Capability Modularity Evidence Manifest

Status: **complete**

This manifest records the evidence reviewed for the capability modularity scorecard. The scorecard, binding policy, adapter seam hardening, shadow replacement trial, governed route records, and cockpit visibility slices add documentation, invariants, source-backed seam contracts, governance records, and redacted operator projections. The first scoped `git_status` route seam records route state and revalidates and replays accepted provider-safe shadow evidence; it does not execute live module code. Broader operation routing remains governed by the dynamic replacement scorecard.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Operation dispatch | `packages/agent/src/domains/capability/operations/dispatch.rs` |
| Process adapter seam | `packages/agent/src/domains/capability/operations/process.rs` |
| Capability binding operations | `packages/agent/src/domains/capability/operations/capability_binding.rs` |
| Capability contract | `packages/agent/src/domains/capability/contract.rs` |
| Capability binding schema fields | `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Capability binding docs/service | `packages/agent/src/domains/capability_binding/mod.rs` |
| Capability route service | `packages/agent/src/domains/capability_binding/route.rs` |
| Capability cockpit projection | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| Capability cockpit contract | `packages/agent/src/domains/capability_binding/contract.rs` |
| Capability shadow trial service | `packages/agent/src/domains/capability_binding/shadow_trial.rs` |
| Capability binding resource definitions | `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |
| Filesystem adapter seam | `packages/agent/src/domains/filesystem/mod.rs` |
| Git adapter seam | `packages/agent/src/domains/git/mod.rs` |
| Jobs adapter seam | `packages/agent/src/domains/jobs/mod.rs` |
| Web adapter seam | `packages/agent/src/domains/web/mod.rs` |
| Subagent adapter seam | `packages/agent/src/domains/subagents/mod.rs` |
| Context-control strategy seam | `packages/agent/src/domains/context_control/mod.rs` |
| Context compaction strategy seam | `packages/agent/src/domains/agent/context/mod.rs` |
| Grant authorization policy | `packages/agent/src/engine/authority/grants/authorization.rs` |
| Engine fabric docs | `packages/agent/src/engine/mod.rs` |
| Authority/grants docs | `packages/agent/src/engine/authority/mod.rs` |
| Engine durability docs | `packages/agent/src/engine/durability/mod.rs` |
| Resource store docs | `packages/agent/src/engine/durability/resources/mod.rs` |
| Replay snapshot docs | `packages/agent/src/engine/durability/replay.rs` |
| Session event store docs | `packages/agent/src/domains/session/event_store/mod.rs` |
| Event redaction docs | `packages/agent/src/domains/session/event_store/redaction.rs` |
| Shared redaction helper | `packages/agent/src/shared/foundation/redaction.rs` |
| Transport docs | `packages/agent/src/transport/mod.rs` |
| Engine transport docs | `packages/agent/src/transport/engine/mod.rs` |
| Transport auth docs | `packages/agent/src/transport/http/auth.rs` |
| Catalog discovery docs | `packages/agent/src/domains/catalog_discovery/mod.rs` |
| Module registry docs | `packages/agent/src/domains/module_registry/mod.rs` |
| Module authoring docs | `packages/agent/src/domains/module_authoring/mod.rs` |
| Module validation docs | `packages/agent/src/domains/module_validation/mod.rs` |
| Module install docs | `packages/agent/src/domains/module_install/mod.rs` |
| Module dependency docs | `packages/agent/src/domains/module_dependencies/mod.rs` |
| Module lifecycle docs | `packages/agent/src/domains/module_lifecycle/mod.rs` |
| Module runtime docs | `packages/agent/src/domains/module_runtime/mod.rs` |
| Module program execution docs | `packages/agent/src/domains/module_program_execution/mod.rs` |
| Tool-source governance docs | `packages/agent/src/domains/tool_sources/mod.rs` |
| Worker lifecycle governance docs | `packages/agent/src/domains/worker_lifecycle/mod.rs` |
| Context control docs | `packages/agent/src/domains/context_control/mod.rs` |
| Engine cockpit iOS docs | `packages/ios-app/docs/architecture.md` |
| Engine cockpit iOS protocol/state/UI | `packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+CapabilityCockpit.swift`, `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift`, `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift`, `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift` |
| Canonical README | `README.md` |

## Baseline Facts

| Fact | Evidence |
|---|---|
| Registry count | 188 entries in `OperationId::ALL_NAMES`. |
| Dispatch parity | 188 static dispatch arms in `execute_operation`; no missing or extra names. |
| Provider surface | One model-facing tool, `capability::execute`. |
| Machine inventory | `packages/agent/docs/capability-modularity-inventory.tsv` lists every operation exactly once. |
| Deterministic grouping | The invariant test maps operation prefixes to the expected family and ownership class. |
| Kernel boundary lockdown | Static invariants require source anchors for authority/grants, event/session log, resource store, redaction/provider-safety, trace/audit/replay/catalog, transport boundary, and module governance pipeline before locked rows can change ownership class. |
| Capability binding policy | `capability_binding_request`, `capability_binding_decision`, and `capability_binding_policy` resources record metadata-only replacement governance with exact selectors, idempotency, stale-version guards, rollback/disable refs, and provider-safe projections. |
| Shadow replacement trial | `capability_shadow_trial_request`, `capability_shadow_trial_decision`, `capability_shadow_trial_run`, and `capability_shadow_trial_evidence` resources record a governed metadata-only `git_status` trial with exact selectors, stale evidence rejection, rollback/disable/abort refs, provider-safe projections, and no dispatch mutation. |
| Governed route records | `capability_replacement_candidate`, `capability_route_binding`, `capability_route_activation`, `capability_route_event`, and `capability_route_rollback` resources record scoped `git_status` route state, activation, routed-invocation, disable, and rollback evidence with exact selectors, stale-version guards, rollback/disable refs, provider-safe projections, and no package-manager/network/deploy behavior. |
| Cockpit visibility | `capability_binding::cockpit_overview` and provider-visible `capability_binding_cockpit_overview` project registry ownership plus scoped binding/shadow-trial/route state for Engine Cockpit as bounded redacted metadata, including total/returned operation counts, list/scan completeness, operation-pool role/replacement classification, agent usage/preflight guidance, redacted replacement-target summaries, active route state, route events, routed invocations, failed-closed/disabled/rolled-back state, terminal controls, and server-derived readiness labels. Broad overview rows omit raw refs; targeted rows may include bounded exact shadow-evidence inspect payloads when scoped evidence exists, and the provider-visible targeted execute wrapper compacts the row into one agent-facing packet so the model can inspect evidence without guessing unsupported list operations or reading a heavy UI inventory payload. |
| Adapter seam hardening | Adapter-replaceable families and the compaction strategy seam now name authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable prerequisites in source docs, inventory metadata, scorecard prose, and static tests. |
| Runtime behavior | The `git_status` dispatcher now checks scoped active route records; when none exists it uses the built-in provider-safe projection, and when a validated route exists it revalidates and replays accepted provider-safe shadow evidence and fails closed if that projection is rejected. It does not execute live module code, mutate the dispatch table, hot-swap modules, install, activate packages, run package managers, restore dependencies, access networks, or deploy. |

## Kernel Boundary Lockdown Evidence

| Area | Source anchors | Inventory lock |
|---|---|---|
| authority/grants | `packages/agent/src/engine/authority/mod.rs`, `packages/agent/src/engine/mod.rs` | Engine-owned grant resolution remains kernel substrate and is not adapter/module-routed. |
| event/session log | `packages/agent/src/domains/session/event_store/mod.rs` | `logs` operations stay `kernel_locked`; event truth and deterministic reconstruction stay server-owned. |
| resource store | `packages/agent/src/engine/durability/mod.rs`, `packages/agent/src/engine/durability/resources/mod.rs` | Resource-backed custody families stay `record_plane`; modules may produce records but cannot bypass the store. |
| redaction/provider-safety | `packages/agent/src/shared/foundation/redaction.rs`, `packages/agent/src/domains/session/event_store/redaction.rs`, `packages/agent/src/domains/capability/mod.rs` | Locked and governance-visible rows retain provider-safe projections and shared redaction anchors. |
| trace/audit/replay/catalog | `packages/agent/src/domains/capability/operations/mod.rs`, `packages/agent/src/engine/durability/replay.rs`, `packages/agent/src/domains/catalog_discovery/mod.rs` | `trace_*`, `replay_manifest`, and `catalog_*` stay `kernel_locked`; catalog discovery is not invocation. |
| transport boundary | `packages/agent/src/transport/mod.rs`, `packages/agent/src/transport/engine/mod.rs`, `packages/agent/src/transport/http/auth.rs` | Transport remains authenticated framing over canonical engine requests and owns no domain behavior. |
| module governance pipeline | `packages/agent/src/domains/module_registry/mod.rs`, `packages/agent/src/domains/module_authoring/mod.rs`, `packages/agent/src/domains/module_validation/mod.rs`, `packages/agent/src/domains/module_install/mod.rs`, `packages/agent/src/domains/module_dependencies/mod.rs`, `packages/agent/src/domains/capability_binding/mod.rs`, `packages/agent/src/domains/module_lifecycle/mod.rs`, `packages/agent/src/domains/module_runtime/mod.rs`, `packages/agent/src/domains/tool_sources/mod.rs`, `packages/agent/src/domains/worker_lifecycle/mod.rs` | Module registry, authoring, validation, install, dependency, capability binding, lifecycle, runtime, procedural, tool-source, worker-package, device-token, and notification-delivery gates stay `governance_locked`. |

## Binding Policy Evidence

| Evidence | Source |
|---|---|
| Request records model operation name, current built-in owner, requested target, ownership class, binding mode, actor scope, rationale, contract/evidence refs, authority/network constraints, stale-version guard, rollback/disable refs, audit refs, and idempotency fingerprint. | `packages/agent/src/domains/capability_binding/records.rs`, `packages/agent/src/domains/capability_binding/service.rs` |
| Locked ownership classes cannot request replacement; adapter/module replacement proposals require rollback/disable metadata and remain metadata only. | `packages/agent/src/domains/capability_binding/validation.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Provider-visible operations require exact selectors for inspect/linked writes, explicit non-wildcard grants, `networkPolicy: none`, and bounded provider-safe projections with no `agent_state` inheritance. | `packages/agent/src/engine/authority/grants/authorization.rs`, `packages/agent/src/domains/capability_binding/authority.rs`, `packages/agent/src/domains/capability_binding/projection.rs` |
| Decision/policy records revalidate expected request/decision versions and preserve audit history through resource versions/events. | `packages/agent/src/domains/capability_binding/service.rs`, `packages/agent/src/domains/capability_binding/resource_store.rs` |
| Side-effect proof explicitly records no dispatch mutation, hot-swap, module activation/execution, dependency restore, package-manager, network, raw path/command/log/file/grant/authority exposure, or repo-managed skill touch. | `packages/agent/src/domains/capability_binding/records.rs`, `packages/agent/src/domains/capability_binding/route.rs`, `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |

## Shadow Replacement Trial Evidence

| Evidence | Source |
|---|---|
| The first trial target is exactly `git_status`; other target operations are rejected before a trial request is recorded. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Trial requests require a deterministic metadata-only candidate adapter description, exact non-wildcard resource selectors, `networkPolicy: none`, rollback/disable/abort refs, stale inventory/policy guards, and no `agent_state` inheritance. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Trial decisions and runs revalidate exact linked-resource selectors and expected current versions before writing append-only decision, run, and evidence resources. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Trial evidence stores only bounded built-in/candidate `git_status` projections and server-computed comparison evidence; evidence inspect requires an exact resource selector and rejects stale expected evidence versions. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| No dispatch mutation or live replacement occurs: `git_status` remains owned by the built-in Git adapter, and shadow-trial side-effect proof records no runtime routing, hot-swap, candidate execution, module activation, package-manager, dependency, or network behavior. | `packages/agent/src/domains/capability/operations/mod.rs`, `packages/agent/src/domains/capability/operations/operation_contract/mod.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |

## Governed Route Record Evidence

| Evidence | Source |
|---|---|
| Route candidate records are limited to the first read-only target, `git_status`, and require candidate owner/module/runtime/lifecycle refs, contract evidence, exact authority constraints, rollback controls, safe audit refs, idempotency, and `networkPolicy: none`. | `packages/agent/src/domains/capability_binding/route.rs`, `packages/agent/src/domains/capability/operations/operation_contract/mod.rs` |
| Route binding records require an exact candidate resource selector, expected candidate version, exact scope, a ready lifecycle state, and a route version before a route can activate. | `packages/agent/src/domains/capability_binding/route.rs`, `packages/agent/src/engine/authority/grants/authorization.rs` |
| Route activation requires a ready binding, exact expected binding version, approval refs, rollback and disable controls, exact non-wildcard route/resource selectors, and `networkPolicy: none`. | `packages/agent/src/domains/capability_binding/route.rs`, `packages/agent/src/domains/capability_binding/authority.rs` |
| `git_status` resolves active scoped route records, skips terminal disabled/rolled-back events, verifies referenced binding/candidate records, emits a durable routed-invocation event, and revalidates and replays accepted provider-safe shadow evidence for active routes. | `packages/agent/src/domains/capability/operations/git.rs`, `packages/agent/src/domains/capability_binding/route.rs` |
| Active route execution fails closed without returning built-in success if the accepted shadow projection is rejected; successful routed output records `acceptedProjectionReplayed: true`, `routeExecutionMode: supervised_shadow_projection_replay`, `liveModuleCodeExecutionSupported: false`, and `builtInProjectionUsed: false`. | `packages/agent/src/domains/capability_binding/route.rs` |

## Cockpit Visibility Evidence

| Evidence | Source |
|---|---|
| The projection is registered as a `capability_binding` system-visible pure-read function with low risk and `capability_binding.read`; it is not a provider-visible `capability::execute` operation. | `packages/agent/src/domains/capability_binding/contract.rs`, `packages/agent/src/domains/capability_binding/mod.rs`, `packages/agent/src/domains/capability_binding/service.rs` |
| Operation owner/status/replacement/readiness fields are derived from `OperationId::ALL_NAMES` and authoritative binding metadata, not from iOS inference. Owner labels and replacement target summaries are redacted; `capability_binding` is exposed as projection source rather than operation owner. | `packages/agent/src/domains/capability/operations/operation_contract/mod.rs`, `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| Scoped binding, shadow-trial, and route summaries count current-session/workspace records only and omit raw resource ids, local paths, commands, logs, code, file contents, grant ids, authority ids, trace ids, invocation ids, token-like strings, and hidden chain-of-thought. The projection reports total versus returned operation count plus operation-list and bounded resource-scan truncation states so partial results remain visibly degraded. | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Projection policy states server-owned truth, projection-only and metadata-only behavior, plus no autonomy creation, dispatch mutation, hot swap, module activation/execution, dependency restore, package-manager, or network side effects. | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| iOS DTOs decode the server projection, view models pass trusted session/workspace context, state maps display labels, and views render details through capability group and operation drill-down instead of top-level telemetry. | `packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+CapabilityCockpit.swift`, `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitViewModel.swift`, `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift`, `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift`, `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift` |

## Adapter Seam Hardening Evidence

| Family | Source-backed seam evidence |
|---|---|
| `filesystem` | `packages/agent/src/domains/filesystem/mod.rs` records exact root authority, preview/commit evidence, bounded file side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `git` | `packages/agent/src/domains/git/mod.rs` records exact repository authority, HEAD/index evidence, guarded Git side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `process_run` | `packages/agent/src/domains/capability/operations/process.rs` records trusted working-directory authority, networkPolicy none, bounded process side effects, provider-safe result projection, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `jobs` | `packages/agent/src/domains/jobs/mod.rs` records supervised runtime authority, lifecycle evidence, bounded job side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `web` | `packages/agent/src/domains/web/mod.rs` records exact network authority, robots/source evidence, fail-closed side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `subagents` | `packages/agent/src/domains/subagents/mod.rs` records exact task/runtime/job authority, merge evidence, bounded subagent side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `context_control_compact` | `packages/agent/src/domains/context_control/mod.rs` and `packages/agent/src/domains/agent/context/mod.rs` record the summarizer strategy seam, provider-safe summary, context audit records, survivor/exclusion policy refs, replay/idempotency evidence, and rollback/disable metadata while keeping context-control records server-owned. |

## Validation Commands

Latest local result:

```bash
CARGO_TARGET_DIR=/tmp/tron-agent-target-mainline-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
# exit 0; 9 passed, 0 failed
```

```bash
CARGO_TARGET_DIR=/tmp/tron-agent-target-mainline-check cargo check --manifest-path packages/agent/Cargo.toml
# exit 0
```

```bash
CARGO_TARGET_DIR=/tmp/tron-agent-target-mainline-check cargo test --manifest-path packages/agent/Cargo.toml --all-targets
# exit 0
```

```bash
CARGO_TARGET_DIR=/tmp/tron-agent-target-mainline-check cargo clippy --manifest-path packages/agent/Cargo.toml --all-targets -- -D warnings
# exit 0
```

```bash
cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# exit 0; 1110 tests passed; ** TEST SUCCEEDED **
```

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::capability_binding::tests -- --nocapture
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/WorkerLifecycleDTOTests -only-testing:TronMobileTests/WorkerLifecycleClientTests -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/AgentCockpitViewModelTests
git diff --check
git diff --cached --check
```

Additional broad gates remain useful before integration when this lands with other work:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo check --manifest-path packages/agent/Cargo.toml
```

## Evidence Notes

- `kernel_locked` and `governance_locked` rows intentionally have binding and rollback scores of `0`; that is a lock, not a missing implementation.
- Capability Binding Policy request/decision/policy records remain a metadata-only governance plane. Governed route records add scoped `git_status` projection routing through revalidated accepted shadow evidence, without live module code execution, package installation, worker enablement, dependency restore, package-manager behavior, network behavior, or broad unapproved module replacement.
- Shadow replacement trial evidence is intentionally metadata-only. It compares bounded built-in and deterministic candidate projections for `git_status`; it does not execute a candidate module or change live operation routing.
- Cockpit visibility is intentionally read-only and redacted. It reports total versus returned operations, operation-list truncation, bounded resource-scan completeness, redacted owner/target labels, active route state, route events, routed invocations, failed-closed/disabled/rolled-back routes, terminal controls, and server-derived readiness; it can make modularity inspectable, but it cannot approve, activate, disable, roll back, route, or execute replacement behavior.
- `adapter_replaceable` rows now name required authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable prerequisites and hand off to the shadow replacement trial.
- `record_plane` rows allow module producers or workflow extension while preserving server-owned custody records and provider-safe projections.
- `context_control_compact` is the only compaction-like strategy seam in this slice: a future summarizer replacement cannot bypass context audit records, survivor/exclusion policy refs, fail-closed proof before provider-context mutation, or expose raw prompt material.
- `module_program_execution_*` is the first module-owned execution pack and is used as the baseline template for later governed replacement.
- Future operations must update the TSV, this scorecard, and this manifest before the invariant test will pass.
