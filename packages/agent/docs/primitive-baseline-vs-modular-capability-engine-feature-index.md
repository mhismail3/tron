# Primitive Baseline vs Modular Capability Engine Feature Index

Date: 2026-06-13

Current frozen baseline: `73706ff874d3791cd929d7f7f18c7848378963dd`

Comparison point: `ad5e484722c6f7abbe764126409494026216ad92`

Frozen refs:

- Branch: `codex/primitive-baseline-2026-06-13`
- Tag: `primitive-baseline-2026-06-13`
- Working branch used for this report: `codex/primitive-minimality-closure-current`

## Purpose

This report indexes the server and iOS functionality that existed at
`ad5e4847` on `next/modular-capability-engine` and is absent, reduced, or
genericized in the current primitive baseline. It is intentionally a feature
index, not a reimplementation plan. The next phase can use it to add features
back one at a time while preserving the current modular, plug-and-play engine
shape.

## Method

Evidence was gathered from repository state, not chat history:

- File-tree comparison between `ad5e4847` and current baseline.
- Domain root and engine root directory comparison.
- Domain `CapabilityContract::new(...)` extraction from both revisions.
- Current primitive `capability::execute` operation inspection.
- iOS `Sources/` tree comparison and removed UI/service/model family counts.
- Default profile settings comparison.
- Agent dependency comparison from `packages/agent/Cargo.toml`.
- Managed skill directory comparison.
- Protocol event constructor grep as a broad surface indicator.
- Current baseline validation evidence from the preceding closure work.

Static comparison has limits: it proves surface presence or absence, not old
runtime quality. Treat every item below as a feature candidate that must be
reintroduced behind current engine authority, durability, replay, transport, and
iOS generic runtime boundaries.

## Baseline Summary

The current baseline is intentionally smaller and harder:

- Server domain roots moved from 36 old roots to 11 current roots.
- First-class domain contracts moved from 187 old IDs to 41 current IDs.
- 40 first-class domain contracts overlap.
- 147 old first-class domain contracts are absent.
- `session::replay_manifest` and the `catalog_discovery::{search,inspect,conformance_report}`
  contracts are current first-class domain contracts absent from the frozen
  primitive baseline.
- Current provider-visible model surface is the single `capability::execute`
  primitive.
- Current execute operations are `observe`, `state_get`, `state_set`,
  `state_list`, `file_read`, `file_write`, `process_run`, `trace_list`,
  `trace_get`, `log_recent`, `replay_manifest`, `catalog_search`,
  `catalog_inspect`, and `catalog_conformance`.
- iOS moved from product-specific `Core`, `Database`, `Models`, `Services`,
  `ViewModels`, and `Views` trees to a thinner `Engine`, `Session`, `Support`,
  and `UI` runtime shell.

The old tree had many useful product features, but they were coupled to fixed
server domains, fixed iOS panels, profile knobs, managed skills, and worker
bootstrap assumptions. The current tree has fewer capabilities, but it has a
clearer substrate for modular reintroduction.

## Current Retained Server Surface

Retained first-class domain contracts:

- `agent::abort`
- `agent::abort_invocation`
- `agent::prompt`
- `agent::prompt_apply`
- `agent::run_turn`
- `agent::status`
- `auth::clear`
- `auth::get`
- `auth::oauth_begin`
- `auth::oauth_complete`
- `auth::remove_account`
- `auth::remove_api_key`
- `auth::rename_account`
- `auth::set_active`
- `auth::update`
- `blob::get`
- `catalog_discovery::conformance_report`
- `catalog_discovery::inspect`
- `catalog_discovery::search`
- `logs::ingest`
- `logs::recent`
- `message::delete`
- `model::list`
- `model::switch`
- `session::archive`
- `session::archive_older_than`
- `session::create`
- `session::delete`
- `session::export`
- `session::fork`
- `session::get_head`
- `session::get_history`
- `session::get_state`
- `session::list`
- `session::reconstruct`
- `session::replay_manifest`
- `session::resume`
- `session::unarchive`
- `settings::get`
- `settings::reset_to_defaults`
- `settings::update`
- `system::get_info`
- `system::ping`
- `system::shutdown`

