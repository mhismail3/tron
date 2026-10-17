# Connection and request wire contract

[Gateway wire index](../README.md#transport)

HTTP/LAN/device admission, hello, requests, cancellation, command receipts, ordered delivery and shared pagination admission. See [connection resilience](connection-resilience.md) for diagnosis and qualification.

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Transport

HTTP admission accounts for physical sockets (128 global / 64 per address),
requests and pending upgrades (128 global / 32 per address / eight per connection),
and authenticated HTTP identity demand (16). Canceled credential waiters leave
ordered admission; active credential I/O keeps its mutex until actual settlement,
and late read leases return to their bounded resource owner. Attachment readers
reserve their 32 slots before metadata I/O; display readers reserve four before
verification/open. Headers allow 15 seconds, complete request bodies five minutes,
and inactivity/upgrade authentication 30 seconds. Normal close and failed startup
share one bounded retirement, fencing observers before one-second physical close.
These disposable limits never cancel accepted domain work or delete a claimed
attachment. See [connection resilience](connection-resilience.md) for exact
ownership, diagnostics, qualification commands, and remaining platform limits.

For failure-boundary interpretation, evidence collection, and regression
expectations, see [connection resilience and diagnosis](connection-resilience.md).

A second, TLS-only listener serves the Mac's private LAN address, so a phone
at home does not depend on Tailscale's path (E-3a). It is on by default (E-3d)
for a Gateway that is not bound to loopback; a loopback bind (`127.0.0.0/8`,
`::1`, `localhost`) keeps one loopback listener like the developer default and
needs `--lan-endpoint on` to serve the lane. `--lan-endpoint off` or
`TRON_GATEWAY_LAN_ENDPOINT=off` is the kill switch for a Mac or a network where
the lane misbehaves, and `on` overrides a loopback default the same way. It
binds only an
RFC 1918 or IPv6 ULA address the Mac actually has — never a wildcard, never
link-local, never Tailscale's own ranges — on the main listener's port, rebinds
when the preferred address changes, and disables itself when the Mac has none.
Its key and self-signed certificate live at `~/.tron/gateway/lan-endpoint/`
(`tls-key.pem`, `tls-certificate.pem`, both 0600 inside a 0700 directory), are
created once on first use, and are replaced only by an explicit rotation: a
paired phone pins the certificate's public key, so a silent regeneration would
break the pin instead of fixing it. A key left without its certificate (a
crash between the two first writes) is completed from that key, which keeps the
pin; a certificate without its key is refused. The listener shares the main listener's HTTP
and WebSocket handling — admission, capacity, heartbeat, revocation, hello and
its header, request-idle and TLS handshake bounds are the same code — and serves
only the socket route and the authenticated
routes: `POST /v1/pair` stays on the main listener, and `/health` on the LAN leg
answers its status alone because any host on that network can reach it. Each
accepted connection's `http.upgrade` record names the leg it arrived on
(`transport=lan`, `tailscale` or `primary`), and each bind, rebind or disable
writes one `lan.listener` record with its state, address family and port but not
the address ([observability](observability.md)).

The Mac-supervised Gateway can take neither spelling in its own arguments: its
LaunchAgent program arguments and environment are the ownership contract the
wrapper checks before registration and against the running process
(`ExistingInstallDetector`, `StableGatewayProvenance` in the Mac app). Its kill
switch is the launchd session's environment, which the launcher inherits and
passes on unchanged (`packages/mac-app/scripts/tron-gateway-launcher.c`):
`launchctl setenv TRON_GATEWAY_LAN_ENDPOINT off`, then a Gateway restart the
user performs; `launchctl unsetenv TRON_GATEWAY_LAN_ENDPOINT` hands the default
back. The variable applies from the next Gateway start, and one
`lan.listener state=disabled reason=setting_off` record is the evidence that it
took effect. That route has not been proved end to end on an installed release
yet.

A paired device learns the lane on the two channels it already owns (E-3b): the
`POST /v1/pair` response and every `hello` answer carry `lanEndpoints` —
`[{host, port}]` for the lane's current bind, or `[]` while the lane is off or
has no private address — and `lanPin`, standard base64 of the SHA-256 of the
certificate's public key as its raw uncompressed X9.63 point (`0x04 || X || Y`,
[shared fixture](../../protocol-fixtures/lan-endpoint-pin.json)). No
unauthenticated route names the lane. A phone replaces the endpoints and pin it
stored on every hello, so a Mac that moved, or whose lane was switched off,
is corrected before the next connection instead of dialling an address this Mac
no longer serves.

