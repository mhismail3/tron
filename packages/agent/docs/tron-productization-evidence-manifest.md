# Tron Productization Evidence Manifest

Created: **2026-06-03**
Scorecard: [`tron-productization-scorecard.md`](tron-productization-scorecard.md)
Current score: **77/100**

This manifest records the evidence used to award productization scorecard
points. It is append-only within each coherent checkpoint: update the relevant
row, note command return codes, and keep open loops explicit.

## Boundaries

- No push, merge, release, deploy, notarization, or production rollout is
  allowed in this campaign.
- No remote package discovery, remote marketplace install, or remote package
  trust implementation is allowed.
- Clients must remain thin: no generated action target construction, approval
  truth, policy, source trust, model routing, or capability binding in iOS, Mac,
  or CLI.
- Product evidence must cite server-owned resources, invocations, catalog
  revisions, generated surfaces, source/trust decisions, screenshots, or logs as
  appropriate.

## Evidence Index

| Row | Status | Evidence |
|---|---|---|
| TPROD-A | passed_after_fix | This manifest and the master scorecard were created in `packages/agent/docs/`. README was updated to list both documents. `productization_scorecard_stays_formalized` was added to `packages/agent/tests/threat_model_invariants.rs`. Baseline audit commands and source references are listed below. |
| TPROD-B | passed_after_fix | Added the managed `self-extend` skill, synced it locally, and verified live worker protocol plus sample local worker flow with focused integration tests. Details below. |
| TPROD-C | passed_after_fix | Live chat-led self-extension proof completed after repairing approval replay, workspace context propagation, sandbox child selector defaults, dashboard helper labels, and cleanup guidance. Details below. |
| TPROD-D | passed_after_fix | Created by Agent shelf/history is product-labeled, server-derived, and covered by focused projection/source/accessibility tests. Details below. |
| TPROD-E | passed_after_fix | Local pack lifecycle product flow is server-owned, product-labeled, and covered by focused engine/iOS tests. Details below. |
| TPROD-F | passed_after_fix | Server-owned plain trust presentation is evidence-backed and rendered by iOS without client-owned trust mapping. Details below. |
| TPROD-G | passed_after_fix | Generated UI authoring product matrix is server-authored through fixed catalog components and covered by Rust/iOS source-guard evidence. Details below. |
| TPROD-H | passed_after_fix | Model presets, automation routing truth, subagent task/model routing, generated lineage UI, and iOS chip data are server-owned and covered by focused Rust/iOS evidence. Details below. |
| TPROD-I | passed_after_fix | Flagship Tron-maintains-Tron chat loop creates, repairs, tests, reviews, and cleans up a workspace helper with generated UI plus model/subagent evidence. Details below. |
| TPROD-J | pending | Three polished local example packs not yet shipped. |
| TPROD-K | pending | Product user/operator/release-note docs not yet complete. |
| TPROD-L | pending | Full hardening, visual QA, soak, and closeout gates not yet run. |

## TPROD-A Evidence

### Inputs

- User supplied `/Users/moose/Downloads/PLAN.md` as the productization plan.
- The goal names
  `packages/agent/docs/tron-productization-scorecard.md`; that path was absent
  before this checkpoint.

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `git status --short --branch` | 0 | Confirmed branch `next/modular-capability-engine` was ahead of origin by one commit and had no unstaged changes at baseline. |
| `sed -n '1,260p' /Users/moose/Downloads/PLAN.md` | 0 | Read the provided plan source. |
| `wc -l /Users/moose/Downloads/PLAN.md` | 0 | Confirmed the plan has 125 lines. |
| `rg --files packages/agent/docs \| sort` | 0 | Confirmed no in-repo productization scorecard existed yet. |
| `sed -n '1,220p' packages/agent/src/lib.rs` | 0 | Audited top-level Rust module docs. |
| `sed -n '1,260p' packages/ios-app/docs/architecture.md` | 0 | Audited iOS thin-client and generated UI baseline docs. |
| `sed -n '1,240p' packages/mac-app/docs/architecture.md` | 0 | Audited Mac wrapper and managed-skill baseline docs. |
| `find packages/agent/skills -maxdepth 2 -type f \| sort` | 0 | Confirmed managed skills exist and `self-extend` is not present. |
| `rg -n "worker::protocol_guide\|ui_surface\|module::register_package\|subagent" README.md packages/agent/src packages/ios-app/Sources packages/mac-app/Sources scripts` | 0 | Located current substrate/product baseline references. |

### Source Evidence

- [`README.md`](../../../README.md): living architecture docs, generated UI,
  local module packages, source trust, worker protocol guide, sandbox-created
  capabilities, and subagent resource lineage.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md):
  thin iOS client boundary, capability-native rendering, Engine Console
  projections, generated UI renderer, and disconnected fail-closed behavior.
- [`packages/mac-app/docs/architecture.md`](../../mac-app/docs/architecture.md):
  Mac wrapper boundary, managed skill sync, menu-bar server observation, and
  CLI dispatcher boundary.
- [`packages/agent/src/engine/primitives/worker.rs`](../src/engine/primitives/worker.rs):
  `worker::protocol_guide` primitive registration.
- [`packages/agent/src/engine/primitives/runtime/worker_protocol.rs`](../src/engine/primitives/runtime/worker_protocol.rs):
  worker protocol guide content owner.
- [`packages/agent/src/engine/primitives/ui.rs`](../src/engine/primitives/ui.rs):
  generated UI primitive lifecycle.
- [`packages/agent/src/engine/resources/ui_surface.rs`](../src/engine/resources/ui_surface.rs):
  fixed generated-UI resource validation.
- [`packages/agent/src/engine/primitives/module.rs`](../src/engine/primitives/module.rs):
  module package registration and activation function surface.

### Baseline Findings

- The low-level substrate for self-extension is present: generated workers,
  local worker spawning, catalog watch/inspect, generated UI resources, package
  registration, source trust, conformance evidence, activation lifecycle,
  promotion, cleanup, and subagent result resources.
- The product campaign is not complete. The repo lacked the master
  productization scorecard, evidence manifest, `self-extend` managed skill,
  chat-led self-extension product flow, created-by-agent shelf, plain trust
  labels, product model presets, example packs, visual QA, and soak evidence.
- TPROD-A is the only row currently awarded points.

### Open Loops

- Start TPROD-B by adding the covering test that requires the managed
  `self-extend` skill and prevents copied worker protocol details from drifting.
- After each row, update this manifest with exact commands, return codes,
  source references, screenshots or runtime ids where relevant, and the next
  open loop.

## TPROD-B Evidence

### Files

