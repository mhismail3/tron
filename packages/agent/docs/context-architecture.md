# Agent Context Architecture Audit

This document maps the current working-tree architecture for everything that can
enter an agent turn's model context. It treats the profile-first Constitution
layout as the primary truth and names the source-of-truth files each subsystem
must resolve through.

## Executive Summary

Tron builds model context through a layered runtime path:

1. Startup initializes the profile-first Constitution home, settings, database, provider
   factory, tool factory, skill registry, memory registry, and orchestrator.
2. `agent.prompt` reconstructs session state, loads rules/memory/job results,
   refreshes skills, applies hook-injected context, and creates a per-run
   `TronAgent`.
3. `TronAgent::run` adds the current user message, enters the turn loop, and
   delegates each turn to `turn_runner`.
4. `turn_runner` asks `ContextManager` for the stable context, attaches
   per-turn volatile context from `RunContext`, records Constitution audit rows,
   asks the provider adapter for its request payload, streams the response, and
   executes requested tools.
5. Tool results and assistant messages are appended back into `ContextManager`
   and persisted to the event store, so the next turn sees the updated history.

The profile-first implementation makes the execution spec auditable: prompts and
provider/context policy seed from `profiles/default`, user settings stay
sparse in `profiles/user`, all model input is recorded as typed context blocks,
and provider payloads are captured with redacted previews.

## Execution Path

```mermaid
flowchart TD
    Start["main.rs startup"] --> Home["ensure_tron_home / Constitution seed + migration"]
    Home --> Settings["settings defaults + sparse user settings + env overrides"]
    Settings --> Services["EventStore, Orchestrator, ProviderFactory, ToolFactory, SkillRegistry, MemoryRegistry"]
    Services --> RPC["agent.prompt RPC handler"]
    RPC --> Reconstruct["Session reconstruction from events"]
    Reconstruct --> Bootstrap["Prompt bootstrap: rules, rules index, pending jobs, process/subagent/user-job results"]
    Bootstrap --> Memory["MemoryRegistry: MEMORY.md + rules/*.md listing"]
    Memory --> AgentFactory["AgentFactory::create_agent"]
    AgentFactory --> ContextManager["ContextManager seeded with system prompt, rules, memory, messages, tools"]
    ContextManager --> UserMessage["TronAgent::run adds current user message"]
    UserMessage --> Turn["turn_runner::execute_turn"]
    Turn --> Compose["build_turn_context + compose_context_blocks"]
    Compose --> Audit["Constitution context + provider payload audit"]
    Audit --> Provider["Provider adapter request"]
    Provider --> Stream["Stream processor + streaming journal"]
    Stream --> Tools["Tool execution waves"]
    Tools --> Events["Persist assistant/tool/rules/events"]
    Events --> Next["Next turn context"]
    Tools --> Next
```

### Startup and Service Construction

`packages/agent/src/main.rs` is the root of the harness. The important context
steps are:

- `init_directories()` calls `core::constitution::ensure_tron_home()`, which
  seeds or migrates the durable `~/.tron` layout before settings and runtime
  services are used.
- The database path resolves through the settings DB path policy, then SQLite
  migrations create or upgrade the event store, including the Constitution
  audit tables.
- `settings::init_settings()` loads Constitution-seeded defaults first, merges
  sparse user settings over them, then applies environment overrides.
- `build_tool_factory()` creates a fresh `ToolRegistry` for each agent run. It
  adds built-in tools, subagent/job tools, MCP tools, and an LLM-backed
  `web_fetch` variant.
- The RPC context holds shared services: `SessionManager`, `EventStore`,
  `Orchestrator`, `ProviderFactory`, `SkillRegistry`, `MemoryRegistry`,
  process/job managers, output buffers, and settings.

### Prompt RPC to Agent Construction

The prompt path is centered on
`packages/agent/src/server/rpc/handlers/agent_prompt_service.rs`.

- `agent.prompt` validates params, loads the session, records prompt history,
  starts a run, and spawns `execute_prompt_run`.
- `execute_prompt_run` reconstructs session messages from events. Chat sessions
  skip project artifacts; normal sessions load prompt bootstrap artifacts.
- For cloud models, `load_prompt_bootstrap` gathers project/global rules,
  `RulesIndex`, pre-activated rules, and pending subagent/process/user-job
  notifications. Local models use a minimal bootstrap and leave pending results
  queued for later cloud-model turns.
