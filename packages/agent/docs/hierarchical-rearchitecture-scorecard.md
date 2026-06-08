# Hierarchical Rearchitecture Scorecard

Current score: **80/100**

Status: **running**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `7cedc8ac3`

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Operating Rules

- The campaign reorganizes ownership boundaries only after red static gates
  describe the current drift.
- Every retained folder must have an owner, reason, allowed contents, and test
  responsibility before closeout.
- Moves must remove old internal paths instead of preserving compatibility
  shims, alias modules, or fallback wrappers.
- Code, tests, docs, generated projects, scorecard, evidence, and inventory
  move together in each checkpoint.
- HRA-0 intentionally leaves the new invariant target red against the current
  tree; later rows turn those gates green by changing the architecture.

## Required Artifacts

| Artifact | Status | Purpose |
|----------|--------|---------|
| `packages/agent/docs/hierarchical-rearchitecture-scorecard.md` | running | Weighted campaign scorecard and open-loop ledger. |
| `packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md` | running | Verification, red/green output, commit hashes, and residual risk. |
| `packages/agent/docs/hierarchical-rearchitecture-inventory.md` | running | Human-readable inventory summary and target architecture notes. |
| `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv` | running | Machine-readable tracked-file inventory. |
| `packages/agent/docs/hierarchical-rearchitecture-move-map.tsv` | running | Machine-readable old-to-new path map. |
| `packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv` | running | HRA-8 machine-readable source/test Swift move map for iOS hierarchy phases. |
| `packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md` | running | HRA-8 XcodeGen, ShareExtension, SourceGuard, and iOS phase-ownership project map. |
| `packages/agent/tests/hierarchical_rearchitecture_invariants.rs` | running | Static hierarchy gates for this campaign. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| HRA-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix | architecture campaign | Required artifacts, README links, CI hook, and red hierarchy invariant target are present. | Red gates are expected until later rows move code. |
| HRA-1 | Whole-repo inventory and target architecture | 8 | passed_after_fix | architecture campaign | Live tracked-file inventory, target move map, folder owner table, drift findings, and large-file budgets are recorded. | Pending move/split rows are implementation work for HRA-2 through HRA-14, not unclassified inventory. |
| HRA-2 | Rust app, transport, shared, and platform roots | 6 | passed_after_fix | Rust app/transport/shared owners | Moved root binary helpers into app CLI/bootstrap, grouped app health/lifecycle/bootstrap, grouped transport HTTP/engine/runtime, collapsed shared into foundation/protocol/server/storage/observability, and updated README/static gates. | HRA-15 still owns broad stale-path doc scans outside current-code docs. |
| HRA-3 | Rust engine kernel and invocation hierarchy | 10 | passed_after_fix | Rust engine owner | Moved kernel/catalog/invocation/runtime modules under owned subsystem roots, collapsed invocation host into `invocation/host`, split kernel types under `kernel/types`, and removed avoidable engine same-name file/folder pairs. | Runtime and authority/durability files that remain over budget have explicit budget rows; HRA-7 owns broader Rust test/doc decomposition. |
| HRA-4 | Rust engine durability and authority hierarchy | 8 | passed_after_fix | Rust engine owner | Moved grants/leases/compensation under `authority`; moved ledger/queue/resources/state/streams under `durability`; kept SQLite codecs under their owning stores; collapsed resource store into `resources/store/mod.rs`. | Authority/durability store modules remain cohesive but over 900 LOC with explicit temporary budgets. |
| HRA-5 | Rust domain vertical slices | 10 | passed_after_fix | Rust domain owners | Moved registration helpers under `domains/registration`; moved agent prompt/loop/context, auth oauth/credentials, model routing/protocol, and settings profile owners; split capability operations, Kimi stream tests, and over-budget domain test modules. | Closed with no remaining HRA-5 temporary file budgets. |
| HRA-6 | Rust session and event-store hierarchy | 7 | passed_after_fix | Rust session owner | Moved session lifecycle/query/reconstruction into owner folders, moved event-store envelope/factory/reconstruction/store/session repository tests to folder-backed modules, and split SQLite event repository tests by behavior. | HRA-7 still owns broader Rust test/doc budget cleanup. |
| HRA-7 | Rust tests and progressive docs | 5 | passed_after_fix | Rust docs/tests owners | Mirrored engine tests to subsystem folders, split root static integration gates into folder-backed modules, decomposed over-budget Rust stores/runtime helpers, and updated progressive docs/README. | iOS hierarchy closure is owned by HRA-9 through HRA-13. |
| HRA-8 | iOS inventory, SourceGuard, and target project map | 6 | passed_after_fix | iOS architecture owner | Added HRA SourceGuard red hierarchy checks, generated the 547-row iOS source/test Swift move map, recorded the XcodeGen/share-extension project map, and added a Rust map-coverage invariant. | HRA-11 through HRA-13 must consume the remaining pending map rows and turn the SourceGuard hierarchy checks green. |
| HRA-9 | iOS Engine hierarchy | 8 | passed_after_fix | iOS engine owner | Moved Engine transport, protocol DTOs, event live/payload/plugin/reconstruction code, persistence, and repositories into target owner folders; split `EngineConnection` into focused WebSocket request, receive, reconnect, frame, and type units; regenerated XcodeGen. | HRA-11 through HRA-13 still own UI, Support, and test hierarchy closure. |
| HRA-10 | iOS Session hierarchy | 7 | passed_after_fix | iOS session owner | Moved Session chat view models, coordinators, messaging, navigation, state, attachments, timeline activity/messages/reconstruction/tokens, and retained parsing under workflow-owned folders; split `CapabilityInvocationDisplayModel` presentation helpers. | HRA-11 through HRA-13 still own UI, Support, and test hierarchy closure. |
| HRA-11 | iOS UI hierarchy | 6 | pending | iOS UI owner | Not started. | Replace `UI/Views` with feature-owned folders. |
| HRA-12 | iOS Support foundation hierarchy | 4 | pending | iOS support owner | Not started. | Split utilities, extensions, infrastructure, and services into concrete support concerns. |
| HRA-13 | iOS tests and generated project closeout | 4 | pending | iOS test owner | Not started. | Mirror tests, decompose SourceGuard, regenerate XcodeGen, and run focused tests. |
| HRA-14 | Mac wrapper hierarchy audit | 2 | pending | Mac wrapper owner | Not started. | Audit Mac source/test folders and move only justified drift. |
| HRA-15 | Scripts, README, and docs path closeout | 2 | pending | docs/scripts owner | Not started. | Remove old-path claims and update README/docs/scripts/workflows. |
| HRA-16 | Final adversarial review and closeout | 2 | pending | architecture campaign | Not started. | Run full verification, adversarial review, ledger append, and final commit. |

