# Post-HRA Adversarial Hardening Evidence Manifest

Current score: **5/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

## Summary

This manifest records the red/green evidence for the post-HRA adversarial
hardening campaign. AHA-0 intentionally adds failing gates before fixes so the
known audit findings are covered by executable proof.

## Evidence Table

| ID | Status | Change summary | Verification | Residuals | Commit |
|----|--------|----------------|--------------|-----------|--------|
| AHA-0 | passed_after_fix | Created the scorecard, evidence manifest, README links, and red static gates for the adversarial audit findings. | Red proof captured by `cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants -- --nocapture`; see AHA-0 red proof below. | The new target is intentionally red until AHA-1 through AHA-9 are implemented. | pending |
| AHA-1 | pending | Not started. | Pending. | Personal-info/source identity leaks remain intentionally red. | pending |
| AHA-2 | pending | Not started. | Pending. | Deleted-doc/template residue remains intentionally red. | pending |
| AHA-3 | pending | Not started. | Pending. | CI/static-gate parity remains intentionally red. | pending |
| AHA-4 | pending | Not started. | Pending. | Xcode drift and Mac test execution parity remain intentionally red. | pending |
| AHA-5 | pending | Not started. | Pending. | Rust module ownership aliases remain intentionally red. | pending |
| AHA-6 | pending | Not started. | Pending. | Rust progressive docs and near-budget rows remain intentionally red. | pending |
| AHA-7 | pending | Not started. | Pending. | iOS `misc` client residue remains intentionally red. | pending |
| AHA-8 | pending | Not started. | Pending. | iOS hierarchy/budget/doc gaps remain intentionally red. | pending |
| AHA-9 | pending | Not started. | Pending. | Inventory/provenance integrity gaps remain intentionally red. | pending |
| AHA-10 | pending | Not started. | Pending. | Final closeout proof remains pending. | pending |

## AHA-0 Red Proof

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants -- --nocapture
```

Result: exit 101 on 2026-06-08. The target compiled and ran 13 tests: 1 passed
and 12 failed intentionally.

Passing setup proof:

- `post_hra_adversarial_hardening_scorecard_stays_formalized`

Red findings covered by executable gates:

- `full_repo_personal_info_guard_passes`: raw `/Users/<USER>` source-path
  equivalents remain in historical evidence and iOS fixtures before AHA-1.
- `live_docs_templates_and_scorecards_have_no_deleted_doc_residue`: live docs,
  templates, and scorecards still contain retired Claude config wording, stale
  active scorecard wording, or deleted-doc claims before AHA-2.
- `github_ci_runs_rust_static_gates_for_docs_templates_ios_and_mac_changes`:
  GitHub CI does not yet prove Rust-owned static gates run for docs/templates,
  iOS, and Mac path changes before AHA-3.
- `github_rust_ci_matches_tron_ci_test_harness_shape`: GitHub Rust CI does not
  yet match the `scripts/tron ci test` harness shape before AHA-3.
- `xcodegen_workflows_fail_on_tracked_project_drift`: workflows do not yet fail
  on tracked Xcode project drift after XcodeGen before AHA-4.
- `mac_ci_runs_focused_wrapper_tests`: GitHub CI does not yet run the focused
  Mac wrapper path/status/Tailscale suites before AHA-4.
- `rust_production_modules_have_no_path_aliases_or_module_inception`: production
  Rust still has `#[path]` aliases and module-inception residue before AHA-5.
- `rust_provider_shared_and_settings_loader_use_physical_owners`: provider
  shared helpers and the settings loader still rely on alias-shaped exports
  before AHA-5.
- `rust_near_budget_files_have_explicit_warning_rows`: seven Rust files at or
  above 850 LOC lack explicit near-budget rows before AHA-6.
- `ios_engine_clients_have_no_misc_facade`: `MiscClient` and `.misc` call sites
  remain before AHA-7.
- `ios_sourceguard_has_deep_hierarchy_and_budget_gates`: SourceGuard lacks the
  deeper iOS hierarchy and Swift near-budget coverage before AHA-8.
- `inventory_and_provenance_have_no_open_or_external_closeout_state`: HRA docs
  still depend on an external Downloads plan path before AHA-9.

## Residual Risk Log

- The target is intentionally red after AHA-0. Each later phase must update this
  manifest with the green proof that closes its own red findings.
