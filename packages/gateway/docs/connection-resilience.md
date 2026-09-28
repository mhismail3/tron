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
  clients are unaffected. A skipped ping is never an unanswered one. A socket that
  stops proving liveness for 12 seconds — a ping the Gateway sent that the client
  left unanswered, or a client that pings on its own and has gone quiet — logs
  one `connection.inbound-silent` (warning) with the peer's Tailscale path, and
  its next inbound frame logs
  `connection.inbound-resumed` (info) with `silentMs`. A client that only answers
  the Gateway's pings is idle between them, not silent, and is never reported:
  its silence says nothing until a ping goes unanswered.
  Both are read from the Gateway log alone and neither changes what the tick does.
  `server-heartbeat.integration.test.ts` pins each case against real sockets on a
  fake heartbeat clock.
- **Phone liveness (C-4):** the phone pings every socket on the one shared
  ten-second wakeup grid the energy plan fixed, and any inbound frame that
  reaches the app after a ping was sent is proof of liveness for that ping:
  messages, pongs and any other data all answer it. A probe's pong returns on
  the downlink, behind whatever data the Gateway has already queued for the
  phone, so a pong can miss its eight-second deadline on a link that is carrying
  data. Such a probe retires the epoch only when nothing arrived after it was
  sent, and the next grid tick re-arms the wait. Only a fully delivered frame
  counts as that proof, so a frame whose last byte arrives later than that
  deadline (about 1 MiB on a path below 1 Mbit/s) leaves a busy link with no
  proof at all and the epoch is still retired as `pong_timeout`. Dead-link
  detection stays within 18 seconds of the last inbound frame: no grid tick is
  later than 10 seconds after it and the deadline is 8 seconds after the tick.
  An excused probe leaves a debug-level `liveness` record with
  `outcome=excused` in the phone's connection log, so a run that shows no
  `pong_timeout` retirement can still tell an excused probe from a probe that
  never missed its deadline.
  `GatewayClientTransportTests` pins each case on a manual clock.
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
- **Latency:** at level 6 a fresh 24 KiB progress frame deflates in about
  0.14 ms and a 600 KB snapshot in about 12.6 ms (levels 1 and 3: about 4.8 and
  3.2 ms, with 22% and 14% more snapshot bytes). Broadcast to decoded delivery on
  loopback measured 0.6 ms against 0.4 ms uncompressed for progress and 18.4 ms
  against 3.0 ms for a snapshot. That is under one display frame, and less than
  the transmission time the smaller frame saves on any phone link slower than
  about 250 Mbit/s. The zlib cap of two only delays a third concurrent snapshot
  compression by one more deflate.
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
- **Phone:** CFNetwork inflates before delivery, and its `maximumMessageSize`
  (1 MiB) applies to compressed wire bytes. A macOS 26 probe received 8 MiB and
  256 MiB inflated messages; uncompressed, anything over 1 MiB fails the receive
  with POSIX 40. With `permessage-deflate` the phone's decoded 1 MiB check
  (`GatewayFramePolicy`) therefore runs after inflation. An over-ceiling frame
  still retires the epoch as a retryable transport failure, now with reason
  `frame_too_large`. Correct traffic is unchanged, because the Gateway refuses a
  decoded frame over 1 MiB on every send path before enqueue and so before
  compression. `server-compression.integration.test.ts` checks direct responses,
  `emitToClient`, global and session broadcasts and synchronization-barrier
  replay. The residual risk is memory use before rejection, and only against a
  malicious or broken authenticated paired Gateway. Such a Gateway already
  controls everything the phone displays.
- **Diagnosis:** `connection.opened` carries `compression=permessage-deflate`
  or `compression=none`. `ws` answers a malformed `Sec-WebSocket-Extensions`
  offer from a paired client with HTTP 400; URLSession never sends one.

## Collect evidence before recovery

1. Export iOS Logs. Keep its capture time, represented time range, app build,
   source freshness, profile labels/aliases, and available Gateway identity.
   Retained/offline records are not a live Gateway health check. If the initial
   fault predates the represented range, it is missing evidence.
