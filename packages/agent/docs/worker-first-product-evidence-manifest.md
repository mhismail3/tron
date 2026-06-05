# Worker-First Tron Product Evidence Manifest

Created: **2026-06-05**
Scorecard: [`worker-first-product-scorecard.md`](worker-first-product-scorecard.md)
Current score: **88/100**

This manifest records evidence for the active worker-first product scorecard.
Update it at each checkpoint with commands, return codes, exact source refs,
screenshots, runtime ids, open loops, and the next test.

## Boundaries

- Remote package discovery, push, merge, release, deploy, notarization, and
  production rollout are outside this campaign.
- iOS, Mac, and CLI must remain thin clients. They do not own approval truth,
  policy, source trust, generated action targets, model routing, worker routing,
  or capability binding.
- Engine substrate remains server-owned and audit-complete. The campaign moves
  that substrate out of the primary product mental model; it does not delete
  audit evidence.
- Default autonomy must be no-prompt unless a fail-closed guardrail blocks the
  work or the explicit QA/testing setting is enabled.

## Evidence Index

| Row | Status | Evidence |
|---|---|---|
| JARVIS-0 | running | Scorecard, manifest, README links, and static guard added. Source baseline is recorded below. Visual baseline screenshots remain open. |
| JARVIS-1 | passed_after_fix | Provider-visible Worker Guide vocabulary replaced the old Capability Primer/harness wording; README context/worker-loop docs plus user/operator/example docs describe worker abilities, Worker Packs, Generated Controls, and Audit; `worker_first_product_static_gates` now blocks `Substrate`, `Primer`, `Bindings`, and `Engine Console` in the primary Work dashboard. |
| JARVIS-2 | passed_after_fix | Default no-prompt autonomy, audited auto-decisions, testing prompts, fail-closed preflight, and replay behavior are covered by Rust tests. |
| JARVIS-3 | passed_after_fix | Worker Guide and execute schema default non-trivial work to worker/subagent delegation, provider-context tests prove guide injection, Work snapshot projects subagent jobs as Workers, and integration proof fans out two session workers without approvals. |
| JARVIS-4 | passed_after_fix | `agent::work_snapshot` is registered and covered by DTO tests for idle state, active work, worker health, milestones, guardrails, and audit refs. |
| JARVIS-5 | passed_after_fix | Top-level iOS Work mode reads `agent::work_snapshot`, renders autonomy/active work/workers/results/guardrails/Audit, and has iPhone/iPad simulator screenshots. |
| JARVIS-6 | passed_after_fix | Work chip/action detail projection replaces generic execute copy; default details show work summary while raw request/result/schema/trace/policy/approval state stays behind Audit Details. Streamed and reconstructed sessions plus hosted iPhone render are covered. |
| JARVIS-7 | passed_after_fix | Worker detail sheets consume server-owned trust/generated controls, filter selected-worker guardrails, and have simulator-hosted screenshots for running, success, failure, and blocked states. |
| JARVIS-8 | passed_after_fix | Agent settings expose Autonomy Mode and plain Guardrails rows; parity/layout tests and simulator render proof cover the worker-first copy. |
| JARVIS-9 | passed_after_fix | User/operator/product notes, local example pack docs, and the managed self-extend skill now describe worker-led autonomous work, Worker Packs, Generated Controls, run-unless-blocked autonomy, and Audit Details. Static docs invariant rejects retired capability-led product wording and remote/release paths. |
| JARVIS-10 | passed_after_fix | Audit-only iOS code was renamed from EngineConsole to AuditDetails ownership, Created-by-Agent projections were renamed to Worker Artifacts, broad absence gates were added, and focused Rust plus simulator tests passed. |
| JARVIS-11 | pending | Not started. |

## JARVIS-0 Evidence

### Inputs

- User supplied an external plan file titled `Worker-First Tron Product
  Scorecard`.