Retained primitive substrate areas:

- Engine authority, invocation, kernel, runtime, durability, catalog, and
  primitive infrastructure.
- Engine state, stream, queue, trigger, resource, grant, storage, catalog,
  worker, trace, log, and replay internals.
- Session event persistence and reconstruction.
- Provider streaming loop and capability invocation plumbing.
- Basic auth, model selection, settings, logging, blob retrieval, message
  delete, and system health/info/shutdown.
- External worker host infrastructure for already-running workers, without the
  old helper-launch/product-worker loop.

## Current Retained iOS Surface

Retained iOS areas:

- Server onboarding and pairing.
- Local paired-server storage and Keychain token storage.
- Engine WebSocket transport and typed client repositories.
- Chat/session shell, message rendering, prompt input, attachments, and local
  reconstruction.
- Settings, provider/auth cards, model/workspace setup, and reconnect flows.
- Diagnostics, local logs, feedback bundle generation, and server log ingest.
- Generic capability result rendering and generic runtime surfaces.
- System and support UI shared components.

## Missing Feature Index

Each section lists the missing feature area, the old surface, the current state,
and the reintroduction constraint.

### 1. Capability Discovery, Routing, and Intent Execution

Old surface:

- Intent-first `capability::execute` that accepted intent, optional target,
  arguments, constraints, idempotency key, and reason.
- Capability registry search and inspection.
- `capability::search` and `capability::inspect` operator/internal functions.
- Local vector search over capability metadata.
- Schema correction and canonicalization.
- `needs_selection`, `needs_input`, `needs_decomposition`, approval/freshness,
  and repair guidance flows.
- Generated Worker Guide and capability primers in model context.
- Capability conformance runs and conformance evidence resources.

Current state:

- Provider sees one `execute` tool with explicit primitive operation names.
- There is no intent resolver, target selector, capability metadata search, or
  model-visible capability catalog.
- `fastembed` and `sqlite-vec` were removed, confirming the local embedding
  registry/search layer is gone.

Reintroduction constraint:

- Discovery should be a modular catalog/resource service, not a return to a
  large provider-visible tool list.
- Intent resolution needs replayable decisions, schema evidence, and
  conformance tests per registered module.

### 2. Filesystem Capability Suite

Old surface:

- `filesystem::read_file`
- `filesystem::write_file`
- `filesystem::list_dir`
- `filesystem::create_dir`
- `filesystem::find`
- `filesystem::glob`
- `filesystem::search_text`
- `filesystem::edit_file`
- `filesystem::diff`
- `filesystem::apply_patch`
- `filesystem::get_home`
- Resource-backed file writes, diffs, patch proposals, and materialized output
  references.

Current state:

- Primitive `file_read` and `file_write` exist under `capability::execute`.
- No first-class filesystem domain, search, glob, edit, diff, patch, directory
  creation, or home-directory helper remains.

Reintroduction constraint:

- Bring back as a bounded filesystem module with authority scopes, path
  normalization, diff evidence, and patch replay records.

### 3. Process, Jobs, and Sandbox Execution

Old surface:

- `process::run` with richer run policy.
- Read-only versus sandbox-materialized execution paths.
- Expected output declarations and output materialization.
- Allowlisted environment behavior.
- Background job lifecycle:
  - `job::background`
  - `job::cancel`
  - `job::list`
  - `job::stream_output`
  - `job::subscribe`
  - `job::unsubscribe`
  - `job::wait`
- PTY/process dependency support through `portable-pty`.

Current state:

- Primitive `process_run` exists, but the old first-class `process::run`,
  background job domain, PTY support, and output materialization policies are
  absent.

Reintroduction constraint:

- Separate synchronous primitive shell execution from a durable job subsystem.
- Jobs need stream replay, cancellation semantics, resource accounting, and
  authority checks before iOS can expose process UI again.

### 4. Web, Browser, and Research Fetching

Old surface:

- `web::search`
- `web::fetch`
- `browser::get_status`
- HTML parsing and conversion through `scraper` and `html2text`.
- Streaming event-source dependency support.
- Managed `browse-the-web` skill.

