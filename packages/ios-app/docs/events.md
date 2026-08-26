# Gateway events

Tron events are transient presentation and invalidation signals delivered by
`GatewayClient`. They are not a durable journal and are not reconstructed into a
local database. Each delivery carries the local connection-epoch identity; `AppModel`
admits only the identity installed before receive activation, so buffered frames from a
retired profile cannot mutate its replacement. Backgrounding is an explicit transport boundary:
`GatewayLifecycleCoordinator` retires the socket epoch and clears queued deliveries while retaining
last-good session projections; foreground creates a new epoch and authoritative session baseline.
`GatewayClient` decodes every inbound response/event frame through one discriminator and prepares large session DTOs on its
actor before crossing into `AppModel`. `GatewayEvent` uses one topic dispatcher for network `Decoder` payloads and local
`JSONValue` fixtures; the adapters share identical topic admission and malformed-event behavior, while the network adapter
continues decoding directly from the original decoder without JSON reserialization. The raw event remains beside that typed preparation:
unknown frame discriminators are ignored, valid unknown sequenced session topics still
advance their cursor, and malformed known session payloads fail closed to authoritative
catch-up instead of disconnecting the transport or consuming their cursor. A quarantined event that cannot
advance the reducer cursor rejects the suffix before baseline publication and triggers the
bounded authoritative retry path.

`AppModel.handle(_:)` owns cross-domain routing; `SessionPresentationStore` exclusively
admits and reduces mounted-session topics:

- `session.summary` enters `SessionCatalogCoordinator`'s ID-indexed monotonic
  phase/name/count projection, so runs started by terminal or another mobile client update
  known dashboard rows synchronously without subscribing every device to every transcript or
  issuing a list request. A summary makes only that row live before full catalog completion;
  unknown summaries request discovery without fabricating a row. The same row projection carries
  Gateway-canonical completion/read-through attention. A final prompt response becomes unread only
  at truthful settlement; opening acknowledges only the completion revision installed by that
  exact presentation/connection owner, transient retries retain the same absolute revision, and
  explicit Mark Read/Unread mutations use command receipts. Cached rows may show
  stale offline attention but never own it, while foreground and background profile event streams
  converge every dashboard. `session.listChanged` marks
  the shared traversal dirty instead of cancel/restarting it. User-scoped 500-row pagination
  has exact page/item/identity/cursor bounds and publishes atomically. Mixed page revisions
  and expired continuation leases restart once from a nil cursor and then retain the previous catalog silently; this expected
  optimistic invalidation no longer creates the intrusive “Sessions changed while loading the
  dashboard” in-app notification or another routine synchronization notice;
- session snapshot/change topics enter the store's composed synchronization quarantine and
  update only the currently subscribed mounted or synchronizing authority. Baseline plus the
  contiguous suffix reduce before snapshot/token publication in one MainActor turn. Full snapshots
  install only at the exact next cursor for
  the same runtime; duplicate/stale cursors are no-ops, gaps/runtime replacement/missing
  baselines request authoritative synchronization, and missing authority or route/payload
  mismatch is discarded without creating or caching state. Synchronous intake revocation rejects all
  later sequenced topics before cursor reduction or cross-domain effects. Extension input leases are tri-state: an omitted
  `inputLease` leaves the prior lease unchanged, an explicit JSON `null` clears it, and a value replaces it only when it
  identifies an admitted surface revision; malformed values fail closed without publishing a partial mutation. Explicit acknowledged open/sync remains the only
  path allowed to replace a cursor or runtime baseline. The same snapshot carries the full
  bounded queue projection (at most 32 authoritative items, including total attachment count and optional photo/file counts)
  and queue revision; queue updates therefore replace the visible
  queued-message cards atomically rather than applying per-row mobile deltas. A Gateway advertising
  `queue-management.v1` must supply both rich fields; iOS admits Edit/Remove only for that
  authoritative pair. Legacy string-only projections remain visibly locked and direct the user to
  update Tron on Mac. A mutation response never rewrites queue projection locally: clear,
  edit, reorder, and remove keep controls inert until a strictly newer sequenced queue revision
  installs from the Gateway. While that mutation is pending, its exact changed/removed operation IDs
  cannot claim queue-to-canonical continuity. If a canonical snapshot would settle one of those IDs,
  iOS keeps the installed queue visible and coalesces only the newest complete conflicting capture until
  the command resolves: success retires and excludes the matching handoff before installation, while
  failure restores exact settlement before installation. A newer queue revision that races ahead of the
  response cannot clear mutation ownership or exclusions until that outcome is known. Presentation
  retirement wakes suspended projection installers and target/generation-gates late command completion.
  The installed queue revision/items and capability authority own the
  card controls; unrelated transcript projection work does not make an installed queue card flicker
  read-only. An explicit user-admitted earlier-page request owns one exact local token through
  paging, projection installation, and anchored prepend settlement (or unanchored installation),
  while reducer/scroll loading only corroborates that transaction and never supplies another label.
