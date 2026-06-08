# Hierarchical Rearchitecture Inventory

Status: `completed`

Generated from the live checkout after HRA-16, then refreshed during AHA-6 to keep the current ownership TSVs aligned with the post-HRA Rust module cleanup. HRA-0/HRA-1 recorded the baseline; HRA-2 through HRA-7 updated the Rust source, engine, domain, session/event-store, test, and progressive-doc hierarchy without compatibility shim modules. HRA-8 added the iOS SourceGuard red gates and source/test move map, HRA-9 consumed the Engine rows, HRA-10 consumed the Session rows, HRA-11 consumed the UI rows, HRA-12 consumed the App/Support rows, HRA-13 consumed the iOS test rows by moving Swift tests into feature-owned mirrors, HRA-14 consumed the Mac wrapper rows, HRA-15 closed live docs/scripts/workflow old-path claims, and HRA-16 closed adversarial findings for old database paths, generic iOS projection buckets, WebSocket test mirroring, same-name Rust event modules, and stale live docs.

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

## HRA-1 Baseline Counts Updated After HRA-16

| Metric | Count |
| --- | --- |
| Tracked files after AHA-6 staged additions | 1384 |
| Files under `packages/agent/src` | 524 |
| Files under `packages/agent/tests` | 33 |
| Files under `packages/ios-app/Sources` | 414 |
| Files under `packages/ios-app/Tests` | 205 |
| Files under `packages/mac-app/Sources` | 74 |
| Files under `packages/mac-app/Tests` | 36 |

## Extension Counts

| Extension | Count |
| --- | --- |
| .swift | 654 |
| .rs | 556 |
| .md | 24 |
| .ttf | 20 |
| .png | 20 |
| .json | 20 |
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
| .xcscheme | 3 |
| .gitignore | 3 |
| .lock | 2 |
| .xcworkspacedata | 1 |
| .xcprivacy | 1 |
| .sql | 1 |
| .py | 1 |
| .pbxproj | 1 |
| .mjs | 1 |
| .env | 1 |

## Package Counts

| Package | Count |
| --- | --- |
| ios-app | 643 |
| agent | 585 |
| mac-app | 119 |
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
| iOS tests | Old technical buckets moved to `Infrastructure`, `Engine`, `Session`, `UI`, and `Support` mirrors; oversized guard/reconstruction tests are decomposed. | HRA-13 |
| Mac wrapper | App, Server, MenuBar, Wizard, Support, and tests now use target owner subfolders; old Services, Mocks, Observability, and loose root files are gone. | HRA-14 |
| Live docs/scripts/workflows | README, iOS docs, Mac docs, scripts, and workflows are guarded against known old path claims outside historical evidence and static absence tests. | HRA-15 |
| Final closeout blockers | Retired DB filename handling was removed from live startup/scripts/Mac paths, `events/tests.rs` and `events/tron.rs` became folder `mod.rs` modules, iOS stored-event projection moved from `Handlers` to `ChatMessageProjection`, and WebSocket reconnect tests now mirror the WebSocket source owner. | HRA-16 |

## Completed Rust Root Findings

The current Rust source root has only `packages/agent/src/lib.rs` and `packages/agent/src/main.rs`. Domain startup helpers live under `packages/agent/src/domains/registration`; non-session domains and the session event-store no longer have avoidable same-name file/folder module pairs. HRA-7 mirrors engine tests under `engine/tests/{authority,catalog,durability,invocation,kernel,runtime}` and splits root static integration targets into folder-backed modules while preserving their integration target names.

HRA-8 added a 547-row iOS source/test Swift move map. HRA-9 updated that map to 550 live Swift rows after the `EngineConnection` split and marked the Engine rows `passed_after_fix`. HRA-10 updated the map to 551 live Swift rows after the Session display-model split and marked the Session rows `passed_after_fix`. HRA-11 updated the map to 553 live Swift rows after the UI support splits, HRA-12 kept the same 553-row coverage while marking the App/Support rows `passed_after_fix`, and HRA-13 updated the map to 566 live Swift rows after the SourceGuard and reconstruction test splits. HRA-16 keeps 566 live Swift rows while replacing the generic reconstruction `Handlers` bucket with `ChatMessageProjection` and moving `EngineConnectionReconnectTests` into the WebSocket test mirror. All iOS source/test map rows are now `passed_after_fix`; the map has no fallback rows, points no live file at old broad-bucket targets, and is guarded by `ios_hra8_move_map_covers_every_source_and_test_swift_file`. HRA-14 updates the global HRA TSV inventory to include 74 Mac source files and 36 Mac test files under the target owner roots.

