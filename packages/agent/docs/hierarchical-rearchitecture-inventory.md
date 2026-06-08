# Hierarchical Rearchitecture Inventory

Status: `running`

Generated from the live checkout after HRA-12. HRA-0/HRA-1 recorded the baseline; HRA-2 through HRA-7 updated the Rust source, engine, domain, session/event-store, test, and progressive-doc hierarchy without compatibility shim modules. HRA-8 added the iOS SourceGuard red gates and source/test move map, HRA-9 consumed the Engine rows, HRA-10 consumed the Session rows, HRA-11 consumed the UI rows, and HRA-12 consumed the App/Support rows by moving Swift production files into feature-owned roots.

Baseline: HRA-0 checkpoint `f14f7b60c`; evidence hash checkpoint `4127619be`.

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Machine-Readable Artifacts

- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-move-map.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md`

The global HRA inventory and move-map TSV files use this stable header:

```text
current_path	target_path	package	area	owner	classification	reason	phase	status	notes
```

Allowed classifications: `retain_in_place`, `move`, `split`, `merge`, `delete`, `asset`, `generated`, `external_boundary`.

Allowed statuses: `pending`, `running`, `passed`, `passed_after_fix`, `failed_unfixed`, `blocked`, `deferred_to_successor`.

The HRA iOS move map uses this HRA-8-specific header:

```text
current_path	target_path	owner	phase	classification	status	reason
```

## HRA-1 Baseline Counts Updated After HRA-12

| Metric | Count |
| --- | --- |
| Tracked files after HRA-12 staged additions | 1355 |
| Files under `packages/agent/src` | 522 |
| Files under `packages/agent/tests` | 26 |
| Files under `packages/ios-app/Sources` | 414 |
| Files under `packages/ios-app/Tests` | 192 |
| Files under `packages/mac-app/Sources` | 72 |
| Files under `packages/mac-app/Tests` | 33 |

## Extension Counts

| Extension | Count |
| --- | --- |
| .swift | 636 |
| .rs | 547 |
| .md | 22 |
| .json | 20 |
| .png | 20 |
| .ttf | 20 |
| .sh | 12 |
| .toml | 10 |
| .svg | 9 |
| .yml | 9 |
| .plist | 7 |
| .xcconfig | 7 |
| [none] | 7 |
| .entitlements | 6 |
| .icns | 4 |
| .tsv | 4 |
| .gitignore | 3 |
| .xcscheme | 3 |
| .lock | 2 |
| .env | 1 |
| .mjs | 1 |
| .pbxproj | 1 |
| .py | 1 |
| .sql | 1 |
| .xcprivacy | 1 |
| .xcworkspacedata | 1 |

## Package Counts

| Package | Count |
| --- | --- |
| ios-app | 630 |
| agent | 574 |
| mac-app | 114 |
| scripts | 22 |
| github | 8 |
| repo | 5 |
| codex | 2 |

## Target Architecture Decisions

| Area | Decision | Phase |
| ---- | -------- | ----- |
| Rust source root | Only `lib.rs` and `main.rs` remain at the crate root; app/bootstrap helpers live under `app`. | HRA-2 |
| Rust app/transport/shared/platform | Use `app/bootstrap`, `app/health`, `app/lifecycle`, `transport/http`, `transport/engine`, `transport/workers`, and scoped shared foundations. | HRA-2 |
| Rust engine | Flat root modules moved to `kernel`, `catalog`, `invocation`, `authority`, `durability`, and `runtime`; avoidable engine same-name pairs removed. | HRA-3/HRA-4 |
| Rust non-session domains | Registration helpers live under `domains/registration`; agent/auth/model/settings/capability use behavior-owned vertical folders. | HRA-5 |
| Rust session/event-store | Session lifecycle/query/reconstruction and event-store envelope/factory/reconstruction/store/sqlite owners use folder-backed modules; oversized event repository tests are split by behavior. | HRA-6 |
| iOS Engine | Replaced `Network`, `Database`, `EventStore`, DTO, protocol, repository, and event core/type buckets with `Transport`, `Protocol`, `Events`, `Persistence`, and `Models`; split the WebSocket connection across focused units. | HRA-9 |
| iOS Session | Chat view models, coordinators, messaging, navigation, and state live under `Session/Chat`; attachment models live under `Session/Attachments`; parser helpers remain under `Session/Parsing`; activity, messages, reconstruction, and tokens live under `Session/Timeline`. `UnifiedEventTransformer` is timeline reconstruction-owned because it projects stored events into chat messages. | HRA-10 |
| iOS UI | `UI/Views` is removed; chat, settings, onboarding, runtime surfaces, capability evidence, reusable components, system sheets, and theme live under feature-owned UI roots. Runtime surface and settings root views are split below the HRA Swift line budget. | HRA-11 |
| iOS Support | App entry points live under `App/Lifecycle`; dependency assembly lives under `Support/Composition`; diagnostics, feedback, foundation, pairing, share, and storage are concrete owners with no broad utilities/extensions/services buckets. | HRA-12 |
| iOS tests | Move old technical buckets to `Infrastructure`, `Engine`, `Session`, `UI`, and `Support` mirrors. | HRA-13 |
| Mac wrapper | Audit and move only justified Mac wrapper drift. | HRA-14 |

## Completed Rust Root Findings

The current Rust source root has only `packages/agent/src/lib.rs` and `packages/agent/src/main.rs`. Domain startup helpers live under `packages/agent/src/domains/registration`; non-session domains and the session event-store no longer have avoidable same-name file/folder module pairs. HRA-7 mirrors engine tests under `engine/tests/{authority,catalog,durability,invocation,kernel,runtime}` and splits root static integration targets into folder-backed modules while preserving their integration target names.

HRA-8 added a 547-row iOS source/test Swift move map. HRA-9 updated that map to 550 live Swift rows after the `EngineConnection` split and marked the Engine rows `passed_after_fix`. HRA-10 updated the map to 551 live Swift rows after the Session display-model split and marked the Session rows `passed_after_fix`. HRA-11 updated the map to 553 live Swift rows after the UI support splits, and HRA-12 keeps the same 553-row coverage while marking the App/Support rows `passed_after_fix`. Only HRA-13 test rows remain pending. The map has no fallback rows, points old broad-bucket paths to target feature owners, and is guarded by `ios_hra8_move_map_covers_every_source_and_test_swift_file`.

## Directories Over 12 Source Files

| Directory | Source files | Owner | Phase |
| --- | --- | --- | --- |
| `packages/ios-app/Sources/Engine/Transport/Clients` | 13 | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Session/Timeline/Messages` | 13 | ios session timeline owner | HRA-10 |
| `packages/ios-app/Sources/UI/Capabilities/Shared` | 19 | ios UI capabilities owner | HRA-11 |
| `packages/ios-app/Sources/UI/Settings/Shell` | 13 | ios UI settings owner | HRA-11 |
| `packages/ios-app/Tests/Infrastructure` | 16 | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Services` | 34 | ios test owner | HRA-13 |
| `packages/ios-app/Tests/ViewModels` | 38 | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Views` | 15 | ios test owner | HRA-13 |
| `packages/mac-app/Tests/Services` | 20 | mac wrapper owner | HRA-14 |