- `compactionQueued` is an optional rolling snapshot field owned by the Gateway's
  single pending maintenance slot. iOS renders it as explicit runtime feedback and never
  inserts a transcript entry or retries the mutation. The row is replaced by existing
  compacting feedback when the Gateway picks up the work, then by the canonical JSONL
  compaction entry. Current Gateways publish one immediate contiguous authoritative snapshot
  at `compaction_end`; it contains the fitted current tail/leaf (including hook-appended suffix)
  and truthful restored prompt/automatic-idle operation state; manual marker cleanup remains compacting
  until durable settlement. iOS retains typed `session.compaction`
  decoding only for rolling compatibility with older Gateways and requests rebaseline for an
  inexact legacy delta.
  `pendingPrompt` is the companion transient admission for a prompt
  whose canonical user entry is still being prepared, including automatic compaction
  during prompt preflight. An ordinary prompt compacting in its own preflight remains
  semantically ordinary (never a fabricated `queuedItem`) but uses the shared emerald queue-card visual
  with “Message” / “After compaction” until its canonical user entry arrives. Gateway binds that entry's
  bounded `presentationId` to the prompt operation ID, which iOS consumes before legacy text
  matching. Submission transport ownership is profile/session scoped across route generations, so leaving and reopening projects the same sending/accepted row without replaying the RPC. One unified physical row namespace spans committed, live/runtime, lifecycle, and queue content: the compaction spinner and canonical pill therefore update under their shared ordinal ID, and an exact operation-bound canonical handoff may reuse the prior lifecycle's physical ID while retaining its canonical semantic ID. Optional skill selection travels as bounded `session.prompt.skillName` metadata rather than
  editor text. The Gateway validates it against the exact live skill catalog, retains the original prompt in
  `pendingPrompt` and queue items, and removes Pi's canonical skill envelope during bounded transcript projection,
  so no lifecycle frame exposes `/skill:` or private skill contents. `session.resourcesChanged` revokes command-catalog readiness and starts one generation-gated reload for the exact mounted subscription before retained skill state can reconcile. An active upload for the exact presentation closes send admission synchronously; stale UI actions retain the draft, attachments, and skill until upload completion. Its initial role-aware entrance remains one-shot; composer collapse and the outgoing graft share one pre-mutation viewport generation, while only the exact lifecycle-to-canonical successor receives the focused replacement morph. Optimistic composer settlement consumes every
  authoritative session-reducer publication directly rather than waiting for delayed transcript formatting. The lifecycle-to-canonical header/status collapse uses one explicitly admitted prompt spring and a short fade under Reduce Motion; unrelated transcript updates do not inherit that transaction, and no scroll command is added. For queued steering/follow-up, the returned prompt operation ID is also the Gateway's
  stable queue-item ID, so a concurrent same-text item cannot settle the wrong optimistic admission. That exact