2. Compare the same UTC interval with `<tronHome>/logs/gateway.jsonl` and its
   bounded `.1` rotation. Join the two sides by the O-1 key: a phone record's
   `gatewayConnectionId` is the Gateway record's `connectionId`, and its
   `clientId`/`attemptId`/`epoch` are the Gateway's `peerClientId`,
   `peerAttemptId` and `peerEpoch`. Only logs from before the correlation key
   shipped (protocol 5) have to be matched by time window instead.
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
| `connection.closed` or `connection.opened` carrying `swapUsedBytes` near `swapTotalBytes`, or `memoryPressure=warn`/`critical` | The host was paging when the phone's socket ended or was re-established. These facts come from the same heartbeat-refreshed sample as `gateway.event-loop-delay`'s, and `hostSampleAgeMs` says how old that sample was when the record was written: a probe that loses its 1 s race is discarded, so the age — not the 25 s tick — bounds the staleness. Read the fields as described under the table; the drop itself can still be the path or the client, so this is evidence about the Mac, not attribution. |
| `stage=hello-send` timeout with `transportOpened=true` | The socket opened but the hello write did not complete; suspect a stalled path after opening. |
| `ping_timeout` with zero event-queue admission/high-water | The local event reducer did not overflow that epoch. Investigate transport/path or an unobserved process stall. |
| Fast successful `session.open`, no `session.sync`, then client close / `decode_limit` | The client rejected response structure before sync. Compare `frameBytes`, `decodeLimit`, `decodeActual`, `decodeMaximum` and sanitized `decodePath`; a sub-megabyte response can still exceed the node ceiling. This is not proof of path loss. |
| `event_overflow` with topic, count/byte limit, oldest age and dequeue timing | Mobile consumer pressure. Trace what held the consumer, including synchronization reads; do not merely enlarge the queue. |
| `connection.outbound-capacity` | Actual server queue count/byte pressure. Inspect high-water marks, `wsBufferedBytes`, next-frame bytes and process memory. |
| `http.request-capacity` / `http.connection-capacity`, or `http.upgrade` with `reason=request_capacity` / `connection_capacity` | Inspect the named global, identity, address or connection bound and retiring owners; one physical socket is not one request. The upgrade record names its bound in `reason` and carries the counts in its message. |
| `connection.superseded` | The same identity reconnected while at its socket cap. Its logged `lastInboundAgeMs` shows how stale the replaced socket was; repeated supersession of fresh sockets suggests a client owning more concurrent sockets than the cap. A socket that had not said hello yet reports the supersession in its own `http.upgrade` (`reason=superseded`). |
| `http.upgrade` with `outcome=abandoned` | The peer reached this Mac and opened the socket, then the attempt ended before hello (`phaseReached=handshake`; `helloMs` is how long it kept the phase open). `reason` names which side ended it: `peer_closed` the peer vanishing, `hello_timeout` the Gateway's own hello deadline (`GATEWAY_CONNECTION_POLICY.helloDeadlineMs`), `superseded` a newer connection from the same identity, `device_revoked` a revocation of the device, `shutting_down` a Gateway shutdown. A large `authMs` means the credential wait was slow, a large `acceptToUpgradeMs` means the request waited behind other HTTP work — neither is a path fault. |
| `http.upgrade` with `outcome=rejected` | The Gateway refused the upgrade; `reason` names which bound or phase did. `phaseReached=request` means before credentials (`warming_up`, `shutting_down`, `request_capacity`, `unexpected_path`, `unreadable_request`), `auth` means the credential or the readiness recheck (`unauthenticated`, `warming_up`, `shutting_down`, `authentication_timeout`) or capacity (`connection_capacity`), `handshake` means the WebSocket handshake itself was refused, `hello` means a hello arrived and was refused (`hello_required`, `protocol_mismatch`) or a frame was (`invalid_frame`: a first frame that is not JSON, or one the WebSocket library itself refuses as oversized or malformed). |
| `http.upgrade` with `outcome=abandoned` and `phaseReached=auth` | The attempt ended while the credential was still being read: `reason=peer_closed` means the peer left, `shutting_down` means a Gateway shutdown destroyed the socket. A peer that left is not a refusal: check the phone's records at that instant before the Gateway's readiness. |
| `http.upgrade` with `outcome=opened` and `authMs` or `helloMs` near or over `UPGRADE_SLOW_WARNING_MS` (1,000 ms) | The connection needed a second or more to become usable. The record is a warning whenever the attempt took at least 1,000 ms from the TCP accept (`acceptToUpgradeMs + authMs + handshakeMs + helloMs`), whatever the phase that was slow. `authMs` is the credential read (device-store mutex); `helloMs` runs from handshake completion to the Gateway processing the hello frame, so it includes the peer's own send delay and the network path, not only the Gateway's handling. Check `gateway.event-loop-delay` and `gateway.resources` around the same instant; the peer's hello key joins this record to its phone records. |
| `connection.inbound-silent` | The socket stayed open, received no frame for at least 12 s, and liveness was expected: either a ping the Gateway sent went unanswered or the client pings on its own and went quiet. `peerPath=relay` or `offline` points at the Tailscale path (`peerRelay` names the relay carrying it, empty for a direct or offline peer); `direct` with a silent socket points at the phone or its process; `unknown` means there is no Tailscale answer for that address (loopback/LAN, no CLI, or a status timeout) and says nothing about the path. The paired `connection.inbound-resumed` gives the episode's `silentMs`. |
| `http.upgrade` with `reason=authentication_timeout` | A pending upgrade exceeded its authentication deadline, so the Gateway refused it (`outcome=rejected`, `phaseReached=auth`). The callback is fenced and its cancellable credential wait is retired. |
| `closeCode` / `httpStatusCode` / `platformCode` | Separate facts, never interchangeable numbers. HTTP 401/403 stop automatic admission; 503 is retryable capacity/unavailability. URLSession may report 1005/1006 rather than expose the peer's exact close frame; that absence must remain explicit. |
| `connection.projection-rejected` | A producer violated the projection contract. Narrow/reproduce that producer instead of reconnecting the whole service indefinitely. |
| `gateway.event-loop-delay` | A sampled heartbeat timer was delayed by at least one second (`durationMs`). Counts, queued bytes, RSS, heap and external-memory bytes help separate queue pressure from wider process work. Over exactly the delayed heartbeat interval it also carries `gcCount`, `gcPauseMs`, `gcMaxPauseMs` and `eventLoopUtilization`, plus host `hostFreeBytes`, `hostTotalBytes`, `swapUsedBytes`, `swapTotalBytes`, `memoryPressure`, `hostMemoryAvailablePercent` and `hostSampleAgeMs` (sampled once per record, bounded to 1 s, `host=unavailable` otherwise). GC pause time close to the delay points at garbage collection; utilization near 1 with little GC points at the Gateway's own synchronous work; low utilization with heavy swap or a low `hostMemoryAvailablePercent` points at the host not running the process. These are observations, not attribution. |
| `gateway.restart-drain.waiting` / `gateway.restart-drain.stalled` | Inspect blocker session, category, method (for `rpc-mutation`), state and age; the stalled path has requested bounded shutdown, not durable success. |

