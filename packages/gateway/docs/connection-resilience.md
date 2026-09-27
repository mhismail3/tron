# Connection resilience and diagnosis

A lost mobile connection is not proof of Gateway overload. Diagnose the owning
boundary before changing limits or restarting anything. The Gateway remains the
owner of accepted commands; mobile reconnect never replays a prompt blindly.

## Failure boundaries

- **Gateway outbound queue:** at most 8 MiB and 4,096 encoded frames per connection,
  including the active write. Exactly one frame enters `ws` at a time. Completion
  releases both its payload reference and byte reservation. A peer exceeding
  either limit loses request/subscription admission immediately; a one-second
  forced-close deadline bounds a stalled close handshake. Other peers and
  accepted domain commands continue independently.
- **WebSocket admission:** live sockets cap at 32 globally and 4 per
  authenticated identity. A roaming or suspended phone leaves half-open sockets
  that heartbeat reaping retires only after three missed 25-second intervals,
  so a new socket from the same identity supersedes that identity's least
  recently active sockets (close code 4000, `connection.superseded`) instead of
  locking the device out with 503. Other identities are never displaced;
  global capacity still rejects them. Closing sockets are not live capacity.
- **Heartbeat:** every 25-second tick counts one miss for each open socket,
  and any inbound frame (message, client ping or pong) resets the count; the
  tick that finds three misses terminates the socket
  (`connection.heartbeat-timeout`). A dead client is therefore retired on the
  fourth tick after its last frame, whatever was sent to it. The Gateway sends
  its own ping on a tick only when the client initiated nothing (no message or
  client ping) during the preceding interval. A foreground phone pings every
  10 seconds, so it is never pinged by the Gateway; silent and pong-only clients
  are pinged on every tick, because a pong answers the Gateway's ping and never
  suppresses the next one. The only difference from pinging every tick is the
  transition from active to quiet: the first tick after a client's last own frame
  may skip its ping, so its first ping can come one tick later and that pong must
  return within about 50 seconds instead of 75 before the fourth tick. Real mobile
  clients enforce an 8-second pong deadline on their own pings, and pong-only
  clients are unaffected. `server-heartbeat.integration.test.ts` pins each case
  against real sockets on a fake heartbeat clock.
- **Projection:** the wire ceiling remains 1 MiB, with a shared 32,768 JSON-value
  node ceiling for local and mobile clients. Transcript pages reserve 24,000
  nodes and snapshots 30,000; dense detail is compacted without editing canonical
  history. Byte size alone does not establish native decoder admission. Final
  overflow gets a correlated `response_too_large` error or an event resync notice.
  Diagnostics include sizes, node-count lower bound and maximum, not content.
  Rejected mutation/receipt projections remain an unknown command outcome, never
  proof that execution failed. Limits are not invitations to allocate an
  unbounded input before projecting it.
- **HTTP transport:** physical sockets, including incomplete headers and
  upgrades, cap at 128 globally / 64 per source address. Pending requests and
  upgrade authentication cap at 128 globally / 32 per address / eight per
  connection; authenticated HTTP requests additionally cap at 16 per identity.
  Headers have a 15-second allowance checked every second. Complete bodies retain
  Node's five-minute allowance for slow uploads; socket/response inactivity and
  pending-upgrade authentication are separately bounded at 30 seconds.
  EOF/error/close retires a pending upgrade even after Node hands off its parser.
  Credential reads remove canceled mutex waiters; a running credential operation
  retains its serialization lock until actual settlement and cannot admit a
  canceled caller. Read/staging transport waits may retire while their bounded
  physical producer finishes; late leases release at the original resource owner.
  Socket closure never manufactures free, unaccounted I/O capacity. Physical
  filesystem stalls can still leave that resource's bounded producer allowance
  unavailable; this does not promise recovery from a broken filesystem.
  Normal close and failed-startup cleanup join one operation, immediately fence
  observers and force physical HTTP socket retirement after one second. Accepted
  domain/pairing/discard mutations keep their settlement authority. Revocation
  closes token-bound live viewers but does not undo an admitted canonical asset
  read. Display-owner removal durably denies future reads immediately; the final
  reader releases the retained bytes under the store's mutation lane. Empty-owner
  metadata is cleanup-only on startup, never restored authority. A blob acquire
  that fails after prune/dispose also releases its retired reservation and bytes.
  A lost upload receipt discards only unclaimed staging, with the store's
  serialized claim check protecting accepted prompt attachments.