operation identity may coalesce the optimistic queue-kind row with its newly admitted authoritative queue card; baseline
operation IDs are never reused for aliasing, and aliases retire when authoritative queue items disappear. The queue row
never borrows an identity from pre-existing or unrelated items. Behavior is normalized before first render,
unknown values stay neutral, and each newly admitted prompt uses its role-aware entrance animation exactly once.
Queue admission and canonical handoff receipts suppress every later entrance; pending/queued-to-canonical replacement preserves canonical semantic IDs while one bounded one-to-one causal alias retains physical row identity. Repeated text, unrelated rows, and alias collisions fail closed. Replacement installs directly visible with only the focused container/header morph and no hidden mount state. Exact off-main-prepared file
previews map through upload blob identity, and prepared image previews transfer by order only when complete count/MIME facts
agree; settlement performs no decode, while ambiguity uses normal media loading. Attachment-only canonical settlement uses an exact attachment metadata multiset even when Pi
  persists synthesized envelope text. `automaticCompactionEnabled` likewise reports
  runtime truth rather than a mobile inference; older snapshots may omit these fields.
  Transcript projection captures the authoritative snapshot and composer handoff
  as one immutable commit; pending/outgoing rows render only from installed
  handoff state, while canonical reconciliation installs handoff `none`. A
  frame gate retains the previous complete commit until the replacement is ready;
- provider, package, settings, trust, and custom-model mutation invalidations
  advance owner revisions across connected clients; each visible surface reloads
  its explicit global or project scope instead of sharing a wrong-scope payload;
