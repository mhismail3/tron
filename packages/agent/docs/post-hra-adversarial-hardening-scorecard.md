# Post-HRA Adversarial Hardening Scorecard

Current score: **47/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `d63e8646a159802202a3ca48b217bedc5e944317`

Plan: `/Users/<USER>/Downloads/PLAN (1).md`, redacted from the operator
Downloads path used to seed this campaign.

## Operating Rules

- The campaign starts with red static gates for the adversarial audit findings.
- Fixes remove old surfaces physically; compatibility facades, fallback imports,
  and stale aliases are not acceptable closeout states.
- Code, tests, docs, generated projects, evidence, and ledger records move
  together for each checkpoint.
- Every phase records honest residuals before commit. Open loops are either
  closed in the next phase or kept visible in this scorecard and the evidence
  manifest.
- Historical evidence may remain only when redacted and clearly marked as
  historical evidence, not live architecture guidance.

## Required Artifacts

| Artifact | Status | Purpose |
|----------|--------|---------|
| `packages/agent/docs/post-hra-adversarial-hardening-scorecard.md` | active | Weighted campaign scorecard, open-loop ledger, and closeout state. |
| `packages/agent/docs/post-hra-adversarial-hardening-evidence-manifest.md` | active | Red/green proof, verification commands, commit hashes, and residual risk. |
| `packages/agent/tests/post_hra_adversarial_hardening_invariants.rs` | red | Integration target for adversarial hardening static gates. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| AHA-0 | Scorecard, evidence, and red-gate setup | 5 | passed_after_fix | architecture campaign | Created this scorecard, evidence manifest, README links, and intentionally red static gate target. | Later rows turn the red gates green. |
| AHA-1 | Personal-info and source identity cleanup | 12 | passed_after_fix | source hygiene owner | Full-repo personal-info guard passes. Historical paths are redacted, iOS fixtures use neutral paths, feedback/release/repo identity uses blank or generic tracked defaults, and the guard bans personal handle/domain split constructions. | Closed; later phases may still edit docs/templates for non-identity residue. |
| AHA-2 | Deleted-doc and template residue | 10 | passed_after_fix | docs/templates owner | Live docs/templates/scorecards residue gate passes. PR template and contributor docs now point at `AGENTS.md`, stale active scorecard wording is completed/current, and historical helper-tree strings are redacted. | Closed; AHA-3 still owns workflow parity. |
| AHA-3 | CI and static-gate parity | 12 | passed_after_fix | CI owner | GitHub CI now has an Ubuntu `rust-static-gates` job for docs/templates/iOS/Mac/script/CI changes, runs PET/PCC/HRA/AHA invariant targets, and the full Rust job invokes `scripts/tron ci test` so serial integration and trace targets match the local harness. `tron ci clippy` docs/help now describe the Cargo lint policy instead of a blanket `-D warnings` contract. | Closed; later phases may add more static gates but workflow parity is established. |
| AHA-4 | Xcode project drift and Mac test execution | 8 | passed_after_fix | Apple CI owner | CI and release workflows fail on tracked iOS/Mac Xcode project drift after `xcodegen generate`. Mac CI keeps `build-for-testing` and adds focused `TronPathsTests`, `ServerStatusPollerTests`, and `TailscaleProbeTests` execution. | Closed; final closeout still reruns local XcodeGen drift checks and focused Mac tests. |
| AHA-5 | Rust module ownership cleanup | 10 | pending | Rust architecture owner | Rust module ownership gate currently fails by design. | Remove production `#[path]` aliases, provider shared aliases, settings loader aliases, and module inception. |
| AHA-6 | Rust progressive docs and near-budget guard | 6 | pending | Rust docs/tests owner | Rust near-budget gate currently fails by design. | Expand progressive docs gates and add 850 LOC warning rows for near-budget Rust files. |
| AHA-7 | iOS transport/domain residue | 10 | pending | iOS engine owner | iOS `misc` gate currently fails by design. | Replace `MiscClient` with concrete system/message/logs clients and remove residue. |
| AHA-8 | iOS hierarchy, budgets, and docs | 9 | pending | iOS architecture owner | iOS hierarchy/budget gate currently fails by design. | Deepen SourceGuard, add Swift near-budget rows, refresh docs, and remove redundant availability noise. |
| AHA-9 | Inventory and provenance integrity | 8 | pending | inventory/provenance owner | Inventory/provenance gate currently fails by design. | Rename current move maps or reconstruct lineage, reject open inventory states at completed score, and archive external HRA plan provenance in repo. |
| AHA-10 | Final adversarial closeout | 10 | pending | architecture campaign | Final proof is pending. | Rerun all gates, broad scans, iOS/Mac checks, adversarial audit, ledger append, hash record, and clean repo proof. |

## Static Gates

The Rust integration target
`post_hra_adversarial_hardening_invariants` owns these checks:

- `post_hra_adversarial_hardening_scorecard_stays_formalized`
- `full_repo_personal_info_guard_passes`
- `live_docs_templates_and_scorecards_have_no_deleted_doc_residue`
- `github_ci_runs_rust_static_gates_for_docs_templates_ios_and_mac_changes`
- `github_rust_ci_matches_tron_ci_test_harness_shape`
- `tron_ci_clippy_contract_matches_cargo_lint_policy`
- `xcodegen_workflows_fail_on_tracked_project_drift`
- `mac_ci_runs_focused_wrapper_tests`
- `rust_production_modules_have_no_path_aliases_or_module_inception`
- `rust_provider_shared_and_settings_loader_use_physical_owners`
- `rust_near_budget_files_have_explicit_warning_rows`
- `ios_engine_clients_have_no_misc_facade`
- `ios_sourceguard_has_deep_hierarchy_and_budget_gates`
- `inventory_and_provenance_have_no_open_or_external_closeout_state`

## Open Loops

- AHA-0 is complete after the red target is committed.
- AHA-1 through AHA-4 are closed. AHA-5 through AHA-10 remain open and
  intentionally red until their owners are implemented.