- **Route workload envelope:** `BlobStore` defaults to 128 items / 200 MiB
  total / 25 MiB per item with 32 concurrent readers and four file
  productions. Attachment downloads reserve 32 readers before metadata/path I/O;
  display artifacts reserve their four-reader allowance before verification/open.
  Browser live views allow 64 registrations, four viewers per
  view, 16 viewers total, and expire idle viewers after 15 seconds. Terminals
  retain 128 records, admit 16 active PTYs, split output into 64 KiB chunks,
  and cap replay at 768 KiB. `UploadStore` independently bounds each configured
  item, 1,024 staging entries, 16,384 retained entries, eight item-sized
  staging units, and a 24-hour unclaimed age; default body admission is four
  concurrent bodies, derived from that staging envelope. These owners release
  on their own finish/close/error
  paths rather than duplicating HTTP counters.
- **Mobile recovery:** while foregrounded with a satisfied network path, one
  reconnect owner retries transient failures indefinitely with a 2-second initial
  delay, 1.7× progression, a 15-second cap, and 20% jitter. Background and
  unsatisfied network paths pause attempts; foreground, path return, and explicit
  Retry accelerate one pending delay. Only authentication, authorization, protocol, and identity
  failures stop automatic recovery. Each handshake has the shared 15-second
  deadline. Last-good projections and mutation receipts remain intact. After two
  consecutive failed handshakes whose `transport-open` record says
  `transportOpened=false`, the dashboard labels the server **No path to this Mac**
  and names the current interface when known. A handshake that opened a transport,
  or an episode that began with `ping_timeout`, stays **Reconnecting**. A successful
  connection resets this presentation; retry timing and ownership do not change.

- **Administrative restart:** `gateway.restart` normally drains accepted work.
  It restarts through the existing bounded shutdown path if the drain makes no
  progress for 180 seconds. An authenticated `{ commandId, restartNow: true }`
  request can escalate an existing drain immediately; it shares command receipts,
  authorization and terminal/install admission guards. The response acknowledges
  command admission, not process replacement. If its response is lost, the
  owning client may reconcile through `gateway.drain.status`; any explicit retry
  uses the same command ID. Receipt deduplication does not authorize automatic
  command replay after reconnect, and an unacknowledged restart must not be
  assumed absent. Shutdown retains the existing cancellation,
  grace and runtime disposal behavior, and unresolved runs recover as interrupted
  or `outcomeUnknown` rather than a successful terminal receipt. Drain logs include
  blocker session, category, state and age. Persistence diagnostics are logged to
  the Gateway log, whose active/rotated files remain bounded to one MiB each.

## Frame compression

Paired devices that offer `permessage-deflate` (URLSession offers it with no
parameters) receive compressed frames; local-credential clients (the Mac app,
CLI) stay uncompressed even when they offer it. `ws` negotiates per server
instance, so the upgrade handler picks one of two instances by the
authenticated credential kind (`PAIRED_PER_MESSAGE_DEFLATE` in
`src/transport/server.ts`). A paired client that does not offer the extension
keeps today's uncompressed frames.

