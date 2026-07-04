# Capability Modularity Evidence Manifest

Status: active / inventory-complete

This manifest records the evidence reviewed for the capability modularity scorecard. The scorecard is a documentation and invariant slice only; it adds no runtime routing behavior.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/registry.rs` |
| Operation dispatch | `packages/agent/src/domains/capability/operations/mod.rs` |
| Capability contract | `packages/agent/src/domains/capability/contract.rs` |
| Module registry docs | `packages/agent/src/domains/module_registry/mod.rs` |
| Module lifecycle docs | `packages/agent/src/domains/module_lifecycle/mod.rs` |
| Module runtime docs | `packages/agent/src/domains/module_runtime/mod.rs` |
| Module dependencies docs | `packages/agent/src/domains/module_dependencies/mod.rs` |
| Module program execution docs | `packages/agent/src/domains/module_program_execution/mod.rs` |
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
| Runtime behavior | No runtime routing or execution behavior changed in this slice. |

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
- `adapter_replaceable` rows name the future replacement target and currently retain follow-up actions for adapter seams or binding policy.
- `record_plane` rows allow module producers or workflow extension while preserving server-owned custody records and provider-safe projections.
- `module_program_execution_*` is the first module-owned execution pack and is used as the baseline template for future governed replacement.
- Future operations must update the TSV, this scorecard, and this manifest before the invariant test will pass.
