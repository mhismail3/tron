# Post-HRA Adversarial Hardening Scorecard

Current score: **100/100**

Status: **completed**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `d63e8646a159802202a3ca48b217bedc5e944317`

Plan: `packages/agent/docs/post-hra-adversarial-hardening-plan-summary.md`,
the redacted in-repo digest of `/Users/<USER>/Downloads/PLAN (1).md`.

## Operating Rules

- The campaign starts with red static gates for the adversarial audit findings.
- Fixes remove old surfaces physically; compatibility facades, old-path imports,
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
| `packages/agent/docs/post-hra-adversarial-hardening-scorecard.md` | completed | Weighted campaign scorecard, open-loop ledger, and closeout state. |
| `packages/agent/docs/post-hra-adversarial-hardening-evidence-manifest.md` | completed | Red/green proof, verification commands, commit hashes, and residual risk. |
| `packages/agent/tests/post_hra_adversarial_hardening_invariants.rs` | completed | Integration target for adversarial hardening static gates. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| AHA-0 | Scorecard, evidence, and red-gate setup | 5 | passed_after_fix | architecture campaign | Created this scorecard, evidence manifest, README links, and intentionally red static gate target. | Later rows turn the red gates green. |
| AHA-1 | Personal-info and source identity cleanup | 12 | passed_after_fix | source hygiene owner | Full-repo personal-info guard passes. Historical paths are redacted, iOS fixtures use neutral paths, feedback/release/repo identity uses blank or generic tracked defaults, and the guard bans personal handle/domain split constructions. | Closed; later phases may still edit docs/templates for non-identity residue. |
| AHA-2 | Deleted-doc and template residue | 10 | passed_after_fix | docs/templates owner | Live docs/templates/scorecards residue gate passes. PR template and contributor docs now point at `AGENTS.md`, stale active scorecard wording is completed/current, and historical helper-tree strings are redacted. | Closed; AHA-3 still owns workflow parity. |
| AHA-3 | CI and static-gate parity | 12 | passed_after_fix | CI owner | GitHub CI now has an Ubuntu `rust-static-gates` job for docs/templates/iOS/Mac/script/CI changes, runs PET/PCC/HRA/AHA invariant targets, and the full Rust job invokes `scripts/tron ci test` so serial integration and trace targets match the local harness. `tron ci clippy` docs/help now describe the Cargo lint policy instead of a blanket `-D warnings` contract. | Closed; later phases may add more static gates but workflow parity is established. |
| AHA-4 | Xcode project drift and Mac test execution | 8 | passed_after_fix | Apple CI owner | CI and release workflows fail on tracked iOS Xcode project drift after `xcodegen generate`; Mac workflows verify the ignored generated project exists and then build/test from it. Mac CI keeps `build-for-testing` and adds focused `TronPathsTests`, `ServerStatusPollerTests`, and `TailscaleProbeTests` execution. | Closed; final closeout still reruns iOS XcodeGen drift checks, Mac generation/build checks, and focused Mac tests. |
| AHA-5 | Rust module ownership cleanup | 10 | passed_after_fix | Rust architecture owner | Production `#[path]` aliases and module-inception allowances are removed. Provider shared helpers live under `providers::shared`, settings loader paths use `profile::storage::loader`, OpenAI provider tests use a normal folder module, and the orchestrator coordinator lives under `orchestrator::core`. | Closed; AHA-6 owns documentation and near-budget watch rows for the new ownership roots. |
| AHA-6 | Rust progressive docs and near-budget guard | 6 | passed_after_fix | Rust docs/tests owner | Ownership-critical Rust roots touched by AHA-5 now carry progressive docs. Current Rust files at or above the 850 LOC warning band have explicit watch rows below without reviving HRA temporary-budget language, and the HRA/PCC inventories cover the moved Rust ownership paths. | Closed; final closeout still reruns the full Rust static targets. |
| AHA-7 | iOS transport/domain residue | 10 | passed_after_fix | iOS engine owner | `MiscClient` is deleted. `EngineClientProtocol` and call sites use concrete `system`, `message`, and `logs` clients; stale Git workflow error/comment residue and `Sub-Managers` terminology are removed. | Closed; no `misc` compatibility facade remains. |
| AHA-8 | iOS hierarchy, budgets, and docs | 9 | passed_after_fix | iOS architecture owner | SourceGuard now enforces deep hierarchy/count/budget gates for Engine clients, shared capability UI, settings shell, shared components, and Session/Chat tests. Swift files at or above the 590 LOC warning band have explicit watch rows, iOS resource docs are current, and redundant iOS 26 availability annotations are removed. | Closed; final closeout reruns XcodeGen drift and focused iOS tests. |
| AHA-9 | Inventory and provenance integrity | 8 | passed_after_fix | inventory/provenance owner | HRA live maps are renamed current ownership maps, the completed-HRA inventory gate rejects open row statuses, and HRA provenance now points at the in-repo plan summary. | Closed; no current inventory or ownership-map row remains open. |
| AHA-10 | Final adversarial closeout | 10 | passed_after_fix | architecture campaign | Full Rust CI, AHA/HRA/PCC/static gates, rustdoc, personal-info guard, XcodeGen drift checks, focused iOS/Mac tests, broad residue scans, and a fresh adversarial subagent audit passed after addressing closeout findings. | Closed; implementation hash is recorded in the evidence manifest. |