Current state:

- No first-class web or browser domains.
- No web search/fetch primitive operation.
- `scraper`, `html2text`, and `eventsource-stream` were removed.

Reintroduction constraint:

- Web access should be a module with source provenance, fetch cache policy,
  redaction boundaries, and explicit network authority. It should not be
  smuggled into general process execution.

### 5. Worktree, Git, and Source-Control Workflow

Old surface:

- Worktree lifecycle:
  - `worktree::acquire`
  - `worktree::release`
  - `worktree::list`
  - `worktree::get_status`
  - `worktree::get_diff`
  - `worktree::get_diff_summary`
  - `worktree::get_committed_diff`
  - `worktree::finalize_session`
  - `worktree::is_git_repo`
- Branch and merge operations:
  - `worktree::commit`
  - `worktree::merge`
  - `worktree::start_merge`
  - `worktree::continue_merge`
  - `worktree::abort_merge`
  - `worktree::rebase_on_main`
  - `worktree::delete_branch`
  - `worktree::prune_branches`
  - `worktree::list_session_branches`
- Conflict handling:
  - `worktree::list_conflicts`
  - `worktree::resolve_conflict`
  - `worktree::resolve_conflicts_with_subagent`
- Staging and discard:
  - `worktree::stage_files`
  - `worktree::unstage_files`
  - `worktree::discard_files`
- Git helpers:
  - `git::clone`
  - `git::sync_main`
  - `git::push`
  - `git::list_local_branches`
  - `git::list_remote_branches`
- iOS SourceChanges views for branch picking, diffs, staging, commit, merge,
  push, pull, rebase, and conflict resolution.

Current state:

- No worktree or git domain roots.
- No fixed iOS source-control panels.
- Plain primitive file/process operations can inspect a repository but do not
  provide source-control workflow semantics.

Reintroduction constraint:

- Worktree state should be a module-owned resource graph, not hidden session
  state. Every branch, diff, merge, and conflict decision needs durable evidence
  and replayable causality.

### 6. Worker Launch, Sandbox Workers, and Self-Extension

Old surface:

- `worker::spawn`
- `spawn_worker`
- `sandbox::list_spawned_workers`
- `sandbox::get_spawned_worker`
- `sandbox::stop_spawned_worker`
- `self_extension::grant_workspace_autonomy`
- Worker protocol guide and runtime-authored worker loop.
- Worker pack runtime and local packs.
- Sandbox-created capabilities, child grants, expected function IDs, source
  trust, and generated UI surfaces.

Current state:

- Engine worker primitives and `/engine/workers` host infrastructure remain for
  already-running external workers.
- The old helper launch loop, sandbox worker lifecycle, first-party worker
  packs, and self-extension grant surface are gone.

Reintroduction constraint:

- Worker launch must be separated from worker protocol hosting. A successor
  launch module needs source provenance, install/update/uninstall boundaries,
  signed or auditable package identity, grant derivation, and conformance tests.

### 7. Subagents and Parallel Work Orchestration

Old surface:

- `agent::spawn_subagent`
- `agent::subagent_status`
- `agent::subagent_result`
- `agent::cancel_subagent`
- Model presets and task profiles.
- Result resources.
- iOS subagent chips, detail sheets, result views, and status views.

Current state:

- No subagent first-class contracts.
- Agent loop is focused on one session turn path and primitive execution.

Reintroduction constraint:

- Subagents should be modeled as durable jobs/workers with explicit task
  authority, parent-child causality, cancellation, result resources, and UI
  projection generated from runtime state.

### 8. Agent Queue, Goals, Work Snapshots, and User Questions

Old surface:

- `agent::run_goal`
- `agent::work_snapshot`
- `agent::queue_prompt`
- `agent::dequeue_prompt`
- `agent::clear_queue`
- `agent::prompt_queue_drain`
- `agent::ask_user`
- `agent::submit_answers`
- iOS Work dashboard, user-interaction sheet, and queue/progress surfaces.

Current state:

