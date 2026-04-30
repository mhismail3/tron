# iii teardown

This document records the reference architecture analysis for iii. It is a
design input, not an implementation dependency.

## Licensing boundary

The iii repository separates licenses by area. The engine is under Elastic
License 2.0, while SDKs, console, and docs are Apache-2.0. Tron should treat
iii engine code as reference material only and should not copy implementation
code, tests, protocol structs, or worker internals without separate approval.

The useful artifact is the model: a small set of primitives that collapse many
backend categories into one runtime. Tron should implement those primitives in
its own style, against its own persistence, auth, settings, event, and agent
runtime constraints.

## Core model

iii centers the system on three primitives:

| Primitive | Role | Tron lesson |
|-----------|------|-------------|
| Function | Stable unit of work, usually named `domain::operation`, with optional request/response schema metadata. | Tron tools, RPC handlers, cron payloads, MCP meta-tools, worktree operations, and agent turns can all become callable functions. |
| Trigger | Declarative binding that causes a function to run: HTTP, cron, queue, state change, stream event, pub/sub topic, or a custom source. | Current Tron RPC routing, cron schedules, event broadcasts, notification actions, and agent queue prompts are all trigger shapes. |
| Worker | Any process or in-process module that registers functions/triggers and can handle invocations. | Tron can start with in-process Rust workers, then add external workers over a Tron-owned protocol. |

The important shift is that "agent harness" and "backend" stop being separate
layers. Agent tools become functions. Memory and state become state functions.
Handoffs become queue triggers. Client updates become stream or pub/sub
triggers. The model does not require every operation to be autonomous; thick
and thin harnesses are both compositions of the same primitives.

## Engine responsibilities

The iii engine owns:

- Worker connection lifecycle.
- Function registry and function owner tracking.
- Trigger type registry and trigger instance registry.
- Invocation routing across local and external workers.
- Deferred invocation results for external calls.
- Discovery functions for functions, workers, triggers, and trigger types.
- Topology notifications when functions or workers appear/disappear.
- Built-in worker initialization from config.
- External worker spawning and reload.
- Trace propagation across nested calls and queue handoffs.

The biggest implementation lesson for Tron is owner tracking. iii records which
worker registered each function/trigger so a reconnecting worker can overwrite
its own stale registrations without deleting another worker's newer version.
Tron needs the same invariant before external or hot-reloadable workers are
allowed.

## Protocol shape

iii's worker protocol is JSON over WebSocket. The notable messages are:

- `registerfunction`: worker registers a callable function with id,
  description, request/response formats, metadata, and optional HTTP
  invocation reference.
- `unregisterfunction`: worker removes a function it owns.
- `invokefunction`: worker or engine asks for a function call by function id,
  payload, invocation id, trace context, baggage, and optional trigger action.
- `invocationresult`: worker replies with result or error.
- `registertrigger`: worker registers a trigger instance with id, trigger
  type, function id, config, and metadata.
- `unregistertrigger`: worker removes a trigger.
- `registertriggertype`: worker adds a new trigger type and its config schema.
- `registerservice`: worker advertises a service namespace.
- `functionsavailable`: topology notification for function catalog changes.
- `ping` / `pong`: liveness.

Tron should not aim for wire compatibility in v1. It should use the same
conceptual envelope: stable ids, typed JSON payloads, schema metadata, trace
context, invocation ids, and explicit ownership.

## Invocation actions

iii distinguishes three call modes:

| Mode | Behavior | Tron use |
|------|----------|----------|
| Sync/default | Caller waits for a result or error. | Reads, validations, direct tool calls, most RPC compatibility calls. |
| Void | Fire-and-forget, no result and no durable retry. | Best-effort broadcasts, non-critical telemetry, UI notifications where loss is acceptable. |
| Enqueue | Durable queue handoff to a named queue, with receipt id, retry, concurrency, FIFO, and DLQ policy. | Agent prompt queues, background jobs, cron fanout, subagent handoff, delayed worktree operations, long tool runs. |

Tron should make this mode explicit in the invocation API instead of hiding it
inside each subsystem. A caller should be able to see whether it is doing a
blocking call, a best-effort notification, or a durable handoff.

## Built-in workers

iii ships many capabilities as workers. The table below maps the useful design
pattern to Tron.

