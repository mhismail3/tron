# Gateway events

Tron events are transient presentation and invalidation signals delivered by
`GatewayClient`. They are not a durable journal and are not reconstructed into a
local database.

`AppModel.handle(_:)` owns routing:

- `session.summary` applies a bounded global phase/name/count projection to
  dashboard rows, so runs started by terminal or another mobile client show the
  active spinner without subscribing every device to every transcript; paginated
  list refreshes carry one revision and restart rather than install mixed pages;
- session snapshot/change topics replace the corresponding authoritative
  snapshot or trigger a paginated list refresh;
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
- terminal output is sequence-checked and deduplicated; a gap or reconnect uses
  `terminal.attach(afterSequence:)` to replay the bounded authoritative PTY tail,
  while terminal exit updates both controls and status;
- stopping/restart topics move connection state into reconnect mode.

A newly navigated chat opens exactly once and replaces any disposable cached or
previously expanded projection with a fresh bounded authoritative latest tail.
It does not enter the visible event-rendering state until two valid exact-bottom
geometry observations confirm positioning; bounded positioning attempts fail into
a recoverable Retry surface instead of revealing an intermediate position. The
opaque opening surface also hides and disables the complete composer interaction
stage until readiness. Session subscription ownership is token-scoped end to end,
so a stale close cannot unsubscribe a newer same-session mount. A reconnect while that same chat remains mounted instead receives
complete current runtime state and preserves compatible explicitly paged history
and the reader's follow/detached mode. If a pathological live
tool run exceeds the ordinary projection budget, duplicate tool detail is
compacted while an active snapshot retains its canonical baseline rows. iOS also
merges an overlapping authoritative tail with any earlier pages already loaded in
that open chat, so a tool burst or resync cannot reveal a new history boundary or
hide visible rows. A later navigation presentation always begins again from the
bounded latest page; this cold-presentation rule is distinct from in-place reconnect.
Phase, operation, tool ordering, and canonical paging cursors remain authoritative. The run continues on the Mac;
the app catches up without presenting transport errors as modal alerts. Foreground activation
coalesces to one responsiveness/list/session reconciliation; an aborted or resumed network path
enters the ordinary reconnect loop. A temporary catch-up pill is deduplicated and removed by the
next successful authoritative session synchronization rather than persisting as an error state.
Earlier canonical entries are fetched through `session.transcript` pages when requested. Event-buffer
overflow closes the connection and forces global/session/terminal reconciliation;
correctness must not depend on receiving every event while disconnected. A bounded
sequenced session heartbeat advances the cursor during silent long-running tools;
it proves the owning runtime connection is live without manufacturing tool output.