- Retained agent contracts are prompt, apply/run-turn internals, abort,
  abort-invocation, and status.
- Goal execution, queued prompts, snapshots, and structured user-question
  surfaces are absent.

Reintroduction constraint:

- Goal/queue orchestration should use engine queues and resources directly, with
  objective provenance, interruptibility, and user-question state captured as
  typed resources.

### 9. Approval and Freshness Workflows

Old surface:

- Engine approval tables and approval UI.
- Approval/freshness pauses inside capability routing.
- iOS EngineApproval chip and approval sheet.

Current state:

- Engine grants/authority remain, but fixed approval product flows were removed.

Reintroduction constraint:

- Approval should be represented as a durable authority decision resource with
  expiry, scope, requester, evidence, and UI projection. It should not be a
  hidden router side channel.

### 10. Context, Compaction, Rules, Hooks, Skills, and Memory

Old surface:

- Context contracts:
  - `context::get_snapshot`
  - `context::get_detailed_snapshot`
  - `context::get_audit_trace`
  - `context::should_compact`
  - `context::preview_compaction`
  - `context::confirm_compaction`
  - `context::compact`
  - `context::can_accept_turn`
  - `context::clear`
- Rules discovery and context inclusion.
- Hook discovery and background/lifecycle hook execution.
- Skills:
  - `skills::list`
  - `skills::get`
  - `skills::activate`
  - `skills::deactivate`
  - `skills::active`
  - `skills::refresh`
- Memory:
  - `memory::retain`
  - `memory::auto_retain_fire`
- Managed first-party skills:
  - `browse-the-web`
  - `explore`
  - `find-skill`
  - `generate`
  - `git-sync`
  - `google-workspace`
  - `heal-skill`
  - `humanizer`
  - `knowledge`
  - `manage-automations`
  - `old-english`
  - `plan`
  - `publish-website`
  - `sandbox`
  - `self-deploy`
  - `self-extend`
  - `self-inspect`
  - `twitter`
  - `vault`

Current state:

- Context assembly is reduced to system/soul prompt, agent-owned state summary,
  explicit memory prompt-trace audit, environment metadata, history, and
  primitive execution results.
- Slice 3 restores only the source-backed memory foundation:
  `memory_engine`, `memory_policy`, `memory_record`, `memory_prompt_trace`,
  `memory_eval_run`, and `memory_migration_envelope` resources plus redacted
  provider-safe audit operations. It does not restore `memory::auto_retain_fire`
  or semantic/vector/procedural memory engines.
- Managed repo skills are intentionally absent.
- No skills, rules, hooks, managed first-party skill bundles, or automatic
  memory-retention roots remain.

Reintroduction constraint:

- Skills/rules/hooks/memory must return as agent-authored or module-owned state
  with provenance, evals, and explicit loading authority. They should not return
  as bootstrap prompt injection or bundled product scaffolding.

### 11. Prompt Artifacts

Old surface:

- `prompt_library::history_list`
- `prompt_library::history_record`
- `prompt_library::history_delete`
- `prompt_library::history_clear`
- `prompt_library::snippet_list`
- `prompt_library::snippet_get`
- `prompt_library::snippet_create`
- `prompt_library::snippet_update`
- `prompt_library::snippet_delete`
- iOS prompt history, snippet list, snippet rows, preview, and management UI.

Current state:

- No prompt library domain or fixed iOS prompt-library UI.

Reintroduction constraint:

- Prompt history/snippets should be resource-backed, portable, and opt-in, with
  privacy redaction and retention policy evidence.

### 12. Notifications, APNs, and Device Broker

Old surface:

- `notifications::send`
- `notifications::list`
- `notifications::mark_read`
- `notifications::mark_all_read`
- `device::register`
- `device::unregister`
- `device::respond`
- APNs dependency and device token tables.
- iOS notification inbox, bell, details, and notification services.

Current state:

- No notifications or device domain roots.
- APNs dependency was removed.
- Current iOS pairing is local paired-server state, not a server-owned device
  broker.

Reintroduction constraint:

- Notifications need per-device authority, token lifecycle, transport privacy,
  retention controls, and clear separation between local diagnostics and push
  delivery.

### 13. Audio Capture, Transcription, and Media

Old surface:

- `voice_notes::save`
- `voice_notes::list`
- `voice_notes::delete`
- `transcription::audio`
- `transcription::list_models`
- `transcription::download_model`
- Server transcription settings.
- iOS audio services, voice-note recording sheet, floating voice-note button,
  waveform, and detail view.

Current state:

- No voice-notes or transcription domain roots.
- iOS chat attachments remain, but voice-note and transcription workflows are
  absent.

Reintroduction constraint:

- Media features need storage/resource ownership, upload size limits, redaction,
  model availability state, and explicit local-vs-server processing boundaries.

### 14. MCP and External Tool Sources

Old surface:

- `mcp::status`
- `mcp::list_capabilities`
- `mcp::add_server`
- `mcp::remove_server`
- `mcp::enable_server`
- `mcp::disable_server`
- `mcp::restart_server`
- `mcp::reload`
- Plugin/source surfaces in iOS and old capability metadata.

Current state:

- No MCP domain root.
- No first-class external tool-source management UI.

Reintroduction constraint:

- MCP should return as a provider of module registrations into the catalog,
  with source identity, sandbox policy, tool schema provenance, and conformance
  gates.

### 15. Program Execution

Old surface:

- `program` domain and JavaScript execution support.
- `rquickjs` and `rquickjs-serde` dependencies.
- `tron-program-worker` binary support.

Current state:

- No program domain and no embedded JavaScript runtime dependency.

Reintroduction constraint:

- Program execution should be isolated behind worker/module boundaries with
  deterministic input/output envelopes, resource limits, and explicit authority.

### 16. Import, Repository, Tree, and History Tooling

Old surface:

- Import:
  - `import::list_sources`
  - `import::list_sessions`
  - `import::preview_session`
  - `import::execute`
- Repository:
  - `repo::get_divergence`
  - `repo::list_sessions`
- Tree:
  - `tree::get_branches`
  - `tree::get_subtree`
  - `tree::get_ancestors`
  - `tree::compare_branches`
  - `tree::get_visualization`
- Session tree UI.

Current state:

- No import, repo, or tree domain roots.
- Session fork/history basics remain, but product-specific tree visualization
  and import flows are gone.

Reintroduction constraint:

- History/import tooling should be modeled as session/resource graph operations
  with migration provenance and replay evidence.

### 17. Cron, Background Automation, and Scheduling

Old surface:

- `cron::create`
- `cron::delete`
- `cron::get`
- `cron::get_runs`
- `cron::list`
- `cron::run`
- `cron::status`
- `cron::update`
- Cron job and run tables.

Current state:

- No cron domain and no scheduler product surface.

Reintroduction constraint:

- Scheduling should use explicit durable triggers, run records, authority
  scopes, missed-run behavior, and user-visible cancellation.

### 18. System Update and Diagnostics Product Surface

Old surface:

- `system::check_for_updates`
- `system::get_update_status`
- `system::get_diagnostics`
- Server update settings.
- iOS system views and diagnostics tied to old product routes.

Current state:

- Retained system contracts are `system::ping`, `system::get_info`, and
  `system::shutdown`.
- Current diagnostics are local/server log and feedback bundle oriented, not the
  old update/status product flow.

Reintroduction constraint:

- Update checking must stay separate from deployment. It needs provenance,
  signed release identity, user approval, and no production deploy command path.

### 19. Fixed iOS Product Panels

Old iOS view roots that no longer exist as fixed product panels:

- Retired feature-specific control, audit, approval, notification, process,
  prompt, session-tree, skill, source-change, subagent, interaction, media, and
  work panel roots from the modular capability engine.

Current state:

- Current UI roots are `Capabilities`, `Chat`, `Components`, `Onboarding`,
  `RuntimeSurfaces`, `Settings`, `System`, and `Theme`.
- Some generic capabilities remain: chat, attachments, onboarding, settings,
  diagnostics, generic runtime surfaces, and capability result rendering.