- Memory is injected for non-local models from `~/.tron/memory/MEMORY.md` plus a
  listing of direct `~/.tron/memory/rules/*.md` files.
- If worktree isolation is active, the git worktree path, branch, and
  profile-backed `git-workflow` prompt are appended to memory content.
- System prompt precedence for normal sessions is project `.tron/SYSTEM.md`,
  then global `~/.tron/profiles/user/prompts/core.md`, then the
  seeded default prompt loaded by `ContextManager`. Chat sessions directly use
  the seeded `chat` prompt.
- `AgentFactory::create_agent` receives provider, tools, hooks, rules, memory,
  messages, rules index, and compaction settings, then builds a `ContextManager`.

### Skill, Hook, and Current User Prompt Injection

Before `TronAgent::run` starts:

- `SkillRegistry` refreshes so changed `SKILL.md` files are visible.
- `prepare_skill_context_from_session` reconstructs session-scoped skill state
  from events and can inject activation, active-skill XML, and one-turn removal
  notices. Under the AskUser compaction policy it can also append a
  `skills.cleared` event.
- The skill index is included according to `settings.skills.showIndex`: always,
  never, or only when no active skill content is present. Local models skip the
  skill index.
- `UserPromptSubmit` hooks can prepend `<hook-context>...</hook-context>` to the
  effective prompt. The hook-added context becomes part of the user message,
  not a separate Constitution context block.
- Multimodal user input can replace the text-only prompt with structured user
  content for images and attachments.

### Turn Runner and Provider Request

`packages/agent/src/runtime/agent/turn_runner.rs` is the single-turn center of
gravity.

- `ContextManager::begin_turn()` advances the per-turn generation used to catch
  stale volatile token estimates.
- Compaction can run before the provider call. If compaction occurs, dynamic
  rules are cleared so path-sensitive context can be rebuilt.
- `build_turn_context` starts from `ContextManager::build_base_context`, attaches
  message history, tool schemas, server origin, skill contexts, job results, and
  dynamic rules from `RunContext`.
- Local providers use `runtime/context/local_policy.rs`: reduced tool schemas,
  no memory, no skill index, no job results, truncated rules, but explicit skill
  activation/active/removal context is retained.
- `compose_context_audit_blocks` compiles the provider-independent audit view.
  It includes prompt blocks plus audit-only tool schemas and conversation
  messages.
- The provider adapter also builds an exact or near-exact provider payload via
  `Provider::audit_payload`. Audit write failures currently fail the turn before
  the model call.
- The provider stream is processed into assistant deltas, thinking deltas, tool
  calls, token usage, and final stop reason. A streaming journal under
  `~/.tron/internal/database/journals/` is required for crash recovery.
- Tool calls are persisted before execution, executed in waves according to tool
  execution mode, then tool results are persisted and appended back into
  `ContextManager`.
- Touched paths can activate scoped rules, which are persisted as
  `rules.activated` and injected into later turns.

## Context Inventory

