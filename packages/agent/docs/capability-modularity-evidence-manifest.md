# Capability Modularity Evidence Manifest

Status: active / kernel-boundary-lockdown-complete

This manifest records the evidence reviewed for the capability modularity scorecard. The scorecard is a documentation and invariant slice only; it adds no runtime routing behavior.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/registry.rs` |
| Operation dispatch | `packages/agent/src/domains/capability/operations/mod.rs` |
| Capability contract | `packages/agent/src/domains/capability/contract.rs` |
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
| Registry count | 157 entries in `SUPPORTED_OPERATION_NAMES`. |
| Dispatch parity | 157 static dispatch arms in `execute_operation`; no missing or extra names. |
| Provider surface | One model-facing tool, `capability::execute`. |
| Machine inventory | `packages/agent/docs/capability-modularity-inventory.tsv` lists every operation exactly once. |
| Deterministic grouping | The invariant test maps operation prefixes to the expected family and ownership class. |
| Kernel boundary lockdown | Static invariants require source anchors for authority/grants, event/session log, resource store, redaction/provider-safety, trace/audit/replay/catalog, transport boundary, and module governance pipeline before locked rows can change ownership class. |
| Runtime behavior | No runtime routing or execution behavior changed in this slice. |

## Kernel Boundary Lockdown Evidence

| Area | Source anchors | Inventory lock |
|---|---|---|
| authority/grants | `packages/agent/src/engine/authority/mod.rs`, `packages/agent/src/engine/mod.rs` | Engine-owned grant resolution remains kernel substrate and is not adapter/module-routed. |
| event/session log | `packages/agent/src/domains/session/event_store/mod.rs` | `logs` operations stay `kernel_locked`; event truth and deterministic reconstruction stay server-owned. |
| resource store | `packages/agent/src/engine/durability/mod.rs`, `packages/agent/src/engine/durability/resources/mod.rs` | Resource-backed custody families stay `record_plane`; modules may produce records but cannot bypass the store. |
| redaction/provider-safety | `packages/agent/src/shared/foundation/redaction.rs`, `packages/agent/src/domains/session/event_store/redaction.rs`, `packages/agent/src/domains/capability/mod.rs` | Locked and governance-visible rows retain provider-safe projections and shared redaction anchors. |
| trace/audit/replay/catalog | `packages/agent/src/domains/capability/operations/mod.rs`, `packages/agent/src/engine/durability/replay.rs`, `packages/agent/src/domains/catalog_discovery/mod.rs` | `trace_*`, `replay_manifest`, and `catalog_*` stay `kernel_locked`; catalog discovery is not invocation. |
| transport boundary | `packages/agent/src/transport/mod.rs`, `packages/agent/src/transport/engine/mod.rs`, `packages/agent/src/transport/http/auth.rs` | Transport remains authenticated framing over canonical engine requests and owns no domain behavior. |
| module governance pipeline | `packages/agent/src/domains/module_registry/mod.rs`, `packages/agent/src/domains/module_authoring/mod.rs`, `packages/agent/src/domains/module_validation/mod.rs`, `packages/agent/src/domains/module_install/mod.rs`, `packages/agent/src/domains/module_dependencies/mod.rs`, `packages/agent/src/domains/module_lifecycle/mod.rs`, `packages/agent/src/domains/module_runtime/mod.rs`, `packages/agent/src/domains/tool_sources/mod.rs`, `packages/agent/src/domains/worker_lifecycle/mod.rs` | Module registry, authoring, validation, install, dependency, lifecycle, runtime, procedural, tool-source, worker-package, device-token, and notification-delivery gates stay `governance_locked`. |

## Validation Commands

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
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
- Kernel Boundary Lockdown is an evidence gate only. It adds no binding policy, runtime capability routing, module replacement, package installation, worker activation, network behavior, or provider-visible operations.
- `adapter_replaceable` rows name the future replacement target and currently retain follow-up actions for adapter seams or binding policy.
- `record_plane` rows allow module producers or workflow extension while preserving server-owned custody records and provider-safe projections.
- `module_program_execution_*` is the first module-owned execution pack and is used as the baseline template for future governed replacement.
- Future operations must update the TSV, this scorecard, and this manifest before the invariant test will pass.