- The plan requires a product model centered on Work, Workers, Worker Packs,
  Autonomy, Guardrails, and Audit.

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `git status --short --branch` | 0 | Confirmed branch `next/modular-capability-engine` was clean before edits. |
| `sed -n '1,260p' README.md` | 0 | Audited root architecture and living-doc map. |
| `sed -n '1,260p' packages/ios-app/docs/architecture.md` | 0 | Audited current iOS thin-client, Engine Console, capability-native chat, and approval baseline docs. |
| `sed -n '1,260p' '/Users/.../PLAN (1).md'` | 0 | Read the external worker-first plan. |
| `rg -n "Engine Console\\|NavigationMode\\.engine\\|NavigationMode\\|capability\\|approval\\|work_snapshot\\|Autonomy\\|Worker" packages/agent/src packages/agent/tests packages/ios-app/Sources packages/ios-app/Tests packages/agent/docs README.md` | 0 | Located current product vocabulary, Engine Console, approval, worker, and missing work snapshot surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_scorecard_invariants -- --nocapture` | 101 | Red proof: failed because the worker-first scorecard docs did not exist yet. |

### Source Evidence

- [`README.md`](../../../README.md): baseline root product wording said the
  iOS app provided a chat and Engine Console harness over server-owned
  substrate; JARVIS-5 changed the current wording to Work plus Audit Details.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md):
  baseline iOS architecture listed `NavigationMode.engine`, Engine Console
  projections, live substrate search suggestions, workers/policies/traces/
  primer/program-runs/substrate sections, and server-owned approval resolving.
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift):
  current primary technical inspection surface.
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleState.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleState.swift):
  current iOS state stitching across status, registry, catalog, control, audit,
  generated UI, and program runs.
- [`packages/ios-app/Sources/Services/Network/Clients/ApprovalClient.swift`](../../ios-app/Sources/Services/Network/Clients/ApprovalClient.swift):
  current thin client for server-owned approval decisions.
- [`packages/ios-app/Sources/Services/Network/Clients/CapabilityClient.swift`](../../ios-app/Sources/Services/Network/Clients/CapabilityClient.swift):
  current Engine Console client surface for capability/admin/catalog/control
  functions.
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md):
  completed predecessor proving the capability/pack-centered baseline at
  100/100.

### Findings

- Baseline primary iOS source included `NavigationMode.engine` and Engine
  Console views.
- Current docs still present Engine Console as a top-level mode and mention
  substrate, primer, bindings, traces, policies, and raw registry details in
  product-adjacent contexts.
- Current approval UX remains prompt-capable and server-owned. The new default
  policy must preserve audit rows while removing default user prompts.
- No `agent::work_snapshot` projection exists in the audited source scan.
- The implementation should reuse the proven engine substrate rather than
  rebuild worker, generated UI, pack, approval, or resource primitives.

### Open Loops

- Visual baseline screenshots remain open.
- JARVIS-0 cannot receive points until current Engine Console, approval prompt,
  worker/capability-heavy UI, and source references are captured together.
- The next implementation checkpoint should collapse product vocabulary and
  continue the iOS replacement work while preserving simulator screenshot proof.

## JARVIS-2 / JARVIS-4 / JARVIS-8 Partial Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml agent_autonomy_settings_deserialize_testing_prompt_mode -- --nocapture` | 0 | Proved the server setting decodes explicit testing mode while defaulting to disabled elsewhere. |
| `cargo test --manifest-path packages/agent/Cargo.toml agent_high_risk_invocation_auto_decides_by_default_without_pending_prompt -- --nocapture` | 0 | Proved default mode executes high-risk approval-required work through audited server auto-decision without an interactive pending prompt. |
| `cargo test --manifest-path packages/agent/Cargo.toml agent_high_risk_auto_decision -- --nocapture` | 101 then 0 | Red/green proof for terminal auto-decision replay. Initial fixture omitted required high-risk compensation metadata; final run proved executed replay, denied replay, and failed replay without duplicate child effects. |
| `cargo test --manifest-path packages/agent/Cargo.toml approval -- --nocapture` | 0 | Proved the existing approval suite still passed after the default-policy change. |
| `cargo test --manifest-path packages/agent/Cargo.toml work_snapshot -- --nocapture` | 101 then 0 | Red/green proof. Initial failure exposed infrastructure workers in the default snapshot and missing literal active-work assertion; final run passed after filtering system workers and asserting active work. |
| `cargo test --manifest-path packages/agent/Cargo.toml agent_high_risk -- --nocapture` | 0 | Proved default auto-decision, testing prompt preservation, guardrail block-before-audit, and idempotent replay behavior together. |
| `cargo test --manifest-path packages/agent/Cargo.toml agent_autonomy_settings -- --nocapture` | 0 | Re-ran the settings serde filter after policy changes. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` | 101 then 0 | Red/green file-budget proof. Initial run caught the expanded approval test file over 1000 LOC; final run passed after moving default-autonomy approval tests into `approval_autonomy.rs` and correcting stale audit rows for `integration.rs` and `threat_model_invariants.rs`. |
| `cd packages/ios-app && xcodegen generate` | 0 | Regenerated the project before simulator tests; no project-file churn remained. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/AgentContextSettingsPageTests` | 65 | Default DerivedData linked stale test objects with an old `CompactionPlugin.Result` initializer. Source inspection showed current tests already used the new initializer. |
| `rm -rf /tmp/tron-xcode-autonomy-dd && xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-autonomy-dd -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/AgentContextSettingsPageTests` | 0 | Fresh simulator test proof: 47 selected tests passed across settings state, server settings protocol, and Agent settings metadata. |
| `xcrun simctl install booted /tmp/tron-xcode-autonomy-dd/Build/Products/Beta-iphonesimulator/TronMobile.app && xcrun simctl launch booted com.tron.mobile.beta && sleep 2 && xcrun simctl openurl booted tron://settings && sleep 2 && mkdir -p /tmp/tron-worker-first-screens && xcrun simctl io booted screenshot /tmp/tron-worker-first-screens/settings-deeplink-unpaired.png` | 0 | Real simulator launch/deep-link proof. Screenshot showed the Settings sheet and Agent tile; no simulator tap/computer-use tool was available to open the Agent detail page from this shell path. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-autonomy-dd -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsAutonomyRendersForVisualQA` | 65 then 0 | Red/green simulator-hosted render proof. Initial compile failed because the source-level layout test file lacked `@testable import TronMobile`; final hosted `UIHostingController` render passed and replaced an unusable `ImageRenderer` placeholder artifact. |
| `rm -rf /tmp/tron-xcode-autonomy-dd && xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-autonomy-dd -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests` | 65 then 0 | Fresh simulator proof after copy/render changes: 17 XCTest cases plus 36 Swift Testing cases passed. Red/green detail: initial rerun failed because the render test used unavailable iOS `homeDirectoryForCurrentUser`; final run passed after switching the seeded workspace path to `NSTemporaryDirectory()`. Final render artifact: `~/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/3D8FAB85-AA8B-4CD4-BE28-01DFF7A815CF/Documents/tron-visual-artifacts/agent-settings-autonomy-render.png`. |

### Source Evidence

- [`packages/agent/src/domains/settings/implementation/types/server.rs`](../src/domains/settings/implementation/types/server.rs):
  adds `AgentAutonomySettings` and default `approvalPromptMode = disabled`.
- [`packages/agent/defaults/profiles/default/profile.toml`](../defaults/profiles/default/profile.toml):
  records the managed default autonomy mode.
- [`packages/agent/src/engine/capabilities.rs`](../src/engine/capabilities.rs)
  and [`packages/agent/src/engine/host/invocation_handle.rs`](../src/engine/host/invocation_handle.rs):
  route high-risk approval-required agent invocations through testing prompts
  only in testing mode; default mode creates audited auto-decision records,
  executes the preserved child invocation, and avoids duplicate resolved events
  for terminal replays.
- [`packages/agent/src/domains/agent/contract.rs`](../src/domains/agent/contract.rs),
  [`packages/agent/src/domains/agent/handlers.rs`](../src/domains/agent/handlers.rs),
  and [`packages/agent/src/domains/agent/operations/work_snapshot.rs`](../src/domains/agent/operations/work_snapshot.rs):
  register and implement `agent::work_snapshot` from server-owned settings,
  catalog, invocation, approval, guardrail, and audit truth.
- [`packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Settings.swift`](../../ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Settings.swift),
  [`packages/ios-app/Sources/ViewModels/State/SettingsState.swift`](../../ios-app/Sources/ViewModels/State/SettingsState.swift),
  and [`packages/ios-app/Sources/Views/Settings/Pages/AgentSettingsPage.swift`](../../ios-app/Sources/Views/Settings/Pages/AgentSettingsPage.swift):
  decode, store, update, and expose the autonomy prompt mode in Agent settings
  with worker-first Autonomy Mode copy.
- [`packages/ios-app/Tests/Views/AgentSettingsPageLayoutTests.swift`](../../ios-app/Tests/Views/AgentSettingsPageLayoutTests.swift):
  locks the Autonomy Mode label, independent-mode copy, QA prompt copy, and
  produces a simulator-hosted visual artifact for the Agent settings page.

### Findings

- Default autonomy is now run-unless-blocked: interactive approval prompts are
  disabled by default, but approval audit records remain durable and testing
  mode preserves the old pending-prompt path for QA.
- Guardrail/schema preflight still happens before auto-decision and creates no
  approval audit record or child effect when it blocks.
- Idempotent default-mode replay returns the original child result, creates one
  approval audit record, performs one child effect, and publishes one resolved
  approval event.
- Terminal default-mode replay is fail-closed: `denied` approval records return
  `APPROVAL_DENIED`, `failed` approval records return the stored child failure,
  neither path retries the child handler, and neither path records a new child
  invocation.
- `agent::work_snapshot` deliberately filters system/infrastructure workers
  from default worker cards so idle snapshots stay product-facing.
- The final simulator render screenshot shows the Agent settings page, Autonomy
  Mode set to Independent, and the copy "Tron runs independently on this Mac,
  audits approval-required work, and only stops when guardrails block it."
- The render fixture now uses a simulator-safe temporary workspace seed instead
  of a macOS-only home-directory API.
- The in-thread tool registry exposed no simulator tap/computer-use control.
  `simctl` launch/openurl/screenshot proved the Settings sheet and Agent tile,
  while the hosted render test proves the Agent detail content.

### Open Loops

- JARVIS-8 settings UX is closed by the Work dashboard/settings checkpoint
  below; JARVIS-11 owns final paired-server soak/action proof.
- JARVIS-5 is closed for the default iOS Work dashboard replacement that
  consumes `agent::work_snapshot`.

## JARVIS-1 / JARVIS-3 Partial Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml primer_uses_worker_first_orchestration_language -- --nocapture` | 101 then 0 | Red/green proof that the generated guide no longer renders `# Capability Primer` or harness wording and now teaches Work router, worker abilities, fan-out, non-trivial delegation, and Audit-only raw ids. |
| `cargo test --manifest-path packages/agent/Cargo.toml worker_guide_docs_are_versioned_resources -- --nocapture` | 101 then 0 | Red/green proof that rendered guide resources use the `Worker guide resource:` pointer, `worker-guide` doc id, `Worker guide` title, and current body. |
| `cargo test --manifest-path packages/agent/Cargo.toml capability_primer_context_stays_within_budget -- --nocapture` | 101 then 0 | Red/green proof that the longer Worker Guide still stays within the profile budget and truncates with worker-ability wording. |
| `cargo test --manifest-path packages/agent/Cargo.toml primer_teaches_self_modifying_worker_lifecycle -- --nocapture` | 0 | Proved the self-extension recipe still covers grant, spawn, inspect, conformance/test, generated UI, promotion, cleanup, chat status, and Audit boundaries. |
| `cargo test --manifest-path packages/agent/Cargo.toml execute_description_teaches_self_modifying_worker_lifecycle -- --nocapture` | 0 | Proved the provider-visible `execute` schema description matches the worker-first self-extension and Audit guidance. |
| `cargo test --manifest-path packages/agent/Cargo.toml capability_primer_follows_dynamic_rules_before_skills -- --nocapture` | 0 | Proved the provider context block ordering still places the generated guide after active rules and before skills. |
| `cargo test --manifest-path packages/agent/Cargo.toml model_run_proves_worker_guide_reaches_provider_context -- --nocapture` | 0 | Proved hosted and local provider routes receive the Worker Guide/resource pointer while local policy strips heavier context. |
| `cargo test --manifest-path packages/agent/Cargo.toml worker_first_orchestration_fans_out_session_workers_without_approvals -- --nocapture` | 0 | Real server/WebSocket proof: spawned two session workers, invoked both through `execute`, verified `agent::work_snapshot` projected both workers, and `approval::list` stayed empty before and after execution. |
| `cargo test --manifest-path packages/agent/Cargo.toml work_snapshot -- --nocapture` | 0 | Proved `agent::work_snapshot` covers idle/default, active work/guardrail/audit refs, and live subagent jobs projected as Worker cards. |

