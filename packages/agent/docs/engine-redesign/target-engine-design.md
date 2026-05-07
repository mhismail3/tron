# Target Engine Design

The target design is now the branch shape: a pure engine capability fabric with
canonical functions as the only executable domain surface.

## Primitives

### Worker

A worker is a live actor that owns namespaces, registers functions/triggers, and
participates in discovery. Workers have:

- stable worker id;
- owner actor and authority grant;
- lifecycle and health;
- namespace claims;
- provenance and promotion rules.

In-process workers own Tron domain behavior. External workers are local and
session-scoped by default. Workspace/system promotion is explicit and audited.

### Function

A function is an agent-visible capability contract. Each function declares:

- canonical `namespace::function` id;
- owning worker;
- visibility and health;
- request/response schema;
- effect class and risk;
- authority requirement;
- idempotency contract when mutating;
- approval metadata when autonomous execution needs a user/system decision;
- resource lease metadata when shared resources are touched;
- compensation contract for high-risk or irreversible effects;
- provenance, revision, and catalog revision.

Hidden apply functions are still cataloged because queues, cron, and runtime
services need stable targets, but normal agents cannot discover or invoke them.

### Trigger

A trigger is a causal rule that invokes a function. Trigger dispatch records:

- trigger id and type;
- actor and actor kind;
- authority grant and scopes;
- trace id and parent invocation;
- target function revision and catalog revision;
- delivery mode;
- idempotency key;
- result or structured error.

Current trigger types include `json_rpc`, `manual`, `cron_schedule`, queue
delivery, stream publication, and local worker invocation paths.

## Public Transport

JSON-RPC exposes only:

- `engine.discover`
- `engine.inspect`
- `engine.watch`
- `engine.invoke`
- `engine.promote`

`engine.invoke` rejects noncanonical ids, hidden/internal ids, stale revisions,
unhealthy functions, unauthorized calls, missing explicit idempotency for
mutations, and approval-required autonomous writes before handler execution.

JSON-RPC request ids are correlation ids. They do not become command ids or
idempotency keys.

The server translates each public `engine.*` JSON-RPC call into an internal
`EngineTransportRequest` before dispatch. The envelope is protocol-neutral:
it contains the target function, trigger, actor, authority grant/scopes, trace,
parent invocation, session/workspace scope, payload, expected revision, and
explicit idempotency key. Later custom engine WebSocket transport work should
build this same envelope and call the same dispatch path.

## Agent Semantics

Agents use stable meta-capabilities to interact with a live catalog:

- discover visible, healthy capabilities;
- inspect schemas, authority, risk, effect, leases, and provenance;
- watch catalog changes by cursor;
- invoke canonical functions;
- request promotion of session-scoped capabilities.

The catalog is not frozen for a full turn. The provider tool surface is
projected from the live catalog at each model-call boundary, so newly registered
or removed capabilities are reflected on the next call.

## Guardrails

The engine fails closed on:

- missing function or trigger;
- hidden/unhealthy/stale target;
- schema validation failure;
- missing authority;
- missing idempotency for mutating functions;
- idempotency payload conflict;
- approval-required autonomous action;
- lease resolver failure or lease conflict;
- handler panic or structured handler error;
- missing stream/queue/approval service where the capability contract requires
  one.

Every failure path records a ledger attempt when enough function/trigger context
exists to do so.

## Runtime Primitives

- **Streams** are live/resumable delivery and watch material. They do not
  replace event-store session truth.
- **State** is scoped projection/cache data. It does not replace event sourcing.
- **Queues** are at-least-once execution with receipts, leases, retries,
  cancellation, backoff, and dead-letter state.
- **Approval** is a first-class pause/resume primitive that preserves original
  invocation context.
- **Leases** protect shared resources and are recorded with invocations.
- **Compensation records** make rollback/manual recovery state inspectable even
  when rollback is not automatic.

## Code Ownership

- Engine-generic behavior belongs in `engine`.
- Tron domain capability handlers and specs belong in `server/capabilities`.
- Reusable server-local dependencies belong in `server/services`.
- JSON-RPC framing/validation/registry belongs in `server/transport/json_rpc`.
- WebSocket owns delivery only; engine streams are the source for migrated live
  events.

## Non-Goals For This Branch

- No remote worker hosting.
- No managed-service behavior.
- No production database migration for engine ledger primitives.
- No public dotted JSON-RPC domain methods.