| Source | Current owner | Included when | Lifecycle | Surface | Cache class | Token accounting | Control knob |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Seeded default system prompts | `~/.tron/profiles/default/prompts/*.md`; loaded by `runtime/context/instruction_prompts` and `ContextManager` | Always, unless project/global override provides core prompt; chat uses `chat`; local uses `local` default | Foundation/session | Provider instructions | Foundation | `systemPrompt` bucket | Edit profile prompt files; project `.tron/SYSTEM.md` |
| Project system prompt override | `.tron/SYSTEM.md` in working directory | Normal non-chat sessions when present | Session | Provider instructions | Foundation | `systemPrompt` bucket | File contents |
| Global user profile prompt | `~/.tron/profiles/user/prompts/core.md` | Normal non-chat sessions when project override absent | Session | Provider instructions | Foundation | `systemPrompt` bucket | File contents |
| Project/global rules | `server/rpc/session_context.rs`, `runtime/context/loader.rs`, `rules_discovery.rs` | Normal sessions; path-scoped rules can be pre-activated or dynamically activated | Session and turn | Provider instructions | Session/turn | `rules` and dynamic-rules buckets | `settings.context.rules.*`, rules files, touched paths |
| Memory root | `runtime/memory/registry.rs`; `~/.tron/memory/MEMORY.md` | Non-local model turns | Session | Provider instructions | Session | `memory` bucket | Memory RPC handlers and file contents |
| Memory detail listing | `~/.tron/memory/rules/*.md` listing only | Non-local model turns, as part of memory content | Session | Provider instructions | Session | `memory` bucket | File presence/frontmatter |
| Worktree isolation note | `agent_prompt_service.rs` plus `git-workflow` prompt | Sessions with acquired worktree | Session | Provider instructions through memory | Session | `memory` bucket | Worktree/session isolation settings |
| Skill index | `skills/injector.rs`; `settings.skills.showIndex` | Cloud models according to show-index policy | Session | Provider instructions | Session | `skillIndex` bucket | Skill registry and `showIndex` |
| Skill activation directive | `prompt_runtime` skill context reconstruction | Active or newly invoked skills | Turn/session | Provider instructions | Turn | `skillContext` volatile estimate | `@skill`, skill RPC events |
| Active skill XML | `SKILL.md` resolved by `SkillRegistry` and injector | Explicitly active skills | Turn/session | Provider instructions | Turn | `skillContext` volatile estimate | Skill files, `@skill`, skill RPC events |
| Skill removal notice | Skill tracker/event reconstruction | One turn after deactivation/removal state requires notice | Turn | Provider instructions | Turn | `skillRemoval` volatile estimate | Skill deactivation/compaction policy |
| Pending job/process/subagent results | Prompt bootstrap from event store managers | Cloud-model normal turns with unconsumed results | Turn | Provider instructions | Turn | `jobResults` volatile estimate | Job/process/subagent events |
| Server origin | RPC context -> `RunContext`/`ContextManager` | Turn context when origin known | Session | Provider instructions | Session | `environment` bucket | Server startup/origin |
| Working directory | `AgentConfig`/`ContextManager` | Every turn | Session | Provider instructions | Session | `environment` bucket | Session working directory/worktree |
| Message history | `ContextManager` `MessageStore`, reconstructed from events | Every turn | Turn/session history | Provider messages | Turn | `messages` bucket | Session events, compaction |
| Current user prompt | `TronAgent::run`; optional multimodal override | Current turn | Turn | Provider message | Turn | `messages` bucket | RPC prompt payload, hook AddContext |
| Tool schemas | `ToolRegistry` definitions | Every turn; reduced for local models | Session | Provider tools | Session | `tools` bucket | Tool factory, denied tools, local policy |
| Tool results | Tool executor -> `ContextManager` messages | After tool execution, next provider request | Turn/history | Provider messages | Turn | `messages` bucket | Tool behavior and compaction |
| Compaction summaries | `compaction_engine`/event reconstruction | After compaction boundaries | Session/history | Provider messages | Session | `messages` bucket | Context compactor settings/RPC |
| Hook AddContext | Hook engine `UserPromptSubmit` action | Hook returns non-empty context under budget | Turn | User message content | Turn | `messages` bucket | Hook files/settings |

### Canonical Context Block Order

`packages/agent/src/llm/shared/context_composition.rs` currently emits these
prompt blocks in precedence order:

| Precedence | Block id | Source home | Surface | Cache class |
| --- | --- | --- | --- | --- |
| 10 | `system.prompt` | `profiles` | Instructions | Foundation |
| 20 | `project.rules` | `workspace` | Instructions | Session |
| 30 | `memory.root` | `memory` | Instructions | Session |
| 40 | `dynamic.rules` | `profiles` | Instructions | Turn |
| 50 | `skills.index` | `skills` | Instructions | Session |
| 60 | `skills.activation` | `skills` | Instructions | Turn |
| 70 | `skills.active` | `skills` | Instructions | Turn |
| 80 | `skills.removal` | `skills` | Instructions | Turn |
| 90 | `jobs.results` | `workspace` | Instructions | Turn |
| 100 | `environment.server` | `internal` | Instructions | Session |
| 110 | `environment.workingDirectory` | `workspace` | Instructions | Session |

The audit-only view adds:

| Precedence | Block id | Source home | Surface | Cache class |
| --- | --- | --- | --- | --- |
| 120 | `tools.schemas` | `profiles` | Tool | Session |
| 130 | `conversation.messages` | `workspace` | Message | Turn |

This ordering is provider-independent. Provider adapters can flatten it, split
it into cacheable chunks, or translate it into native provider fields.

## Provider Adaptation

All providers consume the same `Context` object, but the final payload shape is
provider-specific.