## Static Gates

The Rust integration target
`post_hra_adversarial_hardening_invariants` owns these checks:

- `post_hra_adversarial_hardening_scorecard_stays_formalized`
- `full_repo_personal_info_guard_passes`
- `live_docs_templates_and_scorecards_have_no_deleted_doc_residue`
- `github_ci_runs_rust_static_gates_for_docs_templates_ios_and_mac_changes`
- `github_rust_ci_matches_tron_ci_test_harness_shape`
- `tron_ci_clippy_contract_matches_cargo_lint_policy`
- `external_cli_variance_has_no_compatibility_or_fallback_wording`
- `xcodegen_workflows_match_ios_tracked_and_mac_untracked_policy`
- `mac_ci_runs_focused_wrapper_tests`
- `rust_production_modules_have_no_path_aliases_or_module_inception`
- `rust_provider_shared_and_settings_loader_use_physical_owners`
- `rust_near_budget_files_have_explicit_warning_rows`
- `rust_ownership_roots_have_progressive_docs`
- `ios_engine_clients_have_no_misc_facade`
- `ios_transport_domain_residue_is_removed`
- `ios_sourceguard_has_deep_hierarchy_and_budget_gates`
- `inventory_and_provenance_have_no_open_or_external_closeout_state`

## Open Loops

- No AHA implementation rows remain open. The evidence manifest records the
  final closeout proof, adversarial audit findings, and implementation hashes.

## Rust Near-Budget Watchlist

The hard HRA Rust source/test limit remains 900 LOC. AHA-6 adds an explicit
850 LOC warning band so ownership-critical files cannot quietly cross into the
hard limit without review.

| Path | Current LOC | Owner | Warning-band action | Status |
|------|-------------|-------|---------------------|--------|
| `packages/agent/src/domains/model/providers/factory.rs` | 878 | model providers owner | Watch provider selection/auth construction; split provider-specific builders before adding new provider branches. | watch |
| `packages/agent/src/engine/catalog/registry/mod.rs` | 895 | engine catalog owner | At the hard-limit edge; new catalog mutation or query behavior must move into `catalog_changes`, `invocation`, or a new registry helper module first. | watch |
| `packages/agent/src/engine/durability/ledger/mod.rs` | 862 | engine durability owner | Keep ledger contracts in root; move new SQLite/raw-row behavior into `sqlite_codec` or dedicated helpers. | watch |
| `packages/agent/src/engine/durability/queue/mod.rs` | 861 | engine durability owner | Keep queue contracts in root; move new drain/runtime or SQLite behavior into owned helper modules. | watch |
| `packages/agent/src/engine/invocation/host/mod.rs` | 880 | engine invocation owner | Keep host type boundary in root; move new catalog/substrate/invocation/meta behavior into existing host helper modules. | watch |
| `packages/agent/src/engine/runtime/external_workers/mod.rs` | 855 | engine runtime owner | Move new proxy, lifecycle, or protocol-specific behavior out before it approaches the 900 LOC hard limit. | watch |
| `packages/agent/src/transport/engine/socket/mod.rs` | 873 | engine transport owner | Keep WebSocket session boundary in root; move new wire/projection/outbound behavior into existing socket helper modules. | watch |

## Swift Near-Budget Watchlist

The hard HRA Swift source/test limit remains 700 LOC. AHA-8 adds an explicit
590 LOC warning band so high-pressure UI, diagnostics, and test files cannot
quietly become oversized modules.

| Path | Current LOC | Owner | Warning-band action | Status |
|------|-------------|-------|---------------------|--------|
| `packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift` | 651 | chat event-routing test owner | Split new event-routing coverage into coordinator- or event-family tests before expanding this file. | watch |
| `packages/ios-app/Tests/Engine/Persistence/EventDatabaseTests.swift` | 650 | event database test owner | Add new persistence cases under behavior-specific test files before growing the broad database suite. | watch |
| `packages/ios-app/Tests/UI/Chat/TurnGroupingTests.swift` | 611 | chat grouping test owner | Split new grouping cases into role/timeline-specific tests before expanding shared fixtures. | watch |
| `packages/ios-app/Tests/Session/Chat/TurnLifecycleCoordinatorTests.swift` | 608 | turn lifecycle test owner | Add new lifecycle cases under focused coordinator tests before increasing this broad suite. | watch |
| `packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift` | 595 | settings shell owner | Move new settings section support into page-owned files before expanding the shared shell support file. | watch |
| `packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift` | 593 | model picker owner | Move new provider/model row behavior into focused picker components before growing the sheet root. | watch |
| `packages/ios-app/Tests/Session/Chat/Navigation/ScrollStateCoordinatorTests.swift` | 590 | chat navigation test owner | Move new scroll-state cases into focused navigation tests before this threshold row grows further. | watch |
