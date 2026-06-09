# True Primitive Cleanup Evidence Manifest

Created: 2026-06-09

Scorecard: [`true-primitive-cleanup-scorecard.md`](true-primitive-cleanup-scorecard.md)

Current score: **5/100**

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
| TPC-0 | passed_after_fix | Formalized the TPC scorecard/evidence pair, README links, static invariant target, and current hard-LOC red baseline. Red proof showed the new invariant target did not exist and current source/test files exceeded the TPC hard budgets. | Red target proof: `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 101, no test target named `true_primitive_cleanup_invariants`. Red Rust LOC scan -> exit 0, 20 files over TPC Rust limits. Red Swift LOC scan -> exit 0, 11 files over TPC Swift limits. Green setup proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` -> exit 0, 4 passed; `git diff --check` -> exit 0. | TPC-1 still needs a complete tracked source inventory. TPC-2 through TPC-8 must split or delete the recorded over-budget files. | TPC-0 setup checkpoint |
| TPC-1 | pending | Pending. | Pending. | Pending. | pending |
| TPC-2 | pending | Pending. | Pending. | Pending. | pending |
| TPC-3 | pending | Pending. | Pending. | Pending. | pending |
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
