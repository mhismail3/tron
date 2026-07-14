# True Primitive Cleanup Scorecard

Created: 2026-06-09

Initial score: **0/100**

Current score: **100/100**

Status: **complete**

Branch: `codex/primitive-engine-teardown`

Plan: `/Users/<USER>/Downloads/PLAN (3).md`, redacted from the operator
Downloads path used to seed this campaign.

Evidence manifest:
[`true-primitive-cleanup-evidence-manifest.md`](true-primitive-cleanup-evidence-manifest.md)

Retention inventory:
[`packages/agent/docs/true-primitive-cleanup-retention-inventory.md`](true-primitive-cleanup-retention-inventory.md)
and
[`packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv`](true-primitive-cleanup-retention-inventory.tsv)

## Scope

True Primitive Cleanup is a scorecard-driven teardown and verification pass over
the completed primitive branch. The goal is to remove remaining oversized roots,
fallback behavior, dead state, hollow abstractions, stale docs, broad UI shells,
and unproven worker/runtime surfaces until retained code is plainly one of:

- `primitive`: the model-facing or host-facing primitive itself;
- `implementation`: a narrow implementation of a primitive;
- `support`: boot, provider, storage, transport, platform, or test support;
- `test`: concern-owned verification;
- `docs`: current source-of-truth or durable scorecard evidence;
- `delete`: a tracked surface to remove before closeout.

There are no compatibility obligations for deleted primitive-branch internals.
Provider aliases may remain only inside provider catalog code when they mirror
current upstream model identifiers or dated snapshots.

## Hard Targets

- Rust production source files: **<= 750 LOC**.
- Swift production source files: **<= 575 LOC**.
- Rust test files: **<= 800 LOC**.
- Swift test files: **<= 650 LOC**.
- Any exception must be generated/data-only and listed here. There are no
  approved source/test exceptions at TPC start.