- **Settings:** server context takeover stays on, so a cumulative
  `session.progress` frame compresses to roughly its new text. A client may
  still request `server_no_context_takeover`; it is honored rather than
  rejected, and only then does `ws`'s 1 KiB threshold leave small frames
  uncompressed. Otherwise every frame is compressed. zlib level 6, memLevel 8,
  window bits 15. `ws`'s zlib limiter is process-global and shared by inflate and
  deflate; it is capped at two concurrent operations so file I/O keeps half of
  libuv's four-thread pool. Retained deflate/inflate state is about 300 KiB per
  compressed connection, bounded by the 32-socket cap.
- **Measured (2026-09-27, Apple silicon Mac, host load about 10):** the real
  `GatewayServer` broadcasting to one paired client. Repository TypeScript,
  Swift and Markdown filled the recorded snapshot-burst fixture's transcript
  text (`packages/ios-app/Tests/Fixtures/gateway-real-burst.json.zlib`). Nine
  600 KB `session.snapshot` frames went from 5,465,624 to 1,132,866 wire bytes
  (20.7%). 223 cumulative `session.progress` frames up to 24 KiB went from
  3,038,448 to 39,157 (1.3%). 200 small responses and summaries went from 51,199
  to 6,817 (13.3%). Isolated zlib deflate cost about 24 ms of Mac CPU per
  uncompressed MB for snapshots, about 14 ms per 600 KB snapshot, and about
  0.1 ms per progress frame. Levels 1/3 saved 2–4 points less on snapshots and
  gave 7×/1.6× the progress bytes. Level 9 cost 1.5× the CPU for no gain, and
  memLevel 9 or 7 changed bytes by under 0.2%. Without context takeover, the
  progress sequence stayed at 33.8% of its size.
- **Bounds:** inbound `maxPayload` (the 1 MiB frame ceiling) bounds each
  message after inflation as well as on the wire, and an over-limit message
  closes with 1009 before dispatch. Outbound, the 1 MiB frame ceiling and the
  8 MiB / 4,096-frame queue count uncompressed bytes as queued, exactly as for
  uncompressed peers. A frame completes, and advances `completedFrames` and
  write progress, only from `ws`'s send callback. That callback runs after the
  compressed frame is written, and `ws` compresses one message at a time per
  socket, so order is unchanged. `wsBufferedBytes` includes uncompressed bytes
  awaiting compression. As without compression, a frame not yet written when the
  peer vanishes is reported as `connection.write-error`. Compression lengthens
  that window by the deflate time. Heartbeat pings wait behind an in-progress
  deflate of at most one frame.
- **Phone:** CFNetwork inflates before delivery. Its `maximumMessageSize` (1 MiB)
  bounds only compressed wire bytes. A macOS 26 probe received 8 MiB and 256 MiB
  inflated messages that uncompressed would fail with POSIX 40. The phone's
  decoded-size check is `GatewayFramePolicy`, after inflation (`frame_too_large`).
  The Gateway's decoded 1 MiB outbound ceiling is therefore the primary bound
  on what a phone allocates.
- **Diagnosis:** `connection.opened` carries `compression=permessage-deflate`
  or `compression=none`. `ws` answers a malformed `Sec-WebSocket-Extensions`
  offer from a paired client with HTTP 400; URLSession never sends one.

## Collect evidence before recovery

1. Export iOS Logs. Keep its capture time, represented time range, app build,
   source freshness, profile labels/aliases, and available Gateway identity.
   Retained/offline records are not a live Gateway health check. If the initial
   fault predates the represented range, it is missing evidence.
2. Compare the same UTC interval with `<tronHome>/logs/gateway.jsonl` and its
   bounded `.1` rotation. Match mobile hello successes with server admissions;
   client-side and server-side connection IDs are different namespaces.
3. Use existing local Mac status/health observations to distinguish a responsive
   Gateway from an unreachable mobile path. An OS network path of `satisfied`
   proves neither Tailscale tunnel health nor reachability of the selected Mac.
4. Preserve the first fault and the source/payload revisions used to reproduce it.
   Do not clear app data, Keychain, canonical sessions, or credentials. Gateway
   transitions remain explicit user/maintainer actions.

