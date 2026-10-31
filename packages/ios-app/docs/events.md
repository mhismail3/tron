# Gateway connection and events

The cross-module contract for how the iPhone holds a Gateway connection and turns its events into
presentation. Transport lives in [Core](../Core/README.md), lifecycle and reduction in
[State](../Sources/State/README.md), rendering in the feature modules. The Gateway side is
[connection resilience](../../gateway/docs/connection-resilience.md); record contents are owned by
[observability](../../gateway/docs/observability.md).

## Principles

- Events are invalidation or live-presentation hints. They are not a durable journal, are never
  replayed into a local database, and correctness never depends on receiving every event while
  disconnected. The authoritative snapshot and canonical Pi JSONL decide transcript order and
  lifecycle truth.
- One Gateway runtime is the sole mutable owner of a canonical session; clients attach to it.
  Disconnecting or backgrounding never aborts an accepted run, and an interrupted prompt is never
  replayed automatically.
- Every asynchronous boundary rechecks the exact profile, lifecycle generation, connection epoch,
  presentation activity and latest request it captured; stale work is discarded, not published.

## Transport epochs

`GatewayClient` owns one authenticated WebSocket per connection epoch: socket, receive and liveness
tasks, pending requests, overflow state and handshake projection. Connect and close invalidate older
attempts; late callbacks can only detach or publish for their captured epoch, and every event
delivery carries that local epoch identity, so buffered frames from a retired profile cannot reach
its replacement. Application RPCs are definitely unsent until hello admission and event activation.

- **Deadlines.** Socket open 5 s, then hello and authentication 15 s; URL-loading inactivity 60 s.
  Intentional close sends `goingAway`, waits one second, then hard-invalidates.
- **Liveness.** While foregrounded, every socket (focused and pooled) pings on one shared ten-second
  grid (`MonotonicClock` `gridOrigin`), so the radio wakes once. A missing pong after eight seconds
  with no fully delivered inbound frame since the ping retires the epoch. This keeps
  Tailscale/iOS idle paths alive; the Gateway pings only a client that has gone quiet.
- **Admission.** Decoded frames above the Gateway's 1 MiB ceiling retire the epoch
  (`frame_too_large`, after `permessage-deflate` inflation). Dynamic `JSONValue` is capped at depth
  64, 32,768 nodes, 8,192 members, 1 MiB per string and 4 MiB aggregate. The ordered event hub
  admits the Gateway's 1,024-event quarantine under a 2 MiB byte ceiling; overflow retires the epoch
  and rebaselines rather than dropping sequence.
- **Decoding.** One discriminated `JSONDecoder` entry point per frame; typed views decode from the
  original container without reserialization, and large DTOs are prepared on the client actor so
  the MainActor installs `Sendable` values. Coders are fresh per operation. Typed decode failures
  become bounded `invalid_response` errors naming only method, category and coding path. Unknown
  frame kinds are ignored; malformed known event data is a reducer no-op, never a transport failure.

## Lifecycle and reconnect

`GatewayLifecycleCoordinator` is the sole owner of enrollment, the focused profile, connection
state, reconnect, foreground reconciliation, serial retire/close transitions and teardown.
`DashboardGatewayConnectionPool` holds one lightweight catalog client per other eligible paired Mac
(one per verified physical-machine group), each with an independent failure boundary.

- **Identity.** Pairing responses, hellos and `system.info` must assert a `stable` or `dev` channel
  matching the saved endpoint; mismatches fail closed. Hellos carry the private-LAN lanes
  (`lanEndpoints`) and certificate pin (`lanPin`), replaced on every hello and never read from an
  unauthenticated route. An epoch the LAN lane carried routes that connection's authenticated HTTP
  (live view, media, uploads) through the same pinned endpoint.
- **Schedule.** Each executor owns one `GatewayReconnectSchedule`. The focused profile starts at
  2 s, grows ×1.7 to 15 s with independent 80–120% jitter. A pool entry follows the same curve
  without jitter, then after three consecutive failures grows ×4 to a five-minute cap and shows
  **Offline**; its failure count and last-connected time survive background retirement.
- **Triggers.** Foreground, a real network-path change and explicit Retry cancel one pending delay;
  a path change also restarts the curve. An unsatisfied path parks recovery visibly
  (`reconnect.parked`) and probes again at 30 s; every refusing guard logs `reconnect.skipped`.
- **Stops.** Only unauthenticated, forbidden, protocol-mismatch and identity-mismatch failures stop
  automatic recovery until explicit Retry. Two consecutive failed opens that never opened a socket
  read **Mac unreachable** (with the interface when known). Retry Connection is a client transport
  action, never a Gateway restart or command replay.