- authentication prompts drive the generic secure prompt sheet;
- `session.extensionPresentation` remains the leased transport for semantic updates and native select/confirm/input/editor/questionnaire sheets. Read-only statuses, widgets, and service activity no longer create an ambient composer or Manage Session surface; interactive prompts and editor ownership are unchanged;
- the snapshot `processOverview` authority with its optional nonempty `processActivities` rows and compact `session.processActivity` events drive one package-neutral current/recent projection for assistant commands and admitted subagents. A delta carries an optional exact process upsert, bounded explicit removals, and one same-revision shallow overview. `SessionPresentationStore` applies that replacement atomically and resynchronizes instead of installing an overview around a stale or rejected row; it never rebuilds transcript projection or moves chat scroll state. Terminal lifecycle is latched; delayed full frames cannot resurrect or erase newer process evidence. The Gateway emits a replacement at the exact five-minute expiry even without another chat event. The composer sheet reads mounted rows only, while `SessionProcessHistoryStore` loads canonical pages from `session.processHistory.list/get` for the exact presentation/history generation;
- `session.processTranscript.changed` is a lease-scoped invalidation, not a parent session-cursor event. `GatewayProtocol` dispatches it before the generic `session.*` envelope path. A mounted `ReadOnlySubagentSessionStore` accepts only its exact lease and newer revision, refreshes the newest page through that same lease, and retains already loaded earlier pages when canonical overlap proves append-only continuity. Branch replacement or an unbridgeable gap falls back to the new canonical tail rather than fabricating adjacency. `open/page/close` responses preserve page range, canonical boundary, unique ID, and generation checks; transient current tool/output remains outside canonical transcript rows;
- chat rendering joins canonical calls, live progress, and canonical results by
  `toolCallId` into one ordered timeline. At finalized assistant `message_end`, the
  Gateway publishes complete contiguous declaration groups before their tool starts.
  Runtime-only `groupId`, `groupIndex`, `groupCount`, and `groupFinalized` facts derive
  from the stable assistant presentation identity and first projected content ordinal;
  they describe declaration membership, never inferred parallel execution, and are not
  persisted to Pi JSONL. Provisional streaming calls remain hidden until that boundary.
  Each call still carries a Gateway-issued monotonic execution ordinal and progress
  sequence so equal wall-clock timestamps cannot regress output. A display run keeps
  its first finalized group identity from invocation through completion, reconnect,
  and canonical settlement so final assistant text cannot jump ahead of or reinsert it.
  Only consecutive tool calls consolidate; thinking or other canonical content flushes
  the group and remains in exact transcript order.
  The Gateway supplies monotonic duration samples while a call is running and the
  authoritative final call-to-return duration when it completes; chips display those
  samples without deriving normal timing from the device wall clock. The runtime-only
  tail overlay admits current running executions only. Terminal unanchored executions
  are not synthesized into a duplicate bottom aggregate; they appear only through their
  canonical or streaming transcript position, while anchored terminal calls remain visible.
  Older Gateways
  without live duration samples use a bounded local monotonic fallback. The open detail
  sheet continues to consume the newest immutable call presentation, showing status and all bounded readable
  latest bounded live-output frame. Each newer nonempty frame replaces the displayed frame in place rather than
  accumulating repeated status snapshots; an empty advisory frame preserves the last readable output so an open
  sheet never flashes blank. A terminal live projection whose output/result was intentionally stripped after canonical settlement enriches status and timing only; it cannot erase the canonical tool-result text used by detail sheets. The terminal nonempty result remains authoritative. Gateway and iOS apply the same
  replacement rule so reconnect or projection replacement cannot resurrect discarded frames or erase readable output. Explicit output-truncation state appears only when the runtime flag or
  structured truncation contract says `truncated: true`, and the age of the most recent
  runtime update without automatic scrolling. One mounted tool chip hierarchy presents the
  actual tool name for a single invocation and **Using/Used N tools** for an aggregate;
  extension provenance never substitutes **Extension activity**. Structural chip targets
  exclude duration and payload churn, coalesce for one display frame, and use a monotonic
  latest-target token for local interruptible animation while transcript and scroll
  projection transactions remain stable while the transcript boundary preserves continuous system interaction transactions. Both legacy and consolidated tool chips use native interactive Liquid Glass as their sole press-and-drag owner. Their visible surface handles taps directly and exposes explicit button accessibility semantics; it is not wrapped in a second native `Button` press phase, preserving the system drag morph without an immediate stacked zoom or custom scale/opacity effect. Multi-tool run chips show accumulated time as the sum of their
  invocation durations. Detail summary and rows install atomically for one projection tag,
  and rows remain in reverse canonical invocation order rather than switching when optional
  timing metadata arrives. Known built-ins
  derive only a semantic primary summary from exact request/result keys; compact protocol
  identifiers, timing, and progress remain first in Technical details, followed directly by
  complete Request JSON and Result JSON in that order. Result JSON prefers the response, then
  content-only output, then only a fallback distinct from Request. Exact current-runtime
  monotonic start-to-end durations are authoritative when available; older canonical history derives only
  an observed call-to-result interval because Pi JSONL does not persist tool execution timing;
- transcript structure has one explicit animation boundary: only rows with positive
  semantic-novelty evidence reserve their measured layout and reveal once after
  geometry admission. A page-bounded semantic ledger preserves displayed identities,
  suppresses duplicate entrances, and cannot evict currently visible rows; a cancelled,
  unanimated failsafe reveals any row whose geometry admission never arrives. Installed-row
  updates, live-to-canonical settlement, thinking-height measurement, and tool status changes
  inherit no stack-wide animation. The stable transcript transaction admits only explicit entrance/tool-chip markers and continuous native-control transactions; thinking height/tail motion is row-local downstream of that boundary. Authority-only changes whose bounded transcript/stream/tool/queue/runtime layout identity is unchanged take a synchronous metadata path and cannot arm settlement. The sole composer inset exposes one bottom-aligned measured height; a generation captured before structural mutation keeps pinned tail coupling nonanimated, preserves a detached semantic locus with zero tail commands, coalesces retargets, and yields immediately to direct interaction. Reduce Motion removes spatial transitions. Tool status text
  updates inside its stable row. Ordinary pinned growth, shrink, and discrete insertion remain
  coupled by one mode-qualified native bottom size-change anchor and create no automatic command stream. Native
  bottom distance is bounded for display only: a visible rect beyond the physical content edge is
  not tail settlement. A deliberately detached reader retains the same viewport authority;