Authenticated `system.logs.export` is a user-requested diagnostics projection: it accepts only a
bounded already-redacted snapshot and command ID, appends the newest Gateway debug records (at most
1 MB), writes a server-chosen `<device-hash>-<timestamp>.jsonl` file under
`~/.tron/logs/device-exports/` inside a 0700 directory, and retains only the newest ten exports.
Files are 0600. It never accepts a client filesystem path, reads session content, or creates a public upload. Gateway RPC diagnostics retain bounded structured `method`, `requestID`, `outcome`, `code`, and `durationMs` fields; catalog stage records additionally carry a process-local `workID` and scope so shared materialization cannot be misattributed to one caller. Request IDs are sanitized transport IDs only, and stage timing uses monotonic durations. Catalog admission and viewer capacity/retirement failures additionally carry fixed privacy-safe `reason` codes; arbitrary exception messages, error details and request parameters are not copied into those fields.

- `GET /health` — unauthenticated readiness and compatibility metadata. The bound listener reports `starting`, `catalog-warming`, `attention-recovery`, `automation-recovery`, or `storage-warming` with HTTP 503 until all startup prerequisites complete, then reports `ok` with HTTP 200; every other HTTP route and WebSocket upgrade remains retryable `busy`/503 during warmup and does not enter session APIs.
- `POST /v1/pair` — rate-limited one-time enrollment exchange
- `POST /v1/uploads` — authenticated bounded upload
- `DELETE /v1/uploads/:id` — authenticated discard of unclaimed client staging; prompt-owned attachments fail closed
- `GET /v1/uploads/:id` — authenticated stream for a prompt-owned canonical attachment
- `GET /v1/blobs/:id` — authenticated transient projected blob
- `GET /v1/sessions/:sessionId/display-artifacts/:id` — authenticated, session-authorized immutable display artifact with single-range resume/streaming
- `POST /v1/sessions/:sessionId/live-views/:id` — open a disposable viewer with `{generation}`
- `GET /v1/sessions/:sessionId/live-views/:id/frame` — latest JPEG or a body-free waiting/unchanged response
- `DELETE /v1/sessions/:sessionId/live-views/:id` — close the exact viewer; last native viewer requests joined suspension, never browser automation shutdown
- `GET /v1/socket` — authenticated protocol version 8 WebSocket

Bearer admission is linearized with the paired-device document under the
DeviceStore mutex: the credential check and synchronous HTTP/upgrade registration
share that mutex, but long body, stream, or provider operations are not awaited
under it. The local wrapper credential, pairing invitation, paired-device document,
and revocation replacement are published through the durable file-plus-directory
synchronization primitive, so an acknowledged pairing or revocation is not lost to
a power failure between the rename and the filesystem metadata flush. If the
replacement rename succeeded but later synchronization fails, transport authority
is retired under the credential mutex while the durability error remains visible.
A failed pairing attempt regenerates the invitation even when its consumption
unlinked the old invitation before a directory-sync failure. Device revocation atomically
replaces that document, publishes transport retirement immediately, then performs
best-effort install cleanup. Requests and canonical mutations admitted before the
cut settle independently of their sockets; revoked connections reject later
requests and observer callbacks. Only the exact initiating self-revoke response
may be added after the cut. Previously queued frames drain in order; once that
response is queued, a one-second unref'd flush deadline terminates a stalled
writer instead of retaining its connection capacity indefinitely. An idle writer
closes normally. Observer leases retire at the cut and are checked again after
asynchronous installation. Local-wrapper authority and ordinary
disconnect/resumable provider auth remain independent of paired-device revocation.
The real transport/receipt/runtime regressions in
`src/transport/server-revocation.integration.test.ts` cover these boundaries.

## Pairing and device storage

