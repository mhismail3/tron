# Post-HRA Adversarial Hardening Evidence Manifest

Current score: **47/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

## Summary

This manifest records the red/green evidence for the post-HRA adversarial
hardening campaign. AHA-0 intentionally adds failing gates before fixes so the
known audit findings are covered by executable proof.

## Evidence Table

| ID | Status | Change summary | Verification | Residuals | Commit |
|----|--------|----------------|--------------|-----------|--------|
| AHA-0 | passed_after_fix | Created the scorecard, evidence manifest, README links, and red static gates for the adversarial audit findings. | Red proof captured by `cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants -- --nocapture`; see AHA-0 red proof below. | Closed; later rows own the remaining red gates. | `bc8b33246` |
| AHA-1 | passed_after_fix | Redacted historical `/Users/<USER>` equivalents in evidence, moved ordinary iOS fixtures to neutral `/tmp/tron-fixtures/...` paths, removed tracked personal feedback email/domain/handle literals, replaced repo/release fallbacks with generic placeholders, made iOS feedback recipient blank by default with local/CI override, and expanded `scripts/personal-info-guard.sh` to catch personal handle/domain split constructions. | `scripts/personal-info-guard.sh`, the AHA full-repo personal-info gate, the Cargo repository regression, release-notes self-test, XcodeGen drift check, and focused iOS `AppConstantsTests`/`SourceGuardTests` all passed. Direct grep for raw home paths, personal handle/domain literals, and split handle constructions outside allowlisted guard tests returned no hits. | Closed. | `fb655244c` |
| AHA-2 | passed_after_fix | Rewrote PR template and CONTRIBUTING references to `AGENTS.md`, removed stale skill-copy wording from AGENTS, marked PCC/HRA README scorecard links completed instead of active, replaced a deleted-doc absence claim with current evidence/source-of-truth wording, and redacted historical helper-tree strings from PCC/AHA docs. | `cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants live_docs_templates_and_scorecards_have_no_deleted_doc_residue -- --nocapture` -> exit 0. Direct scan for the deleted-doc/template residue needles returned no hits. | Closed. | `ff5ed492d` |
| AHA-3 | passed_after_fix | Added a separate Ubuntu `rust-static-gates` CI job for docs/templates/iOS/Mac/script/CI path changes, wired it to PET/PCC/HRA/AHA invariant targets, changed GitHub Rust CI to run `scripts/tron ci test`, and aligned Clippy help/docs with the Cargo lint-policy contract. | AHA workflow path/static gate, Rust harness-shape gate, and Clippy contract gate all passed after the workflow/docs update. | Closed; later phases may extend the AHA target with additional static gates. | pending |
| AHA-4 | passed_after_fix | Added post-XcodeGen `git diff --exit-code` checks for tracked iOS/Mac projects in CI and release workflows, kept Mac `build-for-testing`, and added focused CI execution for `TronPathsTests`, `ServerStatusPollerTests`, and `TailscaleProbeTests`. | AHA Xcode drift and Mac wrapper CI gates both passed after the workflow update. | Closed; final closeout still reruns local XcodeGen drift checks and focused Mac tests. | pending |
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

## AHA-1 Verification

Completed source-identity cleanup:

- Historical evidence paths now use `/Users/<USER>` instead of raw developer
  home paths.
- iOS path fixtures now use `/tmp/tron-fixtures/...`.
- `TRON_FEEDBACK_EMAIL` is blank in tracked `Base.xcconfig`; `Local.xcconfig`,
  CI secrets, or release build settings can provide the recipient.
- iOS Mac-download URLs and Mac feedback issue URLs use tracked generic
  placeholders instead of maintainer handles.
- `scripts/personal-info-guard.sh` now bans the personal GitHub handle, personal
  feedback domain, and common split-string forms such as adjacent `"mh"`,
  `"is"`, and `"mail"` fragments.

Focused proof:

```bash
scripts/personal-info-guard.sh
```

