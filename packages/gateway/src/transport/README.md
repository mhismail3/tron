# gateway/transport

## Purpose

The Gateway's network face: enrollment-authenticated HTTP and WebSocket serving,
request dispatch (`GatewayService`), command receipts, per-connection ordered writes,
session subscription and synchronization, uploads/blobs, live-view routes, logging
and diagnostic exports.

## Owns

`server.ts`, `gateway-service.ts` (the RPC switch; `scripts/tron docs rpc` lists it),
`command-receipts.ts`, `session-sync.ts`, `ordered-outbound-queue.ts`,
`connection-policy.ts`, `lan-endpoint.ts`, `tailscale-peer.ts`, `upload-http.ts`,
`request-span.ts`, `stall-diagnostics.ts`, `logger.ts` (`GatewayLogger`) and
`diagnostic-export.ts`.

## Contract

Wire contracts are owned by operation family:

- [Connection and request protocol](../../docs/wire-transport.md): HTTP/LAN/device
  admission, hello, cancellation, receipts, ordered writes and liveness.
- [Media and live viewing](../../docs/wire-media.md): display, browser observation,
  uploads/blobs, exports and prompt image bounds.
- [Session execution and presentation](../../docs/wire-session-execution.md): live
  projections, extension forms, queues, Stop/compaction and session-bound tools.
- [Session discovery and inspection](../../docs/wire-session-inspection.md): catalog,
  acquisition, attention/archive, history and resource reads.
- [Runtime configuration and administration](../../docs/wire-runtime-configuration.md):
  models and context windows, compaction settings, provider auth and packages.
- [Supervised host control](../../docs/wire-host-control.md): Gateway/Mac/device
  control, drain and exit proof, payload health.
- [Delegated activity and extension history](../../docs/delegated-activity.md):
  producer attribution, lifecycle and read-only child ownership.
- [Connection resilience](../../docs/connection-resilience.md): reconnect, protocol
  mismatch and liveness across the phone and Gateway.

**Protocol versions.** One protocol range is projected from the repository manifest
into Gateway payload, Mac app and iOS metadata; validators require one exact range.
A major step (v7, then v8, which replaced per-setting RPCs with `settings.change`)
has no older runtime path: the deployed update helper cannot promote a strictly newer
candidate, so it goes through the manual local Mac Release reinstall (Mac first, then
the iPhone app). Never widen the advertised minimum or allow a mixed pair to bypass
that handoff. Same-major updates use the owned Gateway update flow.

**Logging.** `GatewayLogger` is the one writer. `system.logs` serves the newest 1,000
persisted records (info and above); debug lives only in a bounded memory buffer that
`system.logs.export` appends. Records carry `timestamp`, `level`, `event`, `source`, a
redacted `message` and the writer-stamped `process`, `runtimeEpoch`, `payloadVersion`;
call sites add correlation as fields (`sessionId`, `connectionId`, `commandId`,
`requestID`, `method`, `outcome`, `code`, `reason`, `durationMs`, `step`) and pass a
thrown value as `error` (stored bounded and redacted with one level of `cause`). Levels,
streams, rotation and the event catalog: [observability](../../docs/observability.md).

## Invariants

- **Subscribe/open is a two-phase baseline barrier.** The connection subscribes,
  captures a snapshot cursor, and returns that snapshot with an ephemeral `syncToken`
  and a `subscriptionToken`; the connection-local token map is the only installed
  subscription. Only after `session.sync` acknowledges the exact baseline are later
  sequenced events released, exactly once and in order, except where the outbound
  queue supersedes unsent state that a `session.rebaseline` fully re-states. Fences
  (failure receipts, revision bumps, editor directives) and everything behind them
  arrive in order. Barrier overflow converges with a fresh `session.rebaseline`; only
  an unavailable session falls back to `transport.resyncRequired`.
- A failed open revokes its barrier, timer and subscription at once. Concurrent opens
  of one session on one connection are rejected; establishment and sync commit are
  request-and-token exact.
- A connection whose `hello` declared `clientRole: "mobile"` holds **one mobile
  presentation**: a newer `session.open` retires every other session's sync and
  subscription on it, and an earlier answer's `syncToken` is refused with `conflict`.
  Technical clients keep independent subscriptions.
- Accepted prompts and durable mutations never inherit socket cancellation.
- Every log record is redacted by the writer; a token or user path never reaches a
  file or an export.

## Entry points

- Add an RPC: a `case` in `GatewayService.invoke`, its protocol types in
  `src/protocol/`, and its family's wire doc.
- Receipt-backed mutations: `command-receipts.ts`; sync barrier: `session-sync.ts`.

## Signals

Transport's records (`http.upgrade`, `connection.*`, `rpc.*`, `gateway.resources`) are
catalogued in [observability](../../docs/observability.md) and
[connection resilience](../../docs/connection-resilience.md).

## Verify

```bash
scripts/tron verify --module gateway/transport
scripts/tron test gateway src/transport/sync-protocol.integration.test.ts \
  src/transport/server-capacity.integration.test.ts
```

`sync-protocol.integration.test.ts` covers the barrier and the retiring mobile open;
`server-http-lifecycle.integration.test.ts` exercises the real 15 s header, 30 s
body-idle and 300 s request deadlines (its five-minute trickling body is intended).
Behavior locks: `transport.lock.integration.test.ts`,
`transport.store.lock.integration.test.ts`, `command-receipts.lock.integration.test.ts`.

## Not here

- Session runtimes and receipts' meaning: [gateway/run](../sessions/README.md).
- Settings RPC semantics: [settings contract](../../docs/settings-contract.md).
- The terminal chat client: `src/client/` (`scripts/tron chat`).