- structure/context/resource invalidations reload an already-presented History,
  Manage Session, Agent Context, or Project Resources surface from the runtime. Context,
  tree, and resource reads each carry a subscription-scoped request generation, so an older
  overlapping completion cannot overwrite newer evidence. Manage Session keys Git inspection
  directly to the authoritative cwd instead of waiting behind a broad catalog refresh;
- terminal output/exit payloads decode into typed `Sendable` preparations from the original
  event frame before MainActor routing; malformed known payloads remain inert rather than failing
  the transport. Terminal output is admitted only for a current presentation lease, sequence-checked,
  and deduplicated; frames arriving during attach or gap recovery are held in a bounded
  local quarantine and joined contiguously to `terminal.attach(afterSequence:)` replay. Replay responses
  admit only a strictly contiguous prefix (reset responses may begin at a retained sequence); duplicates,
  reordering, and missing middles never become canonical output and schedule a bounded follow-up.
  A remaining gap schedules at most three immediate recovery attempts before waiting for
  later lifecycle reconciliation; replay reset advances native renderer
  identity, and detach/revocation rejects buffered output and exit frames. Multiple
  presentations share the connection subscription until the final lease closes;
- stopping/restart topics enter the single `GatewayLifecycleCoordinator` reconnect loop with
  the exact delivered local connection identity. A scheduled administrative drain stays connected;
  only `system.stopping` starts `Restarting` and its monotonic 90-second replacement watchdog.
  Connection Settings may temporarily poll bounded drain aggregates for the exact locally requested
  restart/update, but that projection never declares success, disconnects transport, or starts reconnect.
  Duplicate transport signals cannot replace the lifecycle owner or revive work after profile teardown. Its
  nominal 2-second, ×1.7 backoff is independently jittered within a bounded 80–120%
  window and never exceeds 15 seconds; foreground activation accelerates a pending delay
  once without replacing an active handshake.

