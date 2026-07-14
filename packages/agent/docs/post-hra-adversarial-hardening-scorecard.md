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
| AHA-2 | Deleted-doc and template residue | 10 | passed_after_fix | docs/templates owner | Live docs/templates/scorecards residue gate passes. PR template and contributor docs now point at `AGENTS.md`, stale active scorecard wording is completed/current, historical helper-tree strings are redacted, and the only allowed old helper-rule path references are the IARM old-tree census evidence rows. | Closed; AHA-3 still owns workflow parity. |
| AHA-3 | CI and static-gate parity | 12 | passed_after_fix | CI owner | GitHub CI now has an Ubuntu `rust-static-gates` job for docs/templates/iOS/Mac/script/CI changes, runs PET/PCC/HRA/AHA invariant targets, and the full Rust job invokes `scripts/tron ci test` so serial integration and trace targets match the local harness. `tron ci clippy` docs/help now describe the Cargo lint policy instead of a blanket `-D warnings` contract. | Closed; later phases may add more static gates but workflow parity is established. |
| AHA-4 | Xcode project drift and Mac test execution | 8 | passed_after_fix | Apple CI owner | CI and release workflows fail on tracked iOS Xcode project drift after `xcodegen generate`; Mac workflows verify the ignored generated project exists and then build/test from it. Mac CI keeps `build-for-testing` and adds focused `TronPathsTests`, `ServerStatusPollerTests`, and `TailscaleProbeTests` execution. | Closed; final closeout still reruns iOS XcodeGen drift checks, Mac generation/build checks, and focused Mac tests. |
| AHA-5 | Rust module ownership cleanup | 10 | passed_after_fix | Rust architecture owner | Production `#[path]` aliases and module-inception allowances are removed. Provider shared helpers live under `providers::shared`, settings loader paths use `profile::storage::loader`, OpenAI provider tests use a normal folder module, and the orchestrator coordinator lives under `orchestrator::core`. | Closed; AHA-6 owns documentation and near-budget watch rows for the new ownership roots. |
| AHA-6 | Rust progressive docs and near-budget guard | 6 | passed_after_fix | Rust docs/tests owner | Ownership-critical Rust roots touched by AHA-5 carry progressive docs. Current Rust files at or above the 850 LOC warning band must have an accepted owner and decomposition row in the canonical HRA budget ledger, and the HRA/PCC inventories cover moved Rust ownership paths. | Closed; final closeout still reruns the full Rust static targets. |
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

## Canonical Rust Budget Ledger

AHA-6 keeps the earlier 850 LOC warning trigger, but current ownership and
decomposition plans live only in
`packages/agent/docs/hierarchical-rearchitecture-scorecard.md`. The AHA gate
checks that every warning-band file has an accepted row there instead of
maintaining a second line-count snapshot.

## Swift Near-Budget Watchlist

The hard HRA Swift source/test limit remains 700 LOC. AHA-8 adds an explicit
590 LOC warning band so high-pressure UI, diagnostics, and test files cannot
quietly become oversized modules.

| Path | Current LOC | Owner | Warning-band action | Status |
|------|-------------|-------|---------------------|--------|
| `packages/ios-app/Sources/Engine/Persistence/Repositories/SessionRepository.swift` | 615 | session persistence repository owner | Split paged session listing from per-session event reconstruction before adding another persistence query or reconstruction mode. | watch |
| `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` | 888 | worker lifecycle projection owner | Issue aggregation now lives in `AgentCockpitIssueState.swift`; split capability-pool role projection, operation-row mapping, and summary derivation into further focused cockpit projection extensions before adding more presentation fields. | over_limit_followup |
| `packages/ios-app/Sources/UI/Capabilities/CapabilityInvocationViews.swift` | 656 | capability invocation UI owner | Split grouped invocation presentation from single-invocation progressive detail before adding another capability disclosure level. | watch |
| `packages/ios-app/Tests/Engine/Persistence/EventDatabaseTests.swift` | 646 | event database test owner | Add new persistence cases under behavior-specific test files before growing the broad database suite. | watch |
| `packages/ios-app/Tests/Engine/Persistence/SessionRepositoryTests.swift` | 601 | session persistence test owner | Split pagination/listing cases from event reconstruction and projection persistence cases before adding another repository behavior. | watch |
| `packages/ios-app/Tests/Engine/Persistence/Sync/EventStoreManagerTests.swift` | 696 | event-store synchronization test owner | Split cached-session merge/projection cases, global-event lifecycle cases, and SyncState/SessionEvent model cases into focused suites before adding another synchronization behavior. | watch |
| `packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesTests.swift` | 626 | engine protocol test owner | Move new DTO encoding/decoding cases into type-family test files before growing this broad protocol suite. | watch |
| `packages/ios-app/Tests/Engine/Protocol/WorkerLifecycleDTOTests.swift` | 723 | worker lifecycle protocol test owner | Split worker lifecycle DTO cases into capability-cockpit, package, and surface-family suites before broadening this transport/projection test file; this file remains over the hard guard and needs a focused follow-up split. | over_limit_followup |
| `packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+BuildAndProject.swift` | 665 | iOS build/project source-guard owner | Split scheme, XcodeGen, and device-action checks from privacy, storage, and production-surface checks before adding another cross-cutting assertion. | watch |
| `packages/ios-app/Tests/Session/Chat/ChatViewModelPaginationTests.swift` | 591 | chat pagination test owner | Keep pagination/autoload regressions in focused navigation or pagination suites before growing this broad pagination test file further. | watch |
| `packages/ios-app/Tests/Session/Chat/Navigation/ScrollStateCoordinatorTests.swift` | 616 | chat navigation test owner | Top-detent, scroll-phase prefetch, and one-shot pagination regressions now live in focused navigation/autoload tests; split future scroll-state cases before this general coordinator suite grows further. | watch |
| `packages/ios-app/Tests/Session/Chat/TurnLifecycleCoordinatorTests.swift` | 648 | turn lifecycle test owner | Add new lifecycle cases under focused coordinator tests before increasing this broad suite. | watch |
| `packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift` | 604 | chat event-routing test owner | Terminal/error event coverage now lives in a focused sibling suite; split future event-family cases before this broad routing suite grows again. | watch |
| `packages/ios-app/Tests/Session/WorkerLifecycle/AgentCockpitViewModelTestFixtures.swift` | 625 | worker lifecycle test fixture owner | Keep cockpit DTO builders and repository doubles here only; split protocol-family fixtures before adding more fixture state. | watch |
| `packages/ios-app/Tests/UI/Chat/TurnGroupingTests.swift` | 611 | chat grouping test owner | Split new grouping cases into role/timeline-specific tests before expanding shared fixtures. | watch |
| `packages/ios-app/Tests/UI/Onboarding/OnboardingStateTests.swift` | 627 | onboarding state test owner | Add pairing, repair, and persistence cases under focused onboarding suites before expanding this state-owner test file. | watch |