| Provider | Context adaptation | Audit payload status |
| --- | --- | --- |
| Anthropic | Uses `compose_context_parts_grouped`; stable blocks get longer prompt-cache treatment, volatile blocks get shorter cache treatment; tools can also receive cache markers. | Provider builds an exact Anthropic request envelope for audit. |
| OpenAI | Inserts composed context parts as an initial developer message, then converts conversation messages and tools for the Responses API. | Provider builds an exact Responses request envelope for audit. |
| Google | Builds `systemInstruction` from context parts and converts messages/tools to Gemini request body. | Provider builds a request body for audit and includes each context part once. |
| Kimi | Builds a plain system prompt string from composed context parts. | Provider builds a request body for audit. |
| MiniMax | Builds a plain system prompt string from composed context parts. | Provider builds a request body for audit. |
| Ollama | Builds a local-model-optimized system prompt from composed context parts and reduced context. | Provider builds a request body for audit. |

## Persistence and Observability

### Event Store

The event log remains the durable source for conversation history and most
runtime reconstruction:

- `message.user`, `message.assistant`, and `message.system` reconstruct history.
- `tool.call` and `tool.result` preserve tool phases and create later tool
  result messages.
- `rules.loaded`, `rules.indexed`, and `rules.activated` explain rules context.
- `skill.activated`, `skill.deactivated`, and `skills.cleared` explain skill
  context.
- `compact.boundary` and `compact.summary` explain why older messages are
  replaced by summaries.
- Subagent/process/job notifications can become one-turn job-result context.

### Constitution Audit Tables

The implementation adds:

- `constitution_home_audit`: intended to record creates, updates, moves,
  deletes, seeds, repairs, and external edits under `~/.tron`.
- `constitution_resolution_audit`: records settings, profile instructions, context,
  provider payloads, vault access, automation runs, and outcome feedback.
- `constitution_context_blocks`: records typed blocks for each context
  resolution, including source home/path/blob, content hash, token estimate,
  sensitivity, inclusion reason, precedence, cache class, provider surface, and
  lifecycle.

`turn_runner` writes a context resolution before the provider call, then writes a
provider-payload audit record. If either write fails, the turn fails before the
model call so replay integrity is not silently lost.

### Snapshot and Control RPC

The current public observability layer includes context snapshot and compaction
methods such as `context.getSnapshot`, `context.getDetailedSnapshot`,
`context.getAuditTrace`, `context.shouldCompact`, `context.previewCompaction`,
`context.confirmCompaction`, `context.clear`, and `context.compact`. Snapshots
show token breakdown and compaction state; `context.getAuditTrace` exposes the
profile refs, context block rows, cache policy, blob/hash refs, and redacted
provider payload preview for a turn.

## Profile-First Digest

The working tree shifts Tron from a code-bundled prompt/settings model to a
profile-first home model:

- Prompt files moved out of `runtime/context/system_prompts` and provider
  prompt locations into `packages/agent/defaults/profiles/default/**`,
  which seed `~/.tron/profiles/default/**`.
- Settings now load from `~/.tron/profiles/default/settings/defaults.json`
  plus sparse `~/.tron/profiles/user/settings.json`, instead of relying only on compiled
  defaults and a monolithic user settings file.
- Canonical path helpers in `core/foundation/paths.rs` describe the five
  top-level homes: `profiles`, `skills`, `memory`, `workspace`, and `internal`.
- Provider adapters gained `audit_payload` support so the pre-adapter context
  and adapted provider request can both be recorded.
- Runtime context composition now emits typed Constitution context blocks with
  lifecycle/cache/surface metadata.
- SQLite migrations add Constitution audit tables to fresh and existing
  databases.
- First-party skill docs, runtime memory/rules code, and self-inspect guidance
  now use the five-root layout.

## Source-of-Truth Consolidation

The profile-first pass deliberately removes duplicate path and behavior
knowledge from runtime call sites:

- Rust path construction resolves through `core/foundation/paths.rs`; startup and
  migration use `core/foundation/constitution.rs`; execution behavior resolves
  through `core/foundation/profile.rs`.
- Managed defaults are listed once in `constitution.rs` through a
  `managed_default!` macro whose include path and seeded path share the same
  relative source string.
- Prompt, subagent, summarizer, provider, tools, context, settings, and auth
  references are profile-owned. Runtime helpers resolve files from the active
  profile and only restore managed `default` files through the canonical
  recovery contract.