- The old product-specific panels are absent or intentionally collapsed into
  generic runtime rendering.

Reintroduction constraint:

- Prefer server-authored/generic runtime surfaces for module UI. Add fixed iOS
  panels only when the feature is a stable platform concern and has a protocol
  contract that justifies native UI.

### 20. iOS Client, DTO, Event, and Persistence Breadth

Old removed iOS families by static directory count included:

- `Sources/Core/Events`: 90 removed files.
- `Sources/Services/Network`: 43 removed files.
- `Sources/Views/Settings`: 31 removed files.
- `Sources/ViewModels/State`: 29 removed files.
- `Sources/Views/Capabilities`: 28 removed files.
- `Sources/Models/EngineProtocol`: 28 removed files.
- `Sources/ViewModels/Chat`: 19 removed files.
- `Sources/ViewModels/Handlers`: 16 removed files.
- `Sources/Models/Messages`: 16 removed files.
- `Sources/Services/Events`: 8 removed files.
- `Sources/Database/Repositories`: 6 removed files.
- Audio, notification, diagnostics, onboarding, storage, feature models, and
  product view models also had smaller removed families.

Current state:

- iOS protocol/client code is rebuilt around `Engine`, `Session`, `Support`, and
  `UI`.
- Product-specific DTO families for approvals, cron, filesystem, git, import,
  media, notifications, plugin sources, prompt library, repository state, task
  state, and worktrees are absent.

Reintroduction constraint:

- Reintroduce DTOs from current protocol contracts only. Do not resurrect stale
  old DTOs unless the server module contract exists and is tested.

### 21. Event Protocol Surface

Old surface:

- Broad product event families for session, message queue, capability lifecycle,
  config, notification, compact/context, skill, rules, metadata, file,
  worktree, repository, errors, subagents, process/user jobs, todos, hooks,
  memory, device, and server update.

Current state:

- Static grep over shared protocol event constructors is materially smaller
  than the old tree.
- Current protocol focuses on agent/session/model/capability/stream/context
  warning/metadata/error/turn events.
- Product categories tied to removed domains are absent.

Reintroduction constraint:

- Events should be module-owned and versioned. They need replay compatibility,
  iOS decoder tests, and clear fallback behavior for unknown module events.

### 22. Database and Storage Tables

Old surface:

- Branch/worktree tables.
- Engine approval tables.
- Capability registry/search/conformance tables.
- Device token tables.
- Cron job/run tables.
- Constitution/audit/context tables.
- Session profile/worktree override fields.
- Prompt-library, notification, skill/rule/hook, memory, and product projection
  storage.

Current state:

- Current storage is focused on session/event persistence, primitive replay,
  logs, blobs, settings/auth, and engine durability stores.
- Product-specific tables were removed with their domains.

Reintroduction constraint:

- New tables need migrations, rollback/compatibility policy, retention policy,
  and replay evidence. Avoid one-off product tables when a resource type plus
  indexed projection is sufficient.

### 23. Settings and Profile Controls

Old profile settings removed or collapsed:

- `settings.capabilities.process`
- `settings.capabilities.process.sandbox`
- `settings.capabilities.filesystemRead`
- `settings.capabilities.find`
- `settings.capabilities.search`
- `settings.capabilities.web.fetch`
- `settings.capabilities.web.cache`
- `settings.capabilities.browser`
- `settings.capabilities.computerUse`
- `settings.context.rules`
- `settings.agent.autonomy`
- `settings.hooks`
- `settings.server.transcription`
- `settings.server.update`
- `settings.session`
- `settings.session.isolation`
- `settings.skills`
- `settings.memory`
- `settings.git`
- `settings.promptLibrary`
- `settings.mcp`

Current retained settings areas:

- API/provider defaults.
- Retry.
- Context compactor.
- Agent max-turn style controls.
- Logging overrides.
- Observability/log retention.
- Storage.
- Server defaults.
- Tmux.
- UI palette/icons/thinking/input/menu.

Reintroduction constraint:

- Every new setting needs server profile schema, validation, iOS decode/update
  parity, tests, and README maintenance. Avoid module settings that are not
  owned by a registered module.