## One-File Source Directories

| Directory | File | Owner | Phase |
| --- | --- | --- | --- |
| `packages/agent/src/app` | `mod.rs` | repo owner | HRA-15 |
| `packages/agent/src/app/cli` | `mod.rs` | repo owner | HRA-15 |
| `packages/agent/src/app/lifecycle/onboarding` | `mod.rs` | repo owner | HRA-15 |
| `packages/agent/src/domains` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/agent/context/compaction_engine` | `mod.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/agent/loop/stream_processor` | `mod.rs` | rust agent domain owner | HRA-5 |
| `packages/agent/src/domains/auth/credentials/storage` | `mod.rs` | rust auth domain owner | HRA-5 |
| `packages/agent/src/domains/blob` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/message` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/domains/model/providers/openai/types/models` | `mod.rs` | rust model domain owner | HRA-5 |
| `packages/agent/src/domains/session/event_store/envelope` | `mod.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/session/event_store/factory` | `mod.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/session/event_store/reconstruction` | `mod.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/session/event_store/sqlite/migrations` | `mod.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/session/event_store/store` | `mod.rs` | rust session domain owner | HRA-6 |
| `packages/agent/src/domains/settings/profile/storage` | `loader.rs` | rust settings domain owner | HRA-5 |
| `packages/agent/src/domains/system` | `mod.rs` | rust compact domain owner | HRA-5 |
| `packages/agent/src/engine` | `mod.rs` | rust engine owner | HRA-7 |
| `packages/agent/src/engine/tests` | `mod.rs` | rust engine owner | HRA-7 |
| `packages/agent/src/engine/tests/fixtures` | `mod.rs` | rust engine owner | HRA-7 |
| `packages/agent/src/shared` | `mod.rs` | repo owner | HRA-15 |
| `packages/agent/src/shared/protocol/events/tron` | `catalog.rs` | repo owner | HRA-15 |
| `packages/agent/src/transport` | `mod.rs` | repo owner | HRA-15 |
| `packages/ios-app/ShareExtension` | `ShareViewController.swift` | repo owner | HRA-15 |
| `packages/ios-app/Sources/Engine/Events/Plugins/Display` | `DisplayFramePlugin.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Events/Reconstruction/Reconstruction` | `ReconstructedState.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Models` | `ModelFilteringService.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Persistence/SQLite/Schema` | `DatabaseSchema.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Agent` | `EngineProtocolTypes+Agent.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Auth` | `EngineProtocolTypes+Auth.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Catalog` | `EngineProtocolTypes+Catalog.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Events` | `EngineProtocolTypes+Events.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/GeneratedUI` | `EngineProtocolTypes+GeneratedUI.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Interaction` | `EngineProtocolTypes+Interaction.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Model` | `EngineProtocolTypes+Model.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Reconstruct` | `EngineProtocolTypes+Reconstruct.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Session` | `EngineProtocolTypes+Session.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/Settings` | `EngineProtocolTypes+Settings.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Protocol/System` | `EngineProtocolTypes+System.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Engine/Transport/DeepLinks` | `DeepLinkRouter.swift` | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Session/Parsing` | `CapabilityArgumentParser.swift` | ios session parsing owner | HRA-10 |
| `packages/ios-app/Sources/Session/Timeline/Reconstruction` | `UnifiedEventTransformer.swift` | ios session timeline owner | HRA-10 |
| `packages/ios-app/Sources/Support/Foundation` | `AppConstants.swift` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Sources/Support/Foundation/Concurrency` | `AsyncSemaphore.swift` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Sources/Support/Feedback` | `FeedbackComposer.swift` | ios support owner | HRA-12 |
| `packages/ios-app/Sources/Support/Foundation/Media` | `ImageProcessor.swift` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Sources/Support/Foundation/Validation` | `FolderNameValidator.swift` | ios support foundation owner | HRA-12 |
| `packages/ios-app/Sources/Support/Pairing` | `PairingURLParser.swift` | ios support owner | HRA-12 |
| `packages/ios-app/Sources/Support/Share` | `SharedContent.swift` | ios support owner | HRA-12 |
| `packages/ios-app/Sources/UI/Capabilities/Thinking` | `ThinkingDetailSheet.swift` | ios UI capabilities owner | HRA-11 |
| `packages/ios-app/Sources/UI/Onboarding/Pairing` | `QRCodeScannerSheet.swift` | ios UI onboarding owner | HRA-11 |
| `packages/ios-app/Sources/UI/Settings/ModelPicker` | `ModelPickerSheet.swift` | ios UI settings owner | HRA-11 |
| `packages/ios-app/Tests/Core` | `AppConstantsTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Core/Concurrency` | `AsyncSemaphoreTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Navigation` | `DeepLinkRouterTests.swift` | ios test owner | HRA-13 |
| `packages/mac-app/Sources/Support/Feedback` | `FeedbackComposer.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Support/Observability` | `DiagnosticsRedactor.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Mocks` | `MockLaunchAgentManager.swift` | mac wrapper owner | HRA-14 |

## Generic Bucket Directories

| Directory | Owner | Phase |
| --- | --- | --- |
| `packages/ios-app/Tests/Core` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Services` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Utilities` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Views` | ios test owner | HRA-13 |
| `packages/mac-app/Tests/Services` | mac wrapper owner | HRA-14 |

## Same-Name File/Folder Pairs

| File | Folder | Target phase |
| ---- | ------ | ------------ |
| `packages/agent/src/shared/protocol/events/tests.rs` | `packages/agent/src/shared/protocol/events/tests` | HRA-15 |
| `packages/agent/src/shared/protocol/events/tron.rs` | `packages/agent/src/shared/protocol/events/tron` | HRA-15 |

## Over-Budget Files

| Path | LOC | Limit | Owner | Phase |
| --- | --- | --- | --- | --- |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2140 | 700 | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | 1799 | 700 | ios test owner | HRA-13 |
| `packages/mac-app/Tests/Wizard/WizardStepTests.swift` | 717 | 700 | mac wrapper owner | HRA-14 |

## Docs And Scripts With Old Path Claims

Old-path claims are intentionally still visible in historical HRA/PCC evidence artifacts. HRA-15 owns remaining user-facing README/docs/scripts closeout after the code hierarchy is fully moved.

## Open Loops

- HRA-13 still owns iOS test hierarchy moves plus SourceGuard red closure.
- HRA-14 still owns the Mac wrapper audit.
- HRA-15 still owns stale path claims in docs/scripts/README outside evidence history.