The pairing limiter keeps the exact rolling per-address window while retaining at most 4,096
least-recently-used address keys and periodically deleting expired windows; address churn cannot
create append-only process state. Paired-device storage admits at most 256 unique device IDs and
token hashes with bounded names/timestamps; capacity rejection leaves the one-time invitation valid
so an old device can be revoked before retrying. Device metadata is capped at 1 MiB, the local wrapper
credential at 4 KiB, and the one-time invitation at 16 KiB before JSON decode. Local credentials and
invitations also require owner-only regular-file boundaries (symlinks are rejected), exact versions,
purposes, bounded identities/codes, and canonical timestamps. A pairing invitation is consumed before
its device record is written; a failed device write explicitly issues a fresh invitation while the
pairing mutex remains held.

## Hello, requests, receipts and ordered delivery

Every WebSocket starts with:

```json
{"type":"hello","protocolVersion":8}
```

The hello, pairing response, and authenticated `system.info` identify the runtime
with `machineId` (stable per Tron home), `gatewayChannel` (exactly `stable` or
`dev`), and, on current gateways, `machineGroupID` (stable across separate
production and isolated-Dev homes on one physical Mac). Runtime construction
validates `TRON_GATEWAY_CHANNEL`; absence retains the launcher's stable
compatibility default, while every other value fails closed before identity can
be projected. Older gateways omit `machineGroupID`; clients fall back to
`machineId`. The group identifier is only a bounded connection-group hint and
never names or shares session files, credentials, or other canonical runtime
data.

The hello also carries the connection correlation key. The phone sends
`diagnostics: { clientId, attemptId, epoch }`: its client's stable diagnostic
owner ID, the reconnect loop ID or `"initial"`, and the connection epoch number
as a decimal string. The Gateway keeps each value only if it is a token of at
most 64 characters of `[A-Za-z0-9-]`. It drops an invalid or missing value and
never rejects the hello for one. It stamps the kept values as `peerClientId`,
`peerAttemptId` and `peerEpoch` on that connection's records
([observability](observability.md)). The hello response adds
`connectionId`, and the phone logs it as `gatewayConnectionId`. Both halves are
diagnostic only: a peer that omits them still connects.