### Source Evidence

- [`packages/agent/src/domains/capability/registry/primer.rs`](../src/domains/capability/registry/primer.rs):
  renders `# Worker Guide`, teaches non-trivial delegation/fan-out, and keeps
  raw grants, traces, resource refs, child invocation ids, function ids, and
  raw schemas in Audit.
- [`packages/agent/src/domains/capability/contract.rs`](../src/domains/capability/contract.rs):
  updates the model-visible `execute` schema description to the Work router and
  autonomous Worker extension vocabulary.
- [`packages/agent/src/domains/capability/operations/mod.rs`](../src/domains/capability/operations/mod.rs):
  stores generated guide docs as `worker-guide` with the `Worker guide
  resource:` pointer while preserving the underlying typed `harness_doc`
  resource kind.
- [`packages/agent/src/domains/model/providers/shared/context_composition.rs`](../src/domains/model/providers/shared/context_composition.rs):
  labels the provider context block `Worker Guide`.
- [`packages/agent/src/domains/agent/runner/agent/tron_agent_tests.rs`](../src/domains/agent/runner/agent/tron_agent_tests.rs):
  proves generated guide context reaches hosted and local providers.
- [`packages/agent/tests/integration/tests.rs`](../tests/integration/tests.rs):
  adds the fan-out worker proof against a real local server and worker
  processes.
- [`packages/agent/src/domains/agent/operations/work_snapshot.rs`](../src/domains/agent/operations/work_snapshot.rs):
  projects `SubagentManager` jobs as `workerType=agent` Worker cards while
  preserving `agent::spawn_subagent` as the underlying server primitive.
- [`README.md`](../../../README.md) and
  [`packages/agent/docs/context-architecture.md`](context-architecture.md):
  document the generated Worker Guide and internal `capabilities.primer` block
  id without presenting primer vocabulary as product language.

### Findings

- The model-visible guide is worker-first: non-trivial work is orchestrated by
  delegating focused slices to workers/subagents, spawning fan-out workers
  before gathering results, and reporting Work status/outcomes/cleanup in chat.