## Folder Justification Table

HRA-1 owns the exhaustive folder table. HRA-0 records only the active root
owners required to bootstrap the campaign.

| Folder | Owner | Allowed contents | Status |
|--------|-------|------------------|--------|
| `packages/agent/src` | Rust crate boundary | `lib.rs`, `main.rs`, and owned module folders after HRA-2. | passed_after_fix |
| `packages/agent/src/app` | Rust app/bootstrap owner | CLI, bootstrap, health, metrics, lifecycle, and server startup code after HRA-2. | passed_after_fix |
| `packages/agent/src/transport` | Rust transport owner | HTTP, engine socket, worker socket, runtime dispatch, and transport DTOs after HRA-2. | passed_after_fix |
| `packages/agent/src/engine` | Rust engine substrate owner | Kernel, catalog, invocation, authority, durability, runtime, primitives, and engine tests after HRA-3/HRA-4. | passed_after_fix |
| `packages/agent/src/domains` | Rust vertical domain owner | Registration plus behavior-owned domain slices, including session lifecycle/query/reconstruction and event-store owners after HRA-6. | passed_after_fix |
| `packages/agent/src/shared` | Rust cross-owner support owner | Foundation/protocol/server/storage/observability helpers used by multiple owners after HRA-2. | passed_after_fix |
| `packages/ios-app/Sources` | iOS app target boundary | App, Engine, Session, UI, Support, Resources, assets, and plist files after HRA-9/HRA-12. | pending |
| `packages/ios-app/Tests` | iOS test target boundary | Infrastructure and tests mirroring Engine, Session, UI, and Support after HRA-13. | pending |
| `packages/mac-app/Sources` | Mac wrapper target boundary | App, Server, MenuBar, Wizard, Support, Resources, and assets after HRA-14. | pending |
| `packages/mac-app/Tests` | Mac wrapper test target boundary | Tests mirroring Mac wrapper features after HRA-14. | pending |

## Large File Budgets

Every current over-budget source/test file has an explicit owner, limit, current
LOC, and phase-owned decomposition plan. HRA-5 now closes without any remaining
HRA-5 temporary budget rows.

| Path | Owner | Limit | Current LOC | Decomposition plan | Status |
|------|-------|-------|-------------|--------------------|--------|
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` | ios UI owner | 700 | 817 | HRA-11 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Sources/UI/Views/Settings/SettingsView.swift` | ios UI owner | 700 | 735 | HRA-11 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | ios test owner | 700 | 2140 | HRA-13 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | ios test owner | 700 | 1743 | HRA-13 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/mac-app/Tests/Wizard/WizardStepTests.swift` | mac wrapper owner | 700 | 717 | HRA-14 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |

## Static Gates

The Rust integration target `hierarchical_rearchitecture_invariants` owns these
checks:

- `hierarchical_rearchitecture_scorecard_stays_formalized`
- `tracked_files_have_rearchitecture_inventory_rows`
- `rust_source_root_has_only_allowed_entry_files`
- `rust_app_transport_shared_roots_are_owned`
- `rust_engine_root_has_no_unowned_flat_modules`
- `rust_engine_subsystem_roots_are_owned`
- `rust_engine_has_no_same_name_file_folder_pairs`
- `rust_non_session_domains_have_no_same_name_file_folder_pairs`
- `rust_session_domain_uses_lifecycle_query_reconstruction_owners`
- `rust_session_event_store_has_no_same_name_file_folder_pairs`
- `rust_session_event_store_uses_owned_modules_without_path_attrs`
- `rust_session_event_repository_tests_are_behavior_split`
- `rust_model_domain_uses_routing_and_protocol_owners`
- `rust_auth_domain_uses_oauth_and_credentials_owners`
- `rust_agent_domain_uses_prompt_loop_context_owners`
- `rust_domain_root_has_only_owned_boundaries`
- `rust_capability_execute_operations_are_decomposed`
- `rust_settings_domain_keeps_worker_root_thin`
- `rust_engine_tests_are_mirrored_by_subsystem`
- `rust_hra7_has_no_remaining_overbudget_rust_files`
- `rust_progressive_docs_declare_dependency_and_test_ownership`
- `ios_hra8_move_map_covers_every_source_and_test_swift_file`
- `ios_engine_hra9_sources_use_target_boundaries`
- `ios_session_hra10_sources_use_target_boundaries`
- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`
- `large_files_have_decomposition_budget_rows`

## Open Loops

- HRA-11 through HRA-13 still own iOS UI, Support, and test hierarchy moves plus SourceGuard red closure.
- The project `@self-inspect` skill referenced by `AGENTS.md` is not installed
  in this Codex environment; direct repository and database inspection will be
  used until an equivalent skill becomes available.
