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

Wire contracts by owner (method list: `scripts/tron docs rpc`):
[protocol](protocol.md) (admission, hello, cancellation, receipts, ordered writes,
liveness), [execution](../sessions/execution.md), [catalog](../sessions/catalog.md),
[display](../display/README.md), [uploads](../machine/uploads.md),
[runtime configuration](../admin/runtime-configuration.md),
[host control](../admin/host-control.md),
[delegated activity](../sessions/delegated-activity.md) and
[connection resilience](../../docs/connection-resilience.md).

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
streams and rotation: [observability](../../docs/observability.md); records: Signals below.

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

Connection records carry `connectionId`, `peerClientId`, `peerAttemptId` and `peerEpoch`
(the peer's hello key, when sent); "the host sample" is `stall-diagnostics.ts`'s
heartbeat-refreshed memory reading with its age.

| Signal | Level | Meaning |
|---|---|---|
| `gateway.bound` | info | The listener bound, before warmup; with `gateway.listening` it bounds the warmup window |
| `gateway.startup-phase` | info | `setStartupPhase` named the warmup phase `/health` reports during a 503 warmup (phase in the message) |
| `gateway.listening` | info | Warmup finished and the Gateway serves; host and port in the message |
| `gateway.transport-closing` | info | `finishClose` began retiring sockets; separates transport retirement from process stop |
| `lan.listener` | info for a bind, a rebind or an expected disable (`setting_off`, `no_private_address`); warning for `bind_failed` and the `certificate_*` disables | The private-LAN listener (`lan-endpoint.ts`) bound, moved or disabled, written only on a transition: `state`, `family`, `port`, and `reason` while disabled; never the address |
| `gateway.restart.requested` | info | An authenticated client requested a restart (`gateway-service.ts`); active-session count in the message; opens the drain timeline |
| `gateway.stop.requested` | info | An authenticated client requested an intentional stop, recorded before its receipt settles |
| `gateway.event-loop-delay` | warning | A heartbeat arrived `EVENT_LOOP_DELAY_WARNING_MS` (1,000 ms) late: `durationMs`, GC pauses, loop utilization and the host sample ([reading the host fields](../../docs/connection-resilience.md#reading-the-host-memory-fields)) |
| `gateway.resources` | debug for a quiet minute; info when a named step moved; warning past `HEAP_WARNING_SHARE` (0.70), `EVENT_LOOP_P99_WARNING_MS` (100 ms) or `UNAUDIENCED_SNAPSHOT_WARNING` | One closed window per `RESOURCE_SAMPLE_INTERVAL_MS` (60 s): heap, RSS, loop delay p50/p99/max and utilization, live runtimes with transcript bytes and subscribers, snapshot builds (and those with no ready recipient), per-topic frames and bytes, catalog walks, fsyncs (`syncDurably`), outbound accepted and coalesced bytes. Steps: p99 in 20 ms bands, max in 250 ms bands, heap ±256 MiB, RSS ±10%, a runtime published or evicted |
| `gateway.resources-failed` | warning, once per run of failures | A resource sample threw (`error`), or a tick found the previous sample still running (`reason`) |
| `connection.opened` | debug for a local probe, info for a paired device | The first valid hello on an admitted socket: correlation, local/paired, role, `compression` ([frame compression](../../docs/connection-resilience.md#frame-compression)), admission-to-hello time; for a device the host sample and `hostSampleAgeMs` |
| `http.connection-unused` | warning | An admitted TCP socket (main or LAN) closed before any request or upgrade: `transport`, `acceptToCloseMs`, `bytesRead`, platform `code`, `transportEnd`, `reason` (`silent`, `partial_http`, `invalid_http`, `tls_error`, `incomplete_tls_or_http`); never packets, paths or addresses |
| `connection.closed` | debug for a local probe, info for a device | The socket closed: correlation, `durationMs`, `transportEnd` (`reset`, `timeout`, `fin`, `none` = no cause observed); close detail, frame counters and queue ages in the message; for a device the host sample |
| `connection.superseded` | warning | A newer connection from one device identity displaced older ones: the displaced socket's correlation, inbound age and the limits |
| `connection.heartbeat-timeout` | warning | Three heartbeat intervals passed with no inbound frame; miss count, inbound and write-progress ages and queue counters say whether the peer was silent or the writer stuck |
| `connection.inbound-silent` | warning | No inbound frame for `INBOUND_SILENCE_WARNING_MS` (12 s) while liveness was expected; once per episode: `peerPath`, `peerPathSource`, `peerRelay` and Tailscale peer counters from one bounded `tailscale status` read, `unansweredPingMs` |
| `connection.inbound-resumed` | info | The first inbound frame after a silence episode; `silentMs` |
| `connection.outbound-capacity` | warning | The outbound queue hit its frame or byte bound and the connection closes: queue counts, high-water marks, `oldestTopic`, `nextTopic`/`nextBytes`, socket buffer and process pressure |
| `connection.write-error` | error | A socket write failed: `error`, completed and accepted frame counts |
| `connection.projection-rejected` | warning when an oversized frame becomes a bounded preview; error when encoding throws | Type, topic, byte count and node bounds; never the payload or the exception |
| `http.connection-capacity` | warning | A new HTTP socket arrived at the connection limit; counts and limits in the message |
| `http.request-capacity` | warning | An HTTP request arrived at admission capacity; a refused upgrade is `http.upgrade` `reason=request_capacity` |
| `http.upgrade` | debug when opened at hello within `UPGRADE_SLOW_WARNING_MS` (1,000 ms); info for `warming_up`/`shutting_down`; warning when abandoned, otherwise rejected or slower | One record per WebSocket upgrade, at the phase it ends: `outcome`, `phaseReached`, `reason` (the bound or side that ended it), `transport` (`lan`, `tailscale`, `primary`), `acceptToUpgradeMs` (from the TCP accept), `authMs`, `handshakeMs`, `helloMs`, correlation once known, `peerProtocolVersion` on `protocol_mismatch` |
| `http.upload.phase` | info | An authenticated `/v1/uploads` request with a valid `X-Tron-Request-ID` reached the route (`step=received`) or was staged (`step=staged`); elapsed time, staged bytes; never host, filename, MIME type, token or body |
| `http.upload` | info when the response finished; warning on failure | One terminal record per upload: `requestID`, `outcome` (`response-finished`, `failure`), failure category, `durationMs`, staged or observed bytes; finishing is not proof the phone received it |
| `http.upload-cleanup` | warning | Discarding an abandoned upload failed other than by conflict or not-found; owned bytes remain |
| `rpc.error` | warning for a `GatewayError` other than `internal`; error, with `error`, for a fault or `internal` | An RPC handler threw: `method`, `requestID`, `connectionId`, `sessionId`, `commandId`, `code`, `outcome`, `reason`, `operationId`, `ageMs` |
| `rpc.received` | info | An admitted `system.logs.export` reached its handler (`outcome=admitted`); joins the phone's `logs.export.requested` to `rpc.completed` |
| `rpc.completed` | debug for a success under `SLOW_RPC_WARNING_MS` (1,000 ms), or `SLOW_PROMPT_WARNING_MS` (250 ms) for a prompt; warning at or above it, on failure or on `connectionClosed` | Every RPC end: correlation, `outcome`, `durationMs`, `stages` (`request-span.ts`, most expensive first, ≤ 1,024 bytes) and `unaccountedMs`. Prompt spans name lane waits, inventory admission, receipt persistence and response write; `settings.resolve` names its store awaits as finite `settings.*` stages |
| `receipt.completed-persist-failed` | warning | The detached completed-receipt write after an accepted `session.prompt` response failed (`gateway-service.ts`); the pending receipt stays the replay fence |
| `rpc.cancelled` | debug under `SLOW_RPC_WARNING_MS`; warning at or above it | A `{type:"cancel",id}` frame named a disposable read this connection owns, or a shared `session.open` lost its last waiter: `stage` (innermost open), `durationMs`, `stages`; replaces `rpc.completed`. Mutations and prompts are never cancelled |
| `gateway.shed` | warning | A disposable read outlived its `DISPOSABLE_READ_DEADLINES_MS` deadline (`reason=deadline`), or a cold load (raised from `runtime-registry.ts`) met a heap past `HEAP_REFUSAL_SHARE` (`reason=heap`, `admission` `open`/`import`, heap bytes); the client gets `busy` with `retryAfterMs`; replaces `rpc.completed` |
| `session.abort.settled` | info | `session.abort` settled (`gateway-service.ts`); `sessionId`, kind and operation in the message |
| `session.abort.unsettled` | warning | `session.abort` threw; the runtime stays busy |
| `artifacts.session-cleanup-pending` | warning | A deleted session's owned-artifact cleanup rejected; the leftover bytes remain |

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
