# Target Tron-native engine design

This is the proposed v1 architecture for a Tron-owned engine. It borrows iii's
primitive model while preserving Tron-specific constraints: local-first daemon,
SQLite event sourcing, current settings parity, client pairing, skill/memory
files, MCP meta-tools, worktree isolation, and agent runtime invariants.

## Architecture overview

```text
clients / cron / state / queue / streams / workers
        |
        v
Trigger registry -> invocation router -> function registry
        |                 |                 |
        |                 v                 |
        |          trace/context            |
        |                 |                 |
        v                 v                 v
state worker       queue worker       in-process/external workers
stream worker      event worker       agent/tool/MCP/worktree workers
```

The engine is a routing and lifecycle layer. It should not become another
monolith that owns all business logic. Workers own behavior; the engine owns
registration, discovery, dispatch, persistence hooks, trace propagation, and
policy enforcement.

## Core types

The implementation can evolve, but v1 needs these contracts.

| Type | Required fields |
|------|-----------------|
| `FunctionId` | Stable string id, preferably `namespace::operation`. |
| `WorkerId` | Stable worker identity plus connection instance id for reconnects. |
| `TriggerId` | Stable trigger identity, unique per trigger registration. |
| `FunctionDefinition` | id, description, input schema, output schema, metadata, owner worker id, visibility, stability. |
| `TriggerDefinition` | id, trigger type, target function id, config, action, metadata, owner worker id. |
| `TriggerTypeDefinition` | id, description, config schema, delivery semantics. |
| `Invocation` | invocation id, function id, payload, action, trace context, auth context, deadline, caller metadata. |
| `InvocationResult` | invocation id, success payload or structured error, trace context, timing, retryability. |
| `WorkerDefinition` | id, kind, registered functions/triggers, health, metadata, capabilities. |

Schemas should use JSON Schema. Rust implementations can derive them with
`schemars`; hand-authored schemas are acceptable for compatibility functions.

## Worker kinds

Tron should add worker capability in this order:

1. In-process Rust workers: ordinary modules implementing a worker trait.
2. Compatibility workers: adapters that expose current RPC/tool behavior as
   functions while old handlers still exist.
3. External local workers: WebSocket protocol with scoped worker tokens.
4. Managed/sandbox workers: isolated processes or microVMs that can register
   functions after stricter policy exists.

In-process workers are enough to prove the model and migrate most current
server behavior. External workers should wait for stable ownership, schema,
auth, trace, and queue semantics.

## Registration and ownership

The engine must track ownership for every registered function, trigger, and
trigger type.

Rules:

- A worker can update or remove registrations it owns.
- A worker cannot replace another worker's registration unless policy grants
  explicit namespace ownership.
- Core namespaces are reserved.
- Reconnects re-register owned functions and triggers idempotently.
- Worker disconnect removes only registrations owned by that connection unless
  the registration is explicitly durable.
- Durable trigger definitions can outlive a worker only if their target
  function is still available or their queue policy permits waiting.

This ownership model is required before live extensibility is safe.

## Invocation lifecycle

The engine invocation path should be:

1. Resolve function id from the registry.
2. Check auth, visibility, namespace, and trigger/action policy.
3. Validate payload against request schema when present.
4. Create or continue a trace span.
5. Dispatch to an in-process handler, external worker, queue, or void action.
6. Record structured logs/events with invocation id and trace id.
7. Validate response schema when present.
8. Return result, receipt, or no-result according to action.

Invocation actions:

| Action | Result contract |
|--------|-----------------|
| `sync` | Caller receives success payload or structured error. |
| `void` | Caller receives immediate acknowledgement only; no retry. |
| `enqueue` | Caller receives queue receipt; worker execution is durable and retryable. |

Timeouts and cancellation should be part of the invocation context, not hidden
inside individual handlers.

## Built-in Tron workers

Initial worker namespaces:

| Worker | Responsibility |
|--------|----------------|
| `engine` | Discovery, health, worker/function/trigger catalogs, topology streams. |
| `rpc_compat` | Mirrors current RPC handlers into functions during migration. |
| `event` | Session/event-store append, read, reconstruct, subscribe. |
| `stream` | Durable client subscriptions for session events, tool output, jobs, browser/display, transcription. |
| `state` | Scoped KV/document state for non-event-sourced data. |
| `queue` | Durable named queues, receipts, retries, concurrency, DLQ/redrive. |
| `cron` | Cron trigger type backed by current automations definitions and SQLite runtime state. |
| `agent` | Prompt queue, run turn, abort, status, context, subagents. |
| `tool` | Tool registry and tool function invocation. |
| `mcp` | MCP search/call and server lifecycle functions. |
| `worktree` | Git/worktree functions and merge/conflict workflows. |
| `settings` | Typed settings read/update/reset with iOS parity guarantees. |
| `auth` | Provider auth and server/worker token management. |
| `observability` | Logs, metrics, traces, recent logs, health diagnostics. |

These workers may begin as modules in one process. The abstraction is still
valuable because discovery, routing, tests, and migration boundaries become
uniform before process isolation is introduced.

## Discovery API

The engine should expose discoverable functions equivalent to:

- `engine::functions::list`
- `engine::functions::get`
- `engine::workers::list`
- `engine::workers::get`
- `engine::triggers::list`
- `engine::trigger_types::list`
- `engine::topology::stream`

Function catalog entries need:

- id and description.
- input/output schemas.
- owner worker.
- visibility: internal, client, agent, worker, admin.
- stability: experimental, migration, stable.
- invocation modes allowed.
- auth scopes required.
- metadata for legacy RPC method names, current tool names, or client feature
  flags.

The agent context builder should eventually consume discovery output instead
of a hand-wired tool list. Large catalogs, especially MCP, can still be exposed
through search/call functions rather than all inline.

## Trigger model

Trigger types for v1:

| Trigger type | Use |
|--------------|-----|
| `rpc` | Compatibility route from existing JSON-RPC method to function. |
| `http` | Future direct HTTP endpoint to function. |
| `cron` | Scheduled automations. |
| `queue` | Durable job/message delivery. |
| `state` | Reactive state change. |
| `event` | Event-store append/replay conditions. |
| `stream` | Client or worker stream lifecycle events. |
| `device` | Device approval/response events. |
| `hook` | Pre/post invocation hooks and conditions. |

Trigger definitions should be data, not code branches inside the server. A
trigger points at a function and declares how delivery should happen.

## State, streams, and queue

State:

- Scoped key/value or document records.
- Not a replacement for session event sourcing.
- Supports `get`, `set`, `update`, `delete`, `list`, and state-change triggers.
- Uses explicit scopes and schema metadata where possible.

Streams:

- Durable cursor-based streams for clients and workers.
- Session events, tool output, jobs, display/browser streams, transcription,
  topology, and notifications should all use the same subscription model.
- WebSocket is transport, not the stream abstraction.

Queue:

- Named durable queues with receipt ids.
- Retry policy, max attempts, concurrency, FIFO option, cancellation, and DLQ.
- Queue events are observable and trace-linked.
- Agent prompt queues, background jobs, cron execution, subagents, and long
  tool runs should converge here.

## Observability

Every invocation needs an invocation id and trace id. The trace should propagate
through nested function calls, queue handoffs, cron runs, stream events, logs,
tool calls, and event-store appends.

Minimum v1 observability:

- Structured invocation start/end/error logs.
- Trace id and invocation id stored with relevant event/log/job records.
- `observability::logs::recent` and health functions mapped from current
  diagnostics.
- Span timing around dispatch and handler execution.

OpenTelemetry export can be a later worker. The first requirement is that a
single agent turn, tool call, queued job, and event broadcast can be followed
inside Tron's own logs and database.

## Security model

Security defaults:

- Client bearer tokens remain for paired Mac/iOS clients.
- Worker tokens are separate from client bearer tokens.
- External worker registration is disabled until scoped worker auth exists.
- Namespace registration is allowlisted.
- Core namespaces cannot be overridden by ordinary workers.
- Function visibility controls discovery output.
- Admin-only functions are hidden from agent and client contexts unless policy
  explicitly exposes them.
- Approval gates and confirmation flows are middleware/trigger conditions, not
  ad hoc checks spread through handlers.

## Client API transition

The final client API can break, but transition should be controlled:

1. Keep current `/ws` JSON-RPC while engine compatibility functions mirror it.
2. Add engine discovery and stream functions behind the server.
3. Move selected client flows to engine-native calls once stable.
4. Remove compatibility handlers only after Mac/iOS clients consume the new
   contract.

The server design should avoid committing to several public intermediate
protocols. Compatibility is for migration and validation, not a permanent
second API.