## Interpret the diagnostics

| Evidence | Interpretation / next check |
| --- | --- |
| `stage=transport-open` (`transportOpened=false`) timeout | The WebSocket never opened: the phone's path did not reach the Mac (endpoint, network or Tailscale path). `waitedForConnectivity=true` means URLSession itself waited for a path; `interfaces=` lists the phone's current path interfaces (`other` is typically the Tailscale tunnel). Not evidence about the Gateway. |
| `stage=hello-receive` timeout with `transportOpened=true` | The socket opened (`transportOpenMs`) but the Mac did not answer hello within the deadline. Check the Gateway log for a matching `connection.opened` and for `gateway.event-loop-delay` around that time. |
| `stage=hello-send` timeout with `transportOpened=true` | The socket opened but the hello write did not complete; suspect a stalled path after opening. |
| `ping_timeout` with zero event-queue admission/high-water | The local event reducer did not overflow that epoch. Investigate transport/path or an unobserved process stall. |
| Fast successful `session.open`, no `session.sync`, then client close / `decode_limit` | The client rejected response structure before sync. Compare `frameBytes`, `decodeLimit`, `decodeActual`, `decodeMaximum` and sanitized `decodePath`; a sub-megabyte response can still exceed the node ceiling. This is not proof of path loss. |
| `event_overflow` with topic, count/byte limit, oldest age and dequeue timing | Mobile consumer pressure. Trace what held the consumer, including synchronization reads; do not merely enlarge the queue. |
| `connection.outbound-capacity` | Actual server queue count/byte pressure. Inspect high-water marks, `wsBufferedBytes`, next-frame bytes and process memory. |
| `connection.capacity` / `http.request-capacity` / `http.connection-capacity` | Inspect the named global, identity, address or connection bound and retiring owners; one physical socket is not one request. |
| `connection.superseded` | The same identity reconnected while at its socket cap. Its logged `lastInboundAgeMs` shows how stale the replaced socket was; repeated supersession of fresh sockets suggests a client owning more concurrent sockets than the cap. |
| `http.authentication-timeout` | A pending upgrade exceeded its authentication deadline. The callback is fenced and its cancellable credential wait is retired. |
| `closeCode` / `httpStatusCode` / `platformCode` | Separate facts, never interchangeable numbers. HTTP 401/403 stop automatic admission; 503 is retryable capacity/unavailability. URLSession may report 1005/1006 rather than expose the peer's exact close frame; that absence must remain explicit. |
| `connection.projection-rejected` | A producer violated the projection contract. Narrow/reproduce that producer instead of reconnecting the whole service indefinitely. |
| `gateway.event-loop-delay` | A sampled heartbeat timer was delayed by at least one second (`durationMs`). Counts, queued bytes, RSS, heap and external-memory bytes help separate queue pressure from wider process work. Over exactly the delayed heartbeat interval it also carries `gcCount`, `gcPauseMs`, `gcMaxPauseMs` and `eventLoopUtilization`, plus host `hostFreeBytes`, `swapUsedBytes` and `memoryPressure` (sampled once per record, bounded to 1 s, `host=unavailable` otherwise). GC pause time close to the delay points at garbage collection; utilization near 1 with little GC points at the Gateway's own synchronous work; low utilization with heavy swap or `memoryPressure=warn`/`critical` points at the host not running the process. These are observations, not attribution. |
| `gateway.restart-drain.waiting` / `gateway.restart-drain.stalled` | Inspect blocker session, category, method (for `rpc-mutation`), state and age; the stalled path has requested bounded shutdown, not durable success. |

Memory measurements and timer drift are observations, not attribution. The
25-second heartbeat sampler cannot prove absence of every shorter event-loop
stall. A current low-RSS process likewise does not describe its historical peak.

## Regression expectations and remaining limits

