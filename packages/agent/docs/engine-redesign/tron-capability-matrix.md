# Tron capability matrix

This inventory maps the current server to future engine primitives. It is based
on source inspection on 2026-04-30.

## Current server shape

The Rust agent is a single crate with these top-level modules:

| Layer | Modules | Current role |
|-------|---------|--------------|
| Foundation | `core`, `settings`, `skills`, `transcription` | IDs, settings schema, skill registry, transcription sidecar. |
| Services | `cron`, `events`, `import`, `llm`, `mcp`, `prompt_library`, `tools`, `worktree` | Durable data, LLM providers, external tools, automation, git/worktree, imports. |
| Orchestration | `runtime` | Agent loop, context, hooks, memory, subagents, session orchestration. |
| Interface | `server` | Axum HTTP/WS, bearer auth, RPC dispatch, event broadcasting, APNS. |

`main.rs` currently wires all core service instances up front: event store,
session manager, orchestrator, skill registry, memory registry, provider
factory, process manager, tool config, subagent manager, job manager, tool
factory, transcription sidecar, cron scheduler, worktree services, RPC context,
method registry, WebSocket server, event bridge, cron broadcaster, and startup
jobs.

## RPC surface

The current source-of-truth registry in `server/rpc/handlers/mod.rs` registers
165 methods.

| Prefix | Count | Engine mapping |
|--------|------:|----------------|
| `worktree` | 23 | Worktree worker functions; some mutations use queue actions. |
| `session` | 13 | Session/event-store worker functions; session streams for live updates. |
| `agent` | 10 | Agent worker functions and queue-backed triggers. |
| `auth` | 9 | Auth worker functions; privileged settings/state operations. |
| `mcp` | 8 | MCP worker with discovery and tool-call functions. |
| `cron` | 8 | Cron trigger worker plus job management functions. |
| `context` | 8 | Agent context worker functions. |
| `system` | 6 | Engine/system worker functions. |
| `skill` | 6 | Skill registry worker plus session-skill state functions. |
| `tree` | 5 | Event graph query functions. |
| `sandbox` | 5 | Later sandbox/job worker functions. |
| `promptSnippet` | 5 | Prompt library state functions. |
| `job` | 5 | Queue/process worker functions and streams. |
| `git` | 5 | Git worker functions. |
| `events` | 5 | Event-store worker functions and subscriptions. |
| `import` | 4 | Import worker functions. |
| `voiceNotes` | 3 | Client/data worker functions. |
| `transcribe` | 3 | Transcription worker functions and streams. |
| `settings` | 3 | Settings state worker functions. |
| `promptHistory` | 3 | Prompt library state functions. |
| `plan` | 3 | Session-mode state functions. |
| `notifications` | 3 | Notification state/stream functions. |
| `filesystem` | 3 | Filesystem worker functions. |
| `device` | 3 | Device request/response worker functions. |
| `browser` | 3 | Stream worker functions. |
| `repo` | 2 | Repository query functions. |
| `model` | 2 | Model registry/provider functions. |
| `logs` | 2 | Logging/observability functions. |
| Singletons | 7 | `tool`, `message`, `memory`, `file`, `display`, `config`, `blob` worker functions. |

The current RPC registry should be mirrored into engine discovery before it is
replaced. The first compatibility worker can expose each RPC handler as a
function with ids such as `rpc::session.create` or normalized ids such as
`session::create`. The final architecture should prefer normalized `::`
function ids and keep legacy JSON-RPC names only as compatibility metadata.

## Runtime and agent loop

Current runtime data path:

1. Client sends WebSocket RPC.
2. RPC handler calls orchestrator/session/runtime services.
3. Runtime builds context, calls the LLM provider, processes stream events,
   executes tools, records events, and loops.
4. Orchestrator broadcasts events back to clients.

Engine mapping:

| Current concept | Future primitive |
|-----------------|------------------|
| `agent.prompt` | Trigger that enqueues `agent::run_turn`. |
| `agent.queuePrompt` / dequeue / clear | Queue worker functions for session prompt queues. |
| `AgentRunner` / turn runner | Agent worker function implementation. |
| Tool executor | Function invoker over tool functions, with guardrail/confirmation middleware. |
| Hooks | Trigger conditions or post-invocation triggers. |
| Subagents | Agent worker invocations on queue-backed child sessions. |
| Context manager | Context worker functions plus state/event dependencies. |
| Memory registry | Memory worker functions backed by workspace memory files. |
| Stream processor | Stream worker producer for tokens, thinking, tool calls, and lifecycle. |

Agent behavior must remain deterministic around persistence ordering. Existing
invariants like `agent.complete` before `agent.ready`, compaction before ledger
writing, and per-session serialized writes should become engine-level
acceptance tests before the agent loop is migrated.

