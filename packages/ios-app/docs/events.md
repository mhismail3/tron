# Gateway events

Tron events are transient presentation and invalidation signals delivered by
`GatewayClient`. They are not a durable journal and are not reconstructed into a
local database. Each delivery carries the local connection-epoch identity; `AppModel`
admits only the identity installed before receive activation, so buffered frames from a
retired profile cannot mutate its replacement. `GatewayClient` decodes every inbound
response/event frame through one discriminator and prepares large session DTOs on its
actor before crossing into `AppModel`. The raw event remains beside that typed preparation:
unknown frame discriminators are ignored, valid unknown sequenced session topics still
advance their cursor, and malformed known inner payloads retain their prior reducer-level
no-op behavior instead of disconnecting the transport. A quarantined event that cannot
advance the reducer cursor rejects the suffix before baseline publication and triggers the
bounded authoritative retry path.

`AppModel.handle(_:)` owns cross-domain routing; `SessionPresentationStore` exclusively
admits and reduces mounted-session topics:

- `session.summary` enters `SessionCatalogCoordinator`'s monotonic phase/name/count
  projection, so runs started by terminal or another mobile client update dashboard
  rows without subscribing every device to every transcript. Unknown summaries request
  discovery without fabricating a row; paginated list refreshes carry typed latest-load
  admission and one revision, restarting rather than installing mixed or stale pages;
- session snapshot/change topics enter the store's composed synchronization quarantine and
  update only the currently subscribed mounted or synchronizing authority. Baseline plus the
  contiguous suffix reduce before snapshot/token publication in one MainActor turn. Full snapshots
  install only at the exact next cursor for
  the same runtime; duplicate/stale cursors are no-ops, gaps/runtime replacement/missing
  baselines request authoritative synchronization, and missing authority or route/payload
  mismatch is discarded without creating or caching state. Synchronous intake revocation rejects all
  later sequenced topics before cursor reduction or cross-domain effects. Explicit acknowledged open/sync remains the only
  path allowed to replace a cursor or runtime baseline;
- provider, package, settings, trust, and custom-model mutation invalidations
  advance owner revisions across connected clients; each visible surface reloads
  its explicit global or project scope instead of sharing a wrong-scope payload;
- authentication prompts drive the generic secure prompt sheet;
- extension interaction topics drive select, confirm, input, or editor sheets;
- chat rendering joins canonical calls, live progress, and canonical results by
  `toolCallId` into one ordered timeline. Parallel calls carry a Gateway-issued
  monotonic ordinal, and each call carries a monotonic progress sequence so equal
  wall-clock timestamps cannot regress output. A run keeps the first call's row
  identity from invocation through completion so final assistant text cannot jump
  ahead of or reinsert it. Only consecutive tool calls consolidate; thinking or
  other canonical content flushes the group and remains in exact transcript order.
  Every chip has a locally ticking elapsed clock; its detail
  sheet shows the bounded readable live-output tail, current structured result, and
  age of the most recent runtime update. Exact current-runtime durations are used
  when available; older canonical history derives only an observed call-to-result
  interval because Pi JSONL does not persist tool execution timing;
- structure/context/resource invalidations reload an already-presented History,
  Fork, Manage Session, or Project Resources surface from the runtime;
- terminal output is admitted only for a current presentation lease, sequence-checked,
  and deduplicated; frames arriving during attach or gap recovery are held in a bounded
  local quarantine and joined contiguously to `terminal.attach(afterSequence:)` replay.
  A remaining gap schedules at most three immediate recovery attempts before waiting for
  later lifecycle reconciliation; replay reset advances native renderer
  identity, and detach/revocation rejects buffered output and exit frames. Multiple
  presentations share the connection subscription until the final lease closes;
- stopping/restart topics enter the single `GatewayLifecycleCoordinator` reconnect loop with
  the exact delivered local connection identity; duplicate transport signals cannot replace that
  owner or revive work after profile teardown. Its
  nominal 2-second, ×1.7 backoff is independently jittered within a bounded 80–120%
  window and never exceeds 15 seconds; foreground activation accelerates a pending delay
  once without replacing an active handshake.