- **Attempt boundary.** An attempt ends at authenticated handshake plus event activation, which
  publishes Connected. Mounted restoration, terminal reattachment and catalog, provider, settings
  and device reads run beneath that socket and are cancelled by its loss; a slow restoration never
  relabels a live socket or delays the next attempt.
- **Background.** Scene backgrounding cancels disposable reconciliation, preserves routes and
  last-good projections, and retires the socket epoch before suspension. Foreground creates one
  fresh epoch and authoritative baselines. Accepted Gateway work continues on the Mac.
- **Profile switch.** Synchronously revokes admission and presentation intake, awaits the exact
  transport close, then changes profile. The previous and target catalogs stay as bounded stale
  dashboard buckets until replaced.
- **Restart drain.** `system.stopping` starts `Restarting` with a 90-second watchdog; the
  replacement handshake returns to Connected. Drain phase and counts are diagnostic presentation
  only. A device install emits no lifecycle event; its sheet polls `device.install.status`.

## Requests and receipts

Each request moves through queued, sending and sent. Cancellation before send is definitive;
anything after send begins yields a local, non-Codable possibly-sent error a Gateway response cannot
forge. `ConfirmedMutationExecutor` is the single lifecycle-bound receipt owner for every mutation
domain: after an uncertain outcome it waits for reconnect and polls the command receipt, reuses
completed results, retries only confirmed-missing commands with the same ID, and never replays
pending or cancelled ones. Before first transmission it may wait up to eight seconds for a
same-generation reconnect and retry one definitely-unsent attempt; that is admission delay, not
replay. Receipt reconciliation may cross a same-profile reconnect; profile replacement forbids it.

## Session synchronization

`SessionPresentationStore` is the sole MainActor owner of the mounted session: immutable target,
revocation, live snapshot, subscription lease, synchronization and quarantine, cursor reducer,
transcript paging and session-keyed context/tree/resources/commands.

- **Open.** `session.open` returns a snapshot and sync token that stay provisional until
  `session.sync` succeeds and the exact route intent revalidates. Both tokens are nonempty,
  printable UTF-8 of at most 200 bytes; a stale open closes only its provisional token. The same
  token then owns the subscription and `session.close` releases only a matching token.
- **Quarantine.** During an attempt the session's events are quarantined, those the baseline covers
  dropped, contiguity validated, and baseline plus drained suffix published in one MainActor turn.
  One intent-keyed coordinator owns the outcome; reconnect callers await it, and one bounded
  three-attempt loop replaces recursive resynchronization.
- **Cursor.** Outside an explicit install a full snapshot hint needs the current subscription, the
  same runtime and exactly the next sequence. Duplicates are no-ops; gaps, runtime replacement and
  missing baselines resynchronize; route or payload mismatch is discarded. Unknown sequenced topics
  still advance the cursor. Revocation synchronously rejects every later sequenced topic.
- **Rebaseline.** Quarantine overflow, or a Gateway outbound queue that superseded unsent state,
  arrives as `session.rebaseline`, installed as a fresh baseline without another open. Snapshots
  must not regress the authority or live-activity revisions; malformed frames, tails over 512 items
  or queue projections over 32 items fail into the same bounded path.
- **Paging.** Snapshot tails are bounded to 800 KB / 512 items; `session.transcript` pages to
  600 KB / 512 items with exact `start`/`end`/`total` and an echoed projected neighbor. Raw
  `parentId` links are never display adjacency. A reconnect while mounted keeps compatible
  explicitly loaded history; a new navigation always starts from a fresh latest page.
- **Runtime replacement.** A reconnect that installs a new runtime for the same session clears
  context, tree, resource and command projections and rejects their stale completions and errors.
- **Visibility.** Once the synchronized chat is mounted on the active lineage in an active scene,
  the store renews a token-bound `session.presentation.set` lease (45 s, renewed on the ping grid).
  The Gateway uses it to commit completion read-through and suppress the completion alert.

## Global topics

`AppModel.handle(_:)` routes cross-domain topics; feature owners consume them:

- `session.summary` updates `SessionCatalogCoordinator`'s monotonic row projection synchronously
  (phase, name, counts, attention, `activeSince`, `foregroundPhase`, `hasActiveSubagents`,
  `waitingForUser`). An unknown summary requests discovery and never fabricates a row.
  `session.listChanged` marks the shared catalog traversal dirty; a traversal may revalidate its
  previous projection token and receive `notModified`.
