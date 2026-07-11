# Hierarchical Rearchitecture Scorecard

Current score: **100/100**

Status: **completed**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `7cedc8ac3`

Plan summary: `packages/agent/docs/hierarchical-rearchitecture-plan-summary.md`.

## Operating Rules

- The campaign reorganizes ownership boundaries only after red static gates
  describe the current drift.
- Every retained folder must have an owner, reason, allowed contents, and test
  responsibility before closeout.
- Moves must remove old internal paths instead of preserving compatibility
  shims, alias modules, or old-path wrappers.
- Code, tests, docs, generated projects, scorecard, evidence, and inventory
  move together in each checkpoint.
- HRA-0 intentionally leaves the new invariant target red against the current
  tree; later rows turn those gates green by changing the architecture.

## Required Artifacts

| Artifact | Status | Purpose |
|----------|--------|---------|
| `packages/agent/docs/hierarchical-rearchitecture-scorecard.md` | completed | Weighted campaign scorecard and open-loop ledger. |
| `packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md` | completed | Verification, red/green output, commit hashes, and residual risk. |
| `packages/agent/docs/hierarchical-rearchitecture-inventory.md` | completed | Human-readable inventory summary and target architecture notes. |
| `packages/agent/docs/hierarchical-rearchitecture-plan-summary.md` | completed | In-repo summary of the operator HRA handoff plan and provenance boundary. |
| `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv` | completed | Machine-readable tracked-file inventory. |
| `packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv` | completed | Machine-readable current ownership map. |
| `packages/agent/docs/hierarchical-rearchitecture-ios-current-ownership-map.tsv` | completed | HRA-8 machine-readable source/test Swift current ownership map for iOS hierarchy phases. |
| `packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md` | completed | HRA-8 XcodeGen, ShareExtension, SourceGuard, and iOS phase-ownership project map. |
| `packages/agent/tests/hierarchical_rearchitecture_invariants.rs` | completed | Static hierarchy gates for this campaign. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| HRA-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix | architecture campaign | Required artifacts, README links, CI hook, and red hierarchy invariant target are present. | Red gates are expected until later rows move code. |
| HRA-1 | Whole-repo inventory and target architecture | 8 | passed_after_fix | architecture campaign | Live tracked-file inventory, current ownership map, folder owner table, drift findings, and large-file budgets are recorded. | Closed; all current inventory and ownership-map rows are complete after AHA-9. |
| HRA-2 | Rust app, transport, shared, and platform roots | 6 | passed_after_fix | Rust app/transport/shared owners | Moved root binary helpers into app CLI/bootstrap, grouped app health/lifecycle/bootstrap, grouped transport HTTP/engine/runtime, collapsed shared into foundation/protocol/server/storage/observability, and updated README/static gates. | HRA-15 still owns broad stale-path doc scans outside current-code docs. |
| HRA-3 | Rust engine kernel and invocation hierarchy | 10 | passed_after_fix | Rust engine owner | Moved kernel/catalog/invocation/runtime modules under owned subsystem roots, collapsed invocation host into `invocation/host`, split kernel types under `kernel/types`, and removed avoidable engine same-name file/folder pairs. | Closed by HRA-7 decomposition and AHA-6 near-budget watch rows. |
| HRA-4 | Rust engine durability and authority hierarchy | 8 | passed_after_fix | Rust engine owner | Moved grants/leases/compensation under `authority`; moved ledger/queue/resources/state/streams under `durability`; kept SQLite codecs under their owning stores; collapsed resource store into `resources/store/mod.rs`. | Closed by HRA-7 decomposition. AHA-6 records current Rust files at or above the 850 LOC warning band as active watch rows. |
| HRA-5 | Rust domain vertical slices | 10 | passed_after_fix | Rust domain owners | Moved registration helpers under `domains/registration`; moved agent prompt/loop/context, auth oauth/credentials, model routing/protocol, and settings profile owners; split capability operations, Kimi stream tests, and over-budget domain test modules. | Closed with no remaining HRA-5 temporary file budgets. |
| HRA-6 | Rust session and event-store hierarchy | 7 | passed_after_fix | Rust session owner | Moved session lifecycle/query/reconstruction into owner folders, moved event-store envelope/factory/reconstruction/store/session repository tests to folder-backed modules, and split SQLite event repository tests by behavior. | HRA-7 still owns broader Rust test/doc budget cleanup. |
| HRA-7 | Rust tests and progressive docs | 5 | passed_after_fix | Rust docs/tests owners | Mirrored engine tests to subsystem folders, split root static integration gates into folder-backed modules, decomposed over-budget Rust stores/runtime helpers, and updated progressive docs/README. | iOS hierarchy closure is owned by HRA-9 through HRA-13. |
| HRA-8 | iOS inventory, SourceGuard, and target project map | 6 | passed_after_fix | iOS architecture owner | Added HRA SourceGuard red hierarchy checks, generated the iOS source/test Swift current ownership map, recorded the XcodeGen/share-extension project map, and added a Rust map-coverage invariant. | Closed; later iOS/Mac/docs/final closeout rows are complete. |
| HRA-9 | iOS Engine hierarchy | 8 | passed_after_fix | iOS engine owner | Moved Engine transport, protocol DTOs, event live/payload/plugin/reconstruction code, persistence, and repositories into target owner folders; split `EngineConnection` into focused WebSocket request, receive, reconnect, frame, and type units; regenerated XcodeGen. | Closed; later iOS test mirroring is complete in HRA-13. |
| HRA-10 | iOS Session hierarchy | 7 | passed_after_fix | iOS session owner | Moved Session chat view models, coordinators, messaging, navigation, state, attachments, timeline activity/messages/reconstruction/tokens, and retained parsing under workflow-owned folders; split `CapabilityInvocationDisplayModel` presentation helpers. | Closed; later iOS test mirroring is complete in HRA-13. |
| HRA-11 | iOS UI hierarchy | 6 | passed_after_fix | iOS UI owner | Replaced `UI/Views` with `UI/Chat`, `UI/Settings`, `UI/Onboarding`, `UI/RuntimeSurfaces`, `UI/Capabilities`, `UI/Components`, `UI/System`, and `UI/Theme`; split runtime surface and settings support files. | Closed; later iOS test mirroring is complete in HRA-13. |
| HRA-12 | iOS Support foundation hierarchy | 4 | passed_after_fix | iOS support owner | Moved app entry points under `App/Lifecycle`; moved dependency assembly to `Support/Composition`; split support helpers into diagnostics, feedback, foundation, pairing, share, and storage owners; removed broad utility, extension, infrastructure, observability, settings, and service buckets. | Closed; later iOS test mirroring and SourceGuard decomposition are complete in HRA-13. |
| HRA-13 | iOS tests and generated project closeout | 4 | passed_after_fix | iOS test owner | Moved all iOS tests into `Engine`, `Session`, `UI`, `Support`, and `Infrastructure` mirrors; decomposed `SourceGuardTests` and `UnifiedEventTransformerTests`; regenerated XcodeGen; SourceGuard and moved-test batches pass. | Closed; HRA-16 added a WebSocket test mirror guard for the final reconnect-test move. |
| HRA-14 | Mac wrapper hierarchy audit | 2 | passed_after_fix | Mac wrapper owner | Moved App, Server, MenuBar, Wizard, and Support sources into target owner folders; mirrored Mac tests to App, Server, MenuBar, Support, Wizard, and Infrastructure; split `WizardStepTests`; XcodeGen and Mac tests pass. | Closed; HRA-16 corrected the Mac DB lock path to `tron.sqlite.lock`. |
| HRA-15 | Scripts, README, and docs path closeout | 2 | passed_after_fix | docs/scripts owner | Added a live docs/scripts/workflows old-path static gate; fixed stale README, iOS development docs, Mac architecture docs, and personal-info guard paths; regenerated inventories. | Closed; HRA-16 fixed adversarially found live docs/scripts path drift. |
| HRA-16 | Final adversarial review and closeout | 2 | passed_after_fix | architecture campaign | Ran full closeout verification and adversarial review; removed live retired DB filename handling, renamed iOS reconstruction projection owners, moved WebSocket reconnect tests to the mirrored owner, eliminated Rust event same-name module pairs, refreshed live docs/inventories, regenerated Xcode projects, and appended the ledger. | Closed; no HRA implementation loops remain. |

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
| `packages/ios-app/Sources` | iOS app target boundary | App/Lifecycle, Engine, Session, UI, scoped Support, Resources, assets, and plist files after HRA-12. | passed_after_fix |
| `packages/ios-app/Tests` | iOS test target boundary | Infrastructure and tests mirroring Engine, Session, UI, and Support after HRA-13. | passed_after_fix |
| `packages/mac-app/Sources` | Mac wrapper target boundary | App/Lifecycle, App/CommandMode, App/Composition, Server/LaunchAgent, Server/Health, Server/Paths, Server/PairingToken, Server/ProcessControl, MenuBar, Wizard, Support, Resources, and assets after HRA-14. | passed_after_fix |
| `packages/mac-app/Tests` | Mac wrapper test target boundary | Tests mirroring Mac wrapper App, Server, MenuBar, Support, Wizard, and Infrastructure fake owners after HRA-14. | passed_after_fix |