- The old `# Capability Primer`, harness customization, `Harness docs
  resource:`, and `agent-capability-primer` runtime grant naming were removed
  from active source/test surfaces except negative assertions that prevent
  reintroduction.
- The fan-out integration proof created no approval prompts. This proves the
  JARVIS-2 no-prompt policy composes with JARVIS-3 worker orchestration.
- `agent::work_snapshot` projects spawned helper workers as product Worker
  cards for the tested session.
- `agent::work_snapshot` projects live subagent jobs as product Worker cards
  with delegated-work ability, run id, elapsed time, health, and Audit ref.

### Open Loops

- JARVIS-1 still needs primary UI vocabulary gates after Work dashboard/chat
  replacement removes the Engine Console path.
- JARVIS-3 is closed for server orchestration/projection. JARVIS-5 and
  JARVIS-7 own iOS presentation and detail sheets for the Worker cards.

## JARVIS-5 / JARVIS-8 Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineNavigationTests -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/WorkDashboardStateTests` | 65 | Red proof: the navigation/client/state tests referenced the Work route and DTOs before implementation. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-work-green1 -only-testing:TronMobileTests/EngineNavigationTests -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/WorkDashboardStateTests` | 0 | Green proof: 15 selected simulator tests passed for Work navigation, `agent::work_snapshot` read behavior, and `WorkDashboardState` load/error/blocked paths. |
| `TRON_VISUAL_ARTIFACT_DIR=/tmp/tron-visual-artifacts xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-work-visual -only-testing:TronMobileTests/WorkDashboardViewTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsExposePlainGuardrails -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsAutonomyUsesWorkerFirstCopy -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsAutonomyRendersForVisualQA` | 0 | Simulator proof: Work dashboard source gate plus Agent settings Guardrails/Autonomy layout tests passed. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-work-checkpoint -only-testing:TronMobileTests/EngineNavigationTests -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/WorkDashboardStateTests -only-testing:TronMobileTests/WorkDashboardViewTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsExposePlainGuardrails -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsAutonomyUsesWorkerFirstCopy -only-testing:TronMobileTests/AgentSettingsPageLayoutTests/testAgentSettingsAutonomyRendersForVisualQA` | 0 | Final focused simulator proof after replacing clipped section symbols: 5 XCTest render/layout tests and 15 Swift Testing client/navigation/state tests passed in a fresh DerivedData path. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-work-settings-check -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests` | 65 then 0 | Broader settings red/green proof. Initial run caught `AgentSettingsSection.allCases` still expecting the pre-Guardrails order; final run passed 18 XCTest cases plus 36 Swift Testing cases after adding `.guardrails` after `.autonomy`. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-work-checkpoint -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/WorkDashboardStateTests -only-testing:TronMobileTests/WorkDashboardViewTests` | 0 | Cleanup proof after removing unused `WorkAuditRefDTO.stableId`: 2 XCTest Work dashboard tests and 14 Swift Testing client/state tests passed. |
| `view_image .../work-dashboard-iphone-render.png` | 0 | Visual inspection of the iPhone 17 Pro screenshot confirmed readable Work/Workers/Guardrails/Results/Audit layout with no overlap or clipped section icons. |
| `view_image .../work-dashboard-ipad-render.png` | 0 | Visual inspection of the iPad screenshot confirmed the same content remains legible with centered max-width layout and no overlap. |

### Simulator Evidence

- Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`.
- Bundle under test: `TronMobile.app` from the `Tron` scheme, Beta
  simulator configuration.
- Final Work dashboard iPhone artifact:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/7F21D653-1081-4241-A0C4-B476D89BFD9F/Documents/tron-visual-artifacts/work-dashboard-iphone-render.png`.
- Final Work dashboard iPad artifact:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/7F21D653-1081-4241-A0C4-B476D89BFD9F/Documents/tron-visual-artifacts/work-dashboard-ipad-render.png`.
- Final Agent settings Autonomy/Guardrails render artifact:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/167B2E85-478E-4469-9F1D-3162F36BE5A2/Documents/tron-visual-artifacts/agent-settings-autonomy-render.png`.
- The simulator app attempted to reconnect to the default local server
  `ws://127.0.0.1:19847/engine`; the server was not running, so logs include
  expected `NSURLErrorDomain Code=-1004` connection-refused warnings. The
  hosted render and client tests use deterministic fixtures and still passed.
- The in-thread tool registry still exposed no simulator tap/computer-use
  control. Simulator proof therefore uses `xcodebuild`, hosted SwiftUI
  rendering, `simctl`-backed app execution through XCTest, emitted PNG
  artifacts, and manual visual inspection through the local image viewer.

### Source Evidence

- [`packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift`](../../ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift):
  adds typed Work snapshot DTOs for autonomy, active work, workers, abilities,
  milestones, guardrails, audit refs, and scope.
- [`packages/ios-app/Sources/Services/Network/Clients/AgentClient.swift`](../../ios-app/Sources/Services/Network/Clients/AgentClient.swift):
  adds the read-only `agent::work_snapshot` call with optional session/workspace
  context and limit params.
- [`packages/ios-app/Sources/ViewModels/State/WorkDashboardState.swift`](../../ios-app/Sources/ViewModels/State/WorkDashboardState.swift):
  keeps iOS state thin: refresh/load/error state, blocked-work summary, and
  worker milestone filtering only.
- [`packages/ios-app/Sources/Views/Chat/SessionSidebar.swift`](../../ios-app/Sources/Views/Chat/SessionSidebar.swift)
  and [`packages/ios-app/Sources/Views/Chat/ContentView.swift`](../../ios-app/Sources/Views/Chat/ContentView.swift):
  replace the top-level Engine route with Work.
- [`packages/ios-app/Sources/Views/Work/WorkDashboardView.swift`](../../ios-app/Sources/Views/Work/WorkDashboardView.swift):
  renders the minimal Work surface and keeps the old technical console behind
  one Audit Details sheet.
- [`packages/ios-app/Sources/Views/Settings/Pages/AgentSettingsPage.swift`](../../ios-app/Sources/Views/Settings/Pages/AgentSettingsPage.swift)
  and [`packages/ios-app/Sources/Views/Settings/SettingsSupport.swift`](../../ios-app/Sources/Views/Settings/SettingsSupport.swift):
  add plain Guardrails settings copy next to Autonomy Mode.
