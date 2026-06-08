# Hierarchical Rearchitecture Evidence Manifest

Current score: **37/100**

Status: **running**

Branch: `codex/primitive-engine-teardown`

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Evidence Rows

| ID | Status | Evidence | Verification | Open loops | Commit |
|----|--------|----------|--------------|------------|--------|
| HRA-0 | passed_after_fix | Created the scorecard, evidence manifest, human inventory, generated TSV inventory, generated move map, Rust invariant target, README living-doc links, and `scripts/tron.d/quality.sh` CI hook. The invariant target intentionally fails against the current tree on loose Rust root files, flat engine root modules, broad iOS source buckets, non-mirrored iOS test buckets, and over-budget files without decomposition rows. | Red output captured below. | Red gates are expected until HRA-2 through HRA-13 move the tree and HRA-1 records final budgets. | `f14f7b60c` |
| HRA-1 | passed_after_fix | Replaced HRA-0 placeholder TSVs with a live tracked-file target map; recorded counts, extension counts, package counts, loose root files, overfull folders, one-file folders, generic bucket folders, same-name file/folder pairs, over-budget files, docs/scripts old-path claims, and retained folder owners. No code files were moved in this row. | Focused HRA invariant rerun improved from 2 passed/5 failed to 3 passed/4 failed: formalization, inventory coverage, and large-file budget gates pass; root Rust, engine root, iOS source bucket, and iOS test mirror gates remain red for implementation rows. | Pending move/split implementation rows remain HRA-2 through HRA-14; docs closeout remains HRA-15. | `58be3f8df` |
| HRA-2 | passed_after_fix | Moved `main_cli.rs`, `main_runtime.rs`, and `main_tests.rs` under `app/cli` and `app/bootstrap`; moved app config/disk/server/health/metrics/onboarding/shutdown under bootstrap/health/lifecycle; moved transport auth/contracts/engine/engine_ws/setup under http/engine/runtime; collapsed shared root into foundation/protocol/server/storage/observability; removed old path modules instead of re-exporting them. | `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib app::bootstrap -- --quiet` passed 80 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet` passed 27 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet` passed 16 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet` passed 13 tests; HRA invariant target is expected partial red with Rust source-root and HRA-2 shape gates passing. | iOS source/test gates remain red for HRA-9 through HRA-13. | `67b8a5aa6` |
| HRA-3 | passed_after_fix | Moved flat engine root modules into `kernel`, `catalog`, `invocation`, and `runtime`; collapsed `host.rs` plus `host/` into `invocation/host`; split the over-budget kernel type file into `kernel/types/{catalog,function,trigger,worker}.rs`; moved primitive `resource` and `ui` files to folder `mod.rs` owners so no engine same-name file/folder pairs remain. | Command batch passed except the expected partial-red HRA target: Rust engine gates pass and only iOS source/test gates fail. Full command outcomes recorded in HRA-3/HRA-4 verification below. | Engine runtime/store files still over budget are listed with explicit temporary budgets; HRA-7 owns test/doc decomposition after the production hierarchy stabilizes. | `ff4640ce8` |
| HRA-4 | passed_after_fix | Moved grants, leases, and compensation under `authority`; moved ledger, queue, resources, state, and streams under `durability`; kept SQLite codecs under their owning store folders; collapsed resource store into `durability/resources/store/mod.rs`; regenerated HRA and primitive cleanup inventories. | Command batch passed except the expected partial-red HRA target: authority/durability compile and engine tests pass. Full command outcomes recorded in HRA-3/HRA-4 verification below. | Authority/durability store modules remain cohesive but over 900 LOC with explicit temporary budget rows; no compatibility modules preserve old paths. | `ff4640ce8` |
| HRA-5 | running | Added red domain hierarchy gates for non-session same-name module pairs, capability operation decomposition, and settings root operation ownership. | Red gate captured: HRA target ran 13 tests, 8 passed and 5 failed. The three new Rust failures are HRA-5 implementation work; two existing iOS failures remain HRA-9 through HRA-13 work. | Implement domain moves/splits until the new HRA-5 gates pass. | pending |
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

## HRA-1 Inventory Verification

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected partial red gate.

Summary:

```text
running 7 tests
test hierarchical_rearchitecture_scorecard_stays_formalized ... ok
test tracked_files_have_rearchitecture_inventory_rows ... ok
test large_files_have_decomposition_budget_rows ... ok
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED
test rust_engine_root_has_no_unowned_flat_modules ... FAILED
test rust_source_root_has_only_allowed_entry_files ... FAILED

test result: FAILED. 3 passed; 4 failed
```

The remaining failures are not HRA-1 inventory defects. They are implementation
gates for HRA-2, HRA-3/HRA-4, HRA-9/HRA-12, and HRA-13.

## HRA-2 Rust Root Verification

Commands:

```bash
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml --lib app::bootstrap -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `cargo check --bin tron`: passed.
- `app::bootstrap` unit slice: 80 passed.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- db path guard: 13 passed.
- HRA invariant target: expected partial red; Rust source root and HRA-2
  app/transport/shared shape gates pass, while engine and iOS gates remain red
  for later phases.

## HRA-3/HRA-4 Rust Engine Verification

Commands:

```bash
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml engine::tests:: --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `cargo check --bin tron`: passed.
- `engine::tests::` lib slice: 175 passed, 2746 filtered.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- db path guard: 13 passed.
- `cargo fmt --all -- --check`: passed.
- `git diff --check --cached && git diff --check`: passed.
- HRA invariant target: expected partial red with 8 passed and 2 failed. Passing
  gates cover formalization, tracked inventory, Rust source root, HRA-2
  app/transport/shared roots, HRA-3/HRA-4 engine subsystem roots, engine
  same-name file/folder guard, and large-file budget rows. The two remaining
  failures are `ios_sources_do_not_use_broad_views_network_database_buckets`
  and `ios_tests_mirror_source_boundaries`, owned by HRA-9 through HRA-13.

## HRA-5 Red Domain Gates

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate.

Summary:

```text
running 13 tests
test rust_non_session_domains_have_no_same_name_file_folder_pairs ... FAILED
test rust_capability_execute_operations_are_decomposed ... FAILED
test rust_settings_domain_keeps_worker_root_thin ... FAILED
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED

test result: FAILED. 8 passed; 5 failed
```

New HRA-5 failures before implementation:

- `rust_non_session_domains_have_no_same_name_file_folder_pairs`
- `rust_capability_execute_operations_are_decomposed`
- `rust_settings_domain_keeps_worker_root_thin`
