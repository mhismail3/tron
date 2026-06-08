# Hierarchical Rearchitecture Scorecard

Current score: **37/100**

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
| HRA-5 | Rust domain vertical slices | 10 | running | Rust domain owners | Red domain hierarchy gates added for non-session same-name module pairs, capability operation decomposition, and settings root operation ownership. | Reorganize domains by behavior instead of copied boilerplate. |
| HRA-6 | Rust session and event-store hierarchy | 7 | pending | Rust session owner | Not started. | Reorganize session lifecycle/query/reconstruction/event-store/trace and split oversized tests. |
| HRA-7 | Rust tests and progressive docs | 5 | pending | Rust docs/tests owners | Not started. | Mirror tests to new boundaries and update progressive docs. |
| HRA-8 | iOS inventory, SourceGuard, and target project map | 6 | pending | iOS architecture owner | Not started. | Add red SourceGuard hierarchy gates and iOS move map. |
| HRA-9 | iOS Engine hierarchy | 8 | pending | iOS engine owner | Not started. | Reorganize transport, protocol, events, persistence, and model filtering. |
| HRA-10 | iOS Session hierarchy | 7 | pending | iOS session owner | Not started. | Move chat, timeline, state, messaging, navigation, attachments, and parsing. |
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
| `packages/agent/src` | Rust crate boundary | `lib.rs`, `main.rs`, and owned module folders after HRA-2. | running |
| `packages/agent/src/app` | Rust app/bootstrap owner | CLI, bootstrap, health, metrics, lifecycle, and server startup code after HRA-2. | pending |
| `packages/agent/src/transport` | Rust transport owner | HTTP, engine socket, worker socket, runtime dispatch, and transport DTOs after HRA-2. | pending |
| `packages/agent/src/engine` | Rust engine substrate owner | Kernel, catalog, invocation, authority, durability, runtime, primitives, and engine tests after HRA-3/HRA-4. | passed_after_fix |
| `packages/agent/src/domains` | Rust vertical domain owner | Registration plus behavior-owned domain slices after HRA-5/HRA-6. | pending |
| `packages/agent/src/shared` | Rust cross-owner support owner | Foundation/protocol/server/storage/observability helpers used by multiple owners after HRA-2. | pending |
| `packages/ios-app/Sources` | iOS app target boundary | App, Engine, Session, UI, Support, Resources, assets, and plist files after HRA-9/HRA-12. | pending |
| `packages/ios-app/Tests` | iOS test target boundary | Infrastructure and tests mirroring Engine, Session, UI, and Support after HRA-13. | pending |
| `packages/mac-app/Sources` | Mac wrapper target boundary | App, Server, MenuBar, Wizard, Support, Resources, and assets after HRA-14. | pending |
| `packages/mac-app/Tests` | Mac wrapper test target boundary | Tests mirroring Mac wrapper features after HRA-14. | pending |

## Large File Budgets

HRA-0 intentionally starts with no approved over-budget source/test files. The
`large_files_have_decomposition_budget_rows` gate lists every current over-budget
file until HRA-1 records an explicit owner, reason, and decomposition or
temporary budget.

| Path | Owner | Limit | Current LOC | Decomposition plan | Status |
|------|-------|-------|-------------|--------------------|--------|
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | rust agent domain owner | 900 | 1182 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | rust agent domain owner | 900 | 1038 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/auth/provider_credentials/storage/tests.rs` | rust auth domain owner | 900 | 1383 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/capability/operations/mod.rs` | rust compact domain owner | 900 | 927 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/model/providers/anthropic/types.rs` | rust model domain owner | 900 | 941 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/model/providers/kimi/stream_handler.rs` | rust model domain owner | 900 | 991 | HRA-5 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | rust session domain owner | 900 | 1571 | HRA-6 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/src/engine/runtime/external_workers.rs` | rust engine runtime owner | 900 | 901 | Retained as one worker lifecycle runtime while HRA-3 moved it under `runtime`; HRA-7/final closeout will split if it grows or a clearer sub-boundary appears. | temporary_budget |
| `packages/agent/src/engine/authority/grants/mod.rs` | rust engine authority owner | 900 | 958 | Retained as one authority lifecycle store after HRA-4; split validation/store APIs only when a focused HRA-7 test/doc pass can preserve the authority invariant. | temporary_budget |
| `packages/agent/src/engine/durability/ledger/mod.rs` | rust engine durability owner | 900 | 955 | Retained as one ledger/idempotency store boundary after HRA-4; split only with focused ledger tests. | temporary_budget |
| `packages/agent/src/engine/durability/resources/store/mod.rs` | rust engine durability owner | 900 | 972 | Retained as one resource store boundary after HRA-4 with SQLite codec/tests under the store; split only with focused resource-store tests. | temporary_budget |
| `packages/agent/src/engine/tests/grant_authority.rs` | rust engine test owner | 900 | 929 | HRA-7 owns engine test decomposition after production module moves stabilize. | temporary_budget |
| `packages/agent/src/engine/tests/resource_kernel.rs` | rust engine test owner | 900 | 1196 | HRA-7 owns engine test decomposition after production module moves stabilize. | temporary_budget |
| `packages/agent/src/engine/tests/state_queue.rs` | rust engine test owner | 900 | 910 | HRA-7 owns engine test decomposition after production module moves stabilize. | temporary_budget |
| `packages/agent/tests/primitive_code_cleanup_invariants.rs` | rust integration/static test owner | 900 | 943 | HRA-7 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs` | rust integration/static test owner | 900 | 2254 | HRA-7 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Sources/Engine/Network/EngineConnection.swift` | ios engine transport owner | 700 | 958 | HRA-9 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Sources/Session/Messages/CapabilityInvocationDisplayModel.swift` | ios session timeline owner | 700 | 744 | HRA-10 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` | ios runtime surface UI owner | 700 | 817 | HRA-11 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Sources/UI/Views/Settings/SettingsView.swift` | ios settings UI owner | 700 | 735 | HRA-11 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | ios engine test owner | 700 | 2140 | HRA-13 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | ios test infrastructure owner | 700 | 1531 | HRA-13 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |
| `packages/mac-app/Tests/Wizard/WizardStepTests.swift` | mac test owner | 700 | 717 | HRA-14 owns decomposition or movement to the target owner; temporary budget accepted only until that phase closes. | temporary_budget |

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
- `rust_capability_execute_operations_are_decomposed`
- `rust_settings_domain_keeps_worker_root_thin`
- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`
- `large_files_have_decomposition_budget_rows`

## Open Loops

- HRA-9 through HRA-13 still own iOS source/test hierarchy gates.
- HRA-7 still owns Rust test mirroring, progressive docs, and any remaining
  engine over-budget test/store decomposition that proves useful after moves.
- The project `@self-inspect` skill referenced by `AGENTS.md` is not installed
  in this Codex environment; direct repository and database inspection will be
  used until an equivalent skill becomes available.
