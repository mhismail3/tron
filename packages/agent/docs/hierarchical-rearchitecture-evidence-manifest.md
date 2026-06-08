# Hierarchical Rearchitecture Evidence Manifest

Current score: **5/100**

Status: **running**

Branch: `codex/primitive-engine-teardown`

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Evidence Rows

| ID | Status | Evidence | Verification | Open loops | Commit |
|----|--------|----------|--------------|------------|--------|
| HRA-0 | passed_after_fix | Created the scorecard, evidence manifest, human inventory, generated TSV inventory, generated move map, Rust invariant target, README living-doc links, and `scripts/tron.d/quality.sh` CI hook. The invariant target intentionally fails against the current tree on loose Rust root files, flat engine root modules, broad iOS source buckets, non-mirrored iOS test buckets, and over-budget files without decomposition rows. | Red output captured below. | Red gates are expected until HRA-2 through HRA-13 move the tree and HRA-1 records final budgets. | pending |
| HRA-1 | pending | Not started. | pending | Complete final per-file target classification and folder owner table. | pending |
| HRA-2 | pending | Not started. | pending | Move Rust app/transport/shared/platform roots. | pending |
| HRA-3 | pending | Not started. | pending | Move Rust engine kernel/catalog/invocation/runtime. | pending |
| HRA-4 | pending | Not started. | pending | Move Rust engine authority/durability. | pending |
| HRA-5 | pending | Not started. | pending | Move Rust domains to vertical slices. | pending |
| HRA-6 | pending | Not started. | pending | Move Rust session/event-store and split oversized tests. | pending |
| HRA-7 | pending | Not started. | pending | Mirror Rust tests and update progressive docs. | pending |
| HRA-8 | pending | Not started. | pending | Add iOS SourceGuard red hierarchy gates and project map. | pending |
| HRA-9 | pending | Not started. | pending | Move iOS Engine hierarchy and split transport. | pending |
| HRA-10 | pending | Not started. | pending | Move iOS Session hierarchy. | pending |
| HRA-11 | pending | Not started. | pending | Move iOS UI hierarchy. | pending |
| HRA-12 | pending | Not started. | pending | Move iOS Support hierarchy. | pending |
| HRA-13 | pending | Not started. | pending | Mirror iOS tests and regenerate XcodeGen. | pending |
| HRA-14 | pending | Not started. | pending | Audit Mac hierarchy and move justified drift. | pending |
| HRA-15 | pending | Not started. | pending | Close docs/scripts/README old path references. | pending |
| HRA-16 | pending | Not started. | pending | Final verification, adversarial review, ledger, and closeout. | pending |

## HRA-0 Red Static Gate

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate.

Summary:

```text
running 7 tests
test hierarchical_rearchitecture_scorecard_stays_formalized ... ok
test tracked_files_have_rearchitecture_inventory_rows ... ok
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED
test rust_engine_root_has_no_unowned_flat_modules ... FAILED
test rust_source_root_has_only_allowed_entry_files ... FAILED
test large_files_have_decomposition_budget_rows ... FAILED

test result: FAILED. 2 passed; 5 failed
```

Failure inventory:

- `rust_source_root_has_only_allowed_entry_files`: `packages/agent/src/main_tests.rs`,
  `packages/agent/src/main_cli.rs`, and `packages/agent/src/main_runtime.rs`
  remain loose root files.
- `rust_engine_root_has_no_unowned_flat_modules`: flat engine root modules remain
  for compensation, ledger, policy, grants, types, host, registry, protocol,
  triggers, streams, discovery, leases, queue, schema, state, ids, errors,
  invocation, external, and capabilities.
- `ios_sources_do_not_use_broad_views_network_database_buckets`:
  `Sources/UI/Views`, `Sources/Engine/Network`, `Sources/Engine/Database`,
  `Sources/Engine/EventStore`, `Sources/Session/ViewModels/Managers`,
  `Sources/Session/ViewModels/Utilities`, `Sources/Support/Utilities`, and
  `Sources/Support/Extensions` remain.
- `ios_tests_mirror_source_boundaries`: `Tests/Engine`, `Tests/Session`, and
  `Tests/UI` are missing while old test buckets remain under `Core`,
  `Extensions`, `Models`, `Navigation`, `Observability`, `Onboarding`,
  `Repositories`, `Services`, `Theme`, `Utilities`, `ViewModels`, and `Views`.
- `large_files_have_decomposition_budget_rows`: 24 Rust/Swift files currently
  exceed HRA line budgets without explicit HRA-1 budget rows.