## Tools and MCP

The base tool factory registers filesystem, shell, search/find, UI,
notification, web, display, computer-use, and MCP meta-tools. The runtime tool
factory adds subagent spawning, job management, waiting, and an LLM-backed
`WebFetch` override.

Engine mapping:

| Current tool area | Function namespace |
|-------------------|--------------------|
| Read/write/edit/search/find | `filesystem::*` and `workspace::*` functions. |
| Bash and background processes | `process::*`, queue-backed for long runs. |
| UI confirmation/questions | `approval::*` or `device::*` functions with stream/device triggers. |
| Notify app/display/computer-use | `client::*`, `display::*`, `computer::*` functions. |
| Web fetch/search | `web::*` functions, discoverable and separately auth-scoped. |
| SpawnSubagent | `agent::spawn` / `agent::run_turn` queue handoff. |
| ManageJob/Wait | `job::*` functions and job streams. |
| MCP meta-tools | `mcp::search` and `mcp::call`, later direct MCP tool discovery as engine functions if schema/token cost permits. |

MCP already has the right shape: external servers are discovered dynamically,
but compressed behind stable meta-tools. The engine should preserve that option
for large catalogs instead of forcing every MCP tool into the agent context.

## Event store, streams, and state

Current durable database tables are:

`sessions`, `events`, `blobs`, `branches`, `logs`, `device_tokens`,
`notification_read_state`, `cron_jobs`, `cron_runs`, `prompt_history`,
`prompt_snippets`, `workspaces`, and `schema_version`.

Engine mapping:

| Current persistence | Future primitive |
|---------------------|------------------|
| `events` table | Event-store worker; durable source of truth for session history. |
| WebSocket event broadcast | Stream worker subscriptions backed by event ids. |
| `logs` table | Observability worker with trace/span correlation. |
| `cron_jobs` / `cron_runs` | Cron trigger registrations plus run history. |
| Prompt snippets/history | State functions backed by current tables. |
| Device tokens/read state | Notification/device state functions. |
| Blobs | Blob worker functions. |
| Branches/workspaces | Worktree/repo state functions. |

The new state primitive should not replace the event store. It should cover
shared key/value or document state where event sourcing is not already the
source of truth. Session events stay append-only and reconstructable.

## Cron and automations

Current cron has a strong separation:

- Canonical definitions in `~/.tron/workspace/automations/automations.json`.
- Runtime state and run records in SQLite.
- Scheduler loop fires due jobs.
- Executor supports shell, webhook, agent, and system-event payloads.
- Delivery supports silent, WebSocket, APNS, and webhook outcomes.

Engine mapping:

| Current cron piece | Future primitive |
|--------------------|------------------|
| Job definition | Trigger registration with cron config and payload metadata. |
| Scheduler | Cron trigger worker. |
| Shell/webhook/agent/system event payloads | Functions invoked by the trigger. |
| Overlap/misfire/retry policy | Trigger metadata plus queue policy. |
| Run records | Observability/job history functions. |
| Delivery | Stream/pubsub/notification functions. |

The migration should keep the automations JSON file as the authoring source
until the engine state model has proven it can round-trip edits safely.

## Settings and auth

Settings are currently a single typed `TronSettings` tree loaded from
`~/.tron/system/settings.json` with defaults, strict validation, and iOS parity
requirements. Auth uses provider credentials plus a server WebSocket bearer
token for clients.

Engine mapping:

- `settings::get`, `settings::update`, and `settings::reset` become settings
  worker functions.
- Every server setting added to engine configuration still needs iOS settings
  parity.
- Client bearer auth remains distinct from future worker auth.
- External worker tokens should be scoped to namespace registration and
  invocation permissions.
- Auth provider operations remain privileged functions that are never exposed
  to untrusted workers.

## Client-facing surfaces

The first redesign branch is server-first. Current clients still depend on:

- WebSocket RPC framing at `/ws`.
- Event broadcasts over the same connection.
- `/health`, `/health/deep`, and `/metrics`.
- Pairing/onboarding bearer-token behavior.
- Device request/response events for approvals.
- APNS and notification read state.

During migration, a compatibility worker should keep these paths working while
new engine discovery and stream APIs are introduced. The final client API can
break, but it should break once into a clean engine-native surface rather than
through several intermediate public shapes.

## Documentation drift handled during inventory

One drift item was found while building this matrix: `events/mod.rs` said the
event enum had 60 variants, while `events/types/generated.rs` asserts 80. This
pass updates the module documentation to match the source of truth. The root
README RPC count matches the handler registry at 165 methods.