- [`packages/ios-app/Tests/Views/WorkDashboardViewTests.swift`](../../ios-app/Tests/Views/WorkDashboardViewTests.swift):
  locks Work vocabulary, blocks raw Engine Console metric-grid/jargon strings
  in the Work view, and emits iPhone/iPad screenshots.
- [`packages/ios-app/Tests/ViewModels/WorkDashboardStateTests.swift`](../../ios-app/Tests/ViewModels/WorkDashboardStateTests.swift)
  and [`packages/ios-app/Tests/Services/AgentClientTests.swift`](../../ios-app/Tests/Services/AgentClientTests.swift):
  prove the snapshot client/state path without iOS-owned policy joins.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
  and [`README.md`](../../../README.md):
  document Work as the top-level surface and Engine Console as Audit Details.

### Findings

- The primary iOS route is now `NavigationMode.work`, not
  `NavigationMode.engine`.
- The default dashboard is powered by one server-owned `agent::work_snapshot`
  read. iOS no longer needs to combine capability registry, catalog, approval,
  policy, and audit clients to build the main product screen.
- The default Work path shows autonomy status, active work, workers, guardrail
  alerts, recent results, and a single Audit Details entry point; it does not
  show raw catalog/plugin/implementation/binding count grids.
- Guardrails settings are plain and non-technical: Run Unless Blocked is On,
  Audit Trail is Always, and the copy states that server guardrails stop unsafe
  work before it runs.
- The first visual pass caught section-header icon clipping on iPhone. The fix
  replaced wide symbols with stable section icons and the final simulator
  screenshots verified no clipping or text overlap.

### Open Loops

- JARVIS-5 is closed for the default dashboard. JARVIS-7 below closes worker
  detail screenshots across running, success, failure, and blocked states.
- JARVIS-8 is closed for settings UX, but JARVIS-11 owns final paired-server
  action/soak proof.
- JARVIS-10 still owns deleting or renaming remaining audit-only Engine Console
  ownership and adding broad absence gates for primary UI jargon.

## JARVIS-6 Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `xcodegen generate` | 0 | Regenerated the iOS project after adding the action-detail view test file, Work-row model extension, and focused reconstructed-session test file. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-chat-work-red -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/CapabilityInvocationCoordinatorTests/testStreamedCapabilityStartProjectsWorkSummary -only-testing:TronMobileTests/UnifiedEventTransformerTests/testReconstructedCapabilityInvocationProjectsWorkSummary -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests` | 65 | Red proof: new tests failed because `CapabilityInvocationDisplayModel` did not yet expose `workRows`. |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-chat-work-red -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/CapabilityInvocationCoordinatorTests/testStreamedCapabilityStartProjectsWorkSummary -only-testing:TronMobileTests/UnifiedEventTransformerWorkProjectionTests/testReconstructedCapabilityInvocationProjectsWorkSummary -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests` | 0 | Green proof: 27 selected simulator tests passed after the Work projection, Audit Details changes, solid detail-surface guard, and large-file-budget split. |
| `view_image .../capability-invocation-detail-work-render.png` | 0 | Visual inspection confirmed the iPhone detail sheet starts with Run Command, Worker, Work, What happened, Why, Worker, Status, Result, and compact Inputs without raw request/result/schema/trace/policy payloads in the default viewport or reflected text bleed inside the Work card. |

### Simulator Evidence

- Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`.
- Bundle under test: `TronMobile.app` from the `Tron` scheme, Beta
  simulator configuration.
- Hosted iPhone action-detail artifact:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/BD080F62-AA68-458C-92BC-13406AE6F098/Documents/tron-visual-artifacts/capability-invocation-detail-work-render.png`.
- The simulator app attempted to reconnect to the default local server
  `ws://127.0.0.1:19847/engine`; the server was not running, so logs include
  expected `NSURLErrorDomain Code=-1004` connection-refused warnings. The
  hosted render and fixture tests still passed.
- The in-thread tool registry exposed no simulator tap/computer-use control.
  Proof used `xcodebuild`, hosted SwiftUI rendering, simulator app execution
  through XCTest, emitted PNG artifacts, and manual visual inspection through
  the local image viewer.

### Source Evidence

- [`packages/ios-app/Sources/Models/Messages/CapabilityInvocationDisplayModel.swift`](../../ios-app/Sources/Models/Messages/CapabilityInvocationDisplayModel.swift):
  preserves raw request/result and approval state for Audit Details and removes
  the unused `capabilityRows` branch.
- [`packages/ios-app/Sources/Models/Messages/CapabilityInvocationWorkRows.swift`](../../ios-app/Sources/Models/Messages/CapabilityInvocationWorkRows.swift):
  owns `workRows` for What happened / Why / Worker / Status / Result and
  formats result previews into one primary-path line.
- [`packages/ios-app/Sources/Models/Messages/CapabilityPresentation.swift`](../../ios-app/Sources/Models/Messages/CapabilityPresentation.swift):
  presents generic `execute` as Work and derives a readable Worker label from
  server-owned presentation hints, worker id, target namespace, or plugin id.
- [`packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationViews.swift`](../../ios-app/Sources/Views/Capabilities/CapabilityInvocationViews.swift):
  replaces default Request/Approval/Advanced sections with Work and Audit
  Details, keeping raw request/result/approval payloads collapsed behind audit
  disclosures.
- [`packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationDetailComponents.swift`](../../ios-app/Sources/Views/Capabilities/CapabilityInvocationDetailComponents.swift):
  changes the detail header metric from Plugin to Worker and uses a solid
  readable surface for the header.
- [`packages/ios-app/Sources/Views/Capabilities/Shared/CapabilityDetailSection.swift`](../../ios-app/Sources/Views/Capabilities/Shared/CapabilityDetailSection.swift):
  uses a solid detail surface so nearby text does not reflect into the Work
  summary card.
- [`packages/ios-app/Tests/Models/CapabilityInvocationDisplayModelTests.swift`](../../ios-app/Tests/Models/CapabilityInvocationDisplayModelTests.swift):
  locks Work language for generic/resolved execute calls and proves raw schema,
  trace, binding, and implementation ids stay out of the default work rows.
- [`packages/ios-app/Tests/ViewModels/CapabilityInvocationCoordinatorTests.swift`](../../ios-app/Tests/ViewModels/CapabilityInvocationCoordinatorTests.swift):
  covers the streamed capability-start path projecting Work, Worker, and Why
  without execute or implementation jargon in visible chip text.
