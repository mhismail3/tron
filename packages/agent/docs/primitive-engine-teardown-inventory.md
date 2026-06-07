# Primitive Engine Teardown Inventory

Created: 2026-06-07

Scorecard row: PET-1, primitive taxonomy and deletion inventory.

PET-1 status: `passed_after_fix`

Classification vocabulary: `retain`, `delete`, `successor`.

This inventory is the deletion map for the primitive-engine branch. It is not a
product roadmap. A `retain` entry must be required for the bare provider loop,
session/event truth, execution primitive, agent-owned state, observability, or
client shell. A `delete` entry is hard-coded product/tool/policy/UI surface that
must disappear from startup, model context, fresh storage, and primary iOS UI. A
`successor` entry may be recreated later only as agent-owned state or generated
runtime behavior after this branch proves the bare loop.

## Source Audit Commands

All commands were run from `/Users/moose/Downloads/projects/tron` on
`codex/primitive-engine-teardown`.

| Evidence | Command | Exit |
|----------|---------|------|
| Git branch/worktree | `git status --short --branch` | 0 |
| Rust domain roots | `find packages/agent/src/domains -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` | 0 |
| Domain registration list | `sed -n '1,180p' packages/agent/src/domains/registration.rs` | 0 |
| Engine primitive workers | `rg -n "pub\\(crate\\) const .*_WORKER_ID\|pub\\(crate\\) mod" packages/agent/src/engine/primitives/mod.rs` | 0 |
| Runner context planes | `sed -n '1,140p' packages/agent/src/domains/agent/runner/context/mod.rs` | 0 |
| Managed skills absence | `test ! -d packages/agent/skills` | 0 |
| Agent docs | `find packages/agent/docs -maxdepth 1 -type f \| sort` | 0 |
| iOS top-level views | `find packages/ios-app/Sources/Views -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` | 0 |
| iOS service/model roots | `find packages/ios-app/Sources/{Services,Models} -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` | 0 |
| Settings type roots | `find packages/agent/src/domains/settings/implementation/types -type f -name '*.rs' -maxdepth 1 -print \| sort` | 0 |
| Settings UI parity | `rg -n "SettingsPage\|SettingsState\|ServerSettings" packages/ios-app/Sources/Views/Settings packages/ios-app/Sources/ViewModels/State/SettingsState.swift packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes+Settings.swift` | 0 |