`server-capacity.integration.test.ts` protects payload-reference accounting,
count/byte admission, stalled-close retirement, late subscription rejection and
unrelated-client responsiveness. Its regression controls fail against the old
unaccounted-retention/admission behavior. Its ordered-burst and overflow cases
run for local and compressed paired clients; `server-compression.integration.test.ts`
covers negotiation by credential kind, URLSession's bare offer, a requested
`server_no_context_takeover`, and the inflated-size inbound bound. The synchronization and revocation
integration suites protect ordering and accepted-command ownership. iOS recovery
and dashboard owner tests cover attempt exhaustion, explicit retry and entry
replacement without silently resetting the budget.

`projection.test.ts` covers dense browser detail and tiny-content-part aggregates,
including normalized response envelopes. `server-frame.test.ts` and capacity
integration tests cover exact node limits, read-local fallback, both client roles,
and rejected-open subscription cleanup. The shared JSON-limit fixture is checked
against both producer and native constants; the native transport regression drives
an actual over-node-budget frame through decoding, diagnostic capture and strict
retirement. Native confirmed-mutation tests ensure an oversized command/status
response cannot be mistaken for a failed command or authorize replay.

Published subagent transcript leases retain their capacity reservation and exact
identity until their physical read lane drains after close. Closing aborts queued
reads and detaches watchers/timers immediately; an already running filesystem
read remains accounted for until settlement. Delayed page/invalidation callbacks
cannot publish into a successor lease. Repeated close is idempotent, and accepted
stop commands retain their mutation owner. The lease regression verifies capacity
remains occupied while retired physical reads are blocked.

These boundaries are not a certification of unlimited sessions or browser
processes. Cold SDK session opening still parses complete JSONL synchronously;
runtime snapshots perform history-dependent derivations, and projecting large
provider results can do work before final wire truncation. Browser viewer bounds
do not bound provider-owned browser process creation. Session recovery claims the
existing bounded quarantine synchronously and runs only its network wait in an
owned task; optional auth-completion refreshes do not block global intake. Input
cost and provider process creation still require a documented workload envelope,
not a blanket scalability claim. Do not introduce transcript mirrors,
workers, speculative caches, or higher queue limits to conceal them.

## Isolated qualification

- `server-http-lifecycle` and `server-http-admission` exercise cancellation behind
  blocked credentials, pending-upgrade EOF/deadline, bounded late file acquisition,
  partial headers, pipelining, startup failure, and physical close. Resource-store
  regressions protect pre-await reader reservations, exact late release, failed
  acquisitions after prune/dispose, and durable display revocation during reads.
- `server-capacity` checks three connect/fanout/close waves at 1/4/16/32 peers,
  including global summaries for unsubscribed sessions and ordered wire fences.
- `scripts/ios-gateway-e2e-test all` uses a private Gateway and a fixture-only
  bounded proxy. The proxy verifies the harness's sibling Gateway process, its
  birth/command identity and ownership of the loopback listener before forwarding.
  The proxy accepts the app's `permessage-deflate` offer and offers it upstream
  only when the app negotiated it. Its `proxy.bridge-opened` lines and the Gateway's
  `connection.opened` records show what the app negotiated.
  It exercises delayed hello/open/sync, blackholed traffic, HTTP upgrade statuses,
  remote-close metadata, and loss of an accepted response followed by durable
  receipt/canonical exactly-once verification. A skipped boundary case fails the
  runner. CI runs this boundary for source changes, not only SDK upgrades.
- Build source, then run `node --expose-gc packages/gateway/scripts/measure-projection.mjs`
  from the repository root (`--extended` adds 25k/100k-entry histories;
  `--baseline /path/to/compiled/dist` enables balanced comparisons). The tool
  checks canonical input and independent row/content/cursor equality while
  recording input size, branch walks, output bytes/nodes and raw timing samples.
  One canonical branch cut is reused per projection; full-branch tool ownership
  is not replaced by a tail cache. These are warm CPU measurements, not cellular,
  cold-start, energy or unlimited-concurrency certification.