Result: exit 0.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants full_repo_personal_info_guard_passes -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml cargo_pkg_repository_has_no_personal_handle -- --nocapture
```

Result: exit 0, 1 passed.

```bash
scripts/tron-release-notes --test
```

Result: exit 0.

```bash
cd packages/ios-app && xcodegen generate
git diff --exit-code packages/ios-app/TronMobile.xcodeproj
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/AppConstantsTests -only-testing:TronMobileTests/SourceGuardTests
```

Result: exit 0. The focused iOS batch ran 5 `AppConstantsTests` and 35
`SourceGuardTests`; all passed. A first focused run failed on the xcconfig URL
escape, empty feedback-setting parsing, and remaining neutral fixture paths;
those findings were fixed before this green rerun.

Direct grep for the guard's banned raw-home, encoded-home, personal
handle/domain, and split-construction patterns was run with only the guard
script and Rust path-regression test excluded.

Result: no hits.

## AHA-2 Verification

Deleted-doc/template residue cleanup:

- `.github/pull_request_template.md` now references `AGENTS.md`, source-local
  module docs, and package docs rather than retired helper paths.
- `CONTRIBUTING.md` now points contributors at `AGENTS.md` for README
  maintenance.
- `AGENTS.md` keeps the managed-skills teardown rule without stale sync wording.
- README living docs mark PCC/HRA scorecards and gates as completed while AHA
  remains active.
- Historical PCC/AHA scorecard and evidence text no longer retain the deleted
  helper-tree path names or uppercase retired guidance filename.

Proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants live_docs_templates_and_scorecards_have_no_deleted_doc_residue -- --nocapture
```

Result: exit 0, 1 passed.

Direct scan for the deleted-doc/template residue needles across GitHub
templates, README, CONTRIBUTING, AGENTS, package docs, and scorecards returned
no hits.

## AHA-3 Verification

CI/static-gate parity cleanup:

- `.github/workflows/ci.yml` now has a `rust-static-gates` Ubuntu job that runs
  `primitive_engine_teardown_plan_invariants`,
  `primitive_code_cleanup_invariants`, `hierarchical_rearchitecture_invariants`,
  and `post_hra_adversarial_hardening_invariants`.
- The static-gates path filter includes GitHub templates, README,
  CONTRIBUTING, AGENTS, agent docs, iOS, Mac, scripts, and CI workflow changes.
- The full Rust job now invokes `scripts/tron ci test` instead of a plain
  `cargo test`, preserving the local harness shape for serial integration tests
  and `primitive_trace_execution`.
- `tron ci clippy` help and live docs now describe enforcement through
  `packages/agent/Cargo.toml` lint levels rather than a blanket `-D warnings`
  policy.

Proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants github_ci_runs_rust_static_gates_for_docs_templates_ios_and_mac_changes -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants github_rust_ci_matches_tron_ci_test_harness_shape -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants tron_ci_clippy_contract_matches_cargo_lint_policy -- --nocapture
```

Result: exit 0, 1 passed.

## AHA-4 Verification

Xcode project drift and Mac wrapper CI cleanup:

- CI and iOS release workflows run `git diff --exit-code
  packages/ios-app/TronMobile.xcodeproj` after `xcodegen generate`.
- CI and Mac release workflows run `git diff --exit-code
  packages/mac-app/TronMac.xcodeproj` after `xcodegen generate`.
- Mac CI keeps `xcodebuild build-for-testing` compile/link coverage and adds a
  focused `xcodebuild test` step for `TronPathsTests`,
  `ServerStatusPollerTests`, and `TailscaleProbeTests`.
- Mac development docs now document the focused remote test coverage and keep
  broader app-hosted tests as local verification for wrapper changes.

Proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants xcodegen_workflows_fail_on_tracked_project_drift -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants mac_ci_runs_focused_wrapper_tests -- --nocapture
```

Result: exit 0, 1 passed. A first attempt to run both focused Cargo filters in
one command failed because Cargo accepts only one test name filter; the checks
were rerun individually and passed.
