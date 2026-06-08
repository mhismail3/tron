# Hierarchical Rearchitecture Inventory

Status: `running`

Generated from the live checkout before implementation moves.

Baseline commit: `7cedc8ac3`

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Machine-Readable Artifacts

- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-move-map.tsv`

Both TSV files use this stable header:

```text
current_path	target_path	package	area	owner	classification	reason	phase	status	notes
```

Allowed classifications:

- `retain_in_place`
- `move`
- `split`
- `merge`
- `delete`
- `asset`
- `generated`
- `external_boundary`

Allowed statuses:

- `pending`
- `running`
- `passed`
- `passed_after_fix`
- `failed_unfixed`
- `blocked`
- `deferred_to_successor`

## HRA-0 Baseline Counts

| Metric | Count |
|--------|-------|
| Tracked files from `git ls-files` | 1267 |
| Rust files under `packages/agent/src` | 467 |
| Swift files under `packages/ios-app/Sources` | 355 |
| Swift files under `packages/ios-app/Tests` | 192 |
| Swift files under `packages/mac-app/Sources` | 49 |
| Swift files under `packages/mac-app/Tests` | 33 |

## Current Drift Signals

HRA-0 verifies these drift signals with static gates before implementation
moves:

- Rust source root still contains loose helper files outside `lib.rs` and
  `main.rs`.
- Rust `engine` still exposes many flat root modules instead of subsystem
  folders.
- iOS still has broad `Sources/UI/Views`, `Sources/Engine/Network`,
  `Sources/Engine/Database`, and related technical buckets.
- iOS tests still use broad historical buckets instead of mirroring production
  ownership boundaries.
- Several Rust and Swift source/test files exceed the campaign line budgets and
  need explicit HRA-1 budget rows before they can remain temporarily over
  budget.

## Target Architecture

The target architecture is the hierarchy in `TRON_REARCHITECTURE_PLAN.md` from
the operator Downloads directory, refined only when the live dependency graph
proves a better ownership boundary. HRA-1 owns the final folder table and
per-file move map.

## HRA-0 Inventory Policy

The initial TSV inventory is generated from the real tracked tree plus the new
HRA artifacts created in this checkpoint. Rows are marked `pending` because
HRA-1 owns final classification, target path, and owner decisions. Paths that
are clearly assets or generated project files are labeled immediately so the
static gate can validate the vocabulary.

## Open Loops

- Replace HRA-0 pending placeholders with final HRA-1 classifications.
- Add a complete retained-folder owner table.
- Add explicit large-file decomposition or temporary budget rows.
- Record docs with old path claims and update them in the owning closeout rows.
