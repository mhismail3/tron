# True Primitive Cleanup Evidence Manifest

Created: 2026-06-09

Scorecard: [`true-primitive-cleanup-scorecard.md`](true-primitive-cleanup-scorecard.md)

Current score: **35/100**

Status: **in_progress**

This manifest records command, source-audit, simulator, database, and commit
evidence for the True Primitive Cleanup campaign. Do not award points in the
scorecard without concrete evidence here.

## Baseline

- Branch: `codex/primitive-engine-teardown`.
- Baseline commit before TPC edits: `d307cdad2`.
- Plan: `/Users/<USER>/Downloads/PLAN (3).md`, redacted from the operator
  Downloads path.
- Compatibility assumption: none for deleted primitive-branch internals.

## Row Evidence

| Row | Status | Evidence summary | Commands / artifacts | Residual risk | Checkpoint |
|-----|--------|------------------|----------------------|---------------|------------|
| TPC-0 | passed_after_fix | Formalized the TPC scorecard/evidence pair, README links, static invariant target, and current hard-LOC red baseline. Red proof showed the new invariant target did not exist and current source/test files exceeded the TPC hard budgets. | Red target proof: `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 101, no test target named `true_primitive_cleanup_invariants`. Red Rust LOC scan -> exit 0, 20 files over TPC Rust limits. Red Swift LOC scan -> exit 0, 11 files over TPC Swift limits. Green setup proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 0, 4 passed; `git diff --check` -> exit 0. | TPC-1 still needs a complete tracked source inventory. TPC-2 through TPC-8 must split or delete the recorded over-budget files. | `498abfb24` |
| TPC-1 | passed_after_fix | Added `true-primitive-cleanup-retention-inventory.md` and `true-primitive-cleanup-retention-inventory.tsv`. The TSV now classifies 1,376 tracked and newly introduced files in TPC scope as `primitive`, `implementation`, `support`, `test`, `docs`, or `delete` after TPC-3 split files were added. Red proof failed on the missing inventory artifact before generation. | Red proof: `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants tracked_source_inventory_is_formalized -- --nocapture` -> exit 101, missing `true-primitive-cleanup-retention-inventory.md`. TPC-1 green proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants tracked_source_inventory_is_formalized -- --nocapture` -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 0, 5 passed; `git diff --check` -> exit 0. TPC-2 inventory regeneration: TSV updated to 1,370 rows. TPC-3 inventory regeneration: TSV updated to 1,376 rows. | Hard LOC, fallback/compatibility/no-op, provider alias, iOS fallback, and scripts/deploy cleanup remain owned by later rows. | `92521b511` |
| TPC-2 | passed_after_fix | Split the oversized catalog registry, catalog invocation idempotency, ledger, queue, and stream files into concern-owned modules. Removed default no-op durable-worker/function methods from `EngineLedgerStore`; in-memory and test ledgers now implement those methods explicitly. The TPC-2 static gate now proves the original oversized roots are under budget, the split files exist, and no ledger trait durable-catalog default remains. | Red proof: `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants engine_catalog_and_durability_roots_are_split_and_explicit -- --nocapture` -> exit 101, `engine/catalog/registry/mod.rs` had 895 LOC. Green proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants engine_catalog_and_durability_roots_are_split_and_explicit -- --nocapture` -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_discovery -- --nocapture` -> exit 0, 16 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib ledger_idempotency -- --nocapture` -> exit 0, 11 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib queue_lifecycle -- --nocapture` -> exit 0, 5 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib queue_inspection_persistence -- --nocapture` -> exit 0, 2 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib streams -- --nocapture` -> exit 0, 16 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 0, 6 passed; `git diff --check` -> exit 0. | Later rows own unrelated over-budget Rust files and broader fallback/provider/iOS/script residue scans. | `739612887` |
| TPC-3 | passed_after_fix | Split invocation host construction/bootstrap into `engine/invocation/host/bootstrap.rs` and meta/delegated invocation into `engine/invocation/host/meta_invocation.rs`; split primitive backend stores into `engine/primitives/stores.rs` and worker/function registration assembly into `engine/primitives/workers.rs`; moved trigger runtime helper handlers into `engine/tests/runtime/trigger_helpers.rs`. Added a static TPC-3 gate that proves the original host, primitive, and trigger roots are under their hard limits, the split owners exist, the host root has only the existing catalog-watch re-export, and the primitive root no longer contains `OnceLock` or weak-host store wiring. | Red proof: `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants invocation_host_and_primitive_store_roots_are_narrow -- --nocapture` -> exit 101, `engine/invocation/host/mod.rs` had 880 LOC. Green proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants invocation_host_and_primitive_store_roots_are_narrow -- --nocapture` -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib host_invocation -- --nocapture` -> exit 0, 14 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib meta_primitives -- --nocapture` -> exit 0, 10 passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib triggers -- --nocapture` -> exit 0, 15 passed; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 0, 7 passed; `git diff --check` -> exit 0. | Later rows own unrelated over-budget runtime, provider/auth/model, agent loop, iOS, scripts, and final residue scans. | `c7d16e4b9` |
| TPC-4 | pending | Pending. | Pending. | Pending. | pending |
| TPC-5 | pending | Pending. | Pending. | Pending. | pending |
| TPC-6 | pending | Pending. | Pending. | Pending. | pending |
| TPC-7 | pending | Pending. | Pending. | Pending. | pending |
| TPC-8 | pending | Pending. | Pending. | Pending. | pending |
| TPC-9 | pending | Pending. | Pending. | Pending. | pending |
| TPC-10 | pending | Pending. | Pending. | Pending. | pending |
| TPC-11 | pending | Pending. | Pending. | Pending. | pending |

## Red Baseline Commands

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture
```

Exit code: 101. The target did not exist before TPC-0.

```bash
find packages/agent/src packages/agent/tests -type f -name '*.rs' -exec sh -c 'for f; do n=$(wc -l < "$f" | tr -d " "); case "$f" in *tests*|*/tests.rs) limit=800;; *) limit=750;; esac; if [ "$n" -gt "$limit" ]; then printf "%s\t%s\tlimit=%s\n" "$n" "$f" "$limit"; fi; done' sh {} + | sort -nr
```

Exit code: 0. Output recorded in the scorecard Rust over-budget baseline.

```bash
find packages/ios-app/Sources packages/ios-app/Tests packages/mac-app/Sources packages/mac-app/Tests -type f -name '*.swift' -exec sh -c 'for f; do n=$(wc -l < "$f" | tr -d " "); case "$f" in *Tests*) limit=650;; *) limit=575;; esac; if [ "$n" -gt "$limit" ]; then printf "%s\t%s\tlimit=%s\n" "$n" "$f" "$limit"; fi; done' sh {} + | sort -nr
```

Exit code: 0. Output recorded in the scorecard Swift over-budget baseline.