- [`packages/agent/skills/self-extend/.managed`](../skills/self-extend/.managed)
- [`packages/agent/skills/self-extend/SKILL.md`](../skills/self-extend/SKILL.md)
- [`packages/agent/tests/managed_skill_sources.rs`](../tests/managed_skill_sources.rs)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test managed_skill_sources self_extend_skill_is_managed_and_uses_live_worker_protocol_guide -- --nocapture` | 101 then 0 | Red/green proof: first failed because `self-extend` was absent; after implementation passed and proved `.managed`, parseable frontmatter, `capability::execute`, required flow markers, and absence of copied worker protocol internals. |
| `rsync -a --delete --exclude=node_modules --exclude=.DS_Store packages/agent/skills/self-extend/ ~/.tron/skills/self-extend/` | 0 | Synced the managed repo skill into the local Tron skill directory. |
| `diff -qr packages/agent/skills/self-extend ~/.tron/skills/self-extend` | 0 | Verified installed local copy matches the repo-managed source. |
| `ls -la ~/.tron/skills/self-extend` | 0 | Verified installed `.managed` sentinel and `SKILL.md` are present. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration capability_self_modifying_lifecycle_execute_returns_worker_protocol_guide -- --nocapture` | 0 | Proved live `/engine` `capability::execute` path returns current `worker::protocol_guide` output. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration capability_self_modifying_lifecycle_inspects_session_worker_catalog -- --nocapture` | 0 | Proved sample local worker flow: guide, spawn, catalog watch, inspect, and cleanup through existing live integration harness. |

### Findings

- The skill is intentionally concise and does not embed worker protocol fields,
  socket paths, environment variable names, message shapes, or templates.
- The skill directs every run to fetch live `worker::protocol_guide`, then
  spawn with `worker::spawn`, watch `catalog::watch_snapshot`, inspect with
  `capability::inspect`, author generated UI through `ui::surface_for_target`,
  promote only through `engine::promote`, and clean up with
  `worker::disconnect` or `sandbox::stop_spawned_worker`.
- Existing live integration coverage is the sample local worker proof for this
  row; no new runtime harness was added.

### Open Loops

- Closed by TPROD-C: chat-led workspace autonomy approval, capability
  progression, repair, invocation, and cleanup proof now exists. TPROD-D owns
  durable history/gallery presentation of those created-by-agent events.

## TPROD-C Evidence

### Files

- [`packages/agent/src/domains/sandbox/contract.rs`](../src/domains/sandbox/contract.rs)
- [`packages/agent/src/domains/sandbox/mod.rs`](../src/domains/sandbox/mod.rs)
- [`packages/agent/src/domains/self_extension/contract.rs`](../src/domains/self_extension/contract.rs)
- [`packages/agent/src/domains/self_extension/mod.rs`](../src/domains/self_extension/mod.rs)
- [`packages/agent/src/domains/worktree/contract.rs`](../src/domains/worktree/contract.rs)
- [`packages/agent/src/domains/worktree/mod.rs`](../src/domains/worktree/mod.rs)
- [`packages/agent/skills/self-extend/SKILL.md`](../skills/self-extend/SKILL.md)
- [`packages/agent/src/domains/capability/contract.rs`](../src/domains/capability/contract.rs)
- [`packages/agent/src/domains/capability/registry/primer.rs`](../src/domains/capability/registry/primer.rs)
- [`packages/agent/src/domains/capability/registry/tests/primer.rs`](../src/domains/capability/registry/tests/primer.rs)
- [`packages/agent/src/domains/capability/operations/execute.rs`](../src/domains/capability/operations/execute.rs)
- [`packages/agent/src/domains/capability/operations/mod.rs`](../src/domains/capability/operations/mod.rs)
- [`packages/agent/src/domains/capability/operations/run.rs`](../src/domains/capability/operations/run.rs)
- [`packages/agent/src/domains/capability/operations/tests/policy.rs`](../src/domains/capability/operations/tests/policy.rs)
- [`packages/agent/src/engine/host/invocation_handle.rs`](../src/engine/host/invocation_handle.rs)
- [`packages/agent/src/engine/primitives/runtime/worker_protocol.rs`](../src/engine/primitives/runtime/worker_protocol.rs)
- [`packages/agent/src/engine/primitives/runtime/worker_protocol_template.py`](../src/engine/primitives/runtime/worker_protocol_template.py)
- [`packages/agent/src/engine/tests/approval.rs`](../src/engine/tests/approval.rs)
- [`packages/agent/src/engine/tests/meta_primitives.rs`](../src/engine/tests/meta_primitives.rs)
- [`packages/agent/tests/integration/tests.rs`](../tests/integration/tests.rs)
- [`packages/ios-app/Sources/Models/Dashboard/CapabilityActivityPresentation.swift`](../../ios-app/Sources/Models/Dashboard/CapabilityActivityPresentation.swift)
- [`packages/ios-app/Sources/Models/Dashboard/ServerActivityLine.swift`](../../ios-app/Sources/Models/Dashboard/ServerActivityLine.swift)
- [`packages/ios-app/Sources/Models/Messages/CapabilityInvocationDisplayModel.swift`](../../ios-app/Sources/Models/Messages/CapabilityInvocationDisplayModel.swift)
- [`packages/ios-app/Sources/Models/Messages/CapabilityPresentation.swift`](../../ios-app/Sources/Models/Messages/CapabilityPresentation.swift)
- [`packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationDetailComponents.swift`](../../ios-app/Sources/Views/Capabilities/CapabilityInvocationDetailComponents.swift)
- [`packages/ios-app/Sources/Core/Events/Plugins/Approval/ApprovalPlugins.swift`](../../ios-app/Sources/Core/Events/Plugins/Approval/ApprovalPlugins.swift)
- [`packages/ios-app/Tests/Models/CapabilityInvocationDisplayModelTests.swift`](../../ios-app/Tests/Models/CapabilityInvocationDisplayModelTests.swift)
- [`packages/ios-app/Tests/Core/Events/Plugins/EventPluginTests.swift`](../../ios-app/Tests/Core/Events/Plugins/EventPluginTests.swift)
- [`packages/ios-app/Tests/ViewModels/DashboardCapabilityStreamTests.swift`](../../ios-app/Tests/ViewModels/DashboardCapabilityStreamTests.swift)
- [`packages/ios-app/docs/capability-ui.md`](../../ios-app/docs/capability-ui.md)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`README.md`](../../../README.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cd packages/ios-app && xcodegen generate && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests/testSelfExtensionPresentationHintsKeepChatProjectionPlain -only-testing:TronMobileTests/EventPluginTests/testApprovalPendingPluginUsesPlainWorkspaceAutonomyTextForWorkerSpawn` | 65 | Red proof: test compile failed because `CapabilityInvocationDisplayModel.summaryText` did not exist yet. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests/testSelfExtensionPresentationHintsKeepChatProjectionPlain -only-testing:TronMobileTests/EventPluginTests/testApprovalPendingPluginUsesPlainWorkspaceAutonomyTextForWorkerSpawn` | 0 | Green proof for iOS plain chip summary/status labels and workspace-local approval wording. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/EventPluginTests` | 0 | Broader affected iOS model/event plugin coverage: 39 selected tests passed. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Verified the Rust server changes compile. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after the server and static-gate edits. |
| `cargo test --manifest-path packages/agent/Cargo.toml worker_spawn_has_plain_self_extension_presentation_hints -- --nocapture` | 0 | Proved `worker::spawn` owns product-facing presentation hints at the sandbox contract layer. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration capability_self_modifying_lifecycle_spawns_session_worker -- --nocapture` | 0 | Proved the live `capability::execute -> worker::spawn` session-worker flow returns product presentation hints and a scope-aware `Safe in this chat` summary. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 101 then 0 | First failed because the static guard still expected TPROD-C as `next`; after updating the guard, passed and preserved the no-overclaim score. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 101 then 0 | First failed because `packages/agent/tests/integration/tests.rs` grew from 4708 to 4726 LOC; after updating the cleanup scorecard budget row, passed. |
| `git diff --check` | 0 | Verified whitespace/diff hygiene. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants external_workers_and_sandbox_spawn_are_first_class_engine_surfaces -- --nocapture` | 101 then 0 | Red proof failed because `self_extension` did not exist; green proof now requires approval-owned workspace autonomy beside sandbox-autonomous worker lifecycle. |
| `cargo test --manifest-path packages/agent/Cargo.toml workspace_autonomy -- --nocapture` | 101 then 0 | Red compile proof caught a stale idempotency assertion; green proof covers the self-extension contract and handler-derived workspace grant. |
| `cargo test --manifest-path packages/agent/Cargo.toml worker_spawn_child_grant_can_use_workspace_autonomy_parent -- --nocapture` | 0 | Proved `worker::spawn` can derive a helper child grant from the approved workspace autonomy grant after validating source, actor, workspace, and file root. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventPluginTests/testApprovalPendingPluginUsesPlainWorkspaceAutonomyTextForSelfExtensionGrant` | 65 then 0 | Red proof showed generic engine approval copy for `self_extension::grant_workspace_autonomy`; green proof renders product-facing workspace autonomy copy without raw function ids or approval ids. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants external_workers_and_sandbox_spawn_are_first_class_engine_surfaces -- --nocapture` | 0 | Re-ran the final focused static guard after the workspace autonomy and sandbox validation edits. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Re-ran the scorecard guard at the prior sub-checkpoint and confirmed no early point claim before the live visual/action proof. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 101 then 0 | First failed because `packages/agent/tests/threat_model_invariants.rs` grew from 7577 to 7589 LOC; after updating the cleanup scorecard budget row, passed. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventPluginTests` | 0 | Broader affected approval/event plugin coverage: 21 selected tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml approval_resolution_resumes_host_dispatched_primitives -- --nocapture` | 0 | Regression for approving a paused host-dispatched primitive such as `worker::disconnect`; fixed approval replay recursion through `EngineHostHandle`. |
| `cargo test --manifest-path packages/agent/Cargo.toml primitive_catalog_worker_and_observability_functions_share_engine_path -- --nocapture` | 0 | Proved the worker protocol template waits for `catalog_snapshot` before registration guidance. |
| `cargo test --manifest-path packages/agent/Cargo.toml capability_execute_ -- --nocapture` | 0 | Proved execute wrapper workspace/session context binds actor and child invocation context when transport context is absent, with transport context still winning. |
| `cargo test --manifest-path packages/agent/Cargo.toml workspace_autonomy_spawn_defaults_child_resource_selector_to_workspace -- --nocapture` | 101 then 0 | Red/green proof for the live spawn failure: omission of `resourceSelectors` under a validated workspace autonomy grant now defaults the child selector to `workspace:<workspaceId>`. |
| `cargo test --manifest-path packages/agent/Cargo.toml capability_primer_context_stays_within_budget -- --nocapture` | 0 | Verified the expanded self-extension, selector-default, and cleanup guidance stays within the model primer budget. |
| `cargo test --manifest-path packages/agent/Cargo.toml execute_description_teaches_self_modifying_worker_lifecycle -- --nocapture` | 0 | Verified the provider-visible execute schema teaches workspace ids, selector defaults, sandbox cleanup, and relative worktree discard. |
| `cargo build --manifest-path packages/agent/Cargo.toml --profile dev-server` | 0 | Built the live proof server binary after the engine fixes. |
| `cd packages/ios-app && xcodebuild build -scheme Tron -configuration Beta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-ios-beta-derived-tprod-c-v9-beta` | 0 | Built the beta iOS app used for the live visual proof. |
| `xcrun simctl launch 7BDA4AF9-1C40-47E3-A925-0F88C191F263 com.tron.mobile.beta` | 0 | Launched the beta iOS app on the iPhone 17 Pro simulator for visual proof. |
| `xcrun simctl io 7BDA4AF9-1C40-47E3-A925-0F88C191F263 screenshot /tmp/tron-tprod-c-v10-approval.png` | 0 | Captured the workspace autonomy approval/session-list visual state. |
| `python3` raw WebSocket `/engine` `approval::resolve` for approval `019e8d4d-9c7a-7ed3-878a-20896f4a9433` | 0 | Approved the first helper-file discard request; replay failed safely because the payload used an absolute path. |
| `python3` raw WebSocket `/engine` `approval::resolve` for approval `019e8d51-162b-7370-9255-679e8494b8a7` | 0 | Approved the corrected repo-relative helper-file discard; replay returned `{"success":true}`. |
| `sqlite3 -json /tmp/tron-tprod-c-live-20260603-022322/internal/database/tron.sqlite ... engine_invocations ...` | 0 | Verified live invocation rows: first spawn failed on selector bounds, repaired spawn succeeded, `tprod_c::echo` returned `{"proof":"tprod-c"}`, sandbox stop succeeded, absolute discard failed safely, relative discard succeeded. |
| `xcrun simctl io 7BDA4AF9-1C40-47E3-A925-0F88C191F263 screenshot /tmp/tron-tprod-c-v10-relative-discard-approval.png` | 0 | Captured the corrected cleanup approval visual state. |
| `xcrun simctl io 7BDA4AF9-1C40-47E3-A925-0F88C191F263 screenshot /tmp/tron-tprod-c-v10-dashboard-helper-labels-app.png` | 0 | Captured the refreshed dashboard card with final TPROD-C proof summary and product-facing labels. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/DashboardCapabilityStreamTests/testSandboxHelperDashboardLinesDoNotExposeSpawnedWorkerVocabulary` | 0 | Proved dashboard helper lifecycle labels no longer expose raw spawned-worker vocabulary. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Final TPROD-C scorecard guard: confirmed 22/100, TPROD-C passed, TPROD-D active, and no premature 100/100 claim. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 101 then 0 | Closeout gate first found exact large-file audit drift for touched files; after updating `codebase-cleanup-scorecard.md` for `threat_model_invariants.rs`, `capability/operations/mod.rs`, `sandbox/mod.rs`, and `meta_primitives.rs`, the guard passed. |
| `xcodegen generate` from `packages/ios-app` | 0 | Regenerated `TronMobile.xcodeproj` after adding the dashboard activity presentation model. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventPluginTests` | 0 | Final approval/event plugin coverage: 23 selected tests passed. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests` | 0 | Final chat/detail capability display coverage: 20 selected tests passed. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/DashboardCapabilityStreamTests` | 0 | Final dashboard capability activity coverage: 6 selected tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the cleanup scorecard stayed in its formalized 100/100 maintenance state after the large-file audit update. |
| `git diff --check` | 0 | Final whitespace/diff hygiene check before checkpoint commit. |
| `lsof -nP -iTCP:19847 -sTCP:LISTEN -t` then `kill 67276` then repeat `lsof` | 0, 0, 1 | Stopped the temporary live proof server and confirmed port 19847 no longer had a listener. |