- [`packages/ios-app/Tests/Core/Events/UnifiedEventTransformerWorkProjectionTests.swift`](../../ios-app/Tests/Core/Events/UnifiedEventTransformerWorkProjectionTests.swift):
  covers persisted-session reconstruction projecting the same Work rows from
  interleaved assistant content plus capability lifecycle events.
- [`packages/ios-app/Tests/Views/Capabilities/CapabilityInvocationDetailViewTests.swift`](../../ios-app/Tests/Views/Capabilities/CapabilityInvocationDetailViewTests.swift):
  adds source gates for audit-only raw protocol sections, guards the solid
  detail surface, and emits the hosted iPhone action-detail visual artifact.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
  and [`README.md`](../../../README.md):
  document Work chips/action details and the raw protocol boundary.

### Findings

- Default chat/action details now render one high-signal Work projection per
  invocation. Generic unresolved `execute` appears as Work/Choosing worker
  rather than as a user-facing primitive.
- The default detail sheet shows What happened, Why, Worker, Status, Result,
  and compact Inputs before the progress cards.
- Detail surfaces are solid and readable in the hosted iPhone render; the Work
  card no longer shows reflected text from adjacent content.
- Raw request, raw result, schema, trace, binding, policy, and approval-state
  data remain available, but only under the Audit Details disclosure.
- The live coordinator already deduplicates generating/start events by
  invocation id; the new streamed-path test proves the resulting visible
  projection uses Work/Worker language.
- The reconstructed-session test proves resumed sessions use the same Work
  projection as live sessions.

### Open Loops

- JARVIS-6 is closed for chat/action detail projection.
- JARVIS-7 below closes dedicated Worker detail sheets and state-matrix
  screenshots across running, success, failure, and blocked guardrail states.
- JARVIS-10 still owns broader primary-UI absence gates for remaining
  audit-only Engine Console/jargon cleanup.

## JARVIS-7 Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml work_snapshot -- --nocapture` | 101 | Red proof: worker and subagent snapshots did not expose `trust` or `generatedControls`; both new assertions failed with `Null`. |
| `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-worker-detail-red -only-testing:TronMobileTests/WorkDashboardStateTests -only-testing:TronMobileTests/WorkDashboardViewTests -only-testing:TronMobileTests/AgentClientTests` | 65 | Red proof: Swift failed to compile because `WorkWorkerDTO.trust`, `WorkWorkerDTO.generatedControls`, `WorkGeneratedControlDTO`, `WorkDashboardState.guardrailsForWorker`, and the test-visible worker detail sheet did not exist. |
| `cargo test --manifest-path packages/agent/Cargo.toml work_snapshot -- --nocapture` | 101 then 0 | Green proof after the production patch. The first rerun caught a Rust ownership issue in `worker_trust`; the final run passed all 3 selected `work_snapshot` tests and 5884 filtered library tests. |
| `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-worker-detail-final -only-testing:TronMobileTests/WorkDashboardStateTests -only-testing:TronMobileTests/WorkDashboardViewTests -only-testing:TronMobileTests/AgentClientTests` | 0 | Final simulator proof: 3 XCTest hosted-render/source tests and 14 Swift Testing client/state tests passed. |
| `view_image .../worker-detail-running-render.png` | 0 | Visual inspection confirmed the running worker detail render is nonblank and shows header, Health, Trust, Generated Controls, Guardrails, and Abilities without visible overlap. |
| `view_image .../worker-detail-success-render.png` | 0 | Visual inspection confirmed the success-state render is nonblank and readable. |
| `view_image .../worker-detail-failure-render.png` | 0 | Visual inspection confirmed the failure-state render is nonblank, uses failure health/tints, and remains readable. |
| `view_image .../worker-detail-blocked-render.png` | 0 | Visual inspection confirmed the blocked-state render shows degraded health, guardrail-blocked trust, generated controls, and the blocking guardrail in the first viewport. |

### Simulator Evidence

- Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`.
- Bundle under test: `TronMobile.app` from the `Tron` scheme, Beta simulator
  configuration.
- Hosted Work dashboard artifacts:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/work-dashboard-iphone-render.png`
  and
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/work-dashboard-ipad-render.png`.
- Hosted worker detail artifacts:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/worker-detail-running-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/worker-detail-success-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/worker-detail-failure-render.png`, and
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/8B4A3505-E46D-4BFD-BEE8-D9F5F97488DA/Documents/tron-visual-artifacts/worker-detail-blocked-render.png`.
- The simulator app attempted to reconnect to the default local server
  `ws://127.0.0.1:19847/engine`; the server was not running, so logs include
  expected `NSURLErrorDomain Code=-1004` connection-refused warnings. The
  hosted render and fixture tests still passed.
- The in-thread tool registry exposed no simulator tap/computer-use control.
  Proof used `xcodebuild`, hosted SwiftUI rendering in the simulator process,
  emitted PNG artifacts, and manual visual inspection through the local image
  viewer.

### Source Evidence

- [`packages/agent/src/domains/agent/operations/work_snapshot.rs`](../src/domains/agent/operations/work_snapshot.rs):
  projects server-owned `trust` and `generatedControls` for visible catalog
  workers and live subagent workers.
- [`packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift`](../../ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift):
  decodes worker trust and generated controls without client-side fallback
  reconstruction.
- [`packages/ios-app/Sources/ViewModels/State/WorkDashboardState.swift`](../../ios-app/Sources/ViewModels/State/WorkDashboardState.swift):
  filters existing server guardrails to the selected worker by server-supplied
  ability function ids.
- [`packages/ios-app/Sources/Views/Work/WorkDashboardView.swift`](../../ios-app/Sources/Views/Work/WorkDashboardView.swift):
  passes selected-worker guardrails into `WorkWorkerDetailSheet` and renders
  Health, Trust, Generated Controls, Guardrails, Abilities, Recent Work, and
  Audit History.
- [`packages/ios-app/Tests/Views/WorkDashboardViewTests.swift`](../../ios-app/Tests/Views/WorkDashboardViewTests.swift):
  locks the worker detail vocabulary and emits hosted iPhone screenshots for
  running, success, failure, and blocked guardrail states.
- [`packages/ios-app/Tests/ViewModels/WorkDashboardStateTests.swift`](../../ios-app/Tests/ViewModels/WorkDashboardStateTests.swift)
  and [`packages/ios-app/Tests/Services/AgentClientTests.swift`](../../ios-app/Tests/Services/AgentClientTests.swift):
  cover selected-worker guardrail filtering and decode of trust/generated
  controls from `agent::work_snapshot`.