| iii worker | Reference behavior | Tron-native interpretation |
|------------|--------------------|----------------------------|
| `iii-worker-manager` | Mandatory WebSocket bridge for SDK workers, optional RBAC/middleware, registration prefixing, multiple listeners. | Add a worker gateway after in-process engine primitives exist; default deny external registration until scoped tokens/RBAC exist. |
| `iii-http` | HTTP trigger type that maps HTTP routes to functions. | Replace direct Axum route proliferation with HTTP/WS/client triggers where useful; keep `/health` and bootstrap endpoints ordinary until engine is ready. |
| `iii-queue` | Named queues plus topic subscribers, retries, concurrency, FIFO, DLQ, redrive/discard functions. | Unify agent prompt queues, process jobs, subagent completion queues, cron execution, and long-running tool handoff. |
| `iii-state` | Scoped key-value state with functions and reactive state triggers. | Add a state primitive, but do not flatten event-sourced sessions into KV. Session history remains event-sourced. |
| `iii-stream` | Durable real-time stream API and stream triggers. | Replace ad hoc WebSocket subscriptions with discoverable streams for session events, tool output, jobs, browser/display streams, and transcription progress. |
| `iii-pubsub` | Topic publish/subscribe worker. | Use for best-effort fanout and UI notifications where durable event sourcing is unnecessary. |
| `iii-cron` | Cron trigger type backed by adapter locks. | Convert Tron cron definitions into trigger registrations while retaining current automations file and SQLite runtime state during migration. |
| `iii-observability` | OpenTelemetry traces, metrics, structured logs, alerts, sampling. | Attach invocation trace ids to Tron logs/events/jobs/tool calls first; external OTEL export can follow. |
| `iii-bridge` | Connects two iii instances and exposes/forwards functions. | Later candidate for connecting local Tron daemon, sandbox workers, and remote/edge workers. |
| `iii-exec` | Startup shell pipelines/watch behavior. | Not a core primitive for Tron v1; background `Bash` jobs should go through queue/process worker semantics instead. |

## Discovery

iii exposes live catalog functions such as:

- `engine::functions::list`
- `engine::workers::list`
- `engine::triggers::list`
- `engine::trigger-types::list`
- `engine::functions-available`
- `engine::workers-available`

This is one of the most important pieces to adopt. Tron agents should receive
the current live capability catalog instead of a hand-maintained tool list or
server/client assumptions. Discovery needs schema metadata, ownership,
visibility, auth scope, stability labels, and human-readable descriptions.

## Schema metadata

iii SDKs attach JSON Schema request and response formats. Node can use explicit
schemas such as Zod; Python can infer from Pydantic/type hints; Rust uses
`schemars`.

Tron should treat schemas as required for externally visible functions and
optional only for internal bootstrap functions. Schemas are useful for:

- Agent tool planning and validation.
- Client UI generation and compatibility checks.
- Testing payload drift.
- Runtime guardrails before dispatch.
- Documentation generation.

## SDK behavior

The iii SDKs do three things Tron should copy conceptually:

- Reconnect with backoff.
- Re-register owned functions/triggers after reconnect.
- Maintain an invocation map for in-flight requests and results.

Tron should add these behaviors only after the in-process engine is stable.
External SDKs before ownership, auth, schema, and queue semantics are settled
would make the system harder to debug.

## RBAC and middleware

iii's worker manager can authenticate workers through an auth function, apply
middleware, filter exposed functions, restrict registration, restrict trigger
types, and prefix function registrations.

Tron should adapt this as:

- External workers require a scoped worker token, never the iOS bearer token.
- Tokens grant explicit namespace registration rights and invocation rights.
- Workers cannot override core/system namespaces by default.
- Registration hooks validate schemas, namespace ownership, and metadata.
- Middleware is just function composition: auth, rate limits, audit, and
  confirmation gates should be functions or trigger conditions.

## Sandbox model

iii's sandbox support is a worker that can create microVM workers, run commands,
perform filesystem operations, and register new functions from isolated
environments. The recursive property matters more than the exact microVM stack:
a worker can create another worker, which registers capabilities into the same
catalog.

For Tron, sandbox workers should be a late phase. Current Bash/container
capabilities should first be normalized as engine functions and durable jobs.
Only then should sandbox-created workers be allowed to register new functions.

## What Tron should adopt

- The three primitive model: worker, function, trigger.
- Live discovery with schema metadata and topology change events.
- Explicit invocation modes: sync, void, enqueue.
- Owner-tracked function and trigger registration.
- State, queue, stream, cron, pub/sub, and HTTP as workers/triggers, not
  special framework categories.
- Trace propagation across every function call and durable handoff.
- Reconnect and re-registration semantics for external workers.
- Scoped RBAC before external worker registration.

## What Tron should avoid initially

- Direct iii engine dependency or copied engine code.
- Public external worker protocol before in-process primitives prove out.
- Treating key-value state as a replacement for the session event store.
- Allowing agents to create sandbox workers before registration policy,
  namespace ownership, and audit trails are mature.
- Rebuilding every client surface before the server contract stabilizes.