### Findings

- `worker::spawn` now carries server-owned product hints for helper capability
  creation: display name, chip title, summary text, lifecycle status
  labels, icon, and theme color. The main hints intentionally do not include
  `worker::spawn`.
- `capability::execute` overlays the presentation summary from the actual child
  payload visibility: session workers render `Safe in this chat`; workspace
  workers render `Safe in this workspace`; system visibility renders promotion
  language.
- iOS now maps `summary`/`subtitle` into chip and detail-header text and maps
  lifecycle label hints into status rows and accessibility text.
- `self_extension::grant_workspace_autonomy` now owns the user approval for
  workspace-local self-extension, derives a bounded grant through
  `grant::derive`, and returns product-facing status text while keeping raw
  authority details under Inspect.
- `worker::spawn` remains sandbox-autonomous. When passed
  `workspaceAutonomyGrantId`, it validates that grant's source, actor,
  workspace selector, and file root before using it as the parent for the
  helper worker child grant.
- `approval.pending` for `self_extension::grant_workspace_autonomy` now renders
  workspace-local autonomy approval in plain language instead of generic
  engine-function copy. The dead `worker::spawn` approval special case was
  removed.
- Live proof session `sess_019e8d4a-8f85-77d0-bd3c-92c0f78f2fef` ended with
  assistant text "Clean TPROD-C proof completed." Event rows show
  `worker::spawn` initially failed on child resource selectors, repaired with
  workspace bounds, `tprod_c::echo` invoked successfully, the sandbox worker
  stopped, the absolute-path discard failed closed, the repo-relative discard
  succeeded, and final `capability::inspect` confirmed the helper was no
  longer visible.
