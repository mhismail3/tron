# Connection and request protocol

The wire contract `gateway/transport` owns: HTTP and LAN admission, pairing, hello,
requests, cancellation, receipts, ordered delivery and liveness. Methods:
`scripts/tron docs rpc`. Diagnosis, the full limits table and qualification:
[connection resilience](../../docs/connection-resilience.md). Records: the
[transport README](README.md#signals).

## HTTP admission

- Limits: physical sockets 128 global / 64 per address; requests and pending upgrades
  128 / 32 per address / 8 per connection; authenticated HTTP identity demand 16.
  Headers 15 s, complete bodies 5 min, inactivity and upgrade authentication 30 s.
  Attachment readers reserve their 32 slots before metadata I/O, display readers four.
- A cancelled credential waiter leaves ordered admission; active credential I/O keeps
  its mutex until it settles. Normal close and failed startup share one bounded
  retirement (observers fenced, one-second physical close). These disposable limits
  never cancel accepted domain work or delete a claimed attachment.
- Routes: `GET /health` (unauthenticated; HTTP 503 with `starting`,
  `catalog-warming`, `attention-recovery`, `automation-recovery` or `storage-warming`
  until every startup prerequisite completes, then 200 `ok`; every other route and
  upgrade answers retryable `busy` meanwhile), `POST /v1/pair` (rate-limited one-time
  enrollment), `POST|DELETE|GET /v1/uploads[/:id]` ([uploads](../machine/uploads.md)),
  `GET /v1/blobs/:id`, `GET /v1/sessions/:id/display-artifacts/:id` and the live-view
  routes ([display](../display/README.md)), `GET /v1/socket` (protocol 8 WebSocket).
- `upload-http.ts` owns the three upload exchanges; its synchronous dispatcher returns
  no work for other paths, so live-view open/frame keep their credential cut without
  an inserted await.
- **Revocation.** Bearer admission is linearized with the paired-device document under
  the `DeviceStore` mutex (credential check plus synchronous registration; long I/O is
  never awaited under it). Credential, invitation, device document and revocation are
  published with the durable file-plus-directory sync; if the rename succeeded but sync
  fails, transport authority retires under the mutex and the error stays visible. A
  failed pairing regenerates the invitation. Revocation replaces the document,
  retires transport at once, then cleans installs best-effort. Work admitted before the
  cut settles independently; revoked connections reject later requests and observer
  callbacks. Only the initiating self-revoke response may follow the cut, with a
  one-second flush deadline. Local-wrapper authority and resumable provider auth are
  independent of device revocation.
- **Pairing storage.** The pairing limiter keeps an exact rolling per-address window
  over at most 4,096 LRU addresses. At most 256 devices; metadata 1 MiB, wrapper
  credential 4 KiB, invitation 16 KiB before decode; owner-only regular files (no
  symlinks), exact versions and canonical timestamps. The invitation is consumed
  before the device record is written; a failed write issues a fresh one under the
  pairing mutex; a full store leaves the invitation valid.

## LAN listener

A second, TLS-only listener on the Mac's private LAN address, on the main port. On by
default unless the main bind is loopback (`127.0.0.0/8`, `::1`, `localhost`);
`--lan-endpoint on|off` or `TRON_GATEWAY_LAN_ENDPOINT` overrides. It binds only an
RFC 1918 or IPv6 ULA address the Mac has (never a wildcard, link-local or Tailscale
range), rebinds when it changes and disables itself with none. Key and self-signed
certificate: `~/.tron/gateway/lan-endpoint/` (0600 in 0700), created once, replaced
only by explicit rotation because phones pin the public key; a key without its
certificate is completed from that key, a certificate without its key is refused. It
shares all HTTP/WebSocket handling but serves only the socket and authenticated
routes: pairing stays on the main listener and LAN `/health` answers status only.

The Mac-supervised Gateway takes the kill switch only from the launchd session
environment (`launchctl setenv TRON_GATEWAY_LAN_ENDPOINT off`, then a user restart;
`unsetenv` restores), because its LaunchAgent arguments are the ownership contract
the wrapper verifies; one `lan.listener state=disabled reason=setting_off` record is
the evidence. Pairing responses and every hello carry `lanEndpoints` (`[{host,port}]`
or `[]`) and `lanPin` (base64 SHA-256 of the raw uncompressed X9.63 public key,
[fixture](../../../protocol-fixtures/lan-endpoint-pin.json)); the phone replaces both
on every hello. No unauthenticated route names the lane.

## Hello and identity

Every socket starts with `{"type":"hello","protocolVersion":8}`. Hello, pairing and
`system.info` carry `machineId` (per Tron home), `gatewayChannel` (`stable` or `dev`;
`TRON_GATEWAY_CHANNEL` is validated, absence means `stable`) and `machineGroupID`
(one physical Mac across homes; a connection-group hint only, clients fall back to
`machineId`). The phone may send `diagnostics: {clientId, attemptId, epoch}`; each
value is kept only as a token of ≤ 64 `[A-Za-z0-9-]` characters and stamped as
`peerClientId`/`peerAttemptId`/`peerEpoch`; the answer adds `connectionId`. Both are
diagnostic only.

## Requests, cancellation and deadlines

Requests are `{type,id,method,params}`, answers `{type,id,ok,result|error}`.
`{type:"cancel",id}` (no answer) abandons only `session.open`, `session.list`,
`session.transcript`, `session.history.list`, `session.history.entry`,
`home.memory.view`, `home.memory.evidence`, `model.list`, `provider.list` and
`provider.usage`, recording `rpc.cancelled`; mutations, admitted prompts and
`session.sync` are never cancelled. `DISPOSABLE_READ_DEADLINES_MS` (`server.ts`):
`session.open` 10 s; `session.list`, the transcript/history pages and the Home memory
browser 5 s. An expired read is aborted and answered `busy` with
`details.retryAfterMs` (`gateway.shed reason=deadline`); the phone retries once.
Methods without an entry are never shed (`provider.usage` itself bounds each fetch at
10 s). Concurrency caps queue rather than refuse: two cold runtime loads, one export,
two workspace inspections. Above `HEAP_EVICTION_SHARE` (0.70) idle runtimes retire
largest first until the registry's own accounting is under it; above
`HEAP_REFUSAL_SHARE` (0.85) a cold `open` or `import` is refused `busy`
(`gateway.shed reason=heap`). Protected runtimes are never retired to make room.

A second `session.open` of one session on one connection joins the in-flight attempt
(abandoned only when its last waiter leaves); a non-joining overlap is rejected.
Cancelling an answered open whose barrier was never synchronized revokes that barrier
unless another delivered response carries the same token.

## Command receipts

- Mutations require `params.commandId`; receipts deduplicate completed commands.
  After an uncertain disconnect clients poll `command.status`, reuse a completed
  result, retry only a confirmed-missing command with the same ID, and never replay
  a pending one. A new command ID is not proof that replay is safe.
- `session.prompt` persists its pending receipt before Pi admission and answers when
  admission resolves, finishing the completed write while it keeps the command lane
  and drain owner; duplicates join the lane. Every other method persists the completed
  receipt before answering. Process loss or a failed completion write leaves the
  pending receipt as an outcome-unknown fence; prompts are never re-run.
- An owner-reported unknown outcome keeps the pending receipt; an observed rejection
  removes it. A canonical-ownership write that times out or cannot be proven keeps the
  runtime as a visible drain and eviction blocker that rejects mutations and reload
  (the pinned SDK has no flush acknowledgement, so resending cannot clear it).
- Bounds: one response frame plus 4 KiB per receipt; 32,768 entries and 64 MiB
  aggregate, reserving one maximum completion before a mutation runs; full capacity
  is retryable `busy`. Usage is kept in process and reconciled after a prune; the
  background scheduler prunes every `COMMAND_RECEIPT_PRUNE_INTERVAL_MS` (1 min) and
  admission forces one pass only at capacity. Only expired valid completed receipts
  are reclaimed (editor updates: ten minutes); pending, malformed or mismatched
  evidence is never pruned. Interrupted temporaries are scavenged only when no lane
  holds their command. Identical command keys serialize; everything else is
  concurrent. The store joins accepted persistence before releasing its directory.

## Ordered outbound delivery

`ordered-outbound-queue.ts` owns ordered writes, bounds and supersession; `server.ts`
keeps admission, frame preparation, broadcasts and retirement.

- Bounds: 1 MiB encoded frame, 32,768 JSON nodes, 8 MiB / 4,096 frames queued per
  connection (uncompressed bytes). Transcript pages reserve 24,000 nodes, snapshots
  30,000. Structural pressure compacts disposable detail into explicit previews
  without touching JSONL, ordinals or cursors (`gateway-json-limits.json` fixture).
  A rejected response is `response_too_large`; a rejected event requests resync; an
  accepted command is never undone by projection failure.
- One frame at a time enters `ws`; enqueue order is the ordering boundary. An unsent
  `session.summary` is replaced by a newer one. A newer `session.snapshot` supersedes
  the unsent sequenced state of its own runtime generation up to its `eventSequence`,
  sent as `session.rebaseline` with the connection's `subscriptionToken`. Fences are
  never dropped, nor anything behind them: failure receipts, revision bumps, editor
  directives and frames of another runtime generation. Without an installed token a
  snapshot supersedes nothing. Dropped frames release their reservation and appear as
  `outboundCoalescedFrames`/`Bytes` in `gateway.resources`.
- A broadcast encodes once per operation; only `session.rebaseline` is per connection.
  Overflow closes that peer with `1013`; a stalled peer is force-closed after one
  second but holds capacity until physical close. Write failures terminate the exact
  connection. Retirement aborts disposable waits; accepted prompts and durable
  mutations never inherit socket cancellation.
- Paired devices offering `permessage-deflate` get compressed frames with context
  takeover; local-credential clients do not
  ([frame compression](../../docs/connection-resilience.md#frame-compression)).
- Bounded JSON projection admits nodes before copying, counts sparse-array slots and
  markers, tracks only the active recursion path (shared objects expand per sibling,
  true cycles are marked), and tails large tool-result text before generic previews.

## Liveness

A 25-second heartbeat terminates a socket only after three consecutive ticks with no
inbound frame (pong, ping or application frame resets it). A tick pings only a client
that sent nothing during the interval. The phone probes every 10 s with an 8 s pong
deadline, independent of event reduction, and bounds the hello attempt; losing a
socket never cancels an accepted prompt, and uncertain sends reconcile by command ID.
Twelve seconds of expected-but-missing liveness writes `connection.inbound-silent`
with the Tailscale path. Upgrades, unused connections, close causes (`transportEnd`),
loop stalls and capacity events each have one record (Signals). Paired-device open
and close records carry the heartbeat's host memory sample. Close codes and reasons
are credential-free. Reconnect converges through an authoritative snapshot.

## Pagination and diagnostics

`session.list` and `model.list` are cursor-paginated; a pager reacquires its live
owner lease after a catalog build, so a concurrent listing never returns an already
expired cursor ([catalog](../sessions/catalog.md#catalog-pagination),
[model catalog](../admin/runtime-configuration.md#model-catalog)).
`system.logs.export` accepts only a bounded redacted client snapshot and command ID,
appends the newest debug records (≤ 1 MB) and writes
`~/.tron/logs/device-exports/<device-hash>-<timestamp>.jsonl` (0600 in 0700, newest
ten kept); it never takes a client path or reads session content. RPC records keep
`method`, `requestID`, `outcome`, `code`, `durationMs`; catalog stages add a
process-local `workID`; reasons are fixed codes, never exception text or parameters.

Verify: `server-capacity`, `server-revocation`, `server-upload`,
`server-http-lifecycle` and `sync-protocol` integration tests in this directory.
