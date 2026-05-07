# Pure Engine Cutover

This branch intentionally cut over to the pure engine shape. Current
documentation describes the architecture that exists now.

## Public Cutover

- Public JSON-RPC methods: `engine.discover`, `engine.inspect`,
  `engine.watch`, `engine.invoke`, `engine.promote`.
- Removed dotted domain methods return `METHOD_NOT_FOUND`.
- `engine.invoke` accepts canonical `namespace::function` ids only.
- Mutating invocations require explicit idempotency in the payload.
- JSON-RPC request ids are correlation ids only.

## Server Cutover

- Canonical capability specs in `server/capabilities/catalog.rs` seed the live
  catalog.
- Domain behavior lives in `server/capabilities` and reusable helpers in
  `server/services`.
- JSON-RPC transport code lives in `server/transport/json_rpc`.
- WebSocket delivery is a pump over engine stream records.
- Queue, approval, stream, state, lease, compensation, cron, tool, MCP, and
  local worker paths are engine primitives rather than separate harness layers.

## Acceptance Gates

Before this branch is considered stable, verification must prove:

- public transport method count is exactly 5;
- no production handler-shaped RPC implementation remains;
- no public dotted-method dispatch path remains;
- no engine-native write can execute without an idempotency key;
- high-risk autonomous writes produce approval-required state before execution;
- stream-first event classes do not double-broadcast;
- queue drain and approval resolution preserve original trace, authority,
  parent invocation, idempotency, leases, and compensation metadata;
- model tool schemas are projected from the live engine catalog at each model
  call boundary.

## Client Follow-Up

This branch is server-first and intentionally breaks old clients. The next
client work should replace dotted method calls with:

1. `engine.discover` for available capabilities;
2. `engine.inspect` for contracts and schema details;
3. `engine.invoke` for canonical function execution;
4. `engine.watch` or stream subscriptions for live changes;
5. `engine.promote` for explicit promotion flows.