## Large File Budgets

HRA keeps hard limits visible at 900 LOC for Rust and 700 LOC for Swift. Current
files over that line must carry explicit owner, reason, and decomposition rows;
AHA-6 keeps the separate Rust 850 LOC warning band for files approaching the
hard limit.

| Path | Owner | Budget | Current size | Decomposition plan | Status |
|------|-------|--------|--------------|--------------------|--------|
| `packages/agent/src/domains/jobs/service.rs` | jobs owner | Rust hard limit 900 LOC | 1156 LOC | Split reconciliation/finalization helpers into owner submodules before the next jobs feature expansion. | accepted_budget |
| `packages/agent/src/domains/jobs/tests.rs` | jobs test owner | Rust hard limit 900 LOC | 1056 LOC | Split lifecycle, output, timeout, and reconciliation regression tests into focused modules before adding more jobs coverage. | accepted_budget |
| `packages/agent/src/domains/git/service.rs` | git domain owner | Rust hard limit 900 LOC | 1566 LOC | Split read-only status/diff helpers, staged-index tree evidence, bounded command helpers, and ref command helpers into owner submodules before adding more source-control operations. | accepted_budget |
| `packages/agent/src/domains/git/tests.rs` | git test owner | Rust hard limit 900 LOC | 3069 LOC | Split read-only Git status/diff tests from index-mutation, commit evidence, branch-start evidence, resource/schema, provider-static, and replay tests before adding more source-control coverage. | accepted_budget |
| `packages/agent/src/domains/worker_lifecycle/tests/mod.rs` | worker lifecycle test owner | Rust hard limit 900 LOC | 973 LOC | Keep common worker lifecycle fixtures here; split new manifest/package or lifecycle inspection regression batches into focused sibling test modules before adding more worker runtime coverage. | accepted_budget |
| `packages/agent/src/domains/memory/tests.rs` | memory test owner | Rust hard limit 900 LOC | 1793 LOC | Split retrieval, prompt-inclusion, retention-policy, provider-safe projection, query/decision evidence, and older memory lifecycle fixtures into focused sibling test modules before adding more memory coverage. | accepted_budget |
| `packages/agent/src/domains/module_registry/tests.rs` | module registry test owner | Rust hard limit 900 LOC | 1747 LOC | Slice 24G keeps notification-delivery manifest projection coverage with the existing module-pack manifest regressions; split seed-manifest projection cases into sibling test modules before adding another module-pack manifest. | accepted_budget |
| `packages/agent/src/domains/procedural/service.rs` | procedural domain owner | Rust hard limit 900 LOC | 1976 LOC | Split definition, activation request, activation decision, list/inspect projection, and shared validation helpers into owner modules before expanding procedural module-pack behavior. | accepted_budget |
| `packages/agent/src/domains/procedural/tests.rs` | procedural domain test owner | Rust hard limit 900 LOC | 1399 LOC | Split procedural definition, activation request/decision, authorization denial, and projection redaction fixtures into focused modules before adding more procedural coverage. | accepted_budget |
| `packages/agent/src/engine/authority/grants/authorization.rs` | engine authority owner | Rust hard limit 900 LOC | 2896 LOC | Accepted Slice 24D keeps exact memory query/decision selector enforcement in the shared capability authorization scanner alongside accepted Slice 24C delegated subagent exact task-selector enforcement; split operation/resource selector extraction and per-domain explicit-grant scanners before adding more execute-resource families. | accepted_budget |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs` | capability runtime grant owner | Rust hard limit 900 LOC | 1327 LOC | Accepted Slice 24D keeps exact memory query/decision selectors in the shared provider execute grant derivation path alongside accepted Slice 24C delegated subagent task selectors and delegated module refs; split per-domain grant policy helpers before adding more execute-resource families. | accepted_budget |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/tests/grant_tests.rs` | capability runtime grant test owner | Rust hard limit 900 LOC | 1965 LOC | Accepted Slice 24D keeps memory query/decision runtime-grant regressions with existing execute-resource and delegated subagent grant tests; split resource-family, memory, and delegated subagent fixtures before adding more execute-resource families. | accepted_budget |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/tests/mod.rs` | capability invocation regression owner | Rust warning band 850 LOC | 870 LOC | Split provider-output and execution-wave regressions into focused test modules before adding another invocation behavior. | accepted_budget |
| `packages/agent/src/domains/agent/loop/orchestrator/streaming_journal.rs` | agent loop streaming-journal owner | Rust warning band 850 LOC | 871 LOC | Split journal projection, trace persistence, and replay formatting helpers before adding streaming-journal behavior. | accepted_budget |
| `packages/agent/src/domains/capability/operations/capability_binding.rs` | capability binding execute adapter owner | Rust warning band 850 LOC | 861 LOC | Split request parsing from route-event projection before adding another binding operation. | accepted_budget |
| `packages/agent/src/domains/capability/operations/module_program_execution_tests.rs` | capability execute test owner | Rust hard limit 900 LOC | 1210 LOC | Accepted Slice 24C extends accepted Slice 24B module-program-execution coverage with delegated subagent launch/replay exact-selector integration fixtures; split module-program-execution lifecycle tests from delegated module-pack fixtures before expanding coverage. | accepted_budget |
| `packages/agent/src/domains/subagents/execution.rs` | subagents owner | Rust hard limit 900 LOC | 1171 LOC | Accepted Slice 24C keeps controlled subagent launch/status/result/cancel lifecycle, exact task-selector checks, and delegated module binding checks together; split launch planning, follow-up inspection/cancel/result projection, and authority-selector helpers before expanding subagent behavior. | accepted_budget |
| `packages/agent/src/domains/capability_binding/shadow_trial.rs` | capability binding owner | Rust hard limit 900 LOC | 1671 LOC | Capability modularity keeps request, decision, run, evidence projection, and stale-version guards together for the first metadata-only shadow trial; split request/decision/run/evidence owner modules before adding a second shadow-trial target. | accepted_budget |
| `packages/agent/src/domains/capability_binding/tests.rs` | capability binding test owner | Rust hard limit 900 LOC | 5437 LOC | Binding-policy, shadow-trial, cockpit projection, selector, stale-version, redaction, and no-routing regressions are colocated for the first modularity campaign; split into binding-policy, shadow-trial, cockpit-visibility, and authorization test modules before expanding replacement routing. | accepted_budget |
| `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` | capability cockpit projection owner | Rust hard limit 900 LOC | 2432 LOC | Engine Cockpit projection keeps operation ownership, binding/shadow activity, truncation, and redaction policy together while the projection is new; split aggregation, operation projection, activity summary, and redaction-policy helpers before adding write controls. | accepted_budget |
| `packages/agent/src/domains/model/providers/openai/stream_handler/tests.rs` | OpenAI stream-handler test owner | Rust hard limit 900 LOC | 1139 LOC | Provider streaming regressions keep delta ordering, tool-call parsing, reasoning markers, and failure envelopes adjacent; split thinking, tool-call, completion, and malformed-stream fixtures before adding more provider stream variants. | accepted_budget |
| `packages/agent/src/domains/capability_binding/route.rs` | capability route owner | Rust hard limit 900 LOC | 2231 LOC | Split route activation, disable/rollback, event recording, and lookup/projection helpers before adding another routable operation. | accepted_budget |
| `packages/agent/src/domains/context_control/service.rs` | context-control owner | Rust hard limit 900 LOC | 1391 LOC | Split snapshot composition, compact/clear actions, survivor records, and provider-safe projections before adding another context action. | accepted_budget |
| `packages/agent/src/domains/context_control/tests.rs` | context-control test owner | Rust hard limit 900 LOC | 1258 LOC | Split snapshot, action, survivor, authorization, and replay fixtures before expanding context-control behavior. | accepted_budget |
| `packages/agent/src/domains/capability/operations/operation_contract/records.rs` | capability record-contract owner | Rust hard limit 900 LOC | 1391 LOC | Split record-family schemas by durable domain while retaining one canonical operation-contract facade. | accepted_budget |
| `packages/agent/src/domains/capability/operations/operation_contract/output/projection/mod.rs` | provider evidence projection owner | Rust hard limit 900 LOC | 1752 LOC | Split profile-specific evidence projectors behind the single fail-closed projection entry point before adding an output profile. | accepted_budget |
| `packages/agent/src/domains/capability/operations/operation_contract/output/projection/tests.rs` | provider evidence projection test owner | Rust hard limit 900 LOC | 2007 LOC | Split profile, redaction, semantic-evidence, and truncation regressions into focused test modules before adding projection behavior. | accepted_budget |
| `packages/agent/src/domains/capability/operations/operation_contract/governance.rs` | capability governance-contract owner | Rust hard limit 900 LOC | 1549 LOC | Split governance-family schemas by module lifecycle, dependency, binding, and runtime ownership behind the canonical facade. | accepted_budget |
| `packages/agent/src/domains/capability/operations/operation_contract/authority.rs` | capability authority-contract owner | Rust hard limit 900 LOC | 1370 LOC | Split per-family exact selector and scope derivation tables before adding another authority-bearing operation family. | accepted_budget |
| `packages/agent/src/domains/capability/operations/catalog/mod.rs` | capability discovery owner | Rust hard limit 900 LOC | 1938 LOC | Split search, inspect, recovery, and conformance projections behind one catalog facade before adding discovery behavior. | accepted_budget |
| `packages/agent/src/domains/capability/operations/catalog/tests.rs` | capability discovery test owner | Rust hard limit 900 LOC | 2207 LOC | Split search, inspect, recovery, conformance, and provider-safety regressions before expanding discovery semantics. | accepted_budget |
| `packages/agent/src/domains/capability/operations/trace.rs` | capability trace owner | Rust hard limit 900 LOC | 1035 LOC | Split trace list/get projection from recent-log projection before adding diagnostics behavior. | accepted_budget |
| `packages/agent/src/domains/capability/pool.rs` | capability pool owner | Rust hard limit 900 LOC | 1297 LOC | Split classification inventory, agent guidance, and cockpit projection metadata behind one pool contract before adding a classification axis. | accepted_budget |
| `packages/agent/src/domains/agent/loop/stream_processor/tests/mod.rs` | agent stream test owner | Rust hard limit 900 LOC | 981 LOC | Split thinking, text, capability, and completion stream regressions before expanding stream event types. | accepted_budget |
| `packages/agent/src/domains/module_runtime/service.rs` | module runtime owner | Rust hard limit 900 LOC | 914 LOC | Split request lifecycle and provider-safe runtime projection before adding another runtime action. | accepted_budget |
| `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` | capability binding resource owner | Rust hard limit 900 LOC | 1023 LOC | Split binding, shadow, and route resource definitions into owner modules before adding another durable replacement record. | accepted_budget |
| `packages/ios-app/Tests/Engine/Protocol/WorkerLifecycleDTOTests.swift` | iOS worker lifecycle DTO test owner | Swift hard limit 700 LOC | 794 LOC | Split cockpit, worker lifecycle, and replacement-route decoding fixtures before adding DTO coverage. | accepted_budget |
| `packages/agent/tests/capability_modularity_scorecard_invariants.rs` | capability modularity invariant owner | Rust hard limit 900 LOC | 1205 LOC | The invariant intentionally covers inventory, registry/dispatch parity, kernel/governance locks, adapter seams, cockpit visibility, and docs linkage in one closeout gate; split parser helpers, ownership rules, source-backed seam checks, and artifact-link checks before adding runtime routing invariants. | accepted_budget |
| `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` | iOS cockpit state owner | Swift hard limit 700 LOC | 735 LOC | Cockpit DTO-to-view-state mapping keeps summary, capability groups, activity, verification, and detail state together while the server projection stabilizes; split capability mapping, activity mapping, and detail-state factories before adding new cockpit sections. | accepted_budget |
| `packages/agent/tests/baseline_pre_restoration_closure_invariants.rs` | BPRC invariant owner | Rust hard limit 900 LOC | 913 LOC | Split scorecard/inventory parsing helpers and Phase 2 lineage assertions into folder-backed modules before extending BPRC closure guards. | accepted_budget |
| `packages/agent/tests/ios_affordance_restoration_map_invariants.rs` | IARM invariant owner | Rust hard limit 900 LOC | 1111 LOC | Split helper parsing, physical-device guards, queue/phase anchors, and APNs defer tests into submodules before extending IARM guards. | accepted_budget |

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
- `ios_hra8_ownership_map_covers_every_source_and_test_swift_file`
- `ios_engine_hra9_sources_use_target_boundaries`
- `ios_session_hra10_sources_use_target_boundaries`
- `ios_ui_hra11_sources_use_target_boundaries`
- `ios_support_hra12_sources_use_target_boundaries`
- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`
- `ios_engine_transport_tests_mirror_websocket_owner`
- `large_files_have_decomposition_budget_rows`
- `mac_sources_use_hra14_target_boundaries`
- `mac_tests_mirror_source_boundaries`
- `mac_tests_have_no_remaining_overbudget_swift_files`
- `live_docs_scripts_and_workflows_do_not_claim_old_paths`

## Open Loops

- No HRA implementation rows remain open. Historical evidence artifacts and
  static absence tests intentionally retain old path strings as regression
  needles; live source, docs, scripts, and generated projects are current.