### 24. Dependencies That Indicate Removed Behavior

Removed dependencies and likely feature implications:

- `apns`: push notification delivery.
- `bytemuck`, `image`, `resvg`: image/render/display helpers.
- `chrono-tz`: time-zone-specific scheduling.
- `ed25519-dalek`, `hmac`: package/source trust and signing helpers.
- `enigo`: local computer-use/input control.
- `eventsource-stream`: event-source streaming.
- `fastembed`, `sqlite-vec`: local embedding/vector capability search.
- `globset`: advanced filesystem matching.
- `html2text`, `scraper`: web/HTML parsing.
- `portable-pty`: PTY process execution.
- `rquickjs`, `rquickjs-serde`: JavaScript program execution.
- `unicode-normalization`, `urlencoding`: URL/text normalization helpers for
  product domains.

Reintroduction constraint:

- Do not add dependencies speculatively. Each dependency should enter with the
  module that owns it, focused tests, and a profile/security review where
  relevant.

## Removed First-Class Domain Contracts

These IDs existed at `ad5e4847` and do not exist as first-class current domain
contracts. Some behavior may be partially covered by current primitive
operations, but the old named domain API is absent.

### Agent

- `agent::ask_user`
- `agent::cancel_subagent`
- `agent::clear_queue`
- `agent::dequeue_prompt`
- `agent::prompt_queue_drain`
- `agent::queue_prompt`
- `agent::run_goal`
- `agent::spawn_subagent`
- `agent::subagent_result`
- `agent::subagent_status`
- `agent::submit_answers`
- `agent::work_snapshot`

### Browser, Config, Display, Process, Self-Extension

- `browser::get_status`
- `config::set_reasoning_level`
- `display::stop_stream`
- `process::run`
- `self_extension::grant_workspace_autonomy`
- `spawn_worker`

### Context

- `context::can_accept_turn`
- `context::clear`
- `context::compact`
- `context::confirm_compaction`
- `context::get_audit_trace`
- `context::get_detailed_snapshot`
- `context::get_snapshot`
- `context::preview_compaction`
- `context::should_compact`

### Cron

- `cron::create`
- `cron::delete`
- `cron::get`
- `cron::get_runs`
- `cron::list`
- `cron::run`
- `cron::status`
- `cron::update`

### Device and Notifications

- `device::register`
- `device::respond`
- `device::unregister`
- `notifications::list`
- `notifications::mark_all_read`
- `notifications::mark_read`
- `notifications::send`

### Events

- `events::append`
- `events::get_history`
- `events::get_since`
- `events::subscribe`
- `events::unsubscribe`

### Filesystem

- `filesystem::apply_patch`
- `filesystem::create_dir`
- `filesystem::diff`
- `filesystem::edit_file`
- `filesystem::find`
- `filesystem::get_home`
- `filesystem::glob`
- `filesystem::list_dir`
- `filesystem::read_file`
- `filesystem::search_text`
- `filesystem::write_file`

### Git, Repo, Tree, and Worktree

- `git::clone`
- `git::list_local_branches`
- `git::list_remote_branches`
- `git::push`
- `git::sync_main`
- `repo::get_divergence`
- `repo::list_sessions`
- `tree::compare_branches`
- `tree::get_ancestors`
- `tree::get_branches`
- `tree::get_subtree`
- `tree::get_visualization`
- `worktree::abort_merge`
- `worktree::acquire`
- `worktree::commit`
- `worktree::continue_merge`
- `worktree::delete_branch`
- `worktree::discard_files`
- `worktree::finalize_session`
- `worktree::get_committed_diff`
- `worktree::get_diff`
- `worktree::get_diff_summary`
- `worktree::get_status`
- `worktree::is_git_repo`
- `worktree::list`
- `worktree::list_conflicts`
- `worktree::list_session_branches`
- `worktree::merge`
- `worktree::prune_branches`
- `worktree::rebase_on_main`
- `worktree::release`
- `worktree::resolve_conflict`
- `worktree::resolve_conflicts_with_subagent`
- `worktree::stage_files`
- `worktree::start_merge`
- `worktree::unstage_files`

