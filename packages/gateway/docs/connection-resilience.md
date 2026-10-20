# Connection resilience and diagnosis

A lost mobile connection is not proof of Gateway overload. Diagnose the owning boundary
before changing limits or restarting anything. The Gateway owns accepted commands; mobile
reconnect never replays a prompt blindly. Wire bounds, receipts and the outbound queue:
[protocol](../src/transport/protocol.md); records: [transport Signals](../src/transport/README.md#signals).

## Failure boundaries

- **Outbound queue** (8 MiB / 4,096 frames per connection, one frame in `ws` at a time,
  supersession by `session.summary`/`session.rebaseline`, fences never dropped): a peer over
  either bound loses admission and is force-closed after one second; other peers and accepted
  commands continue.
- **WebSocket admission:** 32 live sockets globally, 4 per identity. A new socket from an
  identity at its cap supersedes that identity's least recently active sockets (close 4000,
  `connection.superseded`) instead of a 503; other identities are never displaced.
- **Heartbeat:** each 25 s tick counts a miss per socket and any inbound frame resets it; three
  misses terminate (`connection.heartbeat-timeout`), so a dead client goes on the fourth tick.
  The Gateway pings only clients that sent nothing during the interval (a foreground phone
  pings every 10 s itself); the first quiet tick may skip its ping, so that pong has about
  50 s instead of 75. Twelve seconds without expected liveness logs `connection.inbound-silent`
  with the Tailscale path; the next frame logs `connection.inbound-resumed` (`silentMs`).
  Pong-only clients are idle, never silent (`server-heartbeat.integration.test.ts`).
- **Phone liveness (C-4):** pings on one shared 10 s grid; any fully delivered inbound frame
  after a ping answers it, and the Gateway writes pongs ahead of its queued frames
  (`server-pong-backlog.integration.test.ts`). A probe retires the epoch (`pong_timeout`) only
  when nothing arrived within its 8 s deadline, so a dead link is detected within 18 s. Excused
  probes leave a debug `liveness outcome=excused` record.
- **Projection:** 1 MiB frames and 32,768 JSON nodes; overflow is a correlated
  `response_too_large` or a resync notice. A rejected mutation projection stays an unknown
  outcome, never a failure.