## Directories Over 12 Source Files

| Directory | Source files | Owner | Phase |
| --- | --- | --- | --- |
| `packages/ios-app/Sources/Engine/Transport/Clients` | 13 | ios engine owner | HRA-9 |
| `packages/ios-app/Sources/Session/Timeline/Messages` | 13 | ios session timeline owner | HRA-10 |
| `packages/ios-app/Sources/UI/Capabilities/Shared` | 19 | ios UI capabilities owner | HRA-11 |
| `packages/ios-app/Sources/UI/Settings/Shell` | 13 | ios UI settings owner | HRA-11 |
| `packages/ios-app/Tests/Engine/Transport/Clients` | 19 | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Session/Chat` | 28 | ios test owner | HRA-13 |

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
| `packages/ios-app/Tests/Engine/Models` | `ModelFilteringServiceTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Engine/Transport/DeepLinks` | `DeepLinkRouterTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Engine/Transport/WebSocket` | `EngineConnectionReconnectTests.swift` | ios test owner | HRA-16 |
| `packages/ios-app/Tests/Session/Parsing` | `CapabilityArgumentParserTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Session/Timeline/Messages` | `CapabilityInvocationDisplayModelTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Support/Feedback` | `FeedbackComposerTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Support/Foundation` | `AppConstantsTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Support/Foundation/Concurrency` | `AsyncSemaphoreTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/Support/Foundation/Validation` | `FolderCreationTests.swift` | ios test owner | HRA-13 |
| `packages/ios-app/Tests/UI/RuntimeSurfaces` | `GeneratedUIRendererTests.swift` | ios test owner | HRA-13 |
| `packages/mac-app/Sources/App/Composition` | `EnvironmentSetup.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/MenuBar/Controller` | `MenuBarController.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Server/LaunchAgent` | `LaunchAgentManaging.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Server/PairingToken` | `BearerTokenReader.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Support/Diagnostics` | `DiagnosticsRedactor.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Support/Feedback` | `FeedbackComposer.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Sources/Support/Foundation` | `VersionDisplay.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/App/CommandMode` | `MacCommandModeServerStarterTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Server/PairingToken` | `BearerTokenReaderTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Support/Diagnostics` | `DiagnosticsRedactorTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Support/Feedback` | `FeedbackComposerTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Support/Foundation` | `VersionDisplayTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Wizard/Components` | `WizardVisualLayoutTests.swift` | mac wrapper owner | HRA-14 |
| `packages/mac-app/Tests/Wizard/Steps` | `InstallPipelineStageOrderingTests.swift` | mac wrapper owner | HRA-14 |

## Generic Bucket Directories

| Directory | Owner | Phase |
| --- | --- | --- |
| _none_ | architecture campaign | HRA-16 |

## Same-Name File/Folder Pairs

| File | Folder | Target phase |
| ---- | ------ | ------------ |
| _none_ | _none_ | HRA-16 |

## Over-Budget Files

| Path | LOC | Limit | Owner | Phase |
| --- | --- | --- | --- | --- |
| _none_ | n/a | n/a | architecture campaign | HRA-16 |

## Docs And Scripts With Old Path Claims

Old-path claims are intentionally still visible in historical HRA/PCC evidence artifacts and negative static absence tests. HRA-15 added `live_docs_scripts_and_workflows_do_not_claim_old_paths` to guard live README/docs/scripts/workflows and fixed the stale live references it exposed.

## Open Loops

- No HRA implementation rows remain open. Historical evidence and static absence
  tests retain old path strings only as regression needles, not live runtime or
  documentation paths.
