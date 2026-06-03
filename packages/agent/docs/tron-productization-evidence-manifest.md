# Tron Productization Evidence Manifest

Created: **2026-06-03**
Scorecard: [`tron-productization-scorecard.md`](tron-productization-scorecard.md)
Current score: **22/100**

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
| TPROD-D | pending | Created-by-agent shelf/history not yet proven. |
| TPROD-E | pending | Local pack lifecycle product flow not yet proven. |
| TPROD-F | pending | Plain trust/promotion/revocation UX not yet proven. |
| TPROD-G | pending | Generated UI authoring product matrix not yet complete. |
| TPROD-H | pending | Model preset, automation, and subagent routing product proof not yet complete. |
| TPROD-I | pending | Flagship Tron-maintains-Tron loop not yet run. |
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

- Closed for TPROD-C. TPROD-D must turn the underlying session-created helper
  lifecycle into a durable created-by-agent gallery/history surface so users can
  browse created, repaired, tested, failed, discarded, stopped, and reused
  helper capabilities without reading raw engine ids.