- **HTTP transport:** the socket, request, upgrade and identity bounds and deadlines in
  [protocol](../src/transport/protocol.md#http-admission). Socket closure never frees
  unaccounted I/O capacity; a stalled filesystem can hold its owner's bounded allowance.
  Revocation closes token-bound viewers but does not undo an admitted asset read;
  display-owner removal denies future reads at once; a lost upload receipt discards only
  unclaimed staging.
- **Shedding (G-12):** every limit is one named constant beside its user; a shed read is
  `busy` with `retryAfterMs` and one `gateway.shed`. Deadlines, cancels and retries never touch
  admitted mutations or prompts. Bounds: `DISPOSABLE_READ_DEADLINES_MS` (`session.open` 10 s;
  list and transcript pages 5 s), `MAXIMUM_CONCURRENT_COLD_LOADS` 2 (FIFO; dropped when its
  last waiter leaves), `MAXIMUM_CONCURRENT_SESSION_EXPORTS` 1,
  `MAXIMUM_CONCURRENT_WORKSPACE_INSPECTIONS` 2, `HEAP_EVICTION_SHARE` 0.70 and
  `HEAP_REFUSAL_SHARE` 0.85 of `heap_size_limit` (so of `--max-old-space-size`; only a cold
  `open` or `import` is refused), and on the phone
  `GatewayDisposableReadPolicy` (one retry, hint capped at 10 s). `LIVE_RUNTIME_BYTE_BUDGET`
  (G-5) is eviction pressure only.
- **Route workloads:** `BlobStore` 128 items / 200 MiB / 25 MiB, 32 readers, four file
  productions; attachments reserve 32 readers and displays four before I/O; live views 64
  registrations, four viewers per view, 16 total, 15 s idle; terminals 128 records, 16 PTYs,
  64 KiB chunks, 768 KiB replay; uploads as in [uploads](../src/machine/uploads.md). Each owner
  releases on its own finish, close or error path.
- **Mobile recovery:** in the foreground on a satisfied path one reconnect owner retries
  transient failures forever: 2 s, ×1.7, 15 s cap, 20% jitter. Dashboard pool entries use the
  same curve without jitter and, after three failed attempts, ×4 up to five minutes until an
  attempt succeeds. Background or unsatisfied paths pause. A foreground cycle, explicit Retry
  or real path change (route interfaces changed, or unsatisfied → satisfied) cancels the wait;
  a path change also restarts the curve (C-3); an unchanged-path notice does not. Only
  authentication, authorization, protocol and identity failures stop recovery. A hello the
  Gateway cannot speak closes 4006 (`PROTOCOL_MISMATCH_CLOSE_CODE`) with
  `{"code":"protocol_mismatch","gatewayProtocol","minProtocol"}` (older Gateways: 1008,
  retried). The open has a 5 s `clientTransportOpenDeadline`; only an opened socket spends the
  15 s `clientHelloDeadline`. Two consecutive handshakes with `transportOpened=false` label the
  server **No path to this Mac**; others stay **Reconnecting**.
- **Administrative restart:** see [host control](../src/admin/host-control.md#drain-and-exit).
  A lost restart response is reconciled through `gateway.drain.status` and retried only with
  the same command ID; unresolved runs recover as interrupted or `outcomeUnknown`.

## Frame compression

Paired devices that offer `permessage-deflate` (URLSession offers it bare) get compressed
frames; local-credential clients never do. `ws` negotiates per server instance, so the upgrade
picks one of two by credential kind (`PAIRED_PER_MESSAGE_DEFLATE` in `src/transport/server.ts`).

- **Settings:** server context takeover on (a cumulative `session.progress` frame costs about
  its new text); a requested `server_no_context_takeover` is honored, and only then do frames
  under 1 KiB go uncompressed. zlib level 6, memLevel 8, window 15; `ws`'s process-global zlib
  limiter is capped at two so file I/O keeps half the libuv pool; about 300 KiB of state per
  compressed connection. Level 6 was chosen by measurement: snapshots
  shrink to about a fifth, progress frames to about 1%, at about 12 ms per 600 KB snapshot.
- **Bounds:** inbound `maxPayload` (1 MiB) applies after inflation (1009 before dispatch);
  outbound frame and queue bounds count uncompressed bytes. A frame completes only from `ws`'s
  send callback, after the compressed write; order is unchanged; `wsBufferedBytes` includes
  bytes awaiting compression; pings wait behind at most one deflate.
- **Phone:** CFNetwork inflates first and its `maximumMessageSize` applies to wire bytes, so the
  decoded 1 MiB check (`GatewayFramePolicy`) runs after inflation and an over-ceiling frame
  retires the epoch (`frame_too_large`). The Gateway refuses decoded frames over 1 MiB before
  enqueue on every path (`server-compression.integration.test.ts`); the residual risk is
  memory before rejection from a malicious paired Gateway.
- **Diagnosis:** `connection.opened` carries `compression=permessage-deflate|none`. A malformed
  `Sec-WebSocket-Extensions` offer gets HTTP 400.

## Collect evidence before recovery

1. Run `scripts/tron-triage PHONE-EXPORT...` first. It reads the exports and
   `<tronHome>/logs/gateway.jsonl` with rotations (`--gateway-logs DIR` for another home)
   read-only and prints one row per outage with cause `path`, `phone-background`,
   `phone-stall`, `gateway-stall`, `gateway-capacity` or `unknown` (first matching rule in
   `scripts/tron_triage.py`) and the evidence lines. `--json`, `--out PATH`;
   `--tailscale-window` reads the Tailscale extension's log for the export's range as path
   evidence, `--tailscale-peer NODEKEY` restricts it to the phone's peer.
2. Export iOS logs; keep capture time, range, build, source freshness, profile labels and
   Gateway identity. Retained records are not a live health check.
3. The tool joins phone and Gateway by key (`gatewayConnectionId` = `connectionId`;
   `clientId`/`attemptId`/`epoch` = `peerClientId`/`peerAttemptId`/`peerEpoch`), else by time
   for pre-protocol-5 logs (`joinedBy`). With a key join only key-joined and Gateway-wide
   records count, and the connection a recovery opened is never the lost one's cause. Outages
   split per scene phase; an attempt belongs to the stretch it began in; a relay window explains
   an episode only if it covers the loss and ends within the recovery delay.
4. A `satisfied` OS path proves neither Tailscale health nor reachability of the Mac.
5. Preserve the first fault and revisions. Never clear app data, Keychain, sessions or
   credentials; Gateway transitions stay the user's or maintainer's.

## Interpret the diagnostics

| Evidence | Interpretation / next check |
| --- | --- |
| `stage=transport-open` timeout (`transportOpened=false`) | The socket never opened: path, endpoint or Tailscale, not the Gateway. `waitedForConnectivity`, `interfaces=` describe the phone's path. |
| `stage=hello-send` / `hello-receive` timeout, `transportOpened=true` | Opened but stalled; for receive, look for `connection.opened` and `gateway.event-loop-delay`. |
| `ping_timeout` with zero event-queue pressure | Not the reducer: transport, path or an unobserved process stall. |
| Fast `session.open`, no `session.sync`, then `decode_limit` | The client rejected structure (`frameBytes`, `decodeLimit`, `decodeActual`, `decodePath`); not path loss. |
| `event_overflow` | Mobile consumer pressure; trace what held it, do not enlarge the queue. |
| `connection.outbound-capacity` | Server queue pressure: high-water marks, `wsBufferedBytes`, `nextTopic`/`nextBytes`, `oldestTopic`, memory. |
| `http.*-capacity`, `http.upgrade reason=*_capacity` | The named bound; one socket is not one request. |
| `connection.superseded` | Same identity reconnected at its cap; repeated fresh supersessions mean a client holding too many sockets. |
| `http.upgrade outcome=abandoned` | Reached the Mac, ended before hello: `reason` `peer_closed`, `hello_timeout`, `superseded`, `device_revoked`, `shutting_down`; large `authMs` or `acceptToUpgradeMs` are local waits, not path faults. |
| `http.upgrade outcome=rejected` | `phaseReached` `request`, `auth` (incl. `authentication_timeout`), `handshake` or `hello` (`hello_required`, `protocol_mismatch`, `invalid_frame`). |
| `http.upgrade outcome=opened` ≥ `UPGRADE_SLOW_WARNING_MS` | Slow to usable; `helloMs` includes the peer's send and path. Check loop delay and resources. |
| `connection.inbound-silent` | `peerPath=relay`/`offline`: Tailscale path; `direct`: phone or its process; `unknown`: no usable answer. Repeats at relay are flaps (below). |
| `closeCode` / `httpStatusCode` / `platformCode` | Separate facts. 401/403 stop admission; 503 is retryable; 1005/1006 may hide the peer's close. |
| `connection.projection-rejected` | A producer broke the projection contract; fix that producer. |
| `gateway.event-loop-delay` | GC pause near the delay → GC; utilization near 1 → the Gateway's own work; heavy swap or low `hostMemoryAvailablePercent` → the host. Observations, not attribution. |
| Host fields on `connection.opened`/`closed` | The host was paging around the drop; evidence about the Mac only. |
| `gateway.restart-drain.waiting` / `.stalled` | Blocker session, category, method, state, age; stalled means bounded shutdown, not success. |

The 25 s sampler cannot prove the absence of shorter stalls; a low current RSS says nothing
about the historical peak.

### Reading the host memory fields

- `hostMemoryAvailablePercent` (`kern.memorystatus_level`): the kernel's available share, the
  number `memory_pressure` prints; the field that answers "was the Mac short of memory?".
- `memoryPressure` (`kern.memorystatus_vm_pressure_level`): normal/warn/critical; can lag.
- `swapUsedBytes` near `swapTotalBytes` is paging hard; a small used value is normal.
- `hostFreeBytes`/`hostTotalBytes` are `os.freemem`/`os.totalmem`; free pages only, so small on
  a healthy Mac.
- `hostSampleAgeMs`: age of the cached sample (probed at startup and each heartbeat, 1 s bound;
  a slow probe keeps the old sample).

## Tailscale flaps

A flap is Tailscale's path dropping to relay-only or offline while the LAN works; nothing flows
until it returns. The phone drops its socket within about 18 s; the Gateway after three missed
heartbeats, so shorter flaps leave only records. The pinned LAN lane is the release's answer:
on a shared network the phone races it against the Tailscale endpoint (E-3c, E-3d); kill switch
`--lan-endpoint off` / `TRON_GATEWAY_LAN_ENDPOINT=off`
([LAN listener](../src/transport/protocol.md#lan-listener)).

- **Gateway records:** one `connection.inbound-silent` per episode per socket (12–37 s after the
  last frame) naming the peer and `peerPath`/`peerRelay`; a surviving socket then logs
  `connection.inbound-resumed`. A disconnected phone leaves the silent record unpaired; the Mac
  ends the socket when the close arrives (`connection.closed` with a large `lastInboundAgeMs`)
  or at about 75–100 s (`connection.heartbeat-timeout`).
- **Triage:** an episode is `path` when its silent record carries `relay`/`offline` or its own
  `transport-open` timed out; `--tailscale-window` names covering windows (`[cause]`) and
  earlier ones as `[context]`, keeping them in `inputs.tailscaleWindow.relayWindows`. Re-run
  soon after an incident: the unified log ages out.
- **User checks:** iPhone Tailscale current and showing a **direct** connection on shared
  Wi-Fi (disabled extension → `transport-open` timeouts with no `http.upgrade`); a rotating
  Private Wi-Fi Address; router band/mesh steering and 802.11k/v/r roaming at the same times;
  read `peerPath` beside the phone's `gateway.attempt` records.

## Regression expectations and remaining limits

`server-capacity`, `server-compression`, `server-heartbeat`, `server-pong-backlog`, the
synchronization and revocation integration suites, and the iOS recovery and dashboard owner
tests protect these boundaries; the shared JSON-limit fixture is checked against producer and
native constants. Subagent transcript leases keep their reservation until their physical read
drains after close.

These are not certifications of unlimited sessions or browser processes: cold SDK opens parse
whole JSONL, snapshots do history-dependent work, and browser viewer bounds do not bound
provider browser processes. Do not add transcript mirrors, workers or higher queue limits to
hide those costs; the catalog ([catalog](../src/sessions/catalog.md#the-catalog-owner)) is one
change-driven owner, not a cache.

## Isolated qualification

- `server-http-lifecycle` and `server-http-admission`: cancellation behind blocked
  credentials, upgrade EOF and deadlines, late file acquisition, partial headers, pipelining,
  startup failure, physical close. `server-capacity`: connect/fan-out/close waves at
  1/4/16/32 peers.
- `scripts/ios-gateway-e2e-test all`: a private Gateway behind a fixture proxy that verifies
  its sibling Gateway before forwarding and mirrors compression; covers compressed frames at
  and one byte over 1 MiB, delayed hello/open/sync, blackholes, upgrade statuses, close
  metadata and a lost accepted response verified exactly once. A skipped case fails. Local
  only; hosted CI does not run it.
- `scripts/ios-gateway-e2e-test run-lan` (after the above; needs a private address): the E-3c
  two-lane race, a live LAN connection through a 90 s blackhole of the saved lane (an upload
  proves HTTP follows the winner), and a lane that never answers TLS losing after the 250 ms
  stagger.
- `node --expose-gc packages/gateway/scripts/measure-projection.mjs [--extended] [--baseline DIST]` after a build: warm CPU projection measurements with equality checks, not cellular,
  cold-start or energy certification.