- Later accepted restoration slices, or implementation-candidate slices pending
  review, may introduce temporary over-budget files only when the current path
  is listed in
  [Post-Restoration Budget Rows And Pending Review Evidence](#post-restoration-budget-rows-and-pending-review-evidence)
  with an owner, reason, and split/decomposition row. Those rows are active
  follow-up obligations, not TPC baseline exceptions.

## Initial Red Findings

TPC-0 red proof found the new invariant target missing and the following
current over-budget files. Rows TPC-2 through TPC-8 own the splits or deletions.

### Rust Over-Budget Baseline

| LOC | Limit | Path | Owner row |
|---:|---:|------|-----------|
| 895 | 750 | `packages/agent/src/engine/catalog/registry/mod.rs` | TPC-2 |
| 888 | 750 | `packages/agent/src/domains/model/providers/factory.rs` | TPC-5 |
| 880 | 750 | `packages/agent/src/engine/invocation/host/mod.rs` | TPC-3 |
| 873 | 750 | `packages/agent/src/transport/engine/socket/mod.rs` | TPC-6 |
| 862 | 750 | `packages/agent/src/engine/durability/ledger/mod.rs` | TPC-2 |
| 861 | 750 | `packages/agent/src/engine/durability/queue/mod.rs` | TPC-2 |
| 855 | 750 | `packages/agent/src/engine/runtime/external_workers/mod.rs` | TPC-4 |
| 836 | 750 | `packages/agent/src/domains/model/providers/openai/message_converter.rs` | TPC-5 |
| 832 | 800 | `packages/agent/src/app/bootstrap/tests.rs` | TPC-9 |
| 830 | 750 | `packages/agent/src/engine/primitives/mod.rs` | TPC-3 |
| 828 | 800 | `packages/agent/src/domains/model/providers/openai/provider/tests.rs` | TPC-5 |
| 816 | 750 | `packages/agent/src/domains/auth/credentials/types.rs` | TPC-5 |
| 814 | 800 | `packages/agent/src/engine/tests/runtime/triggers.rs` | TPC-3 |
| 807 | 750 | `packages/agent/src/domains/model/providers/google/types/mod.rs` | TPC-5 |
| 801 | 750 | `packages/agent/src/domains/agent/loop/turn_runner/persistence.rs` | TPC-6 |
| 801 | 750 | `packages/agent/src/shared/observability/transport.rs` | TPC-6 |
| 785 | 750 | `packages/agent/src/engine/durability/streams.rs` | TPC-2 |
| 775 | 750 | `packages/agent/src/domains/model/providers/ollama/stream_handler.rs` | TPC-5 |
| 768 | 750 | `packages/agent/src/engine/catalog/registry/invocation.rs` | TPC-2 |

### Swift Over-Budget Baseline

| LOC | Limit | Path | Owner row |
|---:|---:|------|-----------|
| 698 | 575 | `packages/ios-app/Sources/UI/Settings/Shell/SettingsView.swift` | TPC-8 |
| 657 | 575 | `packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel.swift` | TPC-8 |
| 652 | 650 | `packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTests.swift` | TPC-8 |
| 652 | 575 | `packages/ios-app/Sources/UI/Chat/Shell/ChatView.swift` | TPC-8 |
| 651 | 650 | `packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift` | TPC-8 |
| 624 | 575 | `packages/ios-app/Sources/UI/Onboarding/Steps/SetupSteps.swift` | TPC-7 |
| 615 | 575 | `packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift` | TPC-7 |
| 595 | 575 | `packages/ios-app/Sources/UI/Theme/TronColors.swift` | TPC-8 |
| 594 | 575 | `packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift` | TPC-8 |
| 592 | 575 | `packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift` | TPC-8 |
| 576 | 575 | `packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift` | TPC-7 |

## Post-Restoration Budget Rows And Pending Review Evidence

These files entered the consolidated line after TPC closeout through accepted
restoration slices and, when present, active implementation-candidate rows that
remain pending review. They keep explicit owners and split obligations until
the next focused decomposition pass brings them back under the TPC hard
targets.

| Path | Owner | Reason | Current LOC / Limit | Split row |
|------|-------|--------|---------------------|-----------|
| `packages/agent/src/domains/jobs/service.rs` | jobs owner | Durable jobs lifecycle service restored for Phase 2 Slice 5A. | 1175 / 750 | Split reconciliation, finalization, cleanup, and output-retention helpers into owner modules before expanding jobs behavior. |
| `packages/agent/src/domains/jobs/tests.rs` | jobs test owner | Jobs lifecycle regression coverage restored for Phase 2 Slice 5A. | 986 / 800 | Split lifecycle, output, timeout, reconciliation, and fail-closed tests into focused modules before adding coverage. |
| `packages/agent/tests/baseline_pre_restoration_closure_invariants.rs` | restoration static gate owner | Phase 2 baseline closure gate now covers Slice 6B/6C/6D docs, provider exposure, resource evidence, and non-goal source-control guards. | 913 / 800 | Split baseline documentation inventory checks from provider/resource/source-control guards before adding more restoration slices. |
| `packages/agent/src/domains/git/service.rs` | git owner | Git evidence service restored for Slice 6A and reused by Slice 6B index mutation, Slice 6C commit, and Slice 6D branch-start preflight/evidence including locked symbolic-HEAD movement. | 1461 / 750 | Split path/repository discovery, status summaries, diff/bounded-output helpers, staged-index tree helpers, and ref command helpers into owner modules before expanding source-control behavior. |
| `packages/agent/src/domains/git/tests.rs` | git test owner | Git status/diff, index mutation, commit, and branch-start regression coverage restored across Phase 2 Slices 6A-6D, including symbolic-HEAD failure rollback and HEAD-drift rejection. | 2718 / 800 | Split read-only status/diff, index mutation, commit, branch-start, resource/schema, and provider-static tests into focused modules before adding more source-control coverage. |
| `packages/agent/src/domains/worker_lifecycle/tests/mod.rs` | worker lifecycle test owner | Worker runtime audit fixes retained existing focused worker lifecycle coverage; Slice 9B kept new inspection regressions in a focused sibling module. | 973 / 800 | Keep common fixtures here; split new manifest/package, inspection, or launch/reconciliation tests into focused modules before adding worker runtime coverage. |
| `packages/agent/src/domains/capability/contract.rs` | capability contract owner | Accepted Slice 24E adds procedural module-pack record/review fields to the single provider-visible `capability::execute` schema while preserving provider portability and the prior single execute contract surface. | 1081 / 750 | Split operation-specific schema field builders into focused contract modules before adding more execute operations. |
| `packages/agent/src/domains/media/tests.rs` | media test owner | Slice 14A idempotency redaction fix adds durable-payload, provider-projection, and lifecycle leak regressions for media artifact resources. | 831 / 800 | Split idempotency/redaction regressions into focused media test modules before adding more media resource coverage. |
| `packages/agent/src/domains/memory/tests.rs` | memory test owner | Accepted Slice 24D adds retrieval, prompt-inclusion, retention-policy, and provider-safe projection regressions to the existing memory foundation test file. | 1784 / 800 | Split retrieval/prompt-inclusion/retention regressions plus older memory lifecycle fixtures into focused memory test modules before adding more memory coverage. |
| `packages/agent/tests/ios_affordance_restoration_map_invariants.rs` | IARM invariant owner | Historical iOS affordance map closure guards remain broad after retrospective hardening. | 1106 / 800 | Split helper parsing, physical-device, queue/phase, APNs defer, and stale-wording guards into modules before extending IARM coverage. |
| `packages/agent/src/engine/authority/grants/authorization.rs` | engine authority owner | Accepted Slice 24E adds exact procedural module-pack selector enforcement to the shared capability authorization path while preserving prior Slice 24D memory query/decision, prior Slice 24C delegated subagent, and module-program-execution exact runtime/job checks. | 3103 / 750 | Split operation/resource selector extraction and per-domain explicit-grant scanners into owner modules before adding more execute-resource families. |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/tests/grant_tests.rs` | capability invocation test owner | Accepted Slice 24E keeps procedural module-pack runtime-grant regressions with prior Slice 24D memory query/decision, execute-resource, and delegated subagent authority regressions. | 1284 / 800 | Split resource-family, procedural, memory, and delegated subagent grant fixtures into focused modules before adding more execute-resource families. |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs` | capability runtime grant owner | Accepted Slice 24E derives exact procedural module-pack selectors alongside prior Slice 24D memory query/decision selectors, prior Slice 24C delegated subagent task selectors, and delegated module refs in the shared provider execute grant derivation path. | 1410 / 750 | Split restored execute-resource family, procedural, memory, and delegated subagent grant derivation helpers into focused owner modules before adding more execute-resource families. |
| `packages/agent/src/engine/tests/authority/execute_goal_authorization.rs` | engine authority test owner | Accepted Slice 24D adds exact memory module-pack execute selector regressions to the shared capability execute authorization test fixture. | 810 / 800 | Split memory/resource-family authorization tests into focused authority test modules before adding more execute-resource families. |
| `packages/agent/src/domains/capability/operations/module_program_execution_tests.rs` | capability execute test owner | Accepted Slice 24C extends accepted Slice 24B module-program-execution coverage with subagent delegation launch/replay exact-selector integration coverage. | 1210 / 800 | Split module-program-execution lifecycle tests from subagent delegation integration fixtures before adding more delegated module-pack coverage. |
| `packages/agent/src/domains/subagents/execution.rs` | subagents owner | Accepted Slice 24C keeps controlled subagent launch/status/result/cancel lifecycle, exact task-selector checks, and delegated module binding checks together. | 1171 / 750 | Split launch planning, follow-up inspection/cancel/result projection, and authority-selector helpers into focused subagent execution modules before expanding subagent behavior. |
| `packages/agent/src/domains/procedural/service.rs` | procedural domain owner | Accepted Slice 24E keeps metadata-only procedural definition, activation request, activation decision, projection-safety, idempotency, and exact-authority checks in the existing procedural owner without restoring repo-managed skills or hook execution. | 1976 / 750 | Split definition, activation request, activation decision, list/inspect projection, and shared validation helpers into owner modules before expanding procedural module-pack behavior. |
| `packages/agent/src/domains/procedural/tests.rs` | procedural domain test owner | Accepted Slice 24E adds definition replay, activation/deactivation/rollback review, exact-selector denial, redaction, and provider-safe projection regressions to the existing inert procedural state tests. | 1399 / 800 | Split procedural definition, activation request/decision, authorization denial, and projection redaction fixtures into focused modules before adding more procedural coverage. |
| `packages/agent/src/domains/module_registry/tests.rs` | module registry test owner | Accepted Slice 24E extends consolidated module-registry manifest tests with the pending-review procedural module pack while existing tests still cover manifest schema, seed redaction, authority scope, lifecycle, and side-effect coverage. | 1028 / 800 | Split manifest schema, authority scope, lifecycle, and side-effect regression fixtures before expanding module registry coverage. |
| `packages/agent/src/domains/module_dependencies/service.rs` | module dependencies implementation owner | Slice 23G accepted row keeps request, decision, and policy activation orchestration together after review accepted the metadata-only dependency policy surface. | 773 / 750 | Split request, decision, policy activation, and shared list/inspect helpers into owner modules before expanding dependency policy behavior. |
| `packages/agent/src/domains/model/providers/openai/message_converter/tests.rs` | OpenAI provider guidance test owner | Context Control implementation-candidate assertions extend the existing consolidated provider schema/guidance coverage slightly above the test-file hard limit while preserving the single execute-provider contract checks. | 812 / 800 | Split execute-schema, provider-guidance, and transcript-conversion fixtures before adding more provider-visible primitive operations. |
| `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` | iOS cockpit session owner | Slice 23H accepted row adds server-owned module activity projection fields to the existing cockpit state boundary. | 582 / 575 | Split module activity projection mapping into a focused sibling state file before expanding cockpit state further. |
| `packages/agent/tests/configuration_profile_environment_discipline_invariants.rs` | CPE invariant owner | Accepted Slice 21A added README/default and iOS editable-setting parity guards to the CPE static target. | 872 / 800 | Split README/default parsing, iOS source-scan parity, and profile-discipline guards into modules before adding more settings coverage. |
| `packages/agent/src/domains/agent/loop/orchestrator/streaming_journal.rs` | agent loop streaming journal owner | Recent streaming/reconstruction hardening keeps persistence ordering, replay cursor, and provider-safe journal projection together while the chat resume invariants settle. | 871 / 750 | Split append/finalize, replay cursor, and projection helpers into owner modules before adding more streaming journal behavior. |
| `packages/agent/src/domains/agent/loop/stream_state.rs` | agent loop stream state owner | Thinking/tool-call streaming convergence hardening expanded the single stream state owner to preserve ordering and in-progress reconstruction invariants. | 833 / 750 | Split thinking, tool-call, and text delta accumulation into focused stream-state modules before adding more stream event families. |
| `packages/agent/src/domains/agent/loop/stream_processor/tests/mod.rs` | stream processor test owner | Provider-normalized streaming regressions remain consolidated while direct provider-wire fixtures are removed from this owner. | 817 / 800 | Split normalized text/thinking/tool-call stream tests into focused modules before adding more stream processor coverage. |
| `packages/agent/src/domains/context_control/service.rs` | context control service owner | Context Control compact/clear/snapshot audit orchestration remains together after the first primitive UI restoration and compaction modularity seam. | 845 / 750 | Split snapshot composition, action recording, compact, clear, and provider-safe projection helpers before expanding context-control behavior. |
| `packages/agent/src/domains/notifications/service.rs` | notification service owner | Redacted notification send, list, inspect, and read-state orchestration remains together while live APNs delivery and durable evidence share one domain owner. | 760 / 750 | Split read/query projection from send/delivery orchestration before adding notification behavior. |
| `packages/agent/src/shared/protocol/model_audit.rs` | model audit protocol owner | Provider request-audit DTOs and redaction-safe protocol projections remain colocated while the restored media and delivery contract stabilizes. | 855 / 750 | Split request, response, and attachment audit projections into focused protocol modules before expanding audit payloads. |
| `packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs` | documentation integrity invariant owner | The top-level harness wires focused documentation/evidence integrity modules and stays slightly above the test limit while current inventory coverage is normalized. | 806 / 800 | Move remaining top-level parsing and campaign-dispatch helpers into the existing focused test modules before adding another integrity campaign. |
| `packages/agent/src/domains/model/providers/google/stream_handler.rs` | Google provider stream handler owner | Provider-native stream decoding remains in one owner while normalized stream-state tests guard cross-provider behavior. | 810 / 750 | Split wire-event decoding from normalized stream-event emission before adding more Gemini event forms. |
| `packages/agent/src/domains/model/providers/openai/stream_handler/tests.rs` | OpenAI provider stream handler test owner | Provider-native stream event regression coverage remains consolidated after thinking/tool-call streaming hardening. | 973 / 800 | Split text deltas, reasoning summaries, tool-call starts/updates, and terminal events into focused provider test modules. |
| `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` | capability binding cockpit visibility owner | Capability ownership, replacement readiness, shadow evidence, and rollback visibility landed together so the cockpit can explain modularity from server truth. | 1293 / 750 | Split summary aggregation, family grouping, operation projection, and provider-safe policy proof into owner modules before expanding cockpit visibility. |
| `packages/agent/src/domains/capability_binding/service.rs` | capability binding service owner | Binding request/decision/policy orchestration sits slightly above budget after the first governed replacement policy slice. | 766 / 750 | Split request, decision, active policy, and list/inspect orchestration before adding more binding policy behavior. |
| `packages/agent/src/domains/capability_binding/shadow_trial.rs` | capability binding shadow trial owner | Metadata-only shadow replacement trial orchestration landed as one owner to prove no live routing changes occur. | 1654 / 750 | Split trial request/decision, run planning, evidence comparison, and rollback/disable metadata into focused modules before adding new shadow targets. |
| `packages/agent/src/domains/capability_binding/tests.rs` | capability binding test owner | Binding policy, classification lock, authorization, redaction, no-routing, and shadow-trial regressions remain consolidated for the first replacement-governance slice. | 1943 / 800 | Split binding lifecycle, policy activation, redaction/provider-safety, no-routing, and shadow-trial tests into focused modules. |
| `packages/agent/tests/capability_modularity_scorecard_invariants.rs` | capability modularity invariant owner | The canonical 157-operation modularity scorecard gate now verifies registry parity, dispatch parity, ownership classes, and source-backed replacement seams. | 1205 / 800 | Split inventory parsing, registry/dispatch parity, classification locks, and source-backed seam guards into focused invariant modules before adding more scorecard dimensions. |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/tests/mod.rs` | capability invocation regression owner | Shared invocation, identity, provider-output, lifecycle, and execution-wave fixtures remain consolidated while the canonical output boundary stabilizes. | 870 / 800 | Split provider-output and execution-wave regressions into focused test modules before adding another invocation behavior. |
| `packages/agent/src/domains/capability/operations/capability_binding.rs` | capability binding adapter owner | Execute-operation adapters for binding, candidate, shadow, route, disable, rollback, and cockpit inspection remain one thin domain bridge. | 861 / 750 | Split read-only inspection adapters from mutating governance adapters before adding another binding operation. |
| `packages/agent/src/domains/capability/operations/catalog/mod.rs` | capability discovery adapter owner | Canonical model-facing search, inspect, unsupported-operation recovery, and conformance projection stay together so discovery semantics cannot drift. | 1938 / 750 | Split search, inspect, and conformance adapters behind one catalog facade before adding discovery behavior. |
| `packages/agent/src/domains/capability/operations/catalog/tests.rs` | capability discovery regression owner | Exhaustive discovery, schema, effect-filter, recovery, and workflow regressions are isolated from production code. | 2207 / 800 | Split search, inspect, conformance, and recovery fixtures before adding another discovery workflow. |
| `packages/agent/src/domains/capability/operations/operation_contract/authority.rs` | canonical authority-contract owner | Exact grants, selectors, network policy, and scope constraints stay in the canonical operation contract. | 1370 / 750 | Split deterministic family tables from shared constructors before adding another authority family. |
| `packages/agent/src/domains/capability/operations/operation_contract/direct.rs` | canonical direct input-contract owner | Closed request schemas for direct filesystem, Git, job, web, and core operations remain one deterministic contract family. | 822 / 750 | Split operation-family tables before adding another direct operation family. |
| `packages/agent/src/domains/capability/operations/operation_contract/governance.rs` | canonical governance input-contract owner | Closed module, procedural, context, and route governance schemas remain one deterministic contract family. | 1549 / 750 | Split module and capability-route family tables before adding another governance family. |
| `packages/agent/src/domains/capability/operations/operation_contract/output/mod.rs` | canonical provider-output owner | Schema validation, semantic validation, text-only transport, and structural budgeting share one output boundary. | 809 / 750 | Split schema construction from rendering and budgeting before adding another envelope feature. |
| `packages/agent/src/domains/capability/operations/operation_contract/output/projection/mod.rs` | canonical provider-evidence projection owner | Provider-safe profile allowlists and redaction stay behind one boundary so raw details cannot bypass custody. | 1750 / 750 | Split profile-specific projectors before adding another output profile. |
| `packages/agent/src/domains/capability/operations/operation_contract/output/projection/tests.rs` | canonical output projection regression owner | Catalog, trace, governance, context, resource, error, and redaction cases validate the real provider envelope. | 2017 / 800 | Split tests by output profile before adding another profile. |
| `packages/agent/src/domains/capability/operations/operation_contract/records.rs` | canonical record input-contract owner | Closed schemas for durable record-plane operations stay in the canonical contract tree. | 1391 / 750 | Split deterministic record-family tables before adding another record family. |
| `packages/agent/src/domains/capability/operations/trace.rs` | capability trace adapter owner | Trace list/get paging, provider-safe projection, and proof metadata remain at one capability boundary. | 1035 / 750 | Split list and inspect projection helpers before expanding trace behavior. |
| `packages/agent/src/domains/capability/pool.rs` | capability pool classification owner | Operation and live catalog audience, replacement, visibility, minimality, and evolution classifications remain one typed owner. | 1125 / 750 | Split agent guidance and projection helpers behind the typed contract before adding another classification dimension. |
| `packages/agent/src/domains/capability_binding/route.rs` | governed route owner | Exact-scope resolution, activation, disable, rollback, event evidence, stale-version checks, and supervised dispatch remain one fail-closed boundary. | 2231 / 750 | Split read resolution from write lifecycle handlers before adding another routed operation. |
| `packages/agent/src/domains/context_control/tests.rs` | context control regression owner | Snapshot, compaction, epoch, survivor, replay, selector, and redaction cases cover one session-scoped contract. | 1258 / 800 | Split read and mutation fixtures before adding another context action. |
| `packages/agent/src/domains/module_runtime/service.rs` | supervised module runtime owner | Lifecycle gating, sandbox/network/secrets policy, cancellation, shutdown, bounded output refs, and authority proof remain one runtime envelope owner. | 914 / 750 | Split request validation from lifecycle transitions before adding another runtime state. |
| `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` | capability binding resource-schema owner | Candidate, binding, activation, event, rollback, and policy records remain one versioned governance schema set. | 1023 / 750 | Split immutable candidate schemas from route lifecycle schemas before adding another record kind. |
| `packages/agent/src/engine/kernel/schema.rs` | kernel schema validation owner | Engine schema definition and payload validation remain one non-replaceable kernel boundary. | 805 / 750 | Split definition validation from payload validation before adding another schema dialect feature. |
| `packages/ios-app/Sources/Engine/Persistence/Repositories/SessionRepository.swift` | iOS session repository owner | Session paging, snapshots, event decoding, and persistence queries remain behind one repository boundary. | 614 / 575 | Split list paging from per-session event reconstruction before adding another query mode. |
| `packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift` | iOS cockpit view owner | Progressive cockpit summary, capability, activity, and drill-down composition remain one native surface. | 599 / 575 | Split capability and activity sections before adding another cockpit section. |
| `packages/ios-app/Sources/UI/Capabilities/CapabilityInvocationViews.swift` | iOS capability invocation view owner | Single and grouped invocation summaries, evidence, request, error, and technical disclosure remain one progressive surface. | 655 / 575 | Split grouped invocation and single-invocation detail views before adding another disclosure level. |
| `packages/ios-app/Tests/Engine/Protocol/WorkerLifecycleDTOTests.swift` | worker lifecycle DTO regression owner | Server-owned cockpit, package, lifecycle, activity, and briefing payload decoding remain covered together. | 794 / 650 | Split package lifecycle and cockpit/briefing DTO fixtures before adding fields. |
| `packages/ios-app/Tests/Session/WorkerLifecycle/AgentCockpitViewModelTestFixtures.swift` | cockpit fixture owner | Shared server-truth DTO and state fixtures support focused cockpit view-model tests without production defaults. | 700 / 650 | Split package and activity fixture families before adding another payload family. |
| `packages/ios-app/Tests/Engine/Persistence/Sync/EventStoreManagerTests.swift` | event-store synchronization test owner | Hosted-test isolation added injected state lifecycle plus accepted-event shutdown and latest-client lane regressions to the cached-session synchronization suite. | 696 / 650 | Split cached-session merge/projection cases, global-event lifecycle cases, and SyncState/SessionEvent model cases into focused suites before adding another synchronization behavior. |
| `packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+BuildAndProject.swift` | iOS build/project source-guard owner | The iOS 27 soft-scroll contract and hosted-test project configuration checks remain alongside existing build, privacy, storage, and physical-device action guards for this checkpoint. | 665 / 650 | Split scroll, scheme, and device-action checks from privacy, storage, and production-surface checks before adding another cross-cutting assertion. |

## Static Gates

`packages/agent/tests/true_primitive_cleanup_invariants.rs` owns TPC static
gates:

- `true_primitive_cleanup_scorecard_stays_formalized`
- `initial_red_findings_are_recorded_until_resolved`
- `tracked_source_inventory_is_formalized`
- `engine_catalog_and_durability_roots_are_split_and_explicit`
- `invocation_host_and_primitive_store_roots_are_narrow`
- `external_worker_runtime_is_loopback_split_and_proven`
- `provider_auth_model_roots_are_split_and_provider_native`
- `transport_agent_observability_roots_are_split_and_explicit`
- `ios_engine_protocol_roots_are_split_and_cache_mode_explicit`
- `ios_ui_state_roots_are_split_and_under_budget`
- `script_runtime_helpers_are_split_and_manual_only`
- `docs_guards_and_inventories_are_current`
- `final_closeout_is_complete`
- `tpc_source_files_are_classified_or_in_pending_inventory_setup`
- `tpc_hard_budget_scan_has_no_open_findings`

## Residual Term Review Policy

TPC-10 reviewed broad cleanup terms across active docs, source, tests, and
scripts. Manual deploy wording is retained only for `tron manual-deploy`,
deploy-restart transport state, release deployment targets, and historical
evidence rows. Provider/wire compatibility terms are retained only when naming
upstream-compatible APIs, serialized provider fields, or negative source guards.
No-op wording is retained only for explicit operation/state names, idempotency
or replay tests, and historical evidence; hidden default behavior remains
forbidden by the row-specific TPC gates.

TPC-0 installs the target and records the red baseline. Later rows may add or
tighten gates only after first recording the failing proof they close.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence | Open loops | Checkpoint |
|----|------|-------:|--------|-------|----------|------------|------------|
| TPC-0 | Scorecard setup | 5 | passed_after_fix | docs/static gates | Added this scorecard, evidence manifest, README living-doc links, setup invariant target, hard-target statement, and current red LOC baseline. Checkpoint commit: `498abfb24`. | TPC-1 owns complete tracked source inventory; TPC-2 through TPC-8 own all over-budget source/test files. | TPC-0 setup checkpoint |
| TPC-1 | Retention inventory | 8 | passed_after_fix | architecture | The retention inventory classifies the current tracked source, docs, test, and script surface. Current coverage is 2,161 paths in TPC scope: 113 `primitive`, 881 `implementation`, 396 `support`, 628 `test`, 143 `docs`, and 0 `delete`. Checkpoint commit: `92521b511`. | No unclassified tracked source remains; explicit post-closeout budget rows name each over-target owner and its split-before-growth condition. | TPC-1 inventory checkpoint |
| TPC-2 | Engine catalog/durability teardown | 12 | passed_after_fix | engine/storage | Split catalog registration, authorization, cleanup, search, and idempotency from the live registry; split ledger SQLite storage from ledger contracts; split queue memory/SQLite stores; split stream memory/SQLite stores; removed default no-op durable-worker/function methods from `EngineLedgerStore` and made in-memory/test ledgers implement them explicitly. Checkpoint commit: `739612887`. | No TPC-2 LOC or no-op default blocker remains; TPC-10 closed broad residue review. | TPC-2 engine/durability checkpoint |
| TPC-3 | Invocation host and primitive stores | 10 | passed_after_fix | engine primitives | Split `EngineHost` construction/bootstrap and meta invocation into `host/bootstrap.rs` and `host/meta_invocation.rs`; split primitive store backends and worker/function registration into `primitives/stores.rs` and `primitives/workers.rs`; moved trigger runtime test helpers into `runtime/trigger_helpers.rs`; added a TPC gate proving the original host, primitive, and trigger roots are under budget and no longer contain weak-host store wiring in the primitive root. Checkpoint commit: `c7d16e4b9`. | No TPC-3 LOC blocker remains; TPC-10 closed broad residue review. | TPC-3 invocation/primitives checkpoint |
| TPC-4 | External worker proof or deletion | 10 | passed_after_fix | runtime | Retained loopback-only external workers with explicit proof: split lifecycle/heartbeat/disconnect and durable health marking into `external_workers/lifecycle.rs`, registration/proxy/stream publication into `external_workers/registration.rs`, and scoped-token/capability validation into `external_workers/validation.rs`; split protocol roundtrip and invoker helpers out of the over-budget behavior test. Checkpoint commit: `6860022df`. | No TPC-4 LOC blocker remains; TPC-10 closed broad residue review. | TPC-4 external-worker checkpoint |
| TPC-5 | Provider/auth/model cleanup | 10 | passed_after_fix | provider/auth/model | Split provider factory tests, OpenAI message-converter tests, auth credential type tests, Ollama stream-handler tests, and OpenAI request-shaping tests into concern-owned child modules; moved the Gemini model registry to `google/types/models.rs`; removed stale compatibility-alias wording from provider root docs; and added a static gate proving TPC-5 files are under budget and provider alias references stay inside the OpenAI model catalog/type-helper boundary. Checkpoint commit: `449616f2e`. | No TPC-5 LOC blocker remains. Provider aliases are intentionally retained only in the OpenAI model registry/catalog tests; TPC-10 closed broad residue review. | TPC-5 provider/auth/model checkpoint |
| TPC-6 | Agent loop/config/context flattening | 10 | passed_after_fix | agent runtime | Split `/engine` WebSocket subscription state, polling, ack, and push cursor advancement into `transport/engine/socket/subscriptions.rs`; moved turn-runner persistence tests to `persistence/tests.rs`; moved SQLite observability transport tests to `transport/tests.rs`; renamed the no-persister persistence test away from no-op wording; and added a static gate proving the three TPC-6 roots are under budget with subscription ownership out of the socket dispatcher. Checkpoint commit: `5b4d43641`. | No TPC-6 LOC blocker remains; TPC-10 closed broad residue review. | TPC-6 transport/agent/observability checkpoint |
| TPC-7 | iOS engine/protocol cleanup | 10 | passed_after_fix | iOS engine shell | Split onboarding setup controls into `SetupStepComponents.swift`, diagnostics bundle DTO/sanitizer/hash helpers into `DiagnosticsBundleTypes.swift`, and generated-runtime rendering helpers into `GeneratedRuntimeSurfaceView+RenderingHelpers.swift`. Added a static gate proving the TPC-7 Swift roots are under 575 LOC, reusable controls/DTOs/helpers are out of the roots, and the local event database still declares temporary cache mode as server-authoritative projection state. Checkpoint commit: `acaa247ee`. | No TPC-7 LOC or temporary-cache ownership blocker remains; TPC-10 closed broad residue review. | TPC-7 iOS engine/protocol checkpoint |
| TPC-8 | iOS UI state flattening | 8 | passed_after_fix | iOS UI/session | Split settings main-section/action rendering into `SettingsView+MainSection.swift`, paired-server row/menu helpers into `SettingsServerSupport.swift`, chat message-list/pagination rendering into `ChatView+MessageList.swift`, chat runtime callback wiring into `ChatViewModel+RuntimeCallbacks.swift`, model-picker sections into `ModelPickerSheet+Sections.swift`, derived theme tokens into `TronThemeTokens.swift`, and typewriter animation tests into `StreamingManagerTypewriterTests.swift`. Added a static gate proving all TPC-8 roots are under budget and no longer own the moved concerns. Checkpoint commit: `10e6aa8ba`. | No TPC-8 Swift LOC blocker remains; TPC-10 closed broad residue review. | TPC-8 iOS UI/session checkpoint |
| TPC-9 | Mac/scripts/runtime helpers | 7 | passed_after_fix | scripts/Mac/runtime | Split the broad bootstrap test root into concern-owned child test modules; renamed the contributor deploy command to `manual-deploy` with no old `deploy` alias; renamed the script module to `manual-deploy.sh`; updated README/CLI help and service recovery guidance; and removed inactive-operation wording from Mac runtime helper comments. Added a static gate proving the split test owners, manual deploy boundary, and Mac/script residue cleanup. Checkpoint commit: `bc9d1950c`. | No TPC-9 LOC, deploy-command, or Mac/script inactive-operation blocker remains; TPC-10 closed broad docs/residue cleanup. | TPC-9 scripts/Mac/runtime checkpoint |
| TPC-10 | Docs, guards, inventories | 5 | passed_after_fix | docs/static gates | Added the final docs/guards/inventories TPC gate, updated active README wording, refreshed HRA/PCC ownership inventories for `scripts/tron.d/manual-deploy.sh`, removed old deploy-command spelling from active reference docs, regenerated the TPC retention inventory for the new guard, and recorded the residual-term review policy. Checkpoint commit: `3a73c7007`. | Closed. | TPC-10 docs/guards/inventory checkpoint |
| TPC-11 | Final closeout | 5 | passed_after_fix | final verification | Added the final closeout gate, ran full closeout verification, adversarial residue scans, ignored-artifact audit, personal-info full scan, hard-budget scans, active-reference drift scans, and clean worktree proof. A continuation audit also fixed the full-suite settings-test race in the watcher proof. Checkpoint commit: `2dbeebe1d`; continuation verification checkpoint: `a9fb3012b`. | No open loops remain. | TPC-11 final closeout checkpoint |

Total weight: **100**

## Checkpoint Protocol

Every row records:

- red proof command and exit code;
- focused verification command and exit code;
- docs/tests/inventory updates;
- honest residual risk;
- checkpoint commit hash and follow-up hash-record commit when practical.

## Open Loops

No open loops remain.
