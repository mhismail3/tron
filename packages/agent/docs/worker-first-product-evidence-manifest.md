# Worker-First Tron Product Evidence Manifest

Created: **2026-06-05**
Scorecard: [`worker-first-product-scorecard.md`](worker-first-product-scorecard.md)
Current score: **22/100**

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
| JARVIS-1 | running | Partial: provider-visible Worker Guide vocabulary replaced the old Capability Primer/harness wording; README context/worker-loop docs describe worker abilities and Audit. Primary UI static gates remain open. |
| JARVIS-2 | passed_after_fix | Default no-prompt autonomy, audited auto-decisions, testing prompts, fail-closed preflight, and replay behavior are covered by Rust tests. |
| JARVIS-3 | running | Partial: Worker Guide and execute schema default non-trivial work to worker/subagent delegation, provider-context tests prove guide injection, and integration proof fans out two session workers without approvals. Subagent Worker projection remains open. |
| JARVIS-4 | passed_after_fix | `agent::work_snapshot` is registered and covered by DTO tests for idle state, active work, worker health, milestones, guardrails, and audit refs. |
| JARVIS-5 | pending | Not started. |
| JARVIS-6 | pending | Not started. |
| JARVIS-7 | pending | Not started. |
| JARVIS-8 | running | Autonomy prompt setting parity, default copy, and simulator render proof are implemented and tested; Guardrails UX/action checks remain open. |
| JARVIS-9 | pending | Not started. |
| JARVIS-10 | pending | Not started. |
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

- [`README.md`](../../../README.md): current root product wording still says
  the iOS app provides a chat and Engine Console harness over server-owned
  substrate.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md):
  current iOS architecture lists `NavigationMode.engine`, Engine Console
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

- Current primary iOS source still includes `NavigationMode.engine` and Engine
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

- JARVIS-8 still needs plain Guardrails settings UX and paired-server simulator
  action checks before receiving points.
- JARVIS-5 still owns the default iOS Work dashboard replacement that consumes
  `agent::work_snapshot`.

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

### Open Loops

- JARVIS-1 still needs primary UI vocabulary gates after Work dashboard/chat
  replacement removes the Engine Console path.
- JARVIS-3 still needs live subagent instances projected as product Workers in
  the Work snapshot/detail model before points can be awarded.