### Findings

- Worker detail truth remains server-owned. iOS decodes `trust`,
  `generatedControls`, abilities, milestones, guardrails, and audit refs from
  `agent::work_snapshot`; it only filters the snapshot for the selected worker.
- Generated controls are derived from server function metadata: pure reads
  render as Read, high-risk or approval-required abilities render as Guarded
  Run, and subagent workers render a Detail control backed by the subagent
  audit ref.
- The default worker detail sheet now exposes the expected operator state in
  the first viewport before raw audit history.
- Existing chat/action capability details remain audit-backed Work action
  details; they are not the primary worker mental model.

### Open Loops

- JARVIS-7 is closed for worker/detail sheets.
- JARVIS-9 below closes the docs/examples rewrite around workers and autonomous
  loops.
- JARVIS-10 owns broad static cleanup gates for remaining primary UI jargon and
  audit-only Engine Console ownership.
- JARVIS-11 owns paired-server soak/action proof and final visual closeout.

## JARVIS-9 Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_scorecard_invariants -- --nocapture` | 101 | Red proof: the new docs/examples invariant failed because the product docs still did not contain `worker-led autonomous work` or the worker-first required wording. |
| `rsync -a --delete --exclude=node_modules --exclude=.DS_Store packages/agent/skills/self-extend/ ~/.tron/skills/self-extend/` | 0 | Synced the managed `self-extend` skill after rewriting the repo-owned source copy. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_scorecard_invariants -- --nocapture` | 0 | Green proof: 2 static scorecard/docs invariant tests passed after the docs, examples, README map, and managed skill rewrite. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | 0 | Verified Rust formatting after updating the scorecard invariant. |
| `git diff --check` | 0 | Verified the docs/test diff has no whitespace errors. |
| `diff -u packages/agent/skills/self-extend/SKILL.md ~/.tron/skills/self-extend/SKILL.md` | 0 | Verified the installed managed skill copy matches the repo source exactly. |
| `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-docs-worker-first -only-testing:TronMobileTests/WorkDashboardViewTests` | 0 | Simulator proof after docs/example changes: 3 Work dashboard XCTest cases passed and emitted fresh iPhone/iPad dashboard plus worker-detail state-matrix artifacts. |
| `view_image .../work-dashboard-iphone-render.png`, `view_image .../work-dashboard-ipad-render.png`, `view_image .../worker-detail-blocked-render.png` | 0 | Visual inspection confirmed the fresh dashboard artifacts are readable/nonblank and the blocked-worker detail has no visible overlap. |

### Simulator Evidence

- Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`.
- Bundle under test: `TronMobile.app` from the `Tron` scheme, Beta simulator
  configuration.
- Fresh hosted artifacts from the JARVIS-9 simulator run:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/work-dashboard-iphone-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/work-dashboard-ipad-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/worker-detail-running-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/worker-detail-success-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/worker-detail-failure-render.png`, and
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/E4B63DFD-BD9B-462E-A6DE-53900B00FFED/Documents/tron-visual-artifacts/worker-detail-blocked-render.png`.
- The simulator app attempted to reconnect to the default local server
  `ws://127.0.0.1:19847/engine`; the server was not running, so logs include
  expected `NSURLErrorDomain Code=-1004` connection-refused warnings. The
  hosted render and source tests still passed.
- The in-thread tool registry exposed no simulator tap/computer-use control.
  Proof used `xcodebuild`, hosted SwiftUI rendering in the simulator process,
  emitted PNG artifacts, and local image inspection.

### Source Evidence

- [`README.md`](../../../README.md): living-doc map now describes the
  self-extending guides and local examples through worker-led autonomous work,
  the Work dashboard, Worker Packs, Generated Controls, and Audit Details.
- [`packages/agent/docs/self-extending-local-product-user-guide.md`](self-extending-local-product-user-guide.md):
  defines the user model as one orchestrator plus workers, with the Work
  dashboard as the main surface and raw protocol evidence in Audit Details.
- [`packages/agent/docs/self-extending-local-product-operator-guide.md`](self-extending-local-product-operator-guide.md):
  keeps `capability::execute` as the technical Work router while making
  worker creation, Worker Pack lifecycle, Generated Controls, and evidence refs
  the operator flow.
- [`packages/agent/docs/self-extending-local-product-troubleshooting.md`](self-extending-local-product-troubleshooting.md):
  troubleshoots workspace autonomy, worker registration, Worker Pack
  activation, Generated Controls, trust labels, and worker routing.
- [`packages/agent/docs/self-extending-local-product-release-notes.md`](self-extending-local-product-release-notes.md):
  recasts the completed productization notes in the worker-first vocabulary.
- [`packages/agent/examples/local-packs/README.md`](../examples/local-packs/README.md)
  plus the three example README files: presents the Tron Maintainer, Everyday
  Organizer, and Creative Knowledge examples as local Worker Packs.
- [`packages/agent/skills/self-extend/SKILL.md`](../skills/self-extend/SKILL.md):
  managed skill now asks agents to create local workers and Worker Packs,
  fetch live Worker Guide evidence, keep default autonomy run-unless-blocked,
  and report evidence in product terms.
- [`packages/agent/tests/worker_first_product_scorecard_invariants.rs`](../tests/worker_first_product_scorecard_invariants.rs):
  adds `worker_first_docs_and_examples_center_workers_and_local_work_loops`,
  requiring the new Worker Pack/Work dashboard/Audit Details vocabulary and
  rejecting retired capability-led docs or `git push`/`tron deploy` product
  paths.

### Findings

- Productization docs no longer sell capability chips, Created by Agent, or
  generic capability packs as the main user model. They define Work, Workers,
  Worker Packs, Autonomy, Guardrails, Generated Controls, and Audit Details.
- Technical capability names remain where they are actual server function
  names or operator evidence paths, but the product narrative is worker-first.
- No remote package discovery, publishing, production rollout, or deployment
  path was added to the local Worker Pack examples or managed self-extension
  guidance.
- The installed managed skill copy under `~/.tron/skills/self-extend/` was
  synchronized from the repo source after the edit.

### Open Loops

- JARVIS-9 is closed for docs/examples.
- JARVIS-1 and JARVIS-10 are closed by the cleanup/static-gate checkpoint
  below.