- Contributor shell paths are centralized in `scripts/tron-lib.sh`; the Mac
  wrapper resolves its data-root paths through `TronPaths.swift`; iOS settings
  remain RPC-backed instead of duplicating filesystem layout.
- README RPC drift is guarded by a registry-count test, and the Mac bundle copy
  phase validates the profile-default shape rather than old instructions/settings
  roots.

## Addressed Findings

These findings were the original audit gaps that drove the profile-first pass.

| Finding | Why it matters | Evidence to inspect |
| --- | --- | --- |
| Seeded `context-blocks.toml` was incomplete | The default policy now names all emitted prompt blocks plus the audit-only tool/message blocks. | `packages/agent/defaults/profiles/default/context/context-blocks.toml`; `llm/shared/context_composition.rs` |
| Google system prompt appeared duplicated | Google now uses only `compose_context_parts`, so `system.prompt` is included once. | `packages/agent/src/llm/google/provider.rs` |
| Global rules path migration was uneven | Global rules route through `~/.tron/memory/rules`; global behavior routes through `~/.tron/profiles`. | `runtime/context/loader.rs`; `server/rpc/session_context.rs`; `core/foundation/paths.rs`; `runtime/memory/registry.rs` |
| `self-inspect` docs showed old home layout | Managed self-inspect docs now describe the five-root profile-first home. | `packages/agent/skills/self-inspect/SKILL.md`; `reference/schema.md` |
| Audit persistence is load-bearing | If Constitution context or provider-payload audit writes fail, the turn fails before the model call. This improves replay integrity but makes audit storage availability part of the critical path. | `runtime/agent/turn_runner.rs` |
| No user-facing audit query surface existed | `context.getAuditTrace` exposes profile refs, context blocks, blob/hash refs, cache policy, and redacted provider payload previews. | `server/rpc/handlers/context.rs`; `server/rpc/context_queries.rs`; Constitution audit repo |
| Existing users needed managed default recovery | Managed `default` files are restored from compiled defaults if missing or corrupt; user profiles fail validation and are not overwritten. | `core/foundation/constitution.rs`; `core/foundation/profile.rs` |

## Migration Retirement Path

The old-layout migration layer is intentionally temporary. It exists only in
`core/foundation/constitution.rs::migrate_legacy_home` and is guarded by
`legacy_tron_home_paths_are_migration_only`, which fails if old Tron Home paths
appear anywhere outside explicit migration/repair surfaces.

Live verification before removal:

1. Start the server from the refactored build against the real `~/.tron`.
2. Confirm the root contains only `internal`, `skills`, `profiles`, `memory`,
   and `workspace`.
3. Run representative flows: agent turn, provider auth, settings read/write,
   skill activation, workspace artifact write, automation load, self-inspect,
   and transcription setup if enabled.
4. Confirm `context.getAuditTrace` returns profile refs, context blocks,
   provider payload refs, and redacted payload previews for a fresh turn.
5. Confirm no new old-root directories are created after at least two clean
   restarts, and no new `constitution_home_audit` migration/repair rows appear
   after the first verified startup.

Removal follow-up:

1. Delete `migrate_legacy_home`, `move_path`, `merge_path`, and generated
   transcription cleanup helpers from `core/foundation/constitution.rs`.
2. Delete legacy-layout test fixtures and update
   `legacy_tron_home_paths_are_migration_only` so old paths are disallowed
   everywhere except intentional repair documentation such as `heal-skill`.
3. Remove stale-path translation entries from managed skills once they are no
   longer useful for user-imported legacy skills.
4. Keep database schema migrations and audit tables; those are durable product
   history, not the temporary filesystem migration bridge.

## Heavy Code Map

