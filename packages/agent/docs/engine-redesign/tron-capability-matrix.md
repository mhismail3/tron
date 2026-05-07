# Tron capability matrix

This inventory maps the current server to the live capability fabric. It is
based on source inspection on 2026-04-30.

## Current server shape

The Rust agent is a single crate with these top-level modules:

| Layer | Modules | Current role |
|-------|---------|--------------|
| Foundation | `core`, `settings`, `skills`, `transcription` | IDs, settings schema, skill registry, transcription sidecar. |
| Services | `cron`, `events`, `import`, `llm`, `mcp`, `prompt_library`, `tools`, `worktree` | Durable data, LLM providers, external tools, automation, git/worktree, imports. |
| Orchestration | `runtime` | Agent loop, context, hooks, memory, subagents, session orchestration. |
| Interface | `server` | Axum HTTP/WS, bearer auth, RPC dispatch, event broadcasting, APNS. |

`main.rs` wires all core service instances up front: event store, session
manager, orchestrator, skill registry, memory registry, provider factory,
process manager, tool config, subagent manager, job manager, tool factory,
transcription sidecar, cron scheduler, worktree services, RPC context, method
registry, WebSocket server, event bridge, cron broadcaster, and startup jobs.

## RPC surface

The current source-of-truth registry in `server/rpc/handlers/mod.rs` registers
170 methods. The exploration branch now registers a `rpc` transport
compatibility worker, domain-owned in-process workers for migrated groups,
canonical domain functions for generic-triggered methods, non-routable
`rpc::<method>` metadata for handler-only inventory, and `json_rpc` trigger
bindings from the legacy method names into the canonical functions.

Fully collapsed groups now include prompt library, settings, logs, skills,
notifications, plan, events, approval get/list/resolve, job controls, the
current agent command controls except `agent.prompt`, and basic filesystem.
Session create/delete/fork/archive/unarchive/archiveOlderThan/export and
context compaction/clear commands are also generic-triggered canonical
functions. Migrated groups delete their method-specific business handlers as
they move behind canonical functions; a few remaining handler structs are
test-only wire fixtures while older regression suites are moved to direct
engine parity tests.

The table is intentionally not just a method inventory. Each row maps current
behavior to first-principles engine concerns: visibility, effect, idempotency,
authority, and causality. A subsystem is not ready to migrate until those
answers are explicit enough to test.