- JARVIS-11 owns paired-server soak/action proof and final visual closeout.

## JARVIS-10 / JARVIS-1 Closeout Evidence

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_static_gates -- --nocapture` | 101 | Red proof: the new cleanup gate failed while the old `packages/ios-app/Sources/Views/EngineConsole` ownership path still existed. |
| `git mv packages/ios-app/Sources/Views/EngineConsole/... packages/ios-app/Sources/Views/AuditDetails/...` plus matching `git mv` operations for state, cache, projection, and test files | 0 | Renamed the audit-only iOS ownership path from EngineConsole to AuditDetails and renamed Created-by-Agent projections to Worker Artifacts. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_static_gates -- --nocapture` | 0 | Green proof: the new Rust cleanup gate passed after the audit-only rename, primary Work vocabulary gate, and default no-prompt assertion. |
| `rg -n 'engineConsole\|EngineConsole\|Engine Console\|Created by Agent\|CreatedByAgent\|createdByAgent\|ConsoleSection\|consoleHeader\|title: "Engine"\|NavigationMode\\.engine' packages/ios-app/Sources packages/ios-app/Tests README.md packages/ios-app/docs/architecture.md packages/agent/tests/threat_model_invariants.rs packages/agent/tests/worker_first_product_static_gates.rs` | 0 | Confirmed old names only remain as intentional retired-string assertions in Rust static guards. |
| `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-audit-details-rename -only-testing:TronMobileTests/WorkDashboardViewTests -only-testing:TronMobileTests/AuditDetailsStateTests -only-testing:TronMobileTests/AuditDetailsWorkerPackProjectionTests -only-testing:TronMobileTests/AuditDetailsWorkerArtifactProjectionTests -only-testing:TronMobileTests/AuditDetailsCacheTests -only-testing:TronMobileTests/AuditDetailsAccessibilityTests -only-testing:TronMobileTests/AuditDetailsWorkerArtifactSourceGuardTests -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/IPadSheetPresentationTests` | 0 | Simulator proof: 13 XCTest cases and 36 Swift Testing cases passed after the rename and source guard updates. |
| `view_image .../work-dashboard-iphone-render.png`, `view_image .../work-dashboard-ipad-render.png`, `view_image .../worker-detail-blocked-render.png` | 0 | Visual inspection confirmed the fresh Work dashboard and blocked-worker detail artifacts were nonblank, readable, and free of visible overlap. |

### Simulator Evidence

- Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`.
- Result bundle:
  `/tmp/tron-xcode-audit-details-rename/Logs/Test/Test-Tron-2026.06.05_15-40-13--0700.xcresult`.
- Fresh hosted artifacts from the JARVIS-10 simulator run:
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/work-dashboard-iphone-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/work-dashboard-ipad-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/worker-detail-running-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/worker-detail-success-render.png`,
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/worker-detail-failure-render.png`, and
  `/Users/moose/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/43A1C55E-3ADC-4B7F-B1D5-ABF089197F88/Documents/tron-visual-artifacts/worker-detail-blocked-render.png`.
- The simulator app attempted to reconnect to
  `ws://127.0.0.1:19847/engine`; the server was not running, so logs include
  expected `NSURLErrorDomain Code=-1004` connection-refused warnings. The
  selected tests passed.
- The in-thread tool registry exposed no simulator tap/computer-use control.
  Proof used `xcodebuild`, hosted SwiftUI rendering in the simulator process,
  emitted PNG artifacts, and local image inspection.

### Source Evidence

- [`packages/agent/tests/worker_first_product_static_gates.rs`](../tests/worker_first_product_static_gates.rs):
  enforces the retired EngineConsole path absence, required AuditDetails path
  presence, primary Work vocabulary gate for `Substrate`, `Primer`,
  `Bindings`, and `Engine Console`, no Work/Agent client ownership of
  `CapabilityClient`, `ApprovalClient`, registry/policy/primer/approval
  internals, and default `approvalPromptMode = "disabled"`.
- [`packages/ios-app/Sources/Views/AuditDetails/AuditDetailsView.swift`](../../ios-app/Sources/Views/AuditDetails/AuditDetailsView.swift),
  [`packages/ios-app/Sources/ViewModels/State/AuditDetailsState.swift`](../../ios-app/Sources/ViewModels/State/AuditDetailsState.swift),
  and [`packages/ios-app/Sources/Services/Storage/AuditDetailsCache.swift`](../../ios-app/Sources/Services/Storage/AuditDetailsCache.swift):
  own the audit-only capability/operator inspection path under Audit Details.
- [`packages/ios-app/Sources/ViewModels/State/AuditDetailsWorkerArtifactProjection.swift`](../../ios-app/Sources/ViewModels/State/AuditDetailsWorkerArtifactProjection.swift)
  and [`packages/ios-app/Sources/Views/AuditDetails/AuditDetailsWorkerArtifactView.swift`](../../ios-app/Sources/Views/AuditDetails/AuditDetailsWorkerArtifactView.swift):
  replace the retired Created-by-Agent product label with Worker Artifacts.
- [`packages/ios-app/Sources/Views/Work/WorkDashboardView.swift`](../../ios-app/Sources/Views/Work/WorkDashboardView.swift):
  continues to expose a single Audit Details entry point and does not depend
  on the audit registry/policy/primer client stack.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md)
  and [`README.md`](../../../README.md): describe Audit Details as an
  audit-only/operator surface behind the Work dashboard rather than a primary
  Engine Console route.

### Findings

- No production iOS source path or identifier still owns the active product
  surface as EngineConsole.
- Primary Work UI rejects low-level `Substrate`, `Primer`, `Bindings`, and
  `Engine Console` vocabulary. Audit Details keeps those technical concepts
  behind the secondary audit entry point.
- The Work dashboard, Work state, and Agent client remain thin on
  `agent::work_snapshot`; they do not import capability/admin/policy/approval
  clients or function names.
- The Xcode project was regenerated after the file moves so simulator builds
  compile the AuditDetails sources directly.
- JARVIS-1 is now closed because the remaining primary UI vocabulary gate was
  implemented and passed as part of the JARVIS-10 cleanup.

### Open Loops

- JARVIS-10 is closed for cleanup/static gates.
- JARVIS-1 is closed for product vocabulary and primary UI gates.
- JARVIS-0 remains open for final combined visual baseline documentation.
- JARVIS-11 owns the paired-server soak/action proof and final closeout.