- Screenshots used for visual proof:
  `/tmp/tron-tprod-c-v10-approval.png`,
  `/tmp/tron-tprod-c-v10-relative-discard-approval.png`, and
  `/tmp/tron-tprod-c-v10-dashboard-helper-labels-app.png`.
- Simulator transcript opening through CoreGraphics clicks was attempted and
  did not activate the card in this environment; TPROD-C scoring is therefore
  based on approval/dashboard screenshots, server event/invocation truth, and
  focused chat/detail display model tests rather than an opened transcript
  screenshot.

### Open Loops

- Closed by TPROD-D. The underlying session-created helper lifecycle now has a
  durable Created by Agent shelf/history surface with product labels, lineage
  chips, and server-owned evidence.

## TPROD-D Evidence

### Files

- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleCreatedByAgentProjection.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleCreatedByAgentProjection.swift)
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleCreatedByAgentView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleCreatedByAgentView.swift)
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleState.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleState.swift)
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift)
- [`packages/ios-app/Tests/ViewModels/EngineConsoleCreatedByAgentProjectionTests.swift`](../../ios-app/Tests/ViewModels/EngineConsoleCreatedByAgentProjectionTests.swift)
- [`packages/ios-app/Tests/Infrastructure/EngineConsoleCreatedByAgentSourceGuardTests.swift`](../../ios-app/Tests/Infrastructure/EngineConsoleCreatedByAgentSourceGuardTests.swift)
- [`packages/ios-app/Tests/Views/EngineConsoleAccessibilityTests.swift`](../../ios-app/Tests/Views/EngineConsoleAccessibilityTests.swift)
- [`packages/ios-app/Tests/ViewModels/EngineConsoleStateTests.swift`](../../ios-app/Tests/ViewModels/EngineConsoleStateTests.swift)
- [`packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift`](../../ios-app/Tests/Infrastructure/SourceGuardTests.swift)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`packages/ios-app/docs/capability-ui.md`](../../ios-app/docs/capability-ui.md)
- [`README.md`](../../../README.md)
- [`packages/agent/docs/codebase-cleanup-scorecard.md`](codebase-cleanup-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests/harnessChangeProjectionExplainsSessionCreatedCapabilityEvidence` | 65 | Red proof: the existing projection lacked `shelfTitle`, `shelfSubtitle`, and `historyLabels` for product shelf/history acceptance. |
| `cd packages/ios-app && xcodegen generate` | 0 | Regenerated the project after renaming the production Created by Agent projection/card and adding focused test files. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleCreatedByAgentProjectionTests` | 0 | Proved the projection derives product-facing titles/subtitles plus created, updated, auto-repaired, tested, failed, promoted, revoked, discarded, and reused history labels from registry/catalog/control/audit/program-run DTOs; 2 Swift Testing tests passed. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleCreatedByAgentSourceGuardTests -only-testing:TronMobileTests/EngineConsoleAccessibilityTests -only-testing:TronMobileTests/SourceGuardTests` | 0 | Proved the shelf remains server-derived, product-labeled, accessible, free of old production `HarnessChange` symbols, and within existing iOS source boundaries; 20 Swift Testing tests passed. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests` | 0 | Re-ran the broader console state suite after extracting the created-by-agent cases; 12 Swift Testing tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the master productization scorecard and evidence manifest now record 31/100, TPROD-D passed, TPROD-E active, and no premature 100/100 claim. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the cleanup scorecard remains in its formalized 100/100 maintenance state after the TPROD-D large-file row update. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 0 | Confirmed exact large-file audit rows after splitting created-by-agent tests out of `EngineConsoleStateTests.swift`. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after the static-gate update. |
| `git diff --check` | 0 | Verified whitespace/diff hygiene for the TPROD-D checkpoint. |

### Findings

- The former user-facing Harness Changes surface is now a Created by Agent shelf
  in production source, state, view, docs, accessibility tests, and source
  guards. A dedicated source guard prevents `EngineConsoleHarnessChange` and
  `Harness Changes` from returning in the production shelf path.
- `EngineConsoleCreatedByAgentProjection` still uses server-owned registry
  implementations, live catalog functions, control snapshot generated-UI refs,
  audit events, and program runs. iOS only projects these DTOs into shelf
  labels; it does not own trust, policy, generated action targets, or binding.
- Shelf titles and subtitles are product-facing. Raw function ids, trace ids,
  child invocation ids, resource refs, and worker ids stay in evidence fields
  or Inspect-oriented details.
- Focused tests moved created-by-agent lifecycle coverage out of the broad
  `EngineConsoleStateTests.swift` matrix. The cleanup large-file audit now
  records that file at 1,019 LOC with a tighter 1,100-line budget.

### Open Loops

- Closed for TPROD-D. TPROD-E must prove the local disk pack lifecycle through
  chat entry plus Console/detail surfaces while preserving the explicit remote
  discovery deferral.

## TPROD-E Evidence

### Files

- [`packages/agent/src/engine/primitives/module.rs`](../src/engine/primitives/module.rs)
- [`packages/agent/src/engine/primitives/module/package_lifecycle.rs`](../src/engine/primitives/module/package_lifecycle.rs)
- [`packages/agent/src/engine/primitives/module/activation_lifecycle.rs`](../src/engine/primitives/module/activation_lifecycle.rs)
- [`packages/agent/src/engine/primitives/module/actions.rs`](../src/engine/primitives/module/actions.rs)
- [`packages/agent/src/engine/primitives/module/registrations.rs`](../src/engine/primitives/module/registrations.rs)
- [`packages/agent/src/engine/primitives/module/resources.rs`](../src/engine/primitives/module/resources.rs)
- [`packages/agent/src/engine/primitives/module/schemas.rs`](../src/engine/primitives/module/schemas.rs)
- [`packages/agent/src/engine/primitives/action_summary.rs`](../src/engine/primitives/action_summary.rs)
- [`packages/agent/src/engine/primitives/control/actions.rs`](../src/engine/primitives/control/actions.rs)
- [`packages/agent/src/engine/primitives/ui/authoring/actions.rs`](../src/engine/primitives/ui/authoring/actions.rs)
- [`packages/agent/src/engine/primitives/ui/authoring/mod.rs`](../src/engine/primitives/ui/authoring/mod.rs)
- [`packages/agent/src/domains/capability/contract.rs`](../src/domains/capability/contract.rs)
- [`packages/agent/src/domains/capability/registry/primer.rs`](../src/domains/capability/registry/primer.rs)
- [`packages/agent/skills/self-extend/SKILL.md`](../skills/self-extend/SKILL.md)
- [`packages/agent/tests/managed_skill_sources.rs`](../tests/managed_skill_sources.rs)
- [`packages/agent/src/engine/tests/module_activation/lifecycle_controls.rs`](../src/engine/tests/module_activation/lifecycle_controls.rs)
- [`packages/agent/src/engine/tests/module_activation/operator_surfaces.rs`](../src/engine/tests/module_activation/operator_surfaces.rs)
- [`packages/agent/src/engine/tests/module_activation/package_registration.rs`](../src/engine/tests/module_activation/package_registration.rs)
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift)
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleModuleProjectionView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleModuleProjectionView.swift)
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleState.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleState.swift)
- [`packages/ios-app/Tests/ViewModels/EngineConsolePackProjectionTests.swift`](../../ios-app/Tests/ViewModels/EngineConsolePackProjectionTests.swift)
- [`packages/ios-app/Tests/ViewModels/EngineConsoleStateTests.swift`](../../ios-app/Tests/ViewModels/EngineConsoleStateTests.swift)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`README.md`](../../../README.md)
- [`packages/agent/docs/codebase-cleanup-scorecard.md`](codebase-cleanup-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml module_remove_package_requires_disabled_activations_and_discards_configs -- --nocapture` | 101 then 0 | Red/green proof: the new lifecycle test first failed before `module::remove_package`; after implementation it proved active activations block removal, disabled activations allow removal, package/config resources are discarded with removal evidence, and removed packs are read-only for configure/activate. |
| `cd packages/ios-app && xcodegen generate` | 0 | Regenerated the project after adding `EngineConsolePackProjectionTests.swift`. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsolePackProjectionTests` | 65 then 0 | Red/green proof: the new focused Swift test first failed because the module projection lacked pack title/subtitle/lifecycle/action labels; after implementation it passed and proved pack product labels, server-owned action labels, generated package surface request purpose, and no worker action leakage. |
| `cargo test --manifest-path packages/agent/Cargo.toml generated_ui_can_author_package_and_activation_operator_surfaces -- --nocapture` | 0 | Proved generated package surfaces use `Pack` vocabulary and expose stored `remove-package` action alongside inspect/configure/activate/source/conformance/trust actions; activation surfaces still expose disable/upgrade/rollback/quarantine. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_resource_types_and_capabilities_are_registered -- --nocapture` | 0 | Proved `module::remove_package` is discoverable, idempotent, resource-backed, and part of the canonical module primitive catalogue. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test managed_skill_sources self_extend_skill_is_managed_and_uses_live_worker_protocol_guide -- --nocapture` | 0 | Proved the managed `self-extend` chat entry names register, inspect, configure, activate, disable, rollback, revoke-source-approval, and remove while still requiring live `worker::protocol_guide` and forbidding copied protocol details. |
| `diff -qr packages/agent/skills/self-extend ~/.tron/skills/self-extend` | 0 | Verified the local installed managed skill matches the repo source after the local-pack lifecycle update. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after the lifecycle/action-summary/static-gate edits. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Verified the Rust server compiles after the pack lifecycle changes. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Verified the productization scorecard/evidence manifest state is formalized at 40/100 with TPROD-F next. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Verified the cleanup scorecard still remains formalized after updating the large-file audit row. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 0 | Verified exact large-file audit rows after `threat_model_invariants.rs` grew to 7,595 LOC and generated-UI action authoring remained within budget. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsolePackProjectionTests -only-testing:TronMobileTests/EngineConsoleStateTests -only-testing:TronMobileTests/SourceGuardTests` | 0 | Verified the new pack projection, touched Engine Console state expectations, and iOS source guards in one selected suite: 29 Swift Testing tests passed. |
| `git diff --check` | 0 | Verified no whitespace errors before staging the checkpoint. |

### Findings

- `module::remove_package` is a high-risk canonical module write. It requires a
  current `worker_package`, honors `expectedCurrentVersionId`, fails closed
  while any matching activation remains live, then marks the package and
  matching configs `discarded` with removal timestamp/reason evidence. It does
  not hard-delete resource history.
- Removed packs cannot be configured or activated until explicitly
  re-registered. This keeps disconnected/offline and removed states
  inspectable but read-only for mutation paths.
- Server action summaries now provide product labels for module actions. iOS
  renders those labels and presentation icons but continues to submit only
  server-authored generated-surface coordinates.
- Generated package surfaces are server-authored `Pack ...` surfaces and expose
  the stored `remove-package` action. The generated UI renderer/client still
  never constructs module target payloads.
- The managed `self-extend` skill and model-facing primer/schema now describe
  the local pack lifecycle through `capability::execute`, including the remote
  discovery deferral.

### Open Loops

- Closed for TPROD-E. TPROD-F is now closed by the evidence below.

## TPROD-F Evidence

### Files

- [`packages/agent/src/engine/primitives/control.rs`](../src/engine/primitives/control.rs)
- [`packages/agent/src/engine/primitives/control/trust_projection.rs`](../src/engine/primitives/control/trust_projection.rs)
- [`packages/agent/src/engine/tests/module_activation/source_trust.rs`](../src/engine/tests/module_activation/source_trust.rs)
- [`packages/agent/src/engine/tests/module_activation/lifecycle_controls.rs`](../src/engine/tests/module_activation/lifecycle_controls.rs)
- [`packages/agent/tests/threat_model_invariants.rs`](../tests/threat_model_invariants.rs)
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift)
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleModuleProjectionView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleModuleProjectionView.swift)
- [`packages/ios-app/Tests/ViewModels/EngineConsoleStateTests.swift`](../../ios-app/Tests/ViewModels/EngineConsoleStateTests.swift)
- [`README.md`](../../../README.md)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml module_source_approval_revocation_and_conformance_are_resource_backed -- --nocapture` | 101 then 0 | Red/green proof: first failed because `moduleSourceTrust` had no `trustPresentation`; after implementation it proved revoked source approval produces `Trust revoked`, `Approval revoked`, `Conformance passed`, `Revocation evidence present`, and `Cleanup not needed` labels from real decision/evidence refs. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_trust_root_signature_policy_allows_signed_activation -- --nocapture` | 0 | Proved signed local packs use `Signature verified` and `Signature trust active` labels from trust-root signature evidence, without showing source approval as required. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_trust_operations_manage_renewal_expiry_and_rotation -- --nocapture` | 101 then 0 | Red/green proof: first exposed that archived expired trust-root decisions rendered as revocation; after the precedence fix, expired signature trust now projects `Trust expired` with a `Signature trust expired` warning. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_remove_package_requires_disabled_activations_and_discards_configs -- --nocapture` | 0 | Proved removed local packs project `Removed` and `Removed locally` labels from discarded package/config resources and removal metadata. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests/moduleOperatorProjectionKeepsServerActionsAndEvidence` | 65 | Red proof: failed to compile because iOS had no `presentation` member on `EngineConsoleModuleSourceTrustSummary`. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests` | 0 | Green proof: after implementation all 12 Engine Console state tests passed and the module projection consumed server-owned trust presentation labels. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after the trust-presentation implementation. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Verified the extracted trust projection module compiles through the server crate. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Verified the productization scorecard/evidence manifest state is formalized at 49/100 with TPROD-F passed and TPROD-G next. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Verified the touched large-file ledger remains formalized after updating current LOC rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 0 | Verified touched Rust files stay inside the cleanup scorecard large-file budgets after extracting `trust_projection.rs`. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests -only-testing:TronMobileTests/EngineConsolePackProjectionTests -only-testing:TronMobileTests/SourceGuardTests` | 0 | Verified thin-client Engine Console trust projection, pack projection, and iOS source guards together: 29 tests passed. |
| `git diff --check` | 0 | Verified whitespace/diff hygiene before the checkpoint commit. |

### Findings

- `control::snapshot.moduleSourceTrust` now includes a server-owned
  `trustPresentation` object with plain status, source, signature, approval,
  conformance, revocation, promotion, cleanup, evidence, and warning labels.
- The presentation is derived from existing resource-backed truth: package
  source evidence refs, source registration decisions, trust-root decisions,
  source approval decisions, approval/trust warnings, conformance evidence,
  optional promotion evidence refs, and removed package lifecycle metadata.
- iOS requires `trustPresentation` before rendering a source-trust row and no
  longer maps raw `sourceTrustStatus`/warning codes into product labels.

### Open Loops

- Closed for TPROD-F. TPROD-G is now closed by the evidence below.

## TPROD-G Evidence

### Files

- [`packages/agent/src/engine/primitives/ui/authoring/mod.rs`](../src/engine/primitives/ui/authoring/mod.rs)
- [`packages/agent/src/engine/primitives/ui/authoring/source_control.rs`](../src/engine/primitives/ui/authoring/source_control.rs)
- [`packages/agent/src/engine/tests/generated_ui.rs`](../src/engine/tests/generated_ui.rs)
- [`packages/agent/tests/threat_model_invariants.rs`](../tests/threat_model_invariants.rs)
- [`README.md`](../../../README.md)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml ui_surface_for_target_authors_source_control_session_surface -- --nocapture` | 101 then 0 | Red/green proof: first failed because the generated source-control surface lacked `Plain Diff Preview`; after implementation it proved preview, diff preview, allowed actions, validation-state cue, Inspect details, stored actions, and no layout-embedded templates. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after the source-control generated UI authoring changes. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Verified the generated UI authoring changes compile through the server crate. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Verified the productization scorecard/evidence manifest state is formalized at 58/100 with TPROD-G passed and TPROD-H next. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Verified the touched large-file ledger remains formalized after updating current LOC rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 0 | Verified touched Rust files stay inside the cleanup scorecard large-file budgets. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/SourceGuardTests` | 0 | Verified the fixed renderer supports the component catalog, submits only stored coordinates, and source guards keep target function/payload-template construction out of Swift: 22 tests passed. |
| `git diff --check` | 0 | Verified whitespace/diff hygiene before the checkpoint commit. |

### Findings

- Source-control generated surfaces now project a product review matrix using
  only fixed catalog components: preview, plain diff preview, allowed actions,
  validation-state cue, Inspect details, recent invocations, and review action
  controls.
- The action table carries product labels, risk, and approval requirement but
  does not inline payload templates or target construction into the layout.
- Existing iOS generated UI rendering remains generic: new review content uses
  existing catalog components and action submissions still carry only stored
  surface/version/action coordinates.

### Open Loops

- Closed for TPROD-G. TPROD-H must add model preset, automation, and subagent
  routing proof with server-owned policy, selected-model disclosure, hosted
  fallback disclosure, subagent chips, and parent/child lineage.

## TPROD-H Evidence

### Files

- [`packages/agent/src/domains/model/presets.rs`](../src/domains/model/presets.rs)
- [`packages/agent/src/domains/model/mod.rs`](../src/domains/model/mod.rs)
- [`packages/agent/src/domains/cron/implementation/domain/types.rs`](../src/domains/cron/implementation/domain/types.rs)
- [`packages/agent/src/domains/cron/implementation/domain/truth.rs`](../src/domains/cron/implementation/domain/truth.rs)
- [`packages/agent/src/domains/cron/implementation/execution/executor.rs`](../src/domains/cron/implementation/execution/executor.rs)
- [`packages/agent/src/domains/cron/implementation/impls.rs`](../src/domains/cron/implementation/impls.rs)
- [`packages/agent/src/domains/cron/operations/jobs.rs`](../src/domains/cron/operations/jobs.rs)
- [`packages/agent/src/domains/agent/contract.rs`](../src/domains/agent/contract.rs)
- [`packages/agent/src/domains/agent/operations/submissions.rs`](../src/domains/agent/operations/submissions.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager.rs`](../src/domains/agent/runner/orchestrator/subagent_manager.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager/execution.rs`](../src/domains/agent/runner/orchestrator/subagent_manager/execution.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager/forwarding.rs`](../src/domains/agent/runner/orchestrator/subagent_manager/forwarding.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager/tracking.rs`](../src/domains/agent/runner/orchestrator/subagent_manager/tracking.rs)
- [`packages/agent/src/domains/capability_support/implementations/traits.rs`](../src/domains/capability_support/implementations/traits.rs)
- [`packages/agent/src/shared/protocol/events/tron/catalog.rs`](../src/shared/protocol/events/tron/catalog.rs)
- [`packages/agent/src/transport/runtime/streams/session/agent.rs`](../src/transport/runtime/streams/session/agent.rs)
- [`packages/agent/src/engine/primitives/ui/authoring/subagent.rs`](../src/engine/primitives/ui/authoring/subagent.rs)
- [`packages/agent/src/engine/tests/cron_resources.rs`](../src/engine/tests/cron_resources.rs)
- [`packages/agent/src/engine/tests/subagent_lineage.rs`](../src/engine/tests/subagent_lineage.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs`](../src/domains/agent/runner/orchestrator/subagent_manager_tests.rs)
- [`packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests/routing_presentation.rs`](../src/domains/agent/runner/orchestrator/subagent_manager_tests/routing_presentation.rs)
- [`packages/ios-app/Sources/Models/Messages/SubagentTypes.swift`](../../ios-app/Sources/Models/Messages/SubagentTypes.swift)
- [`packages/ios-app/Sources/Core/Events/Plugins/Subagent/SubagentSpawnedPlugin.swift`](../../ios-app/Sources/Core/Events/Plugins/Subagent/SubagentSpawnedPlugin.swift)
- [`packages/ios-app/Sources/Core/Events/Plugins/Subagent/SubagentCompletedPlugin.swift`](../../ios-app/Sources/Core/Events/Plugins/Subagent/SubagentCompletedPlugin.swift)
- [`packages/ios-app/Sources/Core/Events/Plugins/Subagent/SubagentFailedPlugin.swift`](../../ios-app/Sources/Core/Events/Plugins/Subagent/SubagentFailedPlugin.swift)
- [`packages/ios-app/Sources/ViewModels/State/SubagentState.swift`](../../ios-app/Sources/ViewModels/State/SubagentState.swift)
- [`packages/ios-app/Sources/ViewModels/Chat/ChatViewModel+SubagentEvents.swift`](../../ios-app/Sources/ViewModels/Chat/ChatViewModel+SubagentEvents.swift)
- [`packages/ios-app/Sources/ViewModels/Chat/ChatViewModel+Pagination.swift`](../../ios-app/Sources/ViewModels/Chat/ChatViewModel+Pagination.swift)
- [`packages/ios-app/Sources/Models/UnifiedEventTransformer.swift`](../../ios-app/Sources/Models/UnifiedEventTransformer.swift)
- [`packages/ios-app/Sources/Core/Events/Transformer/Reconstruction/ReconstructedState.swift`](../../ios-app/Sources/Core/Events/Transformer/Reconstruction/ReconstructedState.swift)
- [`packages/ios-app/Sources/Views/Subagents/SubagentChip.swift`](../../ios-app/Sources/Views/Subagents/SubagentChip.swift)
- [`packages/ios-app/Tests/ViewModels/SubagentStateTests.swift`](../../ios-app/Tests/ViewModels/SubagentStateTests.swift)
- [`README.md`](../../../README.md)
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md)
- [`packages/agent/docs/codebase-cleanup-scorecard.md`](codebase-cleanup-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml cron_agent_turn_model_preset_is_decision_backed_and_product_presented -- --nocapture` | 101 then 0 | Red/green proof: first failed because cron agent-turn payloads had no `modelPreset`/pending `modelRouting`; after implementation it proved schedule-time `Local when possible` presentation is persisted as pending route truth. |
| `cargo test --manifest-path packages/agent/Cargo.toml generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions -- --nocapture` | 101 then 0 | Red/green proof: first failed because generated subagent lineage UI ignored `taskProfile`/`modelRouting`; after implementation it proved Review, Local when possible, selected hosted model, hosted fallback label, and fallback reason render from resource truth with stored actions. |
| `cargo test --manifest-path packages/agent/Cargo.toml spawn_persists_task_profile_and_model_routing_to_events_and_resource -- --nocapture` | 0 | Proved live subagent spawn resolves model route from policy, returns route/profile on the handle, persists them in parent spawn/completion events, and writes them to the final `agent_result` resource. |
| `cargo test --manifest-path packages/agent/Cargo.toml subagent_manager::tests --lib -- --nocapture` | 0 | Proved the full subagent manager namespace after extracting child event forwarding and moving the route/profile persistence case into a focused child test module; 64 tests passed. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all` | 0 | Formatted Rust changes after model preset, cron, and subagent routing implementation. |
| `cd packages/ios-app && xcodegen generate` | 0 | Regenerated `TronMobile.xcodeproj` after iOS route/profile model changes. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SubagentStateTests` | 65 then 0 | First failed because the scheme name was tried as `TronMobile`, then Swift plugin result initializers needed explicit route/profile fields; final run passed 53 selected tests and covered route/profile state plus chip preview data. |
| `cargo test --manifest-path packages/agent/Cargo.toml cron_agent_turn_model_preset_is_decision_backed_and_product_presented -- --nocapture` | 0 | Final focused cron routing rerun after formatting. |
| `cargo test --manifest-path packages/agent/Cargo.toml generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions -- --nocapture` | 0 | Final focused generated UI subagent lineage rerun after formatting. |
| `cargo test --manifest-path packages/agent/Cargo.toml spawn_persists_task_profile_and_model_routing_to_events_and_resource -- --nocapture` | 0 | Final focused live subagent route/resource rerun after formatting. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 101 then 0 | Closeout guard first caught production/test/catalog/static-gate large-file audit drift; final run passed after splitting subagent child forwarding/test routing presentation and syncing exact current LOC rows without widening existing budgets. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the cleanup scorecard remained formalized after the large-file audit update. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the productization scorecard/evidence manifest state is formalized at 68/100 with TPROD-H passed_after_fix and TPROD-I pending. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Broad Rust compile check for the agent package. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Final Rust formatting check. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SubagentStateTests` | 0 | Final focused iOS rerun after Rust cleanup/docs updates; 53 selected tests passed. |

### Findings

- The model domain now owns the product preset vocabulary and
  `ModelRoutingPresentation`. `Local when possible` records explicit local
  opt-in, selected model, local/hosted class, hosted fallback label, fallback
  reason, and profile policy name. Pure route tests cover both local available
  and hosted fallback cases.
- Cron agent-turn payloads can carry `modelPreset`; schedule creation/update
  stamps pending route presentation, while execution resolves the concrete
  model at the boundary and uses that same model for profile planning,
  provider creation, session creation, agent config, run output, and bounded
  run truth.
- `agent::spawn_subagent` accepts `modelPreset` and validated `taskProfile`.
  Capability subagents no longer default through the retired hard-coded
  `SUBAGENT_MODEL`; the manager resolves against active profile settings and
  persists route/profile in parent lifecycle events, live stream payloads,
  handle results, wait results, and resource-native `agent_result` metadata.
- Child event forwarding now lives outside the subagent execution spine, and
  the route/profile persistence scenario lives in a focused child test module.
  The cleanup scorecard exact LOC audit was updated without widening existing
  budgets.
- Generated subagent lineage surfaces render task profile, preset, selected
  model, hosted fallback label, and fallback reason from resource or invocation
  truth. The layout still submits only stored action coordinates.
- iOS remains a thin client for routing: it decodes server `taskProfile` and
  `modelRouting`, stores them in `SubagentInvocationData`, reconstructs them
  from persisted events, and renders compact chip previews for task/model/result
  lineage without owning selection policy.

### Open Loops

- Closed for TPROD-H. TPROD-I now owns the flagship Tron-maintains-Tron
  local work-loop proof.

## TPROD-I Evidence

### Files

- [`packages/agent/tests/integration/tprod_i_flagship.rs`](../tests/integration/tprod_i_flagship.rs)
- [`packages/agent/tests/integration/tests.rs`](../tests/integration/tests.rs)
- [`packages/agent/tests/integration.rs`](../tests/integration.rs)
- [`packages/agent/src/domains/sandbox/mod.rs`](../src/domains/sandbox/mod.rs)
- [`packages/agent/src/domains/sandbox/contract.rs`](../src/domains/sandbox/contract.rs)
- [`packages/agent/tests/threat_model_invariants.rs`](../tests/threat_model_invariants.rs)
- [`README.md`](../../../README.md)
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md)
- [`packages/agent/docs/tron-productization-evidence-manifest.md`](tron-productization-evidence-manifest.md)
- [`packages/agent/docs/codebase-cleanup-scorecard.md`](codebase-cleanup-scorecard.md)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration tprod_i_flagship_chat_loop_reaches_review_ready -- --nocapture` | 101 then 0 | Red/green flagship proof. Failures exposed stack pressure, materialized-file inspect shape, agent-owned autonomy grant validation, workspace id mismatch, approval-required conformance, missing subagent-manager wiring in provider-backed integration servers, and sandbox cleanup's stale volatile-only disconnect guard. Final run passed after root-cause fixes. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all` | 0 | Formatted Rust changes while stabilizing the proof. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 0 | Verified touched large-file audit rows in the cleanup scorecard remain exact after the flagship proof. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants codebase_cleanup_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the cleanup scorecard remains formalized after TPROD-I file-count updates. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants productization_scorecard_stays_formalized -- --nocapture` | 0 | Confirmed the productization scorecard/evidence manifest state is formalized at 77/100 with TPROD-I passed_after_fix and TPROD-J pending. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | 0 | Verified the Rust server compiles after integration harness and sandbox cleanup changes. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified committed Rust formatting. |
| `git diff --check` | 0 | Verified whitespace/diff hygiene before checkpoint review. |

### Findings

- The flagship proof starts from `agent::prompt` and exercises the normal chat
  loop, not a direct-only harness: the scripted assistant calls `execute`
  through model capability invocations and waits for `agent.ready`.
- The session grants workspace-local autonomy to the session agent, fetches
  live `worker::protocol_guide`, writes an intentionally broken
  `materialized_file`, repairs it from the live guide, and verifies version
  history includes both draft and repair.
- The repaired helper registers `tprod_i_flagship::review_ready` as a
  workspace-visible sandbox capability. The proof watches
  `catalog::watch_snapshot`, invokes the helper through `execute`, and inspects
  the helper in product-facing guidance.
- Conformance remains policy-owned: `capability::conformance_run` pauses for a
  user approval, the test resolves `approval::resolve` as a user actor, and the
  approved replay produces `evidence` resource refs before the final answer.
- Generated UI evidence is created through `ui::surface_for_target`; the final
  review-ready answer cites the resulting `ui_surface` resource ref.
- Subagent routing evidence is live: the provider-backed integration server now
  wires the production `SubagentManager`, and the proof spawns a Review
  subagent with `Local when possible` routing, then verifies streamed
  `agent.subagent_spawned` and `agent.subagent_completed` evidence plus the
  `agent_result:subagent:<session>` lineage reference.
- Cleanup stays local and non-release: the helper is stopped with
  `sandbox::stop_spawned_worker`; no push, merge, release, deploy, production
  rollout, or remote package discovery occurs.
- Sandbox cleanup no longer treats a post-stop non-volatile worker state as a
  failed stop. It kills the sandbox-created process and lets the external worker
  manager own durable disconnect/health transitions instead of routing through
  the volatile-only `worker::disconnect` primitive.

### Open Loops

- Closed for TPROD-I. TPROD-J must ship three local example packs: Tron
  maintainer, everyday local automation, and creative/knowledge, with tests,
  docs, no remote discovery, and no personal-info literals.