Requests use `{type,id,method,params}` and receive `{type,id,ok,result|error}`.
A client that stops waiting for a disposable read sends `{type:"cancel",id}` and
receives no answer: the Gateway abandons that request's work and records
`rpc.cancelled` with the stage it interrupted. Cancellation applies only to
`session.open`, `session.list`, `session.transcript`, `session.history.list`,
`session.history.entry`, `home.memory.view`, `home.memory.evidence`,
`model.list`, `provider.list` and `provider.usage`; a cancel for
any other method is ignored. An accepted mutation
or admitted prompt is never cancelled, and neither is a `session.sync`
acknowledgement: their owners settle them durably whatever the client does with
their wait.
Seven of those ten methods have server-side deadlines
(`DISPOSABLE_READ_DEADLINES_MS` in `packages/gateway/src/transport/server.ts`):
10 s for `session.open`, whose cold load may parse a large transcript before its
subscription commits, and 5 s for `session.list` and the transcript pages
(`session.transcript`, `session.history.list`, `session.history.entry`) and the
Home browser (`home.memory.view`, `home.memory.evidence`). A read
that outlives its deadline is aborted, answered `busy` with
`details.retryAfterMs`, and recorded once as `gateway.shed` with
`reason=deadline`; the phone waits that hint (bounded to 10 s), retries the read
once and logs `rpc.retry-after`. A method with no entry in that table has no
deadline and is never shed: that is every mutation, every prompt, `session.sync`,
and the three disposable reads (`model.list`, `provider.list`,
`provider.usage`) whose own owners already allow longer than the client does —
`provider.usage` answers a typed timed-out snapshot after up to 10 s per fetch,
so a deadline below that owner's bound would throw away an answer it was about
to produce.
Concurrency caps queue rather than refuse: two cold runtime loads, one session
export and two workspace inspections at a time, each a named constant next to its
user. Cold loads are additionally gated on heap pressure: above
`HEAP_EVICTION_SHARE` (0.70) of the V8 heap limit idle runtimes are retired
largest first until the share is back under it — the registry's own accounting of
what it gave back is what ends that pass, because `heapUsed` does not fall until
V8 collects — and above `HEAP_REFUSAL_SHARE` (0.85) the admission is refused with
`busy` and `HEAP_REFUSAL_RETRY_AFTER_MS` and one `gateway.shed` with
`reason=heap` naming its `admission` (`open` for a cold runtime load, `import`
for a JSONL import, which is refused before it writes anything). A protected
runtime (a subscriber, a run, a lease) is never retired to make room, so a heap
made of protected runtimes refuses instead of pretending it made room.
`packages/gateway/docs/connection-resilience.md` owns the full limits table.
A second `session.open` for the same connection and session joins the attempt
already in flight and receives its exact result instead of a `conflict`; the
shared attempt is abandoned only when its last waiting request leaves, and a
genuinely overlapping open that is not a join is still rejected. A cancel for a
request that was already cancelled or never admitted changes nothing. A cancel
for an answered `session.open` whose barrier the client never synchronized
revokes that barrier, so a retry in that window is answered instead of failing
as a duplicate - unless another delivered response carries the same token, as a
joined retry's does; that barrier stays for the client to synchronize.
Mutations require `params.commandId`; receipts deduplicate completed commands.
After an uncertain disconnect, clients reconnect and poll `command.status`, reuse
a completed result, retry only a confirmed-missing command with the same ID, and
never blindly replay a pending command. `session.prompt` is the one exception to
waiting for the completed receipt before replying: it keeps the pending receipt
durable before Pi admission, responds as soon as that admission resolves, and
finishes the completed receipt write while retaining the command lane and its
Gateway drain owner. Same-command duplicates join that lane and receive the
stored result. Process loss or a failed completion write in this response window
leaves the pending receipt as an outcome-unknown replay fence; prompts are never
re-run automatically. The receipt-store owner closes admission and joins accepted
receipt persistence, including completion writes and definitive-rejection cleanup,
before releasing its state directory; this drain does not wait for the command's
operation to settle. Every other receipt-backed method still persists its
completed receipt before responding because its acknowledgement boundary has
not been approved to move. A mutation whose owner reports an unknown
outcome keeps its pending receipt even though the operation threw, so the
identical command ID cannot execute twice. Refresh authoritative state before
making a new decision; a new command ID is not proof that replay is safe.
Canonical ownership writes bound the caller's wait, including a write that never
settles. A timeout or unproven append retains the exact runtime as a visible drain
and eviction blocker and rejects further mutations and reload. Even a pre-provider
marker may already have been renamed before an fsync failure. Late physical
completion does not resume abandoned dependent transitions. This deliberately
fails closed: the pinned SDK has no supported repair/flush acknowledgement for a
memory-only canonical entry, so refreshing or resending a command cannot clear
that blocker. Confirmed identity conflicts remain definitive pre-write rejections. An observed application rejection removes
its pending receipt so the definitive error remains definitive; process loss or failure
to persist a successful completion leaves pending state and therefore cannot enable a
blind duplicate. Each receipt is capped at one response frame plus 4 KiB of
identity/envelope overhead before decode and persistence. The store admits at most
32,768 direct entries and 64 MiB of aggregate evidence, reserving one maximum
completion before a mutation executes; full capacity returns retryable `busy`.
Admission keeps an in-process usage total, reconciled from disk when a prune
removed evidence rather than once per receipt write, so sustained revisioned
activity is not quadratic in the receipt count; the age-based prune is the
background-work scheduler's job (`COMMAND_RECEIPT_PRUNE_INTERVAL_MS`, one
minute), and admission only forces one exact pass at the capacity boundary
before it refuses;
owned interrupted atomic-write temporaries are scavenged, but only when the
command that named them no longer holds a lane, so a receipt write in flight
never loses its temporary, and arbitrary files are not treated as receipt
evidence.
Only expired, valid completed receipts are reclaimed; revisioned editor updates use
a ten-minute receipt window because newer revisions supersede them. Pending,
malformed, oversized, or identity-mismatched evidence remains outcome-unknown, is
never pruned, and can never authorize replay. Receipt execution serializes identical command keys only;
unrelated commands and sessions remain concurrent.
`src/transport/ordered-outbound-queue.ts` owns ordered writes, queue bounds and unsent-state supersession; `server.ts` retains socket admission, frame preparation, broadcasts and connection retirement.

