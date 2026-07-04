# Capability Modularity Evidence Manifest

Status: active / shadow-replacement-trial-complete

This manifest records the evidence reviewed for the capability modularity scorecard. The scorecard, binding policy, adapter seam hardening, and shadow replacement trial slices add documentation, invariants, source-backed seam contracts, and metadata-only governance records; they add no runtime routing behavior.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/registry.rs` |
| Operation dispatch | `packages/agent/src/domains/capability/operations/mod.rs` |
| Process adapter seam | `packages/agent/src/domains/capability/operations/process.rs` |
| Capability binding operations | `packages/agent/src/domains/capability/operations/capability_binding.rs` |
| Capability contract | `packages/agent/src/domains/capability/contract.rs` |
| Capability binding schema fields | `packages/agent/src/domains/capability/capability_binding_contract.rs` |
| Capability binding docs/service | `packages/agent/src/domains/capability_binding/mod.rs` |
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
| Canonical README | `README.md` |

## Baseline Facts

| Fact | Evidence |
|---|---|
| Registry count | 170 entries in `SUPPORTED_OPERATION_NAMES`. |
| Dispatch parity | 170 static dispatch arms in `execute_operation`; no missing or extra names. |
| Provider surface | One model-facing tool, `capability::execute`. |
| Machine inventory | `packages/agent/docs/capability-modularity-inventory.tsv` lists every operation exactly once. |
| Deterministic grouping | The invariant test maps operation prefixes to the expected family and ownership class. |
| Kernel boundary lockdown | Static invariants require source anchors for authority/grants, event/session log, resource store, redaction/provider-safety, trace/audit/replay/catalog, transport boundary, and module governance pipeline before locked rows can change ownership class. |
| Capability binding policy | `capability_binding_request`, `capability_binding_decision`, and `capability_binding_policy` resources record metadata-only replacement governance with exact selectors, idempotency, stale-version guards, rollback/disable refs, and provider-safe projections. |
| Shadow replacement trial | `capability_shadow_trial_request`, `capability_shadow_trial_decision`, `capability_shadow_trial_run`, and `capability_shadow_trial_evidence` resources record a governed metadata-only `git_status` trial with exact selectors, stale evidence rejection, rollback/disable/abort refs, provider-safe projections, and no dispatch mutation. |
| Adapter seam hardening | Adapter-replaceable families and the compaction strategy seam now name authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable prerequisites in source docs, inventory metadata, scorecard prose, and static tests. |
| Runtime behavior | No runtime routing, dispatch mutation, module hot-swap, install, activation, execution, package-manager, dependency-restore, or network behavior changed in this slice. |

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
| Side-effect proof explicitly records no runtime routing, dispatch mutation, hot-swap, module activation/execution, dependency restore, package-manager, network, raw path/command/log/file/grant/authority exposure, or repo-managed skill touch. | `packages/agent/src/domains/capability_binding/records.rs`, `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |

## Shadow Replacement Trial Evidence

| Evidence | Source |
|---|---|
| The first trial target is exactly `git_status`; other target operations are rejected before a trial request is recorded. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Trial requests require a deterministic metadata-only candidate adapter description, exact non-wildcard resource selectors, `networkPolicy: none`, rollback/disable/abort refs, stale inventory/policy guards, and no `agent_state` inheritance. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability/capability_binding_contract.rs` |
| Trial decisions and runs revalidate exact linked-resource selectors and expected current versions before writing append-only decision, run, and evidence resources. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| Trial evidence stores only bounded built-in/candidate `git_status` projections and server-computed comparison evidence; evidence inspect requires an exact resource selector and rejects stale expected evidence versions. | `packages/agent/src/domains/capability_binding/shadow_trial.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |
| No dispatch mutation or live replacement occurs: `git_status` remains owned by the built-in Git adapter, and shadow-trial side-effect proof records no runtime routing, hot-swap, candidate execution, module activation, package-manager, dependency, or network behavior. | `packages/agent/src/domains/capability/operations/mod.rs`, `packages/agent/src/domains/capability/operations/registry.rs`, `packages/agent/src/domains/capability_binding/tests.rs` |

## Adapter Seam Hardening Evidence

| Family | Source-backed seam evidence |
|---|---|
| `filesystem` | `packages/agent/src/domains/filesystem/mod.rs` records exact root authority, preview/commit evidence, bounded file side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `git` | `packages/agent/src/domains/git/mod.rs` records exact repository authority, HEAD/index evidence, guarded Git side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `process_run` | `packages/agent/src/domains/capability/operations/process.rs` records trusted working-directory authority, networkPolicy none, bounded process side effects, provider-safe result projection, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `jobs` | `packages/agent/src/domains/jobs/mod.rs` records supervised runtime authority, lifecycle evidence, bounded job side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `web` | `packages/agent/src/domains/web/mod.rs` records exact network authority, robots/source evidence, fail-closed side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `subagents` | `packages/agent/src/domains/subagents/mod.rs` records exact task/runtime/job authority, merge evidence, bounded subagent side effects, provider-safe refs, replay/idempotency evidence, and rollback/disable metadata as replacement prerequisites. |
| `context_control_compact` | `packages/agent/src/domains/context_control/mod.rs` and `packages/agent/src/domains/agent/context/mod.rs` record the summarizer strategy seam, provider-safe summary, context audit records, replay/idempotency evidence, and rollback/disable metadata while keeping context-control records server-owned. |

## Validation Commands

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::capability_binding::tests -- --nocapture
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
- Capability Binding Policy is a metadata-only governance plane. It adds provider-visible request/decision/policy and shadow-trial custody operations, but no runtime capability routing, module replacement, package installation, worker enablement, dependency restore, package-manager behavior, or network behavior.
- Shadow replacement trial evidence is intentionally metadata-only. It compares bounded built-in and deterministic candidate projections for `git_status`; it does not execute a candidate module or change live operation routing.
- `adapter_replaceable` rows now name required authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable prerequisites and hand off to the shadow replacement trial.
- `record_plane` rows allow module producers or workflow extension while preserving server-owned custody records and provider-safe projections.
- `context_control_compact` is the only compaction-like strategy seam in this slice: a future summarizer replacement cannot bypass context audit records or expose raw prompt material.
- `module_program_execution_*` is the first module-owned execution pack and is used as the baseline template for later governed replacement.
- Future operations must update the TSV, this scorecard, and this manifest before the invariant test will pass.