| Prefix | Count | Future mapping | Default visibility | Effect/idempotency | Authority and causality |
|--------|------:|----------------|--------------------|--------------------|-------------------------|
| `system` | 6 | `system::*` and `engine::*` functions. | Client/admin/system. | Mostly reads; shutdown/update checks need explicit risk metadata. | Trace client/system actor and server lifecycle effects. |
| `codexApp` | 1 | `codex_app::*` lifecycle/status functions. | Client/admin. | Pure status read initially; future lifecycle writes need idempotency. | Managed app-server status links to server startup/shutdown authority. |
| `blob` | 1 | `blob::get`. | Session/workspace by blob ownership. | Pure read. | Include blob provenance and session/workspace scope. |
| `session` | 13 | `session` domain worker; all create/delete/fork/archive/export plus safe reads are generic-triggered except resume. | Client/session/workspace. | Reads plus idempotent mutations; create/archiveOlderThan use system idempotency, session-specific commands use session idempotency. | Reads preserve event-store reconstruction; mutations call the existing command service behind canonical functions and preserve broadcasts/worktree cleanup. |
| `agent` | 10 | `agent::*` functions and queue triggers; status, abort/tool abort, queue controls, subagent-result delivery, and confirmation/answer submission are generic-triggered. | Session by default. | `agent.prompt` remains deferred; migrated writes are session-scoped idempotent commands, with approval metadata on high-risk abort. | Turn id, parent invocation, catalog revision, authority grant, stream event, and queue/event-store causality are mandatory. |
| `model` / `config` | 3 | `model::*` and `config::*`. | Client/agent where safe. | List is read; switch/reasoning changes are idempotent writes. | Changes must record session/config scope and actor. |
| `context` | 9 | `context` domain worker; safe reads and compaction/clear commands are generic-triggered. | Session. | Reads plus high-risk reversible/irreversible context mutations with idempotency and approval metadata where destructive. | Compaction ordering, event writes, cache invalidation, and broadcasts remain deterministic behind canonical functions. |
| `events` | 5 | Fully generic-triggered `events` domain worker functions, including stream-backed subscribe/unsubscribe. | Session/workspace/admin. | Reads plus append-only `events.append` and idempotent subscribe/unsubscribe. | Event append and stream subscription records carry trigger/invocation metadata. |
| `settings` | 3 | Fully generic-triggered `settings::*` state functions. | Admin/client. | Read plus high-risk reversible system writes with engine-ledger idempotency. | Must preserve iOS settings parity, strict validation, rollback, MCP reload, and Codex App Server reconfiguration causality. |
| `approval` | 3 | Public `approval.get/list/resolve` JSON-RPC triggers over the engine approval primitive; `approval.request` remains agent/tool-only. | Client/user/admin; resolution requires user/system/admin actor kind. | Reads plus system-idempotent resolve. | Pending/approved/denied/executed records preserve original actor, trace, parent, trigger, scopes, payload fingerprint, and idempotency key. |
| `auth` | 9 | `auth::*` privileged functions. | Admin only. | External/account side effects; high risk. | Never agent-visible without explicit approval and authority. |
| `tool` | 1 | Tool-result compatibility function. | Session. | Append/update tool result; idempotent by tool call id. | Link to parent tool invocation and turn. |
| `message` | 1 | `message::delete`. | Session/client. | Idempotent write. | Event-sourced deletion marker. |
| `logs` | 2 | Fully generic-triggered `observability::logs::*` compatibility functions. | Admin/client filtered. | Ingest append-only with system idempotency; recent read. | Trace/log correlation mandatory; duplicate transport ingests replay before DB insertion. |
| `memory` | 1 | `memory::retain`. | Session/workspace with policy. | Idempotent/append memory update. | User memory files remain governed; no hardcoded personal data. |
| `mcp` | 8 | `mcp::*` worker functions. | Agent/client/admin filtered. | Lifecycle writes require idempotency; search/list are reads. | MCP tool calls inherit caller authority and trace. |
| `skill` | 6 | Fully generic-triggered `skills` domain worker functions over registry and session state. | Session/workspace. | Activate/deactivate are session-scoped idempotent writes; refresh is system-scoped. | Skill provenance and denied/allowed tools affect capability views; activation events are causally linked. |
| `filesystem` / `file` | 4 | `filesystem` domain worker; home/list/read/createDir are generic-triggered compatibility functions. | Session/workspace by path policy. | Reads plus idempotent createDir; broader file writes later. | Path guards, workspace scope, and file effect metadata required before broader writes migrate. |
| `tree` | 5 | `event_graph::*`. | Session/workspace. | Pure reads. | Include source event revision/cursor in result metadata. |
| `import` | 4 | `import::*`. | Admin/workspace. | Preview/list reads; execute append-only/idempotent by import source. | Import provenance and dedupe tags mandatory. |
| `browser` / `display` | 4 | `browser::*`, `display::*`, stream functions. | Session/client. | Stream lifecycle idempotent by stream id. | Link stream writes to session and actor. |
| `job` | 5 | Fully generic-triggered `job` domain worker for background/cancel/list/subscribe/unsubscribe plus queue functions. | Session/client/agent filtered. | Job controls are idempotent by request/job id; cancel is high-risk approval-metadata-bearing. | Background/cancel enqueue hidden apply functions, synchronously drain compatibility receipts, preserve existing job/process manager behavior, persist user-action events, and publish job/queue stream records. |
| `worktree` | 23 | `worktree::*` functions and triggers. | Workspace/session. | Git mutations require idempotency, locks, and compensation where possible. | Branch/worktree state machine must stay auditable. |
| `transcribe` | 3 | `transcription::*`. | Client/session. | Audio processing idempotent by input hash/request id. | Sidecar lifecycle and stream progress trace to request. |
| `device` | 3 | `device::*` and approval triggers. | Client/session/admin. | Register/unregister/respond idempotent by token/request id. | Approval responses must link to pending invocation. |
| `plan` | 3 | Fully generic-triggered `plan` domain worker functions. | Session. | Idempotent session-scoped state writes. | Plan transitions record actor, session, trigger id, and idempotency context. |
| `voiceNotes` | 3 | `voice_note::*`. | Client/session. | Save/delete idempotent by note id. | Link audio/transcription/provenance. |
| `git` / `repo` | 7 | `git::*`, `repo::*`. | Workspace/admin. | Mutations require idempotency and locks. | Remote side effects need risk and approval policy. |
| `sandbox` | 5 | `sandbox::*` worker lifecycle. | Session by default. | Lifecycle idempotent by sandbox id; high-risk execution gated. | Created workers inherit narrowed delegated authority. |
| `notifications` | 3 | Fully generic-triggered `notifications` domain worker functions. | Client/session. | Mark read/all-read are system-scoped idempotent writes; list is read. | Notification effects link to source invocation/event and trigger metadata. |
| `promptHistory` / `promptSnippet` | 8 | `prompt_library::*`; all methods are generic-triggered in the RPC bridge. | Workspace/client. | Prompt-library writes use engine-ledger idempotency; delete/clear effects carry irreversible-risk metadata. | Prompt provenance and retention policy recorded. |
| `cron` | 8 | `cron::*` trigger worker. | Admin/workspace. | Job definitions idempotent by job id; runs append-only. | Trigger fires record schedule, misfire/overlap policy, and target invocation. |

