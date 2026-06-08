# Hierarchical Rearchitecture Inventory

Status: `passed_after_fix`

Generated from the live tracked checkout for HRA-1. No implementation moves were made in this row.

Baseline: HRA-0 checkpoint `f14f7b60c`; evidence hash checkpoint `4127619be`.

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Machine-Readable Artifacts

- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-move-map.tsv`

Both TSV files use this stable header:

```text
current_path	target_path	package	area	owner	classification	reason	phase	status	notes
```

Allowed classifications: `retain_in_place`, `move`, `split`, `merge`, `delete`, `asset`, `generated`, `external_boundary`.

Allowed statuses: `pending`, `running`, `passed`, `passed_after_fix`, `failed_unfixed`, `blocked`, `deferred_to_successor`.

## HRA-1 Baseline Counts

| Metric | Count |
|--------|-------|
| Tracked files from `git ls-files` plus HRA-2 new module maps | 1277 |
| Files under `packages/agent/src` | 471 |
| Files under `packages/agent/tests` | 6 |
| Files under `packages/ios-app/Sources` | 408 |
| Files under `packages/ios-app/Tests` | 192 |
| Files under `packages/mac-app/Sources` | 72 |
| Files under `packages/mac-app/Tests` | 33 |

## Extension Counts

| Extension | Count |
|-----------|-------|
| `.swift` | 630 |
| `.rs` | 473 |
| `.md` | 21 |
| `.json` | 20 |
| `.png` | 20 |
| `.ttf` | 20 |
| `.sh` | 12 |
| `.toml` | 10 |
| `[none]` | 10 |
| `.svg` | 9 |
| `.yml` | 9 |
| `.plist` | 7 |
| `.xcconfig` | 7 |
| `.entitlements` | 6 |
| `.icns` | 4 |
| `.tsv` | 3 |
| `.xcscheme` | 3 |
| `.lock` | 2 |
| `.env` | 1 |
| `.mjs` | 1 |
| `.pbxproj` | 1 |
| `.py` | 1 |
| `.sql` | 1 |
| `.xcprivacy` | 1 |
| `.xcworkspacedata` | 1 |

## Package Counts

| Package | Count |
|---------|-------|
| `ios-app` | 624 |
| `agent` | 498 |
| `mac-app` | 114 |
| `scripts` | 22 |
| `github` | 8 |
| `repo` | 5 |
| `codex` | 2 |

## Target Architecture Decisions

| Area | Decision | Phase |
|------|----------|-------|
| Rust source root | Keep only `lib.rs` and `main.rs`; move `main_cli.rs`, `main_runtime.rs`, and `main_tests.rs` under `app`. | HRA-2 |
| Rust app/transport/shared/platform | Use `app/bootstrap`, `app/health`, `app/lifecycle`, `transport/http`, `transport/engine`, `transport/workers`, and `transport/runtime`; shared survives only for multi-owner helpers. | HRA-2 |
| Rust engine | Move flat root modules to `kernel`, `catalog`, `invocation`, `authority`, `durability`, and `runtime`; collapse `host.rs` plus `host/` into invocation host. | HRA-3/HRA-4 |
| Rust domains | Move domain startup helpers under `registration`; agent/model/auth/settings/session use vertical feature folders; compact domains stay compact. | HRA-5/HRA-6 |
| iOS Engine | Replace `Network`, `Database`, `EventStore`, and DTO buckets with `Transport`, `Protocol`, `Events`, and `Persistence`. | HRA-9 |
| iOS Session | Move chat view-model, handlers, managers, state, messages, activity, reconstruction, and tokens to workflow owners. | HRA-10 |
| iOS UI | Replace `UI/Views` with `UI/Chat`, `UI/Settings`, `UI/Onboarding`, `UI/RuntimeSurfaces`, `UI/Capabilities`, `UI/Components`, `UI/System`, and `UI/Theme`. | HRA-11 |
| iOS Support | Replace broad utilities/extensions/services with composition, diagnostics, pairing, storage, feedback, and scoped foundation concerns. | HRA-12 |
| iOS tests | Move old technical buckets to `Infrastructure`, `Engine`, `Session`, `UI`, and `Support` mirrors. | HRA-13 |
| Mac wrapper | Audit and, when useful, split App/Server/MenuBar/Wizard/Tests into wrapper feature subfolders. | HRA-14 |

## HRA-1 Source Root Loose Files (HRA-2 Completed)

These HRA-1 findings are now implemented in HRA-2. The current source root has
only `packages/agent/src/lib.rs` and `packages/agent/src/main.rs`.

| Path | Target | Phase |
|------|--------|-------|
| `packages/agent/src/main_cli.rs` | `packages/agent/src/app/cli/mod.rs` | HRA-2 |
| `packages/agent/src/main_runtime.rs` | `packages/agent/src/app/bootstrap/mod.rs` | HRA-2 |
| `packages/agent/src/main_tests.rs` | `packages/agent/src/app/bootstrap/tests.rs` | HRA-2 |

## Directories Over 12 Source Files

| Directory | Source files | Owner | Phase |
|-----------|--------------|-------|-------|
| `packages/agent/src/domains/agent/runner/context` | 13 | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator` | 13 | rust agent domain owner | HRA-5 |
| `packages/agent/src/engine` | 21 | rust engine catalog owner | HRA-3 |
| `packages/agent/src/engine/tests` | 16 | rust engine test owner | HRA-3 |
| `packages/ios-app/Sources/Engine/Network` | 16 | ios engine transport owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/DTOs` | 15 | ios engine protocol owner | HRA-9 |
| `packages/ios-app/Sources/UI/Views/Capabilities/Shared` | 19 | ios capability UI owner | HRA-11 |
| `packages/ios-app/Tests/Infrastructure` | 16 | ios test infrastructure owner | HRA-13 |
| `packages/ios-app/Tests/Services` | 34 | ios engine test owner | HRA-13 |
| `packages/ios-app/Tests/ViewModels` | 38 | ios session test owner | HRA-13 |
| `packages/ios-app/Tests/Views` | 15 | ios UI test owner | HRA-13 |
| `packages/mac-app/Tests/Services` | 20 | mac test owner | HRA-14 |

## One-File Source Directories

| Directory | File | Owner | Phase |
|-----------|------|-------|-------|
| `packages/agent/src/app/onboarding` | `mod.rs` | rust app owner | HRA-2 |
| `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/agent/compaction_handler` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/orchestrator` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/session_manager` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/turn_accumulator` | `tests.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/auth/provider_credentials/openai` | `tests.rs` | rust auth domain owner | HRA-5 |
| `packages/agent/src/domains/auth/provider_credentials/storage` | `tests.rs` | rust auth domain owner | HRA-5 |
| `packages/agent/src/domains/blob` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/capability/operations` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/message` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/message_converter` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/provider` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/stream_handler` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/types` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/google/provider` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/google/types` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/ollama/message_converter` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/stream_handler` | `tests.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/types/models` | `catalog.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/session/event_store/event/reconstruct` | `tests.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/session/event_store/sqlite/migrations/tests` | `primitive.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/settings/implementation/storage` | `loader.rs` | rust settings domain owner | HRA-5 |
| `packages/agent/src/domains/system` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/shared/foundation/paths` | `tests.rs` | rust shared owner | HRA-2 |
| `packages/agent/src/shared/protocol/events/tron` | `catalog.rs` | rust shared owner | HRA-2 |
| `packages/agent/src/shared/protocol/messages` | `tests.rs` | rust shared owner | HRA-2 |
| `packages/ios-app/Sources/Engine/Database/Schema` | `DatabaseSchema.swift` | ios engine persistence owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Core` | `AsyncEventStream.swift` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Display` | `DisplayFramePlugin.swift` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Core/Transformer/Reconstruction` | `ReconstructedState.swift` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Types` | `EventTypeRegistry.swift` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Models` | `ModelFilteringService.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol` | `ProtocolConstants.swift` | ios engine protocol owner | HRA-9 |
| `packages/ios-app/Sources/Session/Parsing` | `CapabilityArgumentParser.swift` | ios session owner | HRA-10 |
| `packages/ios-app/Sources/Session/Reconstruction` | `UnifiedEventTransformer.swift` | ios session timeline owner | HRA-10 |
| `packages/ios-app/Sources/Support` | `AppConstants.swift` | ios support owner | HRA-12 |
| `packages/ios-app/Sources/Support/Concurrency` | `AsyncSemaphore.swift` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Sources/Support/Feedback` | `FeedbackComposer.swift` | ios support feedback owner | HRA-12 |
| `packages/ios-app/Sources/Support/Observability` | `DiagnosticsRedactor.swift` | ios support diagnostics owner | HRA-12 |
| `packages/ios-app/Sources/Support/Pairing` | `PairingURLParser.swift` | ios support pairing owner | HRA-12 |
| `packages/ios-app/Sources/Support/Settings` | `PairedServerStore.swift` | ios settings UI owner | HRA-11 |
| `packages/ios-app/Sources/Support/Share` | `SharedContent.swift` | ios support owner | HRA-12 |
| `packages/ios-app/Sources/Support/Storage` | `DraftStore.swift` | ios support storage owner | HRA-12 |
| `packages/ios-app/Sources/UI/Views/Capabilities/Thinking` | `ThinkingDetailSheet.swift` | ios capability UI owner | HRA-11 |
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces` | `GeneratedRuntimeSurfaceView.swift` | ios runtime surface UI owner | HRA-11 |
| `packages/ios-app/Tests/Core` | `AppConstantsTests.swift` | repo owner | HRA-13 |
| `packages/ios-app/Tests/Core/Concurrency` | `AsyncSemaphoreTests.swift` | ios support test owner | HRA-13 |
| `packages/ios-app/Tests/Navigation` | `DeepLinkRouterTests.swift` | ios session test owner | HRA-13 |
| `packages/mac-app/Sources/Support/Feedback` | `FeedbackComposer.swift` | mac support owner | HRA-14 |
| `packages/mac-app/Sources/Support/Observability` | `DiagnosticsRedactor.swift` | mac support owner | HRA-14 |
| `packages/mac-app/Tests/Mocks` | `MockLaunchAgentManager.swift` | mac test owner | HRA-14 |

