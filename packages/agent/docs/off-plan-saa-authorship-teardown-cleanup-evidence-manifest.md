# Off-Plan SAA Authorship Teardown Cleanup Evidence Manifest

Status: **complete**

Current score: **100/100**

Target commit under remediation:
`e781a6aef263327d82f666611cb975a71e67e2ee` (`Complete SAA authorship scorecard`).

## Baseline Evidence

| Evidence | Result |
| --- | --- |
| Branch/base | `codex/off-plan-saa-authorship-teardown-cleanup` created from detached `e781a6aef263327d82f666611cb975a71e67e2ee`. |
| SAA commit inventory | `git show --name-status e781a6aef` identified SAA docs/tests, execute `resource_*` adapter, provider schema/instruction widening, `agent_memory`/`agent_rule` resource definitions, SAA runtime grants, README/CI/static gate entries, and predecessor inventory rows. |
| Pre-SAA source proof | `git diff e781a6aef^ e781a6aef -- ...` showed generic `engine::resource` primitives predated SAA while provider-visible execute resource operations and memory/rule kinds were SAA-only additions. |

## Row Evidence

| Row | Status | Evidence | Verification | Residual risk |
| --- | --- | --- | --- | --- |
| OPSAA-0 | passed_after_fix | Harness artifacts added and wired into README, local quality, and GitHub CI lists. | OPSAA target parses scorecard, evidence, inventory, TSV, README, and CI/local target wiring. | Future remediation campaigns need their own harness rows. |
| OPSAA-1 | passed_after_fix | Inventory classifies SAA surfaces and retained generic substrate. | OPSAA target checks required inventory classifications and paths. | Classification is source-history based; later features need their own proof. |
| OPSAA-2 | passed_after_fix | Provider-visible execute schema and OpenAI clarification are re-narrowed. | OPSAA target rejects `resource_create`, `resource_update`, `resource_link`, `resource_inspect`, and `resource_list` in provider schema/instructions and execute dispatcher. | Other providers rely on shared model capability conversion. |
| OPSAA-3 | passed_after_fix | `packages/agent/src/domains/capability/operations/resource.rs` deleted; generic `engine::resource` retained. | Capability and durability tests exercise retained primitive behavior. | Retained generic resource primitives are not provider-visible through `execute`. |
| OPSAA-4 | passed_after_fix | `agent_memory` and `agent_rule` definitions, namespace claims, grant kind expansion, and durability test requirements removed. | OPSAA target rejects active built-ins, namespace claims, and grant entries. | Future memory/rule resources require a successor scorecard and migration review. |
| OPSAA-5 | passed_after_fix | Active SAA docs/tests deleted and static closeout target removed. | OPSAA target rejects active tracked SAA docs/tests and `self_adapting_agent_authorship_invariants` wiring. | Historical evidence outside active docs may still mention future/successor SAA context. |
| OPSAA-6 | passed_after_fix | HRA/PCC/TPC/SACB inventories remove SAA rows, add OPSAA rows, and refresh counts. | HRA, PCC, TPC, and SACB invariant targets pass after reconciliation. | Inventory counts must be refreshed if tracked files change again. |
| OPSAA-7 | passed_after_fix | Negative guards added in OPSAA target. | `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture`. | Static guards complement, not replace, semantic review. |
| OPSAA-8 | passed_after_fix | Retained primitive behavior covered by existing focused targets. | Capability, durability, trace, SACB, ODA, HRA, PCC, TPC, and integration targets pass. | Full live server/manual UI proof is outside this cleanup. |
| OPSAA-9 | passed_after_fix | Final verification log is recorded below before commit. | Full closeout command list passes, followed by final commit/status checks. | No residual cleanup risk known after clean commit. |

## Verification Log

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Formatting check passes after final docs/test edits. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Rust check passes with existing dead-code warnings in provider/durability code. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::capability --lib -- --nocapture` | passed | Capability library tests pass: 3 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture` | passed | Engine durability tests pass: 41 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | passed | OPSAA static gate passes after scorecard/evidence/inventory closeout. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | passed | ODA invariant target passes: 11 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed | SACB invariant target passes: 17 passed after splitting platform guards. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | passed | HRA invariant target passes: 35 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | passed | PCC invariant target passes: 16 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | passed | TPC invariant target passes: 15 passed after retention inventory and LOC fixes. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Primitive trace integration passes: 8 passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Public transport integration passes: 2 passed. |
| `scripts/tron ci fmt check clippy test` | passed | Full Rust CI passes after OPSAA evidence closure. |
| `scripts/personal-info-guard.sh` | passed | Personal-info guard reports no blocked literals. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | iOS project generation leaves no project diff. |
| `git diff --check` | passed | Diff whitespace check passes. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files reported. |
| `git status --short` | passed | Pre-commit status shows only the intended staged cleanup diff; post-commit status is recorded in final response. |

## Failed Attempts and Fixes

- Initial `off_plan_saa_authorship_teardown_cleanup_invariants` run failed
  because the new cleanup docs still showed in-progress state and the retained
  `ui_surface` guard looked for a string literal instead of the
  `UI_SURFACE_KIND` constant. The docs were closed and the guard now checks the
  retained constant plus durability contract coverage.
- A later OPSAA rerun failed because the inventory markdown linked the TSV by
  basename while the invariant expects the full repo path. The inventory now
  includes `packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv`.
- Initial `true_primitive_cleanup_invariants` rerun failed because the TPC
  retention inventory lacked later ODA/OPSAA rows and
  `security_authority_capability_boundaries/static_guards.rs` exceeded the
  800-line budget. The retention inventory now covers those rows, and SACB
  platform custody/pairing guards are split into
  `platform_guards.rs`.