### Import

- `import::execute`
- `import::list_sessions`
- `import::list_sources`
- `import::preview_session`

### Job

- `job::background`
- `job::cancel`
- `job::list`
- `job::stream_output`
- `job::subscribe`
- `job::unsubscribe`
- `job::wait`

### MCP

- `mcp::add_server`
- `mcp::disable_server`
- `mcp::enable_server`
- `mcp::list_capabilities`
- `mcp::reload`
- `mcp::remove_server`
- `mcp::restart_server`
- `mcp::status`

### Memory and Plan

- `memory::auto_retain_fire`
- `memory::retain`
- `plan::enter`
- `plan::exit`
- `plan::get_state`

### Prompt Artifacts

- `prompt_library::history_clear`
- `prompt_library::history_delete`
- `prompt_library::history_list`
- `prompt_library::history_record`
- `prompt_library::snippet_create`
- `prompt_library::snippet_delete`
- `prompt_library::snippet_get`
- `prompt_library::snippet_list`
- `prompt_library::snippet_update`

### Sandbox and Workers

- `sandbox::get_spawned_worker`
- `sandbox::list_spawned_workers`
- `sandbox::stop_spawned_worker`
- `worker::spawn`

### Skills

- `skills::activate`
- `skills::active`
- `skills::deactivate`
- `skills::get`
- `skills::list`
- `skills::refresh`

### System

- `system::check_for_updates`
- `system::get_diagnostics`
- `system::get_update_status`

### Transcription and Audio Capture

- `transcription::audio`
- `transcription::download_model`
- `transcription::list_models`
- `voice_notes::delete`
- `voice_notes::list`
- `voice_notes::save`

### Web

- `web::fetch`
- `web::search`

## Reintroduction Order Suggested by Architecture Risk

The report is not a plan, but the feature inventory implies a safer order:

1. Capability catalog/discovery metadata, without changing provider-visible tool
   shape.
2. Filesystem module, because it can be bounded and tested against current
   primitive file operations.
3. Durable job/process module, separate from primitive `process_run`.
4. Worktree/git module, built on filesystem and job evidence.
5. Generic module UI projection on iOS, before fixed product panels return.
6. Web/search module with provenance and network authority.
7. Worker launch/module install, after catalog and authority are strong.
8. Subagents/goals/queues, after jobs/workers/resources are mature.
9. Notifications, media/transcription, MCP, memory/skills/hooks, and scheduling
   only after the module/resource/event patterns are proven.

## Validation State of Current Baseline

The current frozen baseline was validated before this report with:

- Full Rust CI: `scripts/tron ci fmt check clippy test`
- Personal-info guard: `scripts/personal-info-guard.sh`
- XcodeGen generation check.
- Full iOS test scheme on iPhone 17 Pro iOS 26.5.
- Focused iOS batches for pairing/storage, attachments/input/share,
  settings/providers/theme, diagnostics/feedback/logs,
  session-persistence/reconstruction, transport/events/protocol, and
  onboarding/UI guards.
- `git diff --check`
- `git ls-files -ci --exclude-standard`
- Computer-use iOS baseline for pair/onboard/new session/send/relaunch/persist.
- Physical iPhone production build/install/launch through the `Tron` scheme and
  `Prod` configuration.

This validates the current baseline, not the old features. Each reintroduced
feature still needs its own tests, docs, scorecard/evidence entry, iOS parity
where applicable, and regression gates.

## Completion Criteria for Future Feature Restoration

For each feature bucket restored from this index:

- Define the module owner and whether it is server-core, external worker,
  iOS-native, or generated runtime UI.
- Define capability contracts and resource/event schemas before UI work.
- Preserve provider-visible minimality unless a scorecard explicitly proves a
  broader surface is needed.
- Add focused Rust tests, iOS tests where UI/protocol changes, and replay or
  invariant tests for durable state.
- Update README/progressive docs and any scorecard evidence in the same commit.
- Prove the feature composes with current authority, replay, logs, settings,
  personal-info guard, and XcodeGen drift checks.