A newly navigated chat opens exactly once and replaces any disposable cached or
previously expanded projection with a fresh bounded authoritative latest tail.
It enters the visible event-rendering state as soon as the authoritative two-phase
handshake completes. Native scroll positioning remains best-effort and never gates
readiness because physical SwiftUI can coalesce geometry callbacks. The composer
remains visible throughout opening, while sending stays disabled until readiness.
Session subscription ownership is token-scoped end to end. The open response remains
provisional until sync acknowledgement and exact route-intent revalidation; baseline plus its
already-drained contiguous event suffix then publish in one MainActor turn. A stale or failed
attempt closes only its provisional token, so a stale close cannot unsubscribe a newer same-session mount. During a rolling
upgrade, iOS accepts an older protocol-v2 `session.open` without the explicit
`subscriptionToken` and uses its `syncToken`, which is the same per-open identity;
this keeps existing Gateway-owned runs available until the Gateway can be restarted
safely. A reconnect while that same chat remains mounted instead receives
complete current runtime state and preserves compatible explicitly paged history
and the reader's follow/detached mode. If a pathological live
tool run exceeds the ordinary projection budget, duplicate tool detail is
compacted while an active snapshot retains its canonical baseline rows. iOS also
merges an overlapping authoritative tail with any earlier pages already loaded in
that open chat, so a tool burst or resync cannot reveal a new history boundary or
hide visible rows. A later navigation presentation always begins again from the
bounded latest page; this cold-presentation rule is distinct from in-place reconnect.
Phase, operation, tool ordering, and canonical paging cursors remain authoritative. A rolling-upgrade
client also normalizes the impossible legacy combination of an idle phase and retained running-tool
overlay to an interrupted chip; it does not expose a fake Stop action for extension-owned detached
work. Current Gateways project that background work separately through extension UI state. Tron
does not mount the retired `pi-subagents` async/fleet editor widgets; the run continues on the Mac
and the app catches up without presenting transport errors as modal alerts. Foreground activation
coalesces to one responsiveness/list/session reconciliation and releases its owned slot on success,
failure, cancellation, or lifecycle replacement. Switch, forget, current-device revoke, and final
teardown invalidate that reconciliation, reconnect/debounce tasks, profile-scoped reads, and
presentation intake before entering the serial retire/close chain; a late old-profile completion is
discarded and no newer handshake can start ahead of an older close. Possibly-sent mutation
reconciliation uses generation-only lifecycle admission so same-profile reconnect may resolve it, but
replacement-profile polling or replay is forbidden. A terminal-open result resolved after a
same-lifecycle connection replacement attaches on the current connection before publishing replay;
a profile-generation replacement discards it. Ordinary scene backgrounding is not teardown. An aborted or resumed network path
enters the ordinary reconnect loop. Compatible reconnect requests share one typed result instead of polling mutable tokens. Fresh
presentation and reconnect intents arbitrate serially, and at most three immediate authoritative
attempts are retained for a continuous gap/overflow burst before the bounded catch-up state wins.
A temporary catch-up pill is deduplicated and removed by the next successful authoritative session synchronization rather than persisting as an error state.
Earlier canonical entries are fetched through `session.transcript` pages when requested. Each page
is capped at 600 KB and 512 items, carries exact `start`/`end`/`total` bounds, and installs only when
`end` equals the requested boundary, `total` still equals the captured canonical total, and
`end - start` equals the decoded item count. Duplicate IDs,
gaps, stale anchors, and mismatched presentation/runtime/subscription leases are discarded rather
than concatenated into plausible history. Event-buffer
overflow closes the connection and forces global/session/terminal reconciliation;
correctness must not depend on receiving every event while disconnected. A bounded
sequenced session heartbeat advances the cursor during silent long-running tools;
it proves the owning runtime connection is live without manufacturing tool output.
