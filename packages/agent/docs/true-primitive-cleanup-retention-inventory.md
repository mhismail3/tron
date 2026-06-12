# True Primitive Cleanup Retention Inventory

Status: `passed_after_fix`

Created: 2026-06-09

Scorecard: [`true-primitive-cleanup-scorecard.md`](true-primitive-cleanup-scorecard.md)

Machine-readable inventory:
[`true-primitive-cleanup-retention-inventory.tsv`](true-primitive-cleanup-retention-inventory.tsv)

## Purpose

This inventory classifies every tracked source, test, docs, and script path in
TPC scope before cleanup rows start deleting or splitting code. It is a
retention map, not an authority source; source files and static gates govern if
this inventory drifts.

## Classification Vocabulary

| Classification | Meaning |
|----------------|---------|
| `primitive` | A retained host/model primitive or direct primitive substrate. |
| `implementation` | A narrow implementation of a retained primitive or client shell behavior. |
| `support` | Boot, provider, storage, transport, platform, resource, asset, or helper support needed by retained behavior. |
| `test` | Unit, integration, static, simulator, or source-guard verification. |
| `docs` | Current docs, scorecards, inventories, evidence, or root guidance. |
| `delete` | A tracked source path selected for deletion by a later TPC row. |

## Coverage Scope

The TSV covers tracked and newly introduced files under:

- `README.md` and `AGENTS.md`;
- `packages/agent/src/`, `packages/agent/tests/`, and `packages/agent/docs/`;
- `packages/ios-app/Sources/`, `packages/ios-app/Tests/`, and `packages/ios-app/docs/`;
- `packages/mac-app/Sources/`, `packages/mac-app/Tests/`, and `packages/mac-app/docs/`;
- `scripts/`.

## Classification Summary

| Classification | Count |
|----------------|------:|
| primitive | 106 |
| implementation | 497 |
| support | 381 |
| test | 473 |
| docs | 72 |
| delete | 0 |

## Owner Summary

| Owner | Count |
|-------|------:|
| `agent_runtime` | 71 |
| `app_bootstrap` | 11 |
| `auth` | 19 |
| `capability` | 1 |
| `capability_execute` | 8 |
| `docs/static gates` | 72 |
| `domain_worker` | 6 |
| `engine` | 101 |
| `ios` | 95 |
| `ios_engine` | 132 |
| `ios_session` | 67 |
| `ios_ui` | 134 |
| `mac` | 76 |
| `model_provider` | 78 |
| `platform` | 2 |
| `protocol` | 1 |
| `registration` | 5 |
| `rust_crate` | 2 |
| `scripts` | 22 |
| `server_errors` | 1 |
| `session` | 1 |
| `session_storage` | 63 |
| `session_store` | 3 |
| `settings` | 16 |
| `shared_foundation` | 44 |
| `test_harness` | 473 |
| `transport` | 25 |

## Delete Candidates

No file is classified as `delete` in the current TPC inventory. Later TPC rows
may delete or split files, then regenerate this inventory.

## Open Loops

- Hard LOC targets are closed for tracked Rust, Swift, and script source/test
  files.
- Broad residue scans and active-doc stale path checks are closed by TPC-10.
- The retained contributor deployment helper is explicitly `manual-deploy`; the
  ordinary `deploy` command spelling is not retained.
- No open loops remain after TPC-11 final verification.