Outbound WebSocket admission keeps the 1 MiB encoded-frame ceiling, a 32,768-value JSON node ceiling, and an 8 MiB / 4,096-frame per-connection aggregate queue ceiling. Byte size alone does not prove native decoder admission: many small browser-result records can exceed the structural limit. Transcript pages reserve 24,000 nodes and snapshots 30,000, leaving room for enclosing metadata. Aggregate structural pressure compacts disposable detail into explicit previews before publication, without changing canonical JSONL, row ordinals, or transcript cursors. The shared `gateway-json-limits.json` fixture pins the native/sender contract. This is the common bounded projection contract for local and mobile clients, not separate audience-specific schemas. Final response rejection stays correlated as `response_too_large`; rejected events request resynchronization. A rejected response does not undo an accepted command: confirmed mutations must preserve outcome uncertainty rather than treat projection failure as definitive execution failure. Node-limit diagnostics report a bounded lower count (`nodeCountAtLeast`) and maximum, never payload content. A connection-local ordered writer hands exactly one frame to the WebSocket implementation at a time; enqueue acceptance is the response/event ordering boundary, so a response remains ahead of its synchronization suffix while concurrent startup catalogs cannot manufacture `bufferedAmount` pressure. A frame whose state a newer frame replaces is dropped while it is still unsent, so a slow link queues current state instead of every superseded revision of it. A newer `session.summary` replaces the unsent revision of that session; a newer `session.snapshot` supersedes the unsent sequenced state of its own runtime generation that its own state fully re-states, up to its own `eventSequence`, and only together with the frame that covers them: the surviving snapshot is encoded as the `session.rebaseline` carrying the whole snapshot and the connection's installed `subscriptionToken`, which the phone admits as fresh authority across the sequences the queue dropped instead of resynchronizing. Installing a snapshot restores state, not every effect: a sequenced frame whose effect no snapshot installation performs (a failure receipt that retires a submission and restores its draft, a resource/structure/context revision bump that reloads commands, an editor directive) is a fence, and the queue drops neither it nor anything behind it, so no replacement has to restore what it cannot. Frames of another runtime generation are fences too, because a replacement runtime restarts `eventSequence` at zero. Without that installed token a snapshot supersedes nothing, the frame already entering `ws` is never recalled, and what a client receives stays a subsequence of what was enqueued in enqueue order. A dropped frame is released with its byte reservation and is no longer outstanding, so the `connection.closed`/`connection.write-error` frame counts still describe frames the connection owed its peer, and `gateway.resources` reports the dropped frames and bytes as `outboundCoalescedFrames`/`outboundCoalescedBytes`. A broadcast prepares one immutable encoding per operation and reuses it for eligible connections, while each barrier and queue retains its existing connection-local byte admission and failure isolation; the coalescing `session.rebaseline` is the one frame encoded per connection, because it carries that connection's installed `subscriptionToken` and nothing else differs. The queue reports the bytes it accepted, so the frame that is actually queued is the one counted. The queue includes its active frame and releases each completed payload at the same boundary as its byte reservation; array compaction must never retain unaccounted completed payloads. Count or byte overflow closes only that peer with `1013`, and the record names the topic of the frame it was waiting on and the one that did not fit. Admission and disposable observers retire immediately, including asynchronous subscription installation that returns after the retirement cut. A one-second forced-close deadline releases a stalled peer; it still consumes connection capacity until physical close. Asynchronous write failures are logged and terminate that exact connection. Each socket also owns abort controllers for in-flight requests: retirement releases disposable `session.list` waits immediately while the coalesced canonical materialization may finish for another caller; accepted prompts and durable mutations never inherit socket cancellation. `server-capacity.integration.test.ts` covers continuously busy payload retention, tiny-frame bursts, superseded-frame replacement and the unchanged backstop, stalled overload closure, unrelated-peer responsiveness, and accepted-command settlement; `sync-protocol.integration.test.ts` covers a superseded frame whose sequence was still quarantined behind a synchronization barrier.
Paired devices that offer `permessage-deflate` get compressed frames with context takeover; local-credential clients stay uncompressed. Every frame, queue and inbound bound above applies to uncompressed bytes. The [frame compression](connection-resilience.md#frame-compression) section owns the settings, measurements and the phone's decoded-size boundary.
The gateway runs a 25-second heartbeat and terminates a socket only after three
consecutive ticks received no frame from it, so half-open Tailscale/iOS paths
are observable without allowing one delayed timer or transient callback stall to destroy a healthy epoch. Pong, ping, and application frames all reset the consecutive-miss counter. A tick sends a WebSocket ping only to a client that initiated no message or ping during the preceding interval, so silent and pong-only clients are pinged every tick while a foreground phone's own pings make server pings unnecessary; the [connection resilience guide](connection-resilience.md) owns the rule and its one-tick transition residual. Mobile clients wait ten seconds between transport-level probes from a liveness task that does not depend on application event reduction. Inbound event traffic therefore cannot starve the client-activity proof. Mobile clients additionally observe pong completion under an eight-second local deadline and bound the entire hello send/receive attempt; loss of that disposable connection never cancels an accepted prompt. Uncertain sends reconcile by command ID on the replacement connection, not by blindly replaying a prompt. Client-side bounded diagnostics distinguish heartbeat timeout, event-buffer overflow, and intentional retirement and remain available offline without sending pre-hello RPCs. Heartbeat timeouts include the disposable connection ID and miss count, and every connection record carries the peer's hello correlation key when it sent one. A socket that stops proving liveness for 12 seconds — a server ping left unanswered, or a client that pings on its own gone quiet — writes one `connection.inbound-silent` warning carrying the peer's Tailscale path (`direct`, `relay`, `offline` or `unknown`), and its next frame writes `connection.inbound-resumed` with `silentMs`; a client that only answers the Gateway's pings is idle between them, never silent. Each upgrade writes exactly one `http.upgrade` record with its phase durations, the phase it reached, its outcome and its structured `reason` ([observability](observability.md)). An admitted physical connection that closes before any HTTP request or upgrade handler writes one `http.connection-unused` warning with its listener, elapsed time, byte count and bounded parser/TLS error code; healthy probes and upgrades do not. The accepted socket and its TLS wrapper share that trace. WebSocket close records carry the raw socket's observed `transportEnd` (`reset`, `timeout`, `fin`, or `none`) so a 1006 no longer discards an observed TCP cause. Sampled heartbeat timer drift of one second or more emits bounded event-loop-delay telemetry with connection/request counts, queued bytes, RSS, heap, and external-memory bytes; this is a sampled diagnostic, not proof that every shorter stall is observed. Outbound-capacity diagnostics include the violated count/byte limits and high-water marks plus those process-pressure facts. Oversized or unencodable projections log bounded rejection diagnostics without payloads, and connection-capacity rejections report actual counts and limits. Timeout and close records also carry non-payload inbound age, write-progress age, and outbound queue counters in the existing bounded message field, preserving the log record schema. A paired device's connection open and close records additionally carry the Mac's free and total memory, swap used and swap total, the kernel's memory pressure and available-memory percentage, and the age of the host sample they came from, taken from the sample the heartbeat keeps current, so a drop during host paging is readable in the same line without a probe of its own, and a sample a discarded probe left older than a tick says so. WebSocket close codes/reasons remain credential-free so transient transport failures are diagnosable. Reconnect and foreground activation converge through an authoritative
snapshot.

## Common JSON projection

Bounded JSON projection admits nodes before copying their values, accounts for
sparse-array null slots and diagnostic markers, and preserves repeated sibling
references without expanding an unbounded intermediate tree. Tool-output suffixes
retain chronological block order and newest text; large tool-result text is tailed
before generic JSON previews so its text/type identity survives.

## Operation groups and shared metadata

Primary operation groups are `system`, `device`, `session`,
`extension`, `provider`, `model`, `auth`, `settings`, `trust`, `packages`,
`models.custom`, `filesystem`, `git`, `terminal`, and uploads/blobs over HTTP.

## Paginated read admission

`session.list` and `model.list` are cursor-paginated so Pi catalogs remain
complete without exceeding bounded gateway frames. A catalog build suspends the
request while other owners continue, so the pager reacquires the live owner lease
after the build before publishing a cursor; a concurrent distinct-owner listing
can therefore never return an immediately expired cursor.

The bounded JSON projector tracks only the active recursion path, so shared Pi metadata objects are expanded for each sibling resource while true cycles remain marked and bounded.