- Home status is re-read (never carried) on a summary for Home's current or open chapter and on
  every `session.listChanged`.
- `automation.changed`, `knowledge.changed`, `notification.inbox.changed`, `devices.changed`,
  `providers.changed`, `models.catalogChanged`, settings, package and trust hints
  advance owner invalidation revisions. Successful reads never advance them, so a visible
  `.task(id:)` reads once per actual invalidation. Only visible owners reload, in their own scope.
- `auth.event`, `auth.prompt` and `auth.completed` belong to the device identity, not the socket:
  socket loss clears the prompt and foreground `auth.resume` rebinds it without a second login.
  Callback codes stay in the iOS listener's memory ([Auth](../Sources/Auth/README.md)).

## Session topics

- **Configuration.** `configurationBlocker` and sequenced `session.configuration` decide whether
  model, thinking and context controls are usable (`null` ready; `running`, `queued`, `settling`,
  `mutation`, `interaction`, `unavailable` locked with an explanation). Readiness never changes the
  canonical revision. Pending choices retire only at the receipt's applied revision.
- **Prompts and queue.** `pendingPrompt` is transient admission; `acceptsQueuedPrompts` alone
  decides whether a draft can steer. The snapshot carries the whole queue (at most 32 items) and its
  revision, replaced atomically; mutation responses never rewrite it locally. The prompt operation
  ID is the queue-item ID and the canonical row's presentation identity; once known, text matching
  is never causal settlement. `session.operationFailed` restores only its exact admission.
  `compactionQueued` is Gateway-owned pending maintenance, never a fabricated entry.
- **Stop.** Carries the authoritative operation ID as its fence; the Gateway rejects a stale tap
  and acknowledges only after every foreground controller and owned bash process settles.
- **Resources.** Skills, prompt templates and extension commands travel as typed
  `resourceInvocations` (#311); arguments are the exact visible text (≤ 5,000 UTF-8 bytes) and are
  never rewritten. `session.resourcesChanged` revokes command-catalog readiness and reloads it.
- **Tools.** Calls, progress and results join by `toolCallId`. Finalized declaration groups
  (`groupId`, `groupIndex`, `groupCount`) describe membership, never parallel execution or
  liveness. `toolSegmentId` scopes one visible conversation segment; only equal nonempty segments
  share a display run, and `activeToolSegmentId` decides which unresolved calls are still live.
  Monotonic duration samples are authoritative and never regress.
- **Context messages.** `custom_message` is model context, right aligned, labeled from producer
  evidence only; `custom`/`appendEntry` is hidden state; `ui.notify` is a canonical centered status,
  never a toast. Hidden internal input (`direction=hiddenInternal`) has no row. Invocation receipts
  reconcile accepted commands after restart without replaying side effects.
- **Extension presentation.** `session.extensionPresentation` mutates only at the exact next
  revision of the installed host epoch; gaps, reordering, malformed payloads or epoch mismatch
  resynchronize. Surface removal is explicit by ID; unknown kinds keep plain text. Closing an
  interaction sheet is local intent, never a cancellation.
- **Processes.** `processOverview`, `processActivities` and `session.processActivity` drive the
  subagent projection; lifecycle is latched and the Gateway owns the five-minute recent boundary.
  `session.processTranscript.changed` is lease-scoped, dispatched before the generic session path.
- **Mac Terminal.** SSH output belongs to the current connection generation, not the
  Gateway event stream. Reconnect creates a new attachment and emulator for tmux's
  authoritative screen repaint; it never replays input or Gateway terminal events.
- **Workspace.** Filesystem and Git have no event stream; visible sheets reconcile on a bounded
  cadence ([Chat](../Sources/UI/Chat/README.md)).

## Diagnostics

Signposts carry only result codes and counts. `GatewayClient` emits `gateway.rpc` for
`session.list`; `AppModel` emits `gateway.catalog` decisions; reconnect, foreground/background and
coarse path changes are bounded lifecycle incidents with loop IDs. A LAN/Tailscale race stamps
`transport=lan|tailscale` and the losing lane's stage and reason (`lan_unreachable`,
`lan_pin_mismatch`, `lan_denied`). Nothing records content, paths, credentials or payloads.
`AppDiagnostics` owns the client ring and Export Diagnostics (`system.logs.export` with
`diagnostic-export.v1`, else a local artifact); the export captures its profile/lifecycle
destination before preparation and never dispatches to a replacement.

## Covered presentation surfaces

Coverage pauses only disposable presentation work; the rules are in
[Presentation activity](presentation-parity.md#presentation-activity).