The covering gate was added first and failed red before this file existed:
`cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
returned exit 101 with
`primitive_engine_teardown_inventory_stays_exhaustive` failing on the missing
inventory file.

## Rust Domain Inventory

PET-1 recorded the product-era domain map before deletion. After PET-10, the
current retained domain roots are `agent`, `auth`, `blob`, `capability`, `logs`,
`message`, `model`, `session`, `settings`, and `system`. Rows for deleted
product domains and collapsed support boundaries remain here only as deletion
evidence and PET-11 re-audit targets.

PET-11's interim hosted-tool/computer-use checkpoint further removed the
OpenAI hosted search/computer-call DTO and stream variants, stale iOS capability
catalog DTO/rendering support, the fixed iOS SessionTree projection, and Mac
Screen Recording/Accessibility onboarding gates. It also collapsed the
top-level `capability_support` domain into the agent runner's primitive surface
resolver. Remaining PET-11 successor rows below still need final retain/delete
proof before closeout.

| Domain | Class | Teardown decision |
|--------|-------|-------------------|
| `agent` | retain | Keep the minimal turn runner, prompt entry, queue handoff, and crash recovery needed for the provider loop. Delete Work dashboard, run-goal product flows, subagent product policy, worker guide projections, and fixed autonomy DTOs. |
| `auth` | retain | Keep provider credential/profile loading, masked auth reads, and local secret handling required before the first model call. Delete product OAuth/update surfaces that are not needed for bootstrap. |
| `blob` | retain | Keep payload/blob resolution for event, resource, and invocation evidence. |
| `browser` | delete | First-party browser/computer-use product capability. Any future browser helper must be agent-authored runtime state. |
| `capability` | retain | Keep only the model-facing `execute` primitive. Delete search, inspect, status, registry snapshot, bindings, plugins, conformance, recipes, vector search, and policy-profile orchestration. |
| `capability_support` | delete | PET-11 collapsed this non-domain support boundary into `domains/agent/runner/agent/primitive_surface.rs`. The provider-visible `execute` surface and per-call scheduling remain agent-runner primitives; the top-level domain root and separate scheduling module are deleted. |
| `context` | delete | The public `context::*` capability plane is deleted. Minimal prompt context assembly, budgeting, compaction, and state/session summaries survive only under the agent runner infrastructure. |
| `cron` | delete | Hard-coded scheduling/automation product plane. Future scheduling must be agent-owned state. |
| `device` | delete | Push/device product workflow. APNs, device-token registration, and relay delivery are deleted; pairing and transport safety remain outside this domain if needed. |
| `display` | delete | Fixed display/computer-use side channel. |
| `events` | delete | Product event capability wrapper. Session/stream storage remains infrastructure, not a model-facing events namespace. |
| `filesystem` | delete | First-party file capability catalog. The retained execution primitive may use bounded host file operations internally. |
| `git` | delete | Source-control product capability. |
| `import` | delete | Product import workflow. |
| `job` | delete | Product job capability wrapper. Engine queue infrastructure remains. |
| `logs` | retain | Keep compact retained-log storage/ingest as observability evidence and expose bounded reads only through `execute.log_recent`. Delete fixed diagnostics APIs, upload policy, and generic query abstractions not needed by the loop. |
| `mcp` | delete | Product protocol and external tool catalog plane. |
| `memory` | delete | Replace hard-coded memory retain/auto-retain with agent-owned state workspace. |
| `message` | retain | Keep message/session truth needed for the chat loop. |
| `model` | retain | Keep provider clients, provider protocol normalization, token/cost accounting, model settings, and streaming/tool-call assembly. |
| `notifications` | delete | Product notification capability, notification inbox/delivery UI, APNs registration, and push relay path are deleted. |
| `plan` | delete | Built-in planning product capability. |
| `process` | delete | First-party process capability catalog. The retained `execute` host may run bounded commands internally without exposing `process::*`. |
| `program` | successor | Delete the registered product capability. Reuse only if PET-7 proves a generic helper runtime that is not a first-party worker-pack lifecycle. |
| `prompt_library` | delete | Product prompt history/snippet surface and settings. |
| `repo` | delete | Product repo/session discovery surface. |
| `sandbox` | successor | Delete `sandbox::*` and `worker::spawn` product lifecycle from startup. Reuse only as a smaller generic helper process substrate if PET-7 proves it. |
| `self_extension` | delete | Product workspace-autonomy grant workflow. Future self-extension must start from agent-owned state and generic execute substrate. |
| `session` | retain | Keep session create/resume/list/reconstruct/delete truth needed by transport and iOS shell. Trim branch/fork/tree/product projections that do not serve the bare loop. |
| `settings` | retain | Keep provider/auth/server/bootstrap settings. Delete capability, skills, hooks, guardrail, prompt-library, protected-branch, and product policy settings. |
| `skills` | delete | Built-in skill discovery, activation, prompt injection, session tracking, and iOS skill surface. |
| `system` | retain | Keep health/ping/info needed by transports and lifecycle. Delete update/product command surfaces unless Mac bootstrap proves infrastructure ownership. |
| `transcription` | delete | Product voice/transcription capability. |
| `tree` | delete | Product session tree visualization wrapper. Minimal session navigation can query session truth directly. |
| `voice_notes` | delete | Product voice-note workflow. |
| `web` | delete | First-party web fetch/search product capability. |
| `worktree` | delete | Product worktree/source-control workflow. |

## Engine Primitive Worker Inventory

Primitive workers are engine-owned, but several have grown into product planes.
PET-3/PET-5/PET-7 must collapse them to loop infrastructure.

| Worker | Class | Teardown decision |
|--------|-------|-------------------|
| `stream` | retain | Event stream truth for transport subscriptions and evidence. |
| `state` | retain | Candidate substrate for the agent-owned state workspace. |
| `queue` | retain | Crash-safe turn and trigger progress. Delete product queue affordances. |
| `resource` | retain | Durable refs/versions for state, evidence, assistant outputs, and generated surfaces. |
| `trigger` | retain | Keep only transport/queue trigger infrastructure required by the loop. Delete cron/product trigger registrations. |
| `grant` | retain | Keep minimal host integrity and scoped authority records. Delete product trust-tier and worker-pack policy assumptions. |
| `approval` | delete | Approval prompts and policy workflow are product-coded. Keep no approval prompt plane unless reduced to a hard infrastructure block for irreversible host risk. |
| `catalog` | retain | Keep internal registry mechanics only if needed by host dispatch; do not expose model-facing catalog discovery. |
| `control` | delete | Product operator dashboard/control snapshot. |
| `worker` | successor | Retain only if PET-7 reduces it to generic helper connection/disconnection substrate. |
| `observability` | retain | Invocation records, Agent Trace-style records, retained logs, and failure evidence for proof and debugging. |
| `storage` | retain | SQLite stats/checkpoint/snapshot infrastructure. Delete product storage controls. |
| `ui` | successor | Keep or replace only as a tiny generic dynamic-surface resource renderer. Delete fixed generated UI targets tied to product domains. |
| `module` | delete | Worker-pack package/config/activation/trust/conformance lifecycle is product-coded. |

## Runner Context Plane Inventory

The context module currently documents rules, hooks, prompt overlays, and local
policy. PET-4/PET-6 must leave only soul, session history, compact state summary,
and minimal provider/runtime accounting.

| Plane | Class | Teardown decision |
|-------|-------|-------------------|
| `context_manager` | retain | Minimal lifecycle and context assembly entry point. |
| `context_snapshot_builder` | retain | Keep only if it builds bare soul/session/state summaries. |
| `compaction_engine` | retain | Summarize old session/state context for provider budgets. |
| `llm_summarizer` | retain | Keep only if it remains provider-loop infrastructure. |
| `summarizer` | retain | Infrastructure interface for compaction recovery. |
| `message_store` | retain | Session message buffer and reconstruction support. |
| `loader` | delete | Project/global rules overlay loader. |
| `local_policy` | delete | Profile-backed local-model capability allow-list and policy plane. |
| `rules_discovery` | delete | Path-scoped hard-coded rules discovery. |
| `rules_index` | delete | Rule lookup/index plane. |
| `rules_tracker` | delete | Per-session rule activation tracking. |
| `instruction_prompts` | delete | Prompt overlay loading beyond the static soul seed. |
| `token_estimator` | retain | Provider/context budget infrastructure. |
| `path_extractor` | retain | Keep only if needed for session workspace context; delete product path heuristics. |
| `constants` | retain | Minimal provider/context budgets only. |
| `types` | retain | Shared context types after product fields are removed. |
| `guardrails` | delete | Runner guardrail product policy plane. |
| `hooks` | delete | Built-in/user hook policy plane. |
| `subagents` | delete | Product subagent orchestration; successor may rebuild from generic helper substrate. |

## First-Party Managed Skill Inventory

All first-party managed skill directories under `packages/agent/skills/` are
classified `delete`. The primitive branch must not seed toolbox behavior through
checked-in skills. Successor work may recreate useful skills as agent-authored
state after bootstrap.

| Skill | Class | Teardown decision |
|-------|-------|-------------------|
| `browse-the-web` | delete | Built-in product skill. |
| `explore` | delete | Built-in product skill. |
| `find-skill` | delete | Skill discovery assumes the skill plane. |
| `generate` | delete | Built-in generation product skill. |
| `git-sync` | delete | Source-control product skill. |
| `google-workspace` | delete | Product integration skill. |
| `heal-skill` | delete | Skill-plane maintenance helper. |
| `humanizer` | delete | Product style skill. |
| `knowledge` | delete | Product knowledge workflow. |
| `manage-automations` | delete | Product automation skill. |
| `old-english` | delete | Product style skill. |
| `plan` | delete | Product planning skill. |
| `publish-website` | delete | Product publishing skill. |
| `sandbox` | delete | Product sandbox skill. |
| `self-deploy` | delete | Deployment skill; production deploy remains user-only and out of scope. |
| `self-extend` | delete | Product self-extension skill. |
| `self-inspect` | delete | Product database inspection skill; PET rows may query DB directly as evidence. |
| `twitter` | delete | Product integration skill. |
| `vault` | delete | Product secret workflow skill. Secrets stay in profile/vault infrastructure, not model context. |

## Documentation Inventory

PET-9 rewrote or deleted product docs so the branch documents only runnable
bare-loop behavior and active deletion evidence. Retired scorecards and guides
are deleted rather than kept as historical source files on this branch.

| Document | Class | Teardown decision |
|----------|-------|-------------------|
| `capability-orchestration-test-scorecard.md` | delete | Historical evidence for the old catalog/execute orchestration. |
| `codebase-cleanup-scorecard.md` | delete | Historical cleanup evidence with product-era architecture references; primitive branch keeps only the active teardown artifacts. |
| `collapsed-engine-hardening-scorecard.md` | delete | Superseded by the active primitive teardown scorecard. |
| `context-architecture.md` | delete | Describes rule/policy context planes that PET-4/PET-6 remove. |
| `engine-redesign/` | delete | Approval/guardrail-era design set superseded by the primitive teardown plan. |
| `hyper-modular-agent-architecture-scorecard.md` | delete | Planning doc for worker-pack/harness product architecture. |
| `hyper-modular-agent-harness-execution-scorecards.md` | delete | Active product harness portfolio; incompatible with primitive branch. |
| `ipad-action-time-followup-scorecard.md` | delete | Product UI action follow-up. |
| `legacy-fallback-cleanup-pass-scorecard.md` | delete | Superseded by PET-10/PET-11 absence gates. |
| `post-100-ipad-ui-regression-scorecard.md` | delete | Product UI regression evidence no longer runnable. |
| `post-100-operating-conditions-scorecard.md` | delete | Product operating evidence no longer runnable. |
| `post-scorecard-gap-hardening-scorecard.md` | delete | Superseded by PET-10/PET-11 absence gates. |
| `primitive-engine-teardown-evidence-manifest.md` | retain | Active evidence manifest for this campaign. |
| `primitive-engine-teardown-inventory.md` | retain | PET-1 deletion map. |
| `primitive-engine-teardown-scorecard.md` | retain | Active teardown scorecard. |
| `profile-control-plane.md` | delete | Product profile/control-plane doc must be rewritten around provider/bootstrap settings only. |
| `self-extending-local-product-operator-guide.md` | delete | Product guide for removed worker packs/generated controls. |
| `self-extending-local-product-release-notes.md` | delete | Product notes for removed surfaces. |
| `self-extending-local-product-troubleshooting.md` | delete | Product troubleshooting for removed surfaces. |
| `self-extending-local-product-user-guide.md` | delete | Product guide for removed surfaces. |
| `token-accounting-hardening-scorecard.md` | delete | Provider accounting is retained in code/tests; the old phase scorecard is not branch truth. |
| `tron-productization-evidence-manifest.md` | delete | Productization evidence for removed surfaces. |
| `tron-productization-scorecard.md` | delete | Productization plan superseded by primitive teardown. |
| `worker-first-product-evidence-manifest.md` | delete | Product evidence for removed Work/Worker Pack surfaces. |
| `worker-first-product-scorecard.md` | delete | Product scorecard for removed worker-first branch. |

## iOS Top-Level Source Inventory

PET-8 must turn iOS into a prompt/session/connection shell plus generic dynamic
runtime output. These package roots are the top-level source cleanup map.

| Source root | Class | Teardown decision |
|-------------|-------|-------------------|
| `App` | retain | Keep app lifecycle, dependency boot, and connection shell. |
| `Assets.xcassets` | retain | Keep minimal app icons/logo/accent assets; delete provider/product icons no longer visible. |
| `Core` | retain | Keep concurrency, DI, event plumbing used by the shell. |
| `Database` | retain | Keep local cache for sessions/messages/settings needed by offline shell. Delete product projection tables. |
| `Extensions` | retain | Keep generic SwiftUI/util extensions used by shell. |
| `IconLayers` | delete | Product visual asset generator unless app icon requires it. |
| `Models` | retain | Keep EngineProtocol, Messages, Tokens. Delete Dashboard, Features, product DTOs. |
| `Protocols` | retain | Keep only shell/service protocols. |
| `Resources` | retain | Keep required fonts/resources only. |
| `Services` | retain | Keep Network, Storage, Settings, Events, Observability, Onboarding, and paired-server bootstrap. Audio/transcription, plugin-source, APNs, notification-store, push-relay clients, and fixed diagnostics RPCs are deleted. |
| `Theme` | retain | Keep minimal accessible styling. |
| `Utilities` | retain | Keep only generic shell utilities. |
| `ViewModels` | retain | Keep chat/session/settings state. Delete fixed product handlers and projections. |
| `Views` | retain | Keep chat/session/settings/onboarding/generic dynamic renderer. Delete fixed product directories listed below. |

## iOS Primary View Inventory

| View root | Class | Teardown decision |
|-----------|-------|-------------------|
| `AgentControl` | delete | Fixed product control surface. |
| `Attachments` | retain | PET-11 proved this is bare prompt-input infrastructure for images, PDFs, and documents. The legacy image-only prompt DTO/request path is deleted; all media flows through unified attachments. |
| `AuditDetails` | successor | Delete fixed audit/worker-pack views. Reuse only generic dynamic-surface rendering if it is decoupled from product targets. |
| `Capabilities` | successor | Retained files must be generic invocation/runtime evidence for the one `execute` primitive. PET-11's interim checkpoint deleted catalog/status/search/inspect/recipe/program/audit/policy DTOs and product-specific result summaries; remaining capability identity/event/display fields still need final retain/delete proof. |
| `Chat` | retain | Primary prompt and assistant output shell. |
| `Components` | retain | Shared generic UI components only. |
| `DynamicSurfaces` | retain | Generic runtime surface rendering for agent-authored UI state. PET-11 must verify no fixed product target leaks through this retained renderer. |
| `EngineApproval` | delete | Product approval prompts; infrastructure blocked state can render as plain message. |
| `InputBar` | retain | Keep prompt composer and attachment entry points. Skills, prompt-library, voice/audio, and fixed action product buttons are deleted. |
| `MessageBubble` | retain | Keep message rendering and generic runtime output. Delete capability/product-specific cards. |
| `Notifications` | delete | Product notification surface. |
| `Onboarding` | retain | Keep server pairing/provider setup needed to reach the loop. |
| `Process` | delete | PET-11 deleted the fixed iOS process dashboard, live `process.*` plugins, `ProcessState`, process sheet, and process-specific result viewer. The retained `process_run` primitive renders through generic capability evidence and trace records. |
| `PromptLibrary` | delete | Product prompt library UI. |
| `Session` | retain | Keep session list/create/resume/delete. Delete clone/worktree/session analytics/product cards. |
| `SessionTree` | delete | PET-11 deleted the fixed iOS session-tree view root, local `TreeRepository`, `EventTreeBuilder`, fork-row visualization, icon catalog, and tests. Session navigation and fork lineage remain only as session/event truth reconstructed through generic session repositories and event queries. |
| `Settings` | retain | Keep connection/provider/server settings plus quick-session, prompt queue, and compaction controls. Agent autonomy, guardrails, hooks, skills, plugin sources, memory/rules, prompt-library, protected branch, and capability settings are deleted. |
| `Skills` | delete | Skill management UI. |
| `SourceChanges` | delete | Source-control product UI. |
| `Subagents` | delete | Product subagent UI. |
| `System` | retain | Keep minimal connection/error sheets. Fixed diagnostics DTOs and RPCs are deleted; runtime evidence comes from trace records, retained logs, and generic capability evidence. |
| `UserInteraction` | delete | PET-11 deleted the bespoke prompt/answer sheet, transformer, coordinator, state, viewer, submit-answer client method, pause plugins, and tests. Future interaction must be agent-authored generated UI/action state, not a hard-coded mid-turn prompt plane. |
| `VoiceNotes` | delete | Product voice note UI. |
| `Work` | delete | Worker-first dashboard. |

## Settings Surface Inventory

The settings parity rule remains, but the primitive branch must shrink the
server settings shape and iOS controls together.

| Surface | Class | Teardown decision |
|---------|-------|-------------------|
| `api.rs` | retain | Provider/API request tuning needed by provider loop. |
| `capabilities.rs` | delete | Product capability knobs for process/filesystem/browser/web/computer-use. |
| `context.rs` | retain | Keep compactor/token budget fields. Delete `rules.discoverStandaloneFiles`. |
| `git.rs` | delete | Protected-branch and source-control settings. |
| `guardrails.rs` | delete | Product guardrail rules/audit settings. |
| `memory.rs` | delete | Auto-retain memory settings. Agent-owned state replaces it. |
| `prompt_library.rs` | delete | Prompt-history/snippet settings. |
| `server.rs` | retain | Provider/default model/default workspace/Tailscale/bootstrap and retained-log policy only. Transcription, product update bootstrap, payload capture level, and inline payload byte settings are deleted. |
| `skills.rs` | delete | Skill discovery/injection settings. |
| `ui.rs` | retain | Keep appearance/accessibility basics only. Delete product dashboard settings. |
| `update.rs` | delete | PET-11 deleted the user-mode updater settings enums/schema. Product update checks are not needed before the first model call and are not primitive loop infrastructure. |
| `SettingsState.swift` | retain | Keep only fields matching retained server settings. |
| `EngineProtocolTypes+Settings.swift` | retain | Decode/update only retained server settings. |
| `ConnectionSettingsPage.swift` | retain | Keep server pairing/provider/bootstrap controls. |
| `AgentSettingsPage.swift` | retain | Retain only quick-session defaults and server-owned queued-message controls. Autonomy, guardrails, hooks, prompt library, protected branches, and plugin-source policy are deleted. |
| `SettingsView` and shared setting components | retain | Keep shell navigation/components after product pages are removed. |

## Deletion Checkpoint Order

1. PET-2/PET-3: shrink backend startup to boot/provider/session/message/logs and one model-facing `execute`; delete registered product namespaces and old registry/recipe/binding/conformance paths.
2. PET-4/PET-6: replace rules, skills, hooks, guardrails, prompt overlays, and memory retain with a static soul plus agent-owned state workspace.
3. PET-5/PET-7: collapse fresh storage and helper substrate so old product tables/resources/events are absent, and any helper runtime is generic substrate only.
4. PET-8: delete fixed iOS product modes and prove the primitive shell on iPhone and iPad.
5. PET-9/PET-10: rewrite docs/assets, add absence gates, and remove dead source until focused Rust/iOS proof is warning-free.
6. PET-11: run closeout proof and re-audit all retained/successor rows for leftover removable code.

## Open Loops After PET-10

- PET-11 proved retained iOS `Attachments` are prompt-input infrastructure and
  deleted the legacy image-only prompt DTO/request path. PET-11 also deleted
  the fixed iOS `SessionTree` projection; session fork lineage remains only as
  generic session/event truth. PET-11 must still audit retained iOS
  `Capabilities` source from first principles. The hard-coded
  `UserInteraction` prompt/answer plane and fixed process dashboard were
  deleted during PET-11.
- PET-11 decided that `session_drafts.skills_json` was stale product DTO
  residue and deleted it from fresh iOS draft storage. PET-11 also deleted
  `EngineProtocolTypes+Repo.swift` and `EngineProtocolTypes+Task.swift` after
  proving they were unreferenced product DTO residue.
- PET-11 collapsed the former `capability_support` row into agent-runner
  `primitive_surface`, deleted the product update-check surface from server,
  iOS, Mac, scripts, docs, and bundled default settings, and flattened
  diagnostics/logging to retained-log storage plus `execute.log_recent`.
  PET-11 also flattened dynamic-surface rendering to schema-versioned runtime
  resources and deleted server-owned target authoring/catalog/refresh policy.
- PET-11 may close only after a fresh end-to-end loop proof and after no
  retained/successor row can be deleted without breaking
  boot/provider/session/execute/state/trace/client-shell primitives.