A newly navigated chat opens exactly once and replaces any disposable cached or
previously expanded projection with a fresh bounded authoritative latest tail. A mounted chat
foreground reconciliation likewise installs the authoritative aggregate as one suppressed-entrance
projection: content that arrived while iOS was backgrounded is shown in place, not replayed as a
burst of row animations or automatic scroll writes. Its monotonic reconciliation
generation is carried through delayed projection work and consumed once at installation,
so a fast network completion cannot reclassify the same suspended rows as fresh later.
After the authoritative two-phase handshake completes, the projection remains behind
the opaque opening surface until the exact physical marker after transcript and queue rows intersects
a plausible native bottom viewport. One leased bottom-edge command realizes a missing lazy tail; submitted commands,
clamped negative bottom distance, auxiliary rows, transient boundary geometry, and overflow overshoot are
not settlement evidence. The native geometry observation identity includes the opening epoch and phase, so
entering positioning replays current geometry even when SwiftUI would coalesce equal numeric fields. Exact-ID
realization can proceed without a geometry sample. If physical proof still cannot settle within 750 milliseconds, the
bounded bottom-edge binding remains owned and the authoritative transcript is revealed best-effort instead of failing
conversation availability. The positioned transcript then fades/rises into view while the tail binding remains
owned through animation completion and two unchanged display frames; best-effort positioning releases after those frames even when no later geometry arrives. Direct user or accessibility interaction
cancels that arm. The composer
remains visible throughout opening, while sending stays disabled until readiness. Opening tail
positioning and post-reveal settlement are owned by the coordinator's mutually exclusive opening
phase; ordinary pinned growth, shrink, and discrete insertion create no command ownership. Explicit
opening, catch-up, semantic restore, and prepend remain command owners; after they release, pinned mode
keeps `ScrollPosition` target-free and uses the native bottom size-change anchor with no recurring command stream.
Short-content alignment remains top-owned. Editor-only composer height changes install atomically;
attachment, selected-skill, and resource-result identity changes use one value-scoped 240 ms smooth
host-height transition, disabled under Reduce Motion. Direct user movement away from the tail and
anchored mode select top retention and remain target-free. A pinned bottom rubber band remains pinned:
past-bottom geometry is directional interaction evidence, not a detached-reader request, and catch-up
appears only after valid geometry moves beyond the tail boundary.
Session subscription ownership is token-scoped end to end. The open response remains
provisional until sync acknowledgement and exact route-intent revalidation; both sync and subscription
credentials must be nonempty, printable UTF-8 tokens no larger than 200 bytes. Baseline plus its
already-drained contiguous event suffix then publish in one MainActor turn. The fitted tail mounts immediately regardless of its display-bearing count; earlier-page reads begin only from the mounted presentation and cannot make the conversation unavailable. A stale or failed
attempt closes only its provisional token, so a stale close cannot unsubscribe a newer same-session mount. Active
protocol-v3 peers always provide explicit subscription ownership. If a reconnect installs a new runtime generation for the same canonical session,
iOS clears context/tree/resource/command projections, invalidates their in-flight request generations,
and advances all three public reload revisions before publishing the replacement. Secondary read successes
and failures both require the exact captured subscription token and latest request generation, so a retired
runtime cannot repopulate data or surface a stale error. A reconnect while that same chat remains mounted instead receives
complete current runtime state and preserves compatible explicitly paged history
and the reader's follow/detached mode. The session snapshot remains the sole whole-session
authority. Transcript presentation retains only an exact, contiguous prefix strictly before
that snapshot's Gateway tail in `MountedTranscriptWindow`; visible ranges and Load earlier
facts are derived from the same coverage. Runtime, structure-revision, total decreases, range,
gaps, and ID conflicts fail closed; leaf changes and total growth are admitted only through exact
canonical overlap, while tail expansion trims prefix overlap only by exact indices and IDs. A later
navigation presentation begins again from the bounded latest page; this cold-presentation
rule is distinct from in-place reconnect. History paging is owned by the session presentation reducer,
not scroll geometry: the bounded authoritative tail publishes immediately even when it is sparse or empty, and a mounted Load earlier request starts without requiring a semantic anchor. Optional history reads never extend the open/sync replay barrier or determine conversation availability. Page admission validates the projected cursor, echoed next projected
entry, runtime, branch leaf, range, total, and IDs; it never mistakes raw parent links through filtered canonical entries for visible-row adjacency.
Tail/keyboard settlement never discards loaded transcript coverage. Snapshot cache files retain only session summaries; legacy snapshot-bearing files decode safely but their snapshots are ignored.
Phase, operation, tool ordering, and canonical paging cursors remain authoritative. A rolling-upgrade
client also normalizes the impossible legacy combination of an idle phase and retained running-tool
overlay to an interrupted chip; it does not expose a fake Stop action for extension-owned detached
work. Current Gateways project that background work through `ExtensionPresentationState`. Tron
decodes the versioned, bounded projection: one host epoch and aggregate revision cover semantic state,
authoritative interactions, generic full-frame surfaces, capabilities/diagnostics, and the optional input
lease. Presentation collections reject their DTO-specific limit during decoding before retaining another
member. Only the exact next revision for the installed epoch mutates state; equal duplicates are inert, while
gaps, lower/reordered revisions, malformed payloads, and epoch mismatch trigger authoritative catch-up.
Fitted snapshots retain bounded omitted surface ID/revision baselines and lease continuity so exact-next
full-frame deltas converge; complete session snapshots replace the projection. Surface clearing is explicit
by ID, so malformed upserts cannot erase valid content;
unknown kinds retain sanitized `plainText`. Notifications travel in a mutation but are never retained or
replayed. Generic status pills, semantic string widgets, and admitted read-only widget surfaces render in
composer-owned slots with no package, command, or opaque-key special treatment; custom/overlay and
interactive surfaces remain deferred. Actionable responses carry the interaction's admission epoch/revision, and offline cache
strips all interactions, surfaces, focus/lease, capabilities/diagnostics, and ephemeral semantic state. Native
composer synchronization is scoped to the exact mounted presentation, suppresses its operation-ID echo,
and never retries a stale base revision as an unconditional overwrite. The run
continues on the Mac and the app catches up without presenting transport errors as modal alerts; recoverable failures use scoped in-app notifications instead.
Interaction sheets, working state (ambient bottom
activity for the ordinary default and explicit rows for custom/retry detail), editor updates, typed generic
notices, and durable extension transcript entries remain active. The canonical session name remains the
primary navigation identity; an extension title is retained only as a presentation hint and cannot replace it. Backgrounding gates and
cancels disposable catalog/foreground reconciliation, never the route or accepted work, but it retires
the shared socket epoch and clears queued live deliveries before suspension. Foreground activation waits
for that retirement, creates one fresh epoch, coalesces to one responsiveness pass, then runs catalog
convergence and mounted-session restoration; terminals reattach only after the mounted session's exact
subscription is installed on that connection. Catalog retention or failure alone does not discard the
last-good mounted projection. The owned foreground slot releases on success, failure, cancellation, or
lifecycle replacement. Switch, forget, current-device revoke, and final
teardown invalidate that reconciliation, reconnect/debounce tasks, profile-scoped reads, and
presentation intake before entering the serial retire/close chain; a late old-profile completion is
discarded and no newer handshake can start ahead of an older close. Possibly-sent mutation
reconciliation uses generation-only lifecycle admission so same-profile reconnect may resolve it, but
replacement-profile polling or replay is forbidden. A terminal-open result resolved after a
same-lifecycle connection replacement attaches on the current connection before publishing replay;
a profile-generation replacement discards it. Ordinary scene backgrounding is a transport retirement,
not a session teardown; accepted runtime work continues on the Mac and the next active scene enters the
ordinary reconnect loop. Compatible reconnect requests share one typed result instead of polling mutable
tokens. Fresh
presentation and reconnect intents arbitrate serially, and at most three immediate authoritative
attempts are retained for a continuous gap/overflow burst before the bounded catch-up state wins.
A temporary catch-up notice is deduplicated, removed on successful synchronization and presentation navigation/close, and automatically expires after a bounded interval if a terminal retry path cannot converge. It never outlives its presentation owner.
Earlier canonical entries are fetched through `session.transcript` pages when requested. Each page
is capped at 600 KB and 512 items, carries exact `start`/`end`/`total` bounds, and installs only when
`end` equals the requested boundary, `total` still equals the captured canonical total, and
`end - start` equals the decoded item count. Duplicate IDs,
gaps, stale anchors, and mismatched presentation/runtime/subscription leases are discarded rather
than concatenated into plausible history. Event-buffer
overflow closes the connection and forces global/session/terminal reconciliation;
correctness must not depend on receiving every event while disconnected. A bounded
sequenced session heartbeat advances the cursor during silent long-running tools;
it proves the owning runtime connection is live without manufacturing tool output. Event-driven desired
projection advancement does not replace the exact installation currently on screen: pending row geometry
remains tagged to that displayed installation until an actual installed transition occurs. Unanchored runtime
tool ordering is status-independent, and only rendered IDs retained by the next installed output preserve a
one-shot discrete-follow entitlement.
