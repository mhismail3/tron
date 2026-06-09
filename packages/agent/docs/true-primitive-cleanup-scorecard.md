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
| 839 | 800 | `packages/agent/src/engine/tests/runtime/external_worker.rs` | TPC-4 |
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
| TPC-1 | Retention inventory | 8 | passed_after_fix | architecture | Added the retention inventory and TSV, then regenerated it after TPC-2 through TPC-11. Current coverage is 1,413 tracked and newly introduced source/docs/script paths in TPC scope: 105 `primitive`, 478 `implementation`, 380 `support`, 418 `test`, 32 `docs`, and 0 `delete`. Checkpoint commit: `92521b511`. | No unclassified tracked source remains. | TPC-1 inventory checkpoint |
| TPC-2 | Engine catalog/durability teardown | 12 | passed_after_fix | engine/storage | Split catalog registration, authorization, cleanup, search, and idempotency from the live registry; split ledger SQLite storage from ledger contracts; split queue memory/SQLite stores; split stream memory/SQLite stores; removed default no-op durable-worker/function methods from `EngineLedgerStore` and made in-memory/test ledgers implement them explicitly. Checkpoint commit: `739612887`. | No TPC-2 LOC or no-op default blocker remains; TPC-10 closed broad residue review. | TPC-2 engine/durability checkpoint |
| TPC-3 | Invocation host and primitive stores | 10 | passed_after_fix | engine primitives | Split `EngineHost` construction/bootstrap and meta invocation into `host/bootstrap.rs` and `host/meta_invocation.rs`; split primitive store backends and worker/function registration into `primitives/stores.rs` and `primitives/workers.rs`; moved trigger runtime test helpers into `runtime/trigger_helpers.rs`; added a TPC gate proving the original host, primitive, and trigger roots are under budget and no longer contain weak-host store wiring in the primitive root. Checkpoint commit: `c7d16e4b9`. | No TPC-3 LOC blocker remains; TPC-10 closed broad residue review. | TPC-3 invocation/primitives checkpoint |
| TPC-4 | External worker proof or deletion | 10 | passed_after_fix | runtime | Retained loopback-only external workers with explicit proof: split lifecycle/heartbeat/disconnect and durable health marking into `external_workers/lifecycle.rs`, registration/proxy/stream publication into `external_workers/registration.rs`, and scoped-token/capability validation into `external_workers/validation.rs`; split protocol roundtrip and invoker helpers out of the over-budget behavior test. Checkpoint commit: `6860022df`. | No TPC-4 LOC blocker remains; TPC-10 closed broad residue review. | TPC-4 external-worker checkpoint |
| TPC-5 | Provider/auth/model cleanup | 10 | passed_after_fix | provider/auth/model | Split provider factory tests, OpenAI message-converter tests, auth credential type tests, Ollama stream-handler tests, and OpenAI request-shaping tests into concern-owned child modules; moved the Gemini model registry to `google/types/models.rs`; removed stale compatibility-alias wording from provider root docs; and added a static gate proving TPC-5 files are under budget and provider alias references stay inside the OpenAI model catalog/type-helper boundary. Checkpoint commit: `449616f2e`. | No TPC-5 LOC blocker remains. Provider aliases are intentionally retained only in the OpenAI model registry/catalog tests; TPC-10 closed broad residue review. | TPC-5 provider/auth/model checkpoint |
| TPC-6 | Agent loop/config/context flattening | 10 | passed_after_fix | agent runtime | Split `/engine` WebSocket subscription state, polling, ack, and push cursor advancement into `transport/engine/socket/subscriptions.rs`; moved turn-runner persistence tests to `persistence/tests.rs`; moved SQLite observability transport tests to `transport/tests.rs`; renamed the no-persister persistence test away from no-op wording; and added a static gate proving the three TPC-6 roots are under budget with subscription ownership out of the socket dispatcher. Checkpoint commit: `5b4d43641`. | No TPC-6 LOC blocker remains; TPC-10 closed broad residue review. | TPC-6 transport/agent/observability checkpoint |
| TPC-7 | iOS engine/protocol cleanup | 10 | passed_after_fix | iOS engine shell | Split onboarding setup controls into `SetupStepComponents.swift`, diagnostics bundle DTO/sanitizer/hash helpers into `DiagnosticsBundleTypes.swift`, and generated-runtime rendering helpers into `GeneratedRuntimeSurfaceView+RenderingHelpers.swift`. Added a static gate proving the TPC-7 Swift roots are under 575 LOC, reusable controls/DTOs/helpers are out of the roots, and the local event database still declares temporary cache mode as server-authoritative projection state. Checkpoint commit: `acaa247ee`. | No TPC-7 LOC or temporary-cache ownership blocker remains; TPC-10 closed broad residue review. | TPC-7 iOS engine/protocol checkpoint |
| TPC-8 | iOS UI state flattening | 8 | passed_after_fix | iOS UI/session | Split settings main-section/action rendering into `SettingsView+MainSection.swift`, paired-server row/menu helpers into `SettingsServerSupport.swift`, chat message-list/pagination rendering into `ChatView+MessageList.swift`, chat runtime callback wiring into `ChatViewModel+RuntimeCallbacks.swift`, model-picker sections into `ModelPickerSheet+Sections.swift`, derived theme tokens into `TronThemeTokens.swift`, and typewriter animation tests into `StreamingManagerTypewriterTests.swift`. Added a static gate proving all TPC-8 roots are under budget and no longer own the moved concerns. Checkpoint commit: `10e6aa8ba`. | No TPC-8 Swift LOC blocker remains; TPC-10 closed broad residue review. | TPC-8 iOS UI/session checkpoint |
| TPC-9 | Mac/scripts/runtime helpers | 7 | passed_after_fix | scripts/Mac/runtime | Split the broad bootstrap test root into concern-owned child test modules; renamed the contributor deploy command to `manual-deploy` with no old `deploy` alias; renamed the script module to `manual-deploy.sh`; updated README/CLI help and service recovery guidance; and removed inactive-operation wording from Mac runtime helper comments. Added a static gate proving the split test owners, manual deploy boundary, and Mac/script residue cleanup. Checkpoint commit: `bc9d1950c`. | No TPC-9 LOC, deploy-command, or Mac/script inactive-operation blocker remains; TPC-10 closed broad docs/residue cleanup. | TPC-9 scripts/Mac/runtime checkpoint |
| TPC-10 | Docs, guards, inventories | 5 | passed_after_fix | docs/static gates | Added the final docs/guards/inventories TPC gate, updated active README wording, refreshed HRA/PCC ownership inventories for `scripts/tron.d/manual-deploy.sh`, removed old deploy-command spelling from active reference docs, regenerated the TPC retention inventory for the new guard, and recorded the residual-term review policy. Checkpoint commit: `3a73c7007`. | Closed. | TPC-10 docs/guards/inventory checkpoint |
| TPC-11 | Final closeout | 5 | passed_after_fix | final verification | Added the final closeout gate, ran full closeout verification, adversarial residue scans, ignored-artifact audit, personal-info full scan, hard-budget scans, active-reference drift scans, and clean worktree proof. | No open loops remain. | TPC-11 final closeout checkpoint pending |

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