Memory measurements and timer drift are observations, not attribution. The
25-second heartbeat sampler cannot prove absence of every shorter event-loop
stall. A current low-RSS process likewise does not describe its historical peak.

### Reading the host memory fields

- `hostMemoryAvailablePercent` (`kern.memorystatus_level`) is the percentage of
  memory the kernel still considers available: the same number `memory_pressure`
  prints, so a value an operator recognizes from that tool reads the same here.
  This is the field that answers "was the Mac short of memory?", read together
  with the other fields below rather than against a fixed threshold.
- `memoryPressure` (`kern.memorystatus_vm_pressure_level`) is the kernel's own
  normal/warn/critical verdict. It can lag a sudden squeeze; read it next to the
  percentage instead of as a substitute for it.
- `swapUsedBytes` against `swapTotalBytes` is what "paging hard" means: used at
  or near the total is a host that is out of headroom, while a small used value
  on a large total is ordinary long-run macOS behavior.
- `hostFreeBytes`/`hostTotalBytes` are Node's `os.freemem`/`os.totalmem`. On
  macOS `os.freemem` counts free pages only, so a healthy, busy Mac normally
  reports a small `hostFreeBytes`; that number alone is not pressure, which is
  why this list carries the kernel's percentage as well.
- `hostSampleAgeMs` is the age of the cached sample when the record was written
  (0 when the record's own probe supplied it). The transport probes the host at
  startup and once per 25 s heartbeat, but a probe that exceeds its 1 s bound is
  discarded and the previous sample stays, so the age — not the tick — bounds
  how stale these numbers can be. Judge a drop or a reconnect with that age in
  view, because a small `swapUsedBytes` can simply be an old sample.

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
  It exercises compressed frames at and one byte over the 1 MiB decoded ceiling,
  delayed hello/open/sync, blackholed traffic, HTTP upgrade statuses,
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