| Area | Files | What to read first |
| --- | --- | --- |
| Startup and service wiring | `packages/agent/src/main.rs` | `init_directories`, DB/settings init, `build_tool_factory`, `init_cron` |
| Runtime module map | `packages/agent/src/runtime/mod.rs` | Module docs and exported runtime types |
| Prompt orchestration | `server/rpc/handlers/agent_prompt_service.rs` | `execute_prompt_run`, prompt bootstrap, skill/hook setup |
| Agent construction | `runtime/agent/factory.rs`, `runtime/agent/tron_agent.rs` | `AgentConfig`, tool filtering, `TronAgent::run` |
| Single-turn execution | `runtime/agent/turn_runner.rs` | `execute_turn`, `build_turn_context`, audit writes, stream/tool phases |
| Context state | `runtime/context/context_manager.rs` | base context, snapshots, compaction triggers, volatile token generation |
| Context composition | `llm/shared/context_composition.rs` | canonical block order and audit-only blocks |
| Provider payloads | `llm/{anthropic,openai,google,kimi,minimax,ollama}` | provider-specific prompt/request adaptation and `audit_payload` |
| Rules | `runtime/context/loader.rs`, `rules_discovery.rs`, `rules_tracker.rs`, `server/rpc/session_context.rs` | discovery, merge order, activation, scoped rules |
| Memory | `runtime/memory/registry.rs`, `server/rpc/handlers/memory.rs` | root memory, rules listing, auto-retain |
| Skills | `skills/registry.rs`, `skills/injector.rs`, prompt runtime helpers | index, active XML injection, event-sourced activation |
| Settings and paths | `settings/storage/loader.rs`, `settings/types`, `core/foundation/paths.rs`, `core/foundation/constitution.rs` | defaults merge, env overrides, home contracts |
| Persistence and audit | `events/sqlite/repositories/constitution.rs`, `events/store/event_store/constitution.rs`, migrations | audit schema, blob storage, write APIs |
| Recovery | `runtime/orchestrator/streaming_journal.rs`, reconstructor/session state code | crash recovery and session replay |

## Transparency and Control Spec

### What can be inspected today

- Context token snapshots through context RPC methods.
- Session history, tool calls/results, compaction events, skill events, rules
  events, and errors through the event log.
- Raw database state through read-only `sqlite3` against
  `~/.tron/internal/database/log.db`.
- Settings through `~/.tron/profiles/default/settings/defaults.json`,
  `~/.tron/profiles/user/settings.json`, settings RPCs, and env overrides.
- Memory through `~/.tron/memory/MEMORY.md`, `~/.tron/memory/rules/*.md`, and
  memory RPC handlers.
- Prompt and provider defaults through `~/.tron/profiles/**` and
  `packages/agent/defaults/profiles/**`.

### What can be controlled today

- Model, provider credentials, retry, server, tools, compaction, rules, hooks,
  skills index behavior, and session/worktree settings.
- Project/user system prompt overrides.
- Project and scoped rules files.
- Memory root and memory detail files.
- Skill activation/deactivation via prompt references or RPC.
- Context compaction through context RPCs.
- Hooks that can inject prompt context, subject to hook budget.

### Remaining hardening areas

- Profile policy names all context block ids, lifecycle, precedence,
  sensitivity, cache class, and provider surface; the Rust composer still owns
  exact assembly semantics and is guarded by coverage/parity tests.
- Provider payload previews are redacted by key name; exact payload bytes remain
  available by blob id through the database/blob path for trusted diagnostics.
- Provider adapters still contain provider-specific edge behavior; profile
  provider policy is the place to move shared behavior when it becomes stable.
- Local/cloud/chat/subagent/cron differences are spread across prompt service,
  local policy, runtime types, settings, and orchestrator code.
- Hook-injected context is folded into the user message, so it is not currently
  represented as its own typed context block.
- Default evolution needs explicit release policy when managed defaults change
  after users have created custom profile overlays.

### What a comprehensive execution spec would need

- A generated or validated context-block manifest that matches
  `compose_context_blocks` and `compose_context_audit_blocks`.
- Broader provider conformance tests around `context.getAuditTrace` output and
  exact block-once inclusion for every provider.
- Provider conformance tests asserting that every provider includes each block
  exactly once, on the intended surface, with expected local/cloud differences.
- Path-contract tests covering `~/.tron` homes, project rules, global rules,
  memory details, managed skills, and seeded instruction defaults.
- A user-facing per-turn context report that combines event history, block
  metadata, token estimates, tool schemas, provider payload identity/hash, and
  compaction state.

## Verification Notes

This audit was grounded with read-only checks:

- `rg` and targeted file reads over runtime, context, provider, settings, paths,
  rules, memory, skills, prompt service, README, and defaults.
- Direct `sqlite3` schema inspection of
  `~/.tron/internal/database/log.db`, including Constitution audit tables and
  row counts.
- `git diff --name-status HEAD` over the uncommitted config/Constitution areas.

Because this is a documentation-only change, the appropriate final verification
is `git diff --check`.