## Generic Bucket Directories

| Directory | Owner | Phase |
|-----------|-------|-------|
| `packages/ios-app/Sources/Engine/Events/Core` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Core/Transformer/Handlers` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Types` | ios engine events owner | HRA-9 |
| `packages/ios-app/Sources/Session/ViewModels/Handlers` | ios session chat owner | HRA-10 |
| `packages/ios-app/Sources/Session/ViewModels/Managers` | ios session chat owner | HRA-10 |
| `packages/ios-app/Sources/Session/ViewModels/Utilities` | ios session chat owner | HRA-10 |
| `packages/ios-app/Sources/Support/Diagnostics/Services` | ios support diagnostics owner | HRA-12 |
| `packages/ios-app/Sources/Support/Infrastructure/Services` | ios support diagnostics owner | HRA-12 |
| `packages/ios-app/Sources/Support/Storage/Services` | ios support storage owner | HRA-12 |
| `packages/ios-app/Sources/Support/Utilities/Core` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Tests/Core` | repo owner | HRA-13 |
| `packages/ios-app/Tests/Services` | ios engine test owner | HRA-13 |
| `packages/ios-app/Tests/Utilities` | ios support test owner | HRA-13 |
| `packages/mac-app/Tests/Services` | mac test owner | HRA-14 |

## Same-Name File/Folder Pairs

| File | Folder | Target phase |
|------|--------|--------------|
| `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs` | `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor` | HRA-5 |
| `packages/agent/src/domains/agent/runner/agent/compaction_handler.rs` | `packages/agent/src/domains/agent/runner/agent/compaction_handler` | HRA-5 |
| `packages/agent/src/domains/agent/runner/agent/turn_runner.rs` | `packages/agent/src/domains/agent/runner/agent/turn_runner` | HRA-5 |
| `packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations.rs` | `packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations` | HRA-5 |
| `packages/agent/src/domains/agent/runner/context/context_manager.rs` | `packages/agent/src/domains/agent/runner/context/context_manager` | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/orchestrator.rs` | `packages/agent/src/domains/agent/runner/orchestrator/orchestrator` | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/session_manager.rs` | `packages/agent/src/domains/agent/runner/orchestrator/session_manager` | HRA-5 |
| `packages/agent/src/domains/agent/runner/orchestrator/turn_accumulator.rs` | `packages/agent/src/domains/agent/runner/orchestrator/turn_accumulator` | HRA-5 |
| `packages/agent/src/domains/auth/provider_credentials/openai.rs` | `packages/agent/src/domains/auth/provider_credentials/openai` | HRA-5 |
| `packages/agent/src/domains/auth/provider_credentials/storage.rs` | `packages/agent/src/domains/auth/provider_credentials/storage` | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/message_converter.rs` | `packages/agent/src/domains/model/providers/anthropic/message_converter` | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/provider.rs` | `packages/agent/src/domains/model/providers/anthropic/provider` | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/stream_handler.rs` | `packages/agent/src/domains/model/providers/anthropic/stream_handler` | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/types.rs` | `packages/agent/src/domains/model/providers/anthropic/types` | HRA-5 |
| `packages/agent/src/domains/model/providers/google/provider.rs` | `packages/agent/src/domains/model/providers/google/provider` | HRA-5 |
| `packages/agent/src/domains/model/providers/google/types.rs` | `packages/agent/src/domains/model/providers/google/types` | HRA-5 |
| `packages/agent/src/domains/model/providers/ollama/message_converter.rs` | `packages/agent/src/domains/model/providers/ollama/message_converter` | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/stream_handler.rs` | `packages/agent/src/domains/model/providers/openai/stream_handler` | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/types.rs` | `packages/agent/src/domains/model/providers/openai/types` | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/types/models.rs` | `packages/agent/src/domains/model/providers/openai/types/models` | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/types/models/catalog.rs` | `packages/agent/src/domains/model/providers/openai/types/models/catalog` | HRA-5 |
| `packages/agent/src/domains/session/event_store/event/reconstruct.rs` | `packages/agent/src/domains/session/event_store/event/reconstruct` | HRA-6 |
| `packages/agent/src/domains/session/event_store/event/reconstruct/tests.rs` | `packages/agent/src/domains/session/event_store/event/reconstruct/tests` | HRA-6 |
| `packages/agent/src/domains/session/event_store/sqlite/migrations/tests.rs` | `packages/agent/src/domains/session/event_store/sqlite/migrations/tests` | HRA-6 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/session.rs` | `packages/agent/src/domains/session/event_store/sqlite/repositories/session` | HRA-6 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/session/tests.rs` | `packages/agent/src/domains/session/event_store/sqlite/repositories/session/tests` | HRA-6 |
| `packages/agent/src/domains/session/event_store/store/event_store.rs` | `packages/agent/src/domains/session/event_store/store/event_store` | HRA-6 |
| `packages/agent/src/domains/session/event_store/store/tests.rs` | `packages/agent/src/domains/session/event_store/store/tests` | HRA-6 |
| `packages/agent/src/engine/grants.rs` | `packages/agent/src/engine/grants` | HRA-4 |
| `packages/agent/src/engine/host.rs` | `packages/agent/src/engine/host` | HRA-3 |
| `packages/agent/src/engine/ledger.rs` | `packages/agent/src/engine/ledger` | HRA-4 |
| `packages/agent/src/engine/primitives/resource.rs` | `packages/agent/src/engine/primitives/resource` | HRA-3 |
| `packages/agent/src/engine/primitives/ui.rs` | `packages/agent/src/engine/primitives/ui` | HRA-3 |
| `packages/agent/src/engine/queue.rs` | `packages/agent/src/engine/queue` | HRA-4 |
| `packages/agent/src/engine/registry.rs` | `packages/agent/src/engine/registry` | HRA-3 |
| `packages/agent/src/engine/resources/store.rs` | `packages/agent/src/engine/resources/store` | HRA-4 |
| `packages/agent/src/shared/foundation/paths.rs` | `packages/agent/src/shared/foundation/paths` | HRA-2 |
| `packages/agent/src/shared/foundation/profile.rs` | `packages/agent/src/shared/foundation/profile` | HRA-2 |
| `packages/agent/src/shared/protocol/events.rs` | `packages/agent/src/shared/protocol/events` | HRA-2 |
| `packages/agent/src/shared/protocol/events/tests.rs` | `packages/agent/src/shared/protocol/events/tests` | HRA-2 |
| `packages/agent/src/shared/protocol/events/tron.rs` | `packages/agent/src/shared/protocol/events/tron` | HRA-2 |
| `packages/agent/src/shared/protocol/messages.rs` | `packages/agent/src/shared/protocol/messages` | HRA-2 |
| `packages/agent/src/shared/storage.rs` | `packages/agent/src/shared/storage` | HRA-2 |
| `packages/agent/src/transport/engine_ws.rs` | `packages/agent/src/transport/engine_ws` | HRA-2 |

## Over-Budget Files

| Path | LOC | Limit | Owner | Phase |
|------|-----|-------|-------|-------|
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1182 | 900 | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1038 | 900 | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/auth/provider_credentials/storage/tests.rs` | 1383 | 900 | rust auth domain owner | HRA-5 |
| `packages/agent/src/domains/capability/operations/mod.rs` | 927 | 900 | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/anthropic/types.rs` | 941 | 900 | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/kimi/stream_handler.rs` | 991 | 900 | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1571 | 900 | rust session domain owner | HRA-6 |
| `packages/agent/src/engine/external.rs` | 906 | 900 | rust engine runtime owner | HRA-3 |
| `packages/agent/src/engine/grants.rs` | 956 | 900 | rust engine authority owner | HRA-4 |
| `packages/agent/src/engine/ledger.rs` | 955 | 900 | rust engine durability owner | HRA-4 |
| `packages/agent/src/engine/resources/store.rs` | 972 | 900 | rust engine durability owner | HRA-4 |
| `packages/agent/src/engine/tests/grant_authority.rs` | 929 | 900 | rust engine test owner | HRA-4 |
| `packages/agent/src/engine/tests/resource_kernel.rs` | 1196 | 900 | rust engine test owner | HRA-4 |
| `packages/agent/src/engine/tests/state_queue.rs` | 907 | 900 | rust engine test owner | HRA-4 |
| `packages/agent/src/engine/types.rs` | 1008 | 900 | rust engine kernel owner | HRA-3 |
| `packages/agent/tests/primitive_code_cleanup_invariants.rs` | 942 | 900 | rust integration/static test owner | HRA-7 |
| `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs` | 2242 | 900 | rust integration/static test owner | HRA-7 |
| `packages/ios-app/Sources/Engine/Network/EngineConnection.swift` | 958 | 700 | ios engine transport owner | HRA-9 |
| `packages/ios-app/Sources/Session/Messages/CapabilityInvocationDisplayModel.swift` | 744 | 700 | ios session timeline owner | HRA-10 |
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` | 817 | 700 | ios runtime surface UI owner | HRA-11 |
| `packages/ios-app/Sources/UI/Views/Settings/SettingsView.swift` | 735 | 700 | ios settings UI owner | HRA-11 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2140 | 700 | ios engine test owner | HRA-13 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | 1531 | 700 | ios test infrastructure owner | HRA-13 |
| `packages/mac-app/Tests/Wizard/WizardStepTests.swift` | 717 | 700 | mac test owner | HRA-14 |

## Docs And Scripts With Old Path Claims

| Path | Matched terms | Closeout phase |
|------|---------------|----------------|
| `README.md` | engine/host.rs, main_cli.rs, main_runtime.rs, main_tests.rs | HRA-15 |
| `packages/agent/docs/primitive-code-cleanup-evidence-manifest.md` | Tests/Services, UI/Views | HRA-15 |
| `packages/agent/docs/primitive-code-cleanup-scorecard.md` | Engine/Network, UI/Views | HRA-15 |
| `packages/agent/docs/primitive-engine-teardown-evidence-manifest.md` | engine/host.rs | HRA-15 |
| `packages/agent/docs/primitive-engine-teardown-inventory.md` | Session/ViewModels, UI/Views | HRA-15 |
| `packages/agent/src/main.rs` | main_tests.rs | HRA-2 |
| `packages/agent/src/main_cli.rs` | main_runtime.rs | HRA-2 |
| `packages/agent/src/main_tests.rs` | main_runtime.rs | HRA-2 |
| `packages/agent/tests/hierarchical_rearchitecture_invariants.rs` | Engine/Database, Engine/Network, Session/ViewModels, Support/Extensions, Support/Utilities, Tests/Services, UI/Views | HRA-7 |
| `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs` | Engine/Database, Engine/Network, Session/ViewModels, Tests/Services, UI/Views, engine/host.rs, main_runtime.rs | HRA-7 |
| `packages/ios-app/Tests/Infrastructure/CleanupGuardTests.swift` | Support/Utilities | HRA-13 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | Engine/Database, Engine/Network, Session/ViewModels, Tests/Services, UI/Views | HRA-13 |
| `packages/ios-app/Tests/Views/InputBarKeyboardTraversalTests.swift` | UI/Views | HRA-13 |
| `packages/ios-app/docs/architecture.md` | UI/Views | HRA-15 |
| `packages/ios-app/docs/onboarding.md` | Session/ViewModels, Support/Extensions, Tests/Services, UI/Views | HRA-15 |
| `packages/mac-app/Sources/Server/BearerTokenReader.swift` | Tests/Services | HRA-14 |
| `packages/mac-app/Sources/Server/SingleInstanceLock.swift` | Tests/Services | HRA-14 |
| `packages/mac-app/Sources/Support/Onboarding/InstallPlanner.swift` | Tests/Services | HRA-14 |
| `packages/mac-app/Sources/Support/Pairing/PairingURLBuilder.swift` | Tests/Services | HRA-14 |
| `packages/mac-app/Sources/Support/Pairing/QRCodeGenerator.swift` | Tests/Services | HRA-14 |

## Retained Folder Owner Table

| Folder | Owner | Reason | Status |
|--------|-------|--------|--------|
| `packages/agent/src` | rust app owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/app` | rust app owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/app/onboarding` | rust app owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/operations` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runner` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runner/agent` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/agent/compaction_handler` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/agent/turn_runner` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/context` | rust agent domain owner | large folder flagged for split or explicit budget | pending |
| `packages/agent/src/domains/agent/runner/context/context_manager` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runner/orchestrator` | rust agent domain owner | large folder flagged for split or explicit budget | pending |
| `packages/agent/src/domains/agent/runner/orchestrator/orchestrator` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/orchestrator/session_manager` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/orchestrator/turn_accumulator` | rust agent domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/agent/runner/pipeline` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runtime` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runtime/runtime` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/agent/runtime/service` | rust agent domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/auth` | rust auth domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/auth/operations` | rust auth domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/auth/provider_credentials` | rust auth domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/auth/provider_credentials/openai` | rust auth domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/auth/provider_credentials/storage` | rust auth domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/blob` | rust compact domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/capability` | rust compact domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/capability/operations` | rust compact domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/logs` | rust compact domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/message` | rust compact domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/operations` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/provider_protocol` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/anthropic` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/anthropic/message_converter` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/anthropic/provider` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/anthropic/stream_handler` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/anthropic/types` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/google` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/google/provider` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/google/types` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/kimi` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/minimax` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/models` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/ollama` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/ollama/message_converter` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/openai` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/openai/stream_handler` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/openai/types` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/openai/types/models` | rust model domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/model/providers/openai/types/models/catalog` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/shared` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/model/providers/tokens` | rust model domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/commands` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/commands/tests` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/event` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/event/reconstruct` | rust session domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/session/event_store/event/reconstruct/tests` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite/migrations` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite/migrations/tests` | rust session domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/session/event_store/sqlite/repositories` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/session` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/session/tests` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/store` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/store/event_store` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/store/tests` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/types` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/session/event_store/types/payloads` | rust session domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/settings` | rust settings domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/settings/implementation` | rust settings domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/settings/implementation/storage` | rust settings domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/domains/settings/implementation/types` | rust settings domain owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/domains/system` | rust compact domain owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/engine` | rust engine catalog owner | large folder flagged for split or explicit budget | pending |
| `packages/agent/src/engine/grants` | rust engine authority owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/host` | rust engine invocation owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/ledger` | rust engine durability owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/primitives` | rust engine primitives owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/primitives/resource` | rust engine primitives owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/primitives/ui` | rust engine primitives owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/queue` | rust engine durability owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/registry` | rust engine catalog owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/resources` | rust engine durability owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/resources/store` | rust engine durability owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/engine/tests` | rust engine test owner | large folder flagged for split or explicit budget | pending |
| `packages/agent/src/platform` | rust platform owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/errors` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/foundation` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/foundation/paths` | rust shared owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/shared/foundation/profile` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/logging` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/protocol` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/protocol/events` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/protocol/events/tests` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/protocol/events/tron` | rust shared owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/shared/protocol/messages` | rust shared owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/agent/src/shared/server` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/shared/storage` | rust shared owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/transport` | rust transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/transport/engine_ws` | rust transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/transport/runtime` | rust transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/transport/runtime/streams` | rust transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/src/transport/runtime/streams/session` | rust transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/agent/tests` | rust integration/static test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources` | repo owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/App` | repo owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Assets.xcassets` | repo owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Assets.xcassets/AccentColor.colorset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/AppIcon.appiconset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/AppIconBeta.appiconset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconAnthropic.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconGit.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconGoogle.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconKimi.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconMiniMax.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconOllama.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/IconOpenAI.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/LaunchScreenBackground.colorset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/TronLogo.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Assets.xcassets/TronLogoVector.imageset` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Engine/Database` | ios engine persistence owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Database/Repositories` | ios engine persistence owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Database/Schema` | ios engine persistence owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Engine/EventStore` | ios engine persistence owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core` | ios engine events owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Engine/Events/Core/Payloads` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/CapabilityInvocation` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Display` | ios engine events owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Lifecycle` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Server` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Session` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Plugins/Streaming` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Transformer` | ios engine events owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Events/Core/Transformer/Handlers` | ios engine events owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Engine/Events/Core/Transformer/Reconstruction` | ios engine events owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Engine/Events/Types` | ios engine events owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Engine/Models` | ios engine owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Engine/Network` | ios engine transport owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Sources/Engine/Network/Clients` | ios engine transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Protocol` | ios engine protocol owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Engine/Protocol/DTOs` | ios engine protocol owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Sources/Engine/Protocols` | ios engine transport owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Repositories/Defaults` | ios engine persistence owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Engine/Repositories/Defaults/Protocols` | ios engine persistence owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Resources/Fonts` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Resources/IconLayers` | repo owner | asset/resource boundary | passed |
| `packages/ios-app/Sources/Session/Activity` | ios session timeline owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/Features` | ios session chat owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/Messages` | ios session timeline owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/Parsing` | ios session owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Session/Reconstruction` | ios session timeline owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Session/Tokens` | ios session timeline owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/ViewModels/Chat` | ios session chat owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/ViewModels/Handlers` | ios session chat owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Session/ViewModels/Managers` | ios session chat owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Session/ViewModels/State` | ios session chat owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Session/ViewModels/Utilities` | ios session chat owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Support` | ios support owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Concurrency` | ios support foundation owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/DependencyInjection` | ios support composition owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Support/Diagnostics/Services` | ios support diagnostics owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Support/Extensions/Swift` | ios support foundation owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Support/Feedback` | ios support feedback owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Infrastructure/Services` | ios support diagnostics owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Support/Observability` | ios support diagnostics owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Pairing` | ios support pairing owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Pairing/Onboarding` | ios support pairing owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/Support/Settings` | ios settings UI owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Share` | ios support owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Storage` | ios support storage owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/Support/Storage/Services` | ios support storage owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/Support/Utilities/Core` | ios support foundation owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Sources/UI/Theme` | ios theme owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Attachments` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Capabilities` | ios capability UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Capabilities/Display` | ios capability UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Capabilities/Shared` | ios capability UI owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Sources/UI/Views/Capabilities/Thinking` | ios capability UI owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/UI/Views/Chat` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Chat/Indicators` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Components` | ios shared component UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces` | ios runtime surface UI owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Sources/UI/Views/InputBar` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/MessageBubble` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Onboarding` | ios onboarding UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Onboarding/Steps` | ios onboarding UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Session` | ios chat UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Settings` | ios settings UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Settings/OAuth` | ios settings UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Settings/Pages` | ios settings UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Settings/Pages/ModelProviders` | ios settings UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/Settings/Shared` | ios settings UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Sources/UI/Views/System` | ios system UI owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Core` | repo owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Tests/Core/Concurrency` | ios support test owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Tests/Core/Events` | ios engine test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Core/Events/Plugins` | ios engine test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Extensions` | ios support test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Infrastructure` | ios test infrastructure owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Tests/Models` | ios session test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Models/EngineProtocol` | ios engine test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Navigation` | ios session test owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/ios-app/Tests/Observability` | ios support test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Onboarding` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Repositories` | ios engine test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Services` | ios engine test owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Tests/Support` | ios support test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Theme` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Utilities` | ios support test owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/ios-app/Tests/ViewModels` | ios session test owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Tests/Views` | ios UI test owner | large folder flagged for split or explicit budget | pending |
| `packages/ios-app/Tests/Views/Capabilities` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Views/Chat` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Views/Components` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/ios-app/Tests/Views/Settings` | ios UI test owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources` | mac app owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/App` | mac app owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Assets.xcassets` | repo owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Assets.xcassets/AppIcon.appiconset` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Assets.xcassets/TronLogo.imageset` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/MenuBar` | mac menu bar owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Resources` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Fonts` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Library/LaunchAgents` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Resources` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/Resources` | repo owner | asset/resource boundary | passed |
| `packages/mac-app/Sources/Server` | mac server owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Support` | mac support owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Support/Feedback` | mac support owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/mac-app/Sources/Support/Observability` | mac support owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/mac-app/Sources/Support/Onboarding` | mac support owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Support/Pairing` | mac support owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Support/Theme` | mac support owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Wizard` | mac wizard owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Sources/Wizard/Steps` | mac wizard owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Tests/MenuBar` | mac test owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Tests/Mocks` | mac test owner | one-source-file folder flagged for collapse or explicit boundary | pending |
| `packages/mac-app/Tests/Observability` | mac test owner | owned source/test boundary under target hierarchy | passed |
| `packages/mac-app/Tests/Services` | mac test owner | generic bucket flagged for rename or scoped justification | pending |
| `packages/mac-app/Tests/Wizard` | mac test owner | owned source/test boundary under target hierarchy | passed |

## Open Loops

- HRA-2 through HRA-14 must execute the pending `move` and `split` rows without compatibility shims.
- HRA-7 and HRA-13 must move tests to mirror production boundaries and keep static gates green as each source area moves.
- HRA-15 must remove old-path claims outside scorecards, evidence, and static absence tests.
- HRA-16 must run the final adversarial review, full verification matrix, and ledger append.