## Runtime and agent loop

Current runtime path:

1. Client sends WebSocket RPC.
2. RPC handler calls orchestrator/session/runtime services.
3. Runtime builds context, calls the LLM provider, processes stream events,
   executes tools, records events, and loops.
4. Orchestrator broadcasts events back to clients.

Live fabric mapping:

| Current concept | Future primitive | Agent-native requirement |
|-----------------|------------------|--------------------------|
| `agent.prompt` | Trigger that invokes or enqueues `agent::run_turn`. | Record actor, session, catalog revision, idempotency key, and prompt causality. |
| Turn runner | `agent::run_turn` function. | Uses stable meta-capabilities over live catalog. |
| Tool executor | `engine::capabilities::invoke` over tool functions. | Enforce visibility, authority, effect, idempotency, and approvals before each tool. |
| Context manager | `context::*` functions. | Context can include live discovery instructions, not static full catalog dumps. |
| Hooks | Trigger conditions or post-invocation triggers. | Loop/depth and idempotency policy prevents runaway cascades. |
| Subagents | Agent worker invocations with delegated authority. | Child agents inherit narrowed grants, not full parent authority. |
| Memory registry | `memory::*` functions backed by workspace files. | Memory writes are governed and idempotent; no personal literals in code/docs. |
| Stream processor | `stream::*` producer for tokens, thinking, tool calls, lifecycle. | Stream records carry trace and parent invocation ids. |

The agent loop should be redesigned around a small stable meta-tool surface:
search/inspect/invoke/watch/spawn/promote. The live catalog provides the actual
capabilities.

## Tools and MCP

The base tool factory currently registers filesystem, shell, search/find, UI,
notification, web, display, computer-use, engine capability tools, and MCP
meta-tools. The runtime tool factory adds subagent spawning, job management,
waiting, and an LLM-backed `WebFetch` override.

Live fabric mapping:

| Current tool area | Function namespace | Effect and policy |
|-------------------|--------------------|-------------------|
| Read/search/find | `filesystem::*`, `workspace::*`. | Pure reads with path scope policy. |
| Write/edit | `filesystem::*`. | Idempotent/reversible writes with file revision and diff provenance. |
| Bash/process | `process::*`, `job::*`, later `sandbox::*`. | High risk; queue-backed, audited, and approval-gated by policy. |
| UI confirmation/questions | `approval::*`, `device::*`. | Approval trigger resolves pending invocation. |
| Notify/display/computer-use | `client::*`, `display::*`, `computer::*`. | Client/device effects with explicit visibility and risk. |
| Web fetch/search | `web::*`. | External reads; auth and network policy recorded. |
| Engine discover/inspect/watch/invoke | `engine::*` plus canonical domain functions. | Stable agent meta-tools over the live catalog; mutating invokes require explicit idempotency and approval-gated functions fail closed. |
| SpawnSubagent | `agent::spawn`, `agent::run_turn`. | Delegated authority and session-scoped visibility. |
| ManageJob/Wait | `job::*`. | Queue/job idempotency and causal status streams. |
| MCP meta-tools | `mcp::search`, `mcp::call`. | Preserve compressed catalog for large MCP tool sets; calls inherit authority. |

MCP already resembles a live capability bridge. Tron should keep the searchable
meta-tool pattern for large catalogs while allowing selected MCP functions to
be promoted into the live catalog when safe.

## Event store, state, streams, and queues

Current durable database tables:

`sessions`, `events`, `blobs`, `branches`, `logs`, `device_tokens`,
`notification_read_state`, `cron_jobs`, `cron_runs`, `prompt_history`,
`prompt_snippets`, `workspaces`, and `schema_version`.

| Persistence area | Future primitive | Rule |
|------------------|------------------|------|
| `events` table | `event` worker and causal ledger. | Session truth remains append-only and reconstructable. |
| WebSocket broadcasts | `stream` worker. | Transport-independent streams with cursors and trace metadata. |
| `logs` table | `observability` worker. | Client log ingestion is append-only and engine-idempotent; logs correlate to trace/invocation ids. |
| `cron_jobs` / `cron_runs` | `cron` trigger worker. | Definitions become triggers; run history remains durable. |
| Prompt snippets/history | `prompt_library` functions. | Idempotent by id/hash with provenance. |
| Device/read state | `device` and `notification` functions. | Approval responses link to pending invocations. |
| Blobs | `blob` functions. | Blob ids and provenance flow through causality. |
| Branches/workspaces | `worktree` and `repo` functions. | Worktree lifecycle remains auditable. |

State is useful for shared mutable values, but it must not replace the event
store. Queues are at-least-once by default, so queue-backed mutating functions
must have idempotency contracts.

## Settings and auth

Settings remain a typed `TronSettings` tree loaded from the active profile plus
the sparse `~/.tron/profiles/user/profile.toml` `[settings]` overlay, with
defaults, strict validation, and iOS parity requirements.

Engine mapping:

- `settings::get`, `settings::update`, and `settings::reset` become privileged
  settings functions.
- New engine settings still need iOS settings parity.
- Client bearer auth remains separate from worker auth.
- Future worker tokens are authority grants with namespace, visibility,
  invocation, trigger, and delegation rights.
- Auth provider operations are high-risk admin functions, never broadly
  agent-visible.

## Client-facing surfaces

Current clients depend on:

- WebSocket RPC framing at `/ws`;
- event broadcasts over the same connection;
- `/health`, `/health/deep`, and `/metrics`;
- pairing/onboarding bearer-token behavior;
- device request/response events for approvals;
- APNS and notification read state.

During migration, a compatibility worker keeps these paths working while live
catalog and stream APIs are introduced. The final client API can break once
into the engine-native surface.

## Migration readiness checklist

Before migrating any row above, define:

- actor kinds allowed to discover and invoke it;
- default visibility and promotion path;
- effect class and risk level;
- idempotency key source and dedupe scope;
- causal records written on success, failure, retry, and cancellation;
- behavior when the owner worker disconnects or the function revision changes;
- tests proving the current RPC path and engine path agree during migration.
