# Tron iOS architecture

Tron for iPhone is the primary interface to the private Tron agent on the Mac.
It is a native SwiftUI application targeting iOS 26. The backing SDK is an
implementation detail; all user-facing language calls the agent Tron.

## Source map

| Directory | Owner |
|---|---|
| `Sources/App` | app composition and lifecycle |
| `Sources/Gateway` | pairing, Keychain profiles, HTTP, WebSocket protocol |
| `Sources/Models` | provider-qualified model and snapshot DTOs |
| `Sources/State` | authoritative UI projection and reconnect orchestration |
| `Sources/Support` | bounded cache and share intake |
| `Sources/UI/Chat` | session shell, chat composition, attachment presentation, entrance rows, transcript, composer, context, and forks |
| `Sources/UI/Onboarding` | pairing/setup flow, reusable onboarding chrome, workspace, provider, and default setup |
| `Sources/UI/Settings` | settings shell plus appearance, connection, provider, agent-default, on-demand package/resource, trust, custom-model, and diagnostic presentations |
| `Sources/UI/Terminal` | sheet composition, presentation lifecycle, and SwiftTerm renderer |
| `Sources/UI/Theme` | historical Tron colors and descriptor-based bundled typography |
| `ShareExtension` | app-group share handoff |

`Sources/Models` keeps wire-compatible value types grouped by authority rather than in one DTO
monolith: gateway connection, session catalog, transcript, session runtime, resource catalog,
workspace, and terminal files. Cross-file references remain plain value composition; no split model becomes a
second cache or reducer.

Chat transcript formatting publishes one immutable `InstalledChatTranscript`: canonical timeline,
queue facts, hidden-thinking semantics, and a `ChatTranscriptHandoffCommit` are admitted together.
The handoff is either none, an authoritative pending prompt, or an outgoing submission with bounded,
frozen attachment DTOs. `ChatTranscriptProjectionTag.HandoffIdentity` contains only compact scalar
attachment preview identities, never preview bytes. Composer and authoritative snapshots are captured
once before submission; handoff-only changes reuse the cached canonical timeline, and the prior complete
commit remains installed until its replacement reaches the frame gate. Canonical JSONL remains the sole
owner of transcript truth.

## State flow

`GatewayClient` performs one authenticated WebSocket connection, protocol hello,
request correlation, deadlines, and event delivery. One private connection epoch owns the
exact socket, receive/liveness tasks, pending requests, liveness timestamp, overflow state,
and handshake projection. The focused chat uses the lifecycle-owned client; the dashboard
uses one bounded lightweight client per eligible non-focused paired Mac through
`DashboardGatewayConnectionPool`, so catalog state from another Mac can update without
replacing the active chat connection. Profiles sharing the selected
`machineGroupID`, profiles with a provisional legacy group (`machineGroupID == machineId`),
or profiles disabled in Connections settings, remain paired but are blocked from
background admission. Their last-known bounded dashboard buckets remain available as
stale projections; transport retirement is not deletion. Selecting a legacy profile once
performs a verified Gateway handshake and persists its real physical-machine group before
it can become a secondary connection. Connect and close invalidate older attempts across every suspension;
late hello, frame, failure, liveness, completion, and close callbacks can only detach or publish
for their captured epoch. Event deliveries carry that non-wire connection identity. App lifecycle
connects prepare the epoch without starting receive/liveness work, install the returned identity,
then idempotently activate one receive owner and one liveness owner; buffered events from a retired profile therefore cannot cross a switch.
Idle transport tasks do not retain an otherwise unowned client. While foregrounded, ten seconds of inbound silence triggers a bounded `system.info` liveness request with an eight-second deadline. That application frame is deliberately earlier than the Gateway's 25-second heartbeat and keeps older URLSession/Tailscale paths alive even when automatic WebSocket pong handling is not surfaced reliably. WebSocket URL loading inactivity remains at 60 seconds for both initial and reconnect requests; the actor's monotonic 15/5-second handshake watchdog and application liveness—not CFNetwork's transport timeout—own those decisions. Intentional closure requests a `goingAway` frame and grants the one-task session a one-second graceful invalidation window; a bounded hard invalidation then releases dead CFNetwork epochs so reconnect loops cannot retain sessions and WebSocket buffers for the 60-second inactivity interval. Its injectable transport ends at WebSocket bytes, and its monotonic-clock and UUID inputs control only time and identity generation. The production transport is an actor-confined ephemeral `URLSession` owner and preserves the existing data frames, headers, deadlines, and random UUID behavior. Scripted test sockets contain no protocol, session, receipt,
or event-admission policy; `GatewayClient` remains the only decoder and client
runtime. Each inbound response/event frame crosses one discriminated `JSONDecoder`
entry point. Typed event views decode directly from that original decoder's payload
container; network bytes are not serialized and parsed again. The client actor best-effort
prepares large session snapshots, summaries, envelopes, streaming items, tool states, unified extension-presentation mutations, and terminal output/exit payloads before delivery, so
the MainActor reducer installs typed `Sendable` values instead of re-encoding and
decoding dynamic payloads. Raw event payloads remain attached for global extension
points and unknown topics. The ordered client event hub admits the Gateway's complete 1,024-event synchronization quarantine under a stricter 2 MiB aggregate byte ceiling; overflow retires the epoch and rebaselines rather than silently dropping sequence. Every Gateway coder is fresh per operation; shared static Foundation
coder instances are forbidden across concurrent frame preparation. Inbound bytes reject frames above
the Gateway's 1 MiB protocol ceiling before JSON parsing. Dynamic `JSONValue` admission
is capped at depth 64, 32,768 nodes, 8,192 members per collection, 1 MiB per UTF-8 string, and
4 MiB of aggregate strings including object keys. Non-finite numbers fail coding, and integer
projection uses exact range-safe conversion. Malformed known event data preserves its former live-reducer
no-op semantics rather than becoming a transport failure, while a non-consumable
quarantined suffix forces another authoritative attempt before its baseline can publish.
Gateway connection and disposable cache intervals use the shared typed
performance-signpost boundary. Signpost metadata is structurally limited to result
codes, item counts, and byte counts; identifiers, paths, methods, filenames, model
names, prompts, transcript content, and terminal output are never recorded. `AppModel`
is the shrinking MainActor composition façade; narrow typed owners retain lifecycle and
coordination state instead of routing facts through unrelated façade fields.
`GatewayLifecycleCoordinator` is the sole owner of enrollment attempts, focused-profile lifecycle,
connection state/info/identity, exact admissions, reconnect, foreground reconciliation, serial
retire/close transitions, and final teardown. A non-selecting pairing commit adds a server without
changing the focused profile; the dashboard pool owns shallow catalog connections for the other
paired profiles, admitting at most one enabled profile per verified physical-machine group, each with an independent failure boundary. Pairing responses, WebSocket hellos, and authenticated `system.info` values must carry a bounded `stable` or `dev` Gateway channel; pairing and every initial/reconnect handshake fail closed unless that asserted identity matches the saved profile endpoint’s expected channel. Port selects the expected profile, but never substitutes for the Gateway’s authenticated assertion. Pool handshakes also validate the paired machine identity; mismatches stop retrying until pairing metadata changes, while malformed bounded catalogs enter the normal retry path. Connections uses those profile-owned clients for per-server gateway metadata and authorized-device discovery. Log history is isolated in a separate top-level Settings destination and Gateway records are fetched only while that sheet is presented, keeping connection and server-detail presentation independent of the bounded log payload. Typed Gateway response decode failures also enter a 200-record, in-memory-only iOS client ring and are merged into that sheet with an explicit `iOS client` source; the in-app notification action links directly to Logs. This local projection is never written to canonical sessions or Gateway logs and disappears when the app exits. Gateway update status/config reads and restart/update/rollback mutations use only the lifecycle-owned focused profile so receipt handling remains authoritative; a non-focused detail must first choose **Use This Server** and never reads update state through the dashboard pool. Runtime source/fingerprint/epoch fields remain optional, while channel identity is required. An exact provenance-bound Debug candidate plus `gateway-update.v1` enables the confirmed **Promote Debug Gateway to Stable** action and pins its version and fingerprint. The separate generic maintenance action is always **Rebuild Gateway from Source**, requires a valid configured source root, and sends source mode; its copy explicitly does not claim that an update is pending, and an arbitrary available artifact never becomes an automatic promotion fallback. A failed deployment exposes one equally confirmed “Roll Back Gateway” action, sending only channel and command ID to the supervised helper through the same receipt path. Bounded `gateway.update.status` and `gateway.update.config.status` projections place live deployment state directly under connection state; a terminal ready state with no candidate is labeled **Installed and running**, while a verified candidate takes precedence as **Update available**. Source revision, runtime epoch, and payload identity stay behind a Technical Details row. Source configuration is one row with a trailing Configure action that reuses the Gateway-backed workspace selector, redacts the accepted Mac path to useful trailing components, and saves only that typed source-root mutation through the same admission/receipt path. Build/update and rollback remain separate confirmed actions outside the configuration container. Status polling is command-ID-bound, bounded to roughly one second, and stops at terminal state, reconnect, or view disappearance; reconnect starts a fresh authoritative read. Missing capability or malformed/unsupported status fails closed without presenting an approval action. `GatewayClient` centrally translates typed-response `DecodingError` values into bounded `invalid_response` failures containing only the RPC method, reason category, and sanitized coding path—never response values—before presentation or local diagnostics. Session synchronization retries a malformed authoritative open response at most twice from a fresh `session.open`; a third failure surfaces a persistent actionable in-app notification with a View Logs action and byte-bounded local diagnostic instead of Foundation's generic decode text. It composes `GatewayClient` without copying that actor's
byte-transport epoch. `AppModel` supplies narrow projection hooks for cache installation, refresh,
session/terminal reconciliation, and synchronous retirement; it no longer stores a parallel lifecycle
phase, reconnect task, pairing attempt, connection identity, or transition waiters. A dedicated
`SessionCatalogCoordinator` owns the focused profile's summaries, while the dashboard pool owns
profile-qualified shallow catalogs for non-focused profiles. `SessionSummary` carries dashboard-only
profile ownership and the dashboard aggregates by `(profileID, sessionID)`; equal bare session IDs from
separate runtimes therefore remain distinct. An ID-indexed monotonic
live-summary overlay, cached/stale/live provenance, and exact profile/lifecycle/connection load admission
remain scoped to each source. Equivalent
foreground, reconnect, unknown-summary, and structural invalidations share one
catalog traversal; invalidation during a traversal sets one dirty bit and receives at most one immediate
follow-up before handing newest truth to a new bounded lease. iOS requests user scope in 500-row pages,
rejects more than 50 pages/25,000 identities, duplicate IDs, cursor cycles, and mixed revisions, and
publishes only a complete catalog. A mixed revision from an older Gateway or an expired continuation lease restarts silently once from a nil
cursor; it is expected optimistic invalidation, not the former actionable “Sessions changed while loading
the dashboard” alert. Known revisioned `session.summary` events apply synchronously without a list read,
and mounted transcript snapshots cannot overwrite those global row fields. Completion attention is one
of those Gateway-canonical row fields: only final settled prompt responses advance it, Mark Read/Unread
uses an absolute command-receipt mutation, and a successful open acknowledges only its returned
completion revision after the snapshot installs. That acknowledgement retries transient failures against
one fixed presentation/connection owner and revision; cancellation retires it, while an older Gateway
without the additive method remains rolling-upgrade compatible. The local snapshot cache is display-only and older peers
missing additive attention fields decode as read during rolling upgrade. The dashboard groups user
sessions by workspace and renders the newest ten per workspace by default; explicit Show more/Show less
pagination is a disposable UI projection with generation-checked staged animations, so catalog refreshes
cannot expose stale rows or leave controls stuck. Successful session creation starts a shared background
catalog reconciliation without delaying chat navigation. The Gateway projects a newly created empty row
while it owns that live runtime slot; if Pi has not persisted content, the disposable row may disappear
after Gateway restart or idle slot retirement. Initial connection, structural and summary events,
reconnect, creation, and deletion own dashboard convergence without a manual refresh surface. Focused and
secondary profile owners retain an unsatisfied structural generation across responsive list failures and retry with
a capped delay until a complete authoritative publication; epoch retirement, backgrounding, and profile removal
cancel that lease rather than turning it into polling.
Cache/disconnect/authoritative installs and removals all
enter that one disposable projection; hidden/local selection policy remains outside it and cannot mount a chat. Cached or stale non-idle rows present as resuming without rewriting
the canonical phase; only a live Gateway-authoritative interrupted phase uses the amber warning.
A focused-profile boundary synchronously invalidates lifecycle admission, chains behind any preceding
retirement, revokes profile-scoped loads and presentation intake, and awaits the exact transport close
before the focused profile changes. A profile switch considers the new socket ready after handshake
and event activation; dashboard refresh, mounted-presentation restoration, and terminal reattachment
continue under the same admission without blocking a valid session route from opening. The previous focused catalog is retained as a bounded stale
dashboard bucket during that transition. A target profile's last bounded bucket is also retained until
its focused catalog replaces it, preventing translucent sheets from exposing an intermediate empty list.
Non-focused dashboard connections are independently retired or
reconnected and never blank healthy profiles when one Mac is offline. Provider-auth prompts are
transport-client scoped: disconnect and profile transitions retire them before a new connection can
receive input, while a transient same-profile reconnect retains the last bounded provider/model catalog
until its atomic replacement arrives. Stale operation responses are treated as a retryable no-op rather
than a misleading broker error. Pairing pre-encodes profile metadata and uses one transactional profile
store boundary: one cached sanitized document is loaded explicitly at init/refresh; atomic Keychain upsert succeeds before a single-document metadata commit, metadata failure
restores the exact prior credential (or removes a newly created one), credential-deletion failure restores
removed metadata, and explicit profile selection must commit its metadata before replacement cache or
socket admission begins. Selection, removal, and rollback failures remain observable to lifecycle ownership,
which retains profile-scoped drafts/cache and enters recoverable offline state instead of reporting success.
Corrupt v2 metadata self-cleans, malformed persisted host/port values are removed before selection,
and valid legacy metadata migrates on the next write. Gateway socket/upload/blob construction uses
failable validated URLs and rejects an invalid profile before opening transport, so neither malformed
metadata nor credential failure can leave selected metadata without its owned secret. Every suspended connect/reconnect/cache boundary revalidates that
lifecycle admission. Mutation receipt reconciliation captures generation-only admission so it may
resolve across a same-profile reconnect, but profile replacement invalidates it before any poll or
replay. Connection-owned terminal-open results that resolve after a same-lifecycle reconnect must attach
again on the current connection before replay can publish; a profile-generation change discards them. An established transport loss gets one immediate reconnect attempt so short network transitions do not impose a guaranteed offline interval. Failed handshakes and subsequent attempts retain the nominal 2-second, ×1.7,
15-second-cap progression. Each sleep is
independently sampled within 80–120% of its nominal value with a hard 15-second effective cap; the
injected unit-interval source and monotonic clock make the exact schedule deterministic in tests.
Foreground activation may cancel only a delay-owned retry and start one immediate attempt; repeated
activation cannot replace an active handshake, and exact attempt generations reject stale cancellation
or unauthorized completion. Background scene transition cancels disposable foreground/catalog reconciliation, preserves the route and bounded profile-owned projections, retires the transport epoch before suspension, and gates event-triggered catalog reads until the next active scene starts one authoritative reconnect pass. After event activation, reconnect and foreground
reconciliation starts dashboard convergence concurrently with mounted-session restoration; terminal
reattachment follows exact mounted-session synchronization because the Gateway requires that connection's
subscription before terminal attach. Provider/settings/device reads cannot delay mounted chat restoration, and focused or background dashboard catalog/schema/application failures retry their projection read without replacing an otherwise responsive exact socket; only observed transport epoch loss enters reconnect. Final teardown cancels and joins the event listener and shares one
completion across concurrent callers; scene backgrounding deliberately does not tear down accepted
Gateway-owned work. It shares the clock/UUID seams for Gateway reconnect, receipt, debounce,
and command-ID work. Its visible-open interval
contains independently measured authoritative synchronization attempts; invalidated
attempts end as discarded rather than being mislabeled as successful. Receipt timing
begins only after an uncertain mutation response, never for an ordinary confirmed
mutation. The observable `TerminalCoordinator` owns terminal request DTOs and wire execution,
presentation/intents, cleanup tasks, receipt-aware commands, attach/replay intervals, gap reconciliation,
and reconnect reattachment. Its sole `TerminalReducer` kernel owns per-terminal operations, shared
attachment leases, typed terminal-event reduction, a global 16-terminal/256-chunk/1 MiB in-flight event
quarantine, replay revisions, and post-detach event admission. Authoritative terminal inventory and presentation revocation prune replay, last-install, exited, pending, and attachment projections; no historical summary map is retained. Terminal open/attach uses one replay
installer and closes its interval only after reset, delta, and a strictly contiguous replay prefix are admitted; duplicate, reordered, or missing-middle chunks remain non-canonical and trigger a bounded follow-up reconciliation.
`terminal.open` requires the exact installed iOS subscription and the Gateway validates the client's
opened-session ownership before creating a PTY, preventing orphan terminal creation during route/reconnect
races. Stale successful attachments schedule an exact-connection compensating detach unless a newer
presentation still owns that terminal; a matching new attach cancels and joins unsent cleanup first.
Resize debounce is keyed by exact presentation intent inside the owner: 120 ms and the existing
20...400-column/5...200-row bounds are unchanged, supersession is silent, distinct presentations remain
independent, and intent/route/profile retirement cancels pending work. The sheet presentation controller
owns one active start/show/open flight and one latest pending route. Read-only phases cancel on replacement;
possibly-sent attach/open phases finish under their revoked intent so stale completed receipts reach compensating
cleanup, while an exact-intent replay gate prevents a confirmed-missing open from creating a new PTY. Only the
newest pending route launches afterward, and terminal action failures use the shared scoped in-app notification without
removing the native renderer. `AppModel` retains only the terminal façade and cross-domain
Gateway event/lifecycle routing; canonical session subscription ownership stays in `SessionPresentationStore`.
It loads a bounded disposable cache first, connects, fetches
cursor-paginated sessions and model catalogs, and replaces local state with
authoritative snapshots. Session snapshots carry a current transcript tail bounded to
800 KB and 512 items; `transcriptStart`/`transcriptTotal` expose earlier canonical Pi
entries, which the chat can request backward in 600 KB/512-item pages without risking an
oversized or generically truncated WebSocket frame. Page `start`/`end`/`total`, item count,
neighbor identity, mount, runtime, and subscription ownership must all agree before prepend.
The presentation owner keeps the newest authoritative tail separate from explicitly loaded
older browsing rows. A fitted empty/short positive-start baseline is compatibility-backfilled under
the provisional subscription before publication, including active and compacting sessions. Every
compatible replacement/reconnect reconciles only an exact visible prefix: the visible coverage end
is the authority tail end, sliding tails promote covered old-tail rows, backward expansion trims the
prefix, and ordinal ID overlap, parent, leaf, and runtime/total identity conflicts fail closed. A
detached reader retains loaded rows; physical return to latest never mutates transcript coverage.
History loading is admitted from the canonical cursor even when no rendered row or semantic scroll
anchor exists; an anchor is optional viewport-preservation evidence. Only duplicate-free bounded
summary rows enter the disk cache.
`ChatTranscriptPresentationStore` serializes snapshot-to-timeline preparation off MainActor,
coalesces a burst to one pending newest source, and keeps the last complete installed commit
visible while a replacement builds. Transcript rows and Load-earlier availability come from the
installed source window, while queue management stays owned by the installed queue revision/items
and the exact Gateway capability authority; generic transcript build lag never locks a stable queue
card. An admitted Load-earlier page owns one local exact token from click through Gateway paging,
projection installation, and anchored prepend (or unanchored installation); ordinary projection
updates do not relabel or disable the pill. It installs only an exact tag
containing session, mounted presentation, runtime, canonical/timeline generations, and paging
bounds/edge identity. It retains at most one installed, one building, and one pending immutable
snapshot/timeline; it is disposable projection state, not a session mirror or event journal.
One deterministic `ChatTranscriptProjectionKernel` converts exact canonical entries into ordered
raw atoms and then globally assembles call/result joins, bootstrap filtering, barriers, grouping,
and semantic maps. Message presentation IDs and required content/thinking-run ordinals arrive from
the Gateway and are never rewritten: the same semantic row, thinking run, and prepared-text source
therefore survive live-to-canonical settlement even though the canonical entry ID changes. Rendered
IDs are deterministically collision-disambiguated only for SwiftUI uniqueness; semantic identity
continues to own entrance and resilience state. The projection worker prepares immutable row-local
markdown/thinking slices with entry-local revision tokens, so render rows perform only cheap revision
equality and never reslice the transcript-wide cache. `ToolExecutionStatePolicy` is shared with
`SessionPresentationStore`, so progress-sequence, timestamp, status-tie, explicit-order, start-time,
and call-ID rules cannot drift between canonical event reduction and sparse rendering. Raw fragments retain the complete
currently visible disposable history—even beyond one 512-item page—because explicitly loaded
history cannot be evicted until forward reload exists. Projection instrumentation reports only a closed privacy-safe mode (`cold`, `fragmentReuse`,
`toolPayloadPatch`, or `isolatedStreamingSuffix`) and aggregate entry/fragment/tool/atom/rendered
counts; it carries no identifiers or content. A pure tool patch reports zero source entries and atoms,
counts every runtime membership state examined in `toolsInspected`, and reports only the distinct
descriptors changed in `toolsPatched`. Opening
a new chat presentation always synchronizes a fresh authoritative bounded latest page; disposable cached or previously paged prefixes are never revealed as
its baseline. The transcript remains behind a nonblank opening surface until the
two-phase `session.open`/`session.sync` handshake installs its authoritative tail, the
exact initial transcript projection, and a physically verified viewport at the marker
after transcript and queue rows. Rows remain fully realizable beneath that opaque cover;
an opacity-zero lazy stack is never used as a layout gate. Only then does the cover fade
while the positioned transcript rises eight points (opacity only under Reduce Motion).
The first-ready performance interval closes after the next display-link frame proves
that ready state was presented. Opening uses one leased bottom-edge `ScrollPosition`
command when the marker is not yet realized, rejects native overflow overshoot as a
bottom boundary, and retains that command through animation completion plus two
unchanged presented frames before releasing the binding. Ordinary pinned resizing then
belongs to the native size-change anchor; detached readers remain unpositioned.
Short-content alignment is always top-owned, so keyboard contraction cannot bodily
translate the transcript.
Test builds can admit one synthetic authoritative
snapshot through the same read gate and skip only the network opening handshake.
The hosted harness still mounts the production chat, lazy transcript, composer
inset, and native scroll view; a display-link recorder coalesces geometry and
semantic row-frame observations to at most one sample per presented frame. These
hooks are absent from Beta and production builds and own no session policy or
runtime state. The
composer remains mounted and visible throughout opening so transient synchronization
cannot remove the primary chat control; sending stays disabled until the authoritative
baseline is ready. A failed transport/sync open shows an explicit retry surface. Once that mounted chat is ready, reconnect and
resynchronization merge compatible live tails with history explicitly loaded in
that viewport so a detached reader is not displaced. Explicit earlier-page loads
remain request-only, are scoped to the exact mount generation/cursor, and restore the
former visible anchor with bounded late-layout correction so the viewport does not jump.
A gesture that begins during that correction cancels every remaining position write
and its final native geometry wins over the pre-load detached state. The UIKit composer keeps focus reconciliation deferred but resolves internal overflow and caret visibility only from final post-layout TextKit geometry, preventing speculative SwiftUI measurement or keyboard/safe-area callbacks from changing the editor offset.
Create and fork return navigation identity without mounting or selecting a transcript;
only the destination route may establish live presentation authority. An admitted composer
transport intentionally survives route disappearance: its target is retained by the
composer admission owner, and revocation makes any late error target-gated and silent rather
than allowing a retired view to surface stale UI state. Backgrounding cancels only disposable
opening, paging, picker, and route work; foreground resumes a non-ready retained presentation
through the same generation checks.

Gateway restart uses a supervised drain contract. The request freezes new mutations,
waits for accepted agent runs to settle in canonical JSONL, then replaces the Gateway
process; active PTYs must be closed first because their process state is not restartable.
iOS keeps the chat mounted, follows `system.stopping` into its ordinary bounded reconnect
loop, and installs a fresh authoritative session baseline from the replacement runtime.
A restart response may be immediate or scheduled behind active runs. Connection Settings may
briefly poll the bounded drain projection only for an operation explicitly requested in that view;
it shows fixed aggregate labels and retains nothing after the view's ownership ends. Drain phase,
counts, and ages are diagnostic presentation only: `system.stopping` and the replacement handshake
remain the sole reconnect and liveness authority. Diagnostics routes current unsupported, busy,
receipt, and transport action failures through the existing global error surface; lifecycle-retired
cancellation remains silent. Unexpected process
death is different: a surviving run marker projects the session as interrupted and Tron
never replays the accepted prompt automatically.

Events are invalidation or live-presentation hints. They do not form a durable
event journal and are never replayed into a local database. `SessionPresentationStore`
is the sole MainActor owner of the mounted immutable target, revocation, live snapshot,
subscription lease, synchronization/quarantine, cursor reducer, transcript paging, and
session-keyed context/tree/resources/commands. `AppModel` routes cross-domain effects through
a weak delegate and retains no token, snapshot graph, presentation generation, or secondary
projection mirror. Revocation synchronously rejects every sequenced topic, not only full snapshots.
Paging, exports, and secondary reads capture an exact unrevoked target plus installed token and
revalidate both after suspension. Export blobs use a file-backed URLSession download with declared
and streamed 25 MiB admission rather than response `Data`; completed downloads move into a protected,
32-file/24-hour bounded staging owner before the artifact store atomically adopts them. Gateway-provided
names reduce to a 160-byte last path component and each artifact enters a unique, protected,
backup-excluded temporary directory. Exact route revalidation removes stale staging and artifacts,
and app launch plus every new export prune malformed or older-than-24-hour disposable artifacts. Paging is read-only
at the Gateway and cannot revive event subscription ownership after close. Cold cache snapshots never
enter the store's authoritative read gate.
`session.open` uses
a two-phase subscription barrier: the authoritative snapshot and ephemeral sync
token are returned first. The snapshot and subscription token remain provisional and
unobservable until `session.sync` succeeds and the exact session/presentation intent is
revalidated. iOS admits both tokens as nonempty, printable UTF-8 values of at most 200 bytes before installation; stale or failed opens close only the already bounded provisional subscription token. The same opaque token
then becomes subscription ownership, and `session.close` only releases a subscription whose
current token matches. Active protocol-v3 peers always provide explicit ownership.
One intent-keyed synchronization coordinator owns the shared outcome and event quarantine.
Compatible reconnect callers await that outcome directly instead of polling tokens; a fresh
presentation never inherits reconnect installation semantics and waits to retry after incompatible
work. Reconnect identity comes from the mounted presentation generation, never mutable dashboard
selection. During an attempt, iOS quarantines that session's events, discards those covered by the new
baseline, validates contiguity, and publishes the baseline plus drained suffix in one MainActor turn
before completing all waiters. Retry and fresh-install invalidation stay in the same owner; one bounded
three-attempt loop replaces recursive resynchronization. A synchronization-quarantine overflow uses the
ownership-scoped `session.rebaseline` event, whose fitted snapshot is installed as a fresh authoritative baseline
without another open handshake; stale/revoked owners ignore it and no fitted baseline retains the
`transport.resyncRequired` fallback. Same-runtime rebaselines must also preserve the monotonic live-activity
revision. Malformed owned snapshot/rebaseline frames and authoritative queue projections with more than 32,
empty, or duplicate identities fail closed into this same bounded synchronization path rather than advancing
a partial cursor or leaving the installed transcript stale. Outside that explicit install, a full `session.snapshot` hint requires the
current subscription plus either mounted authority or its active synchronization lease, the same runtime generation, and exactly
the next event sequence. Equal/lower cursors are discarded without merge, summary write,
or cache save; gaps, runtime replacement, and missing baselines converge through another
authoritative open. Missing live authority and route/payload mismatch are discarded without
creating state. Buffer overflow,
oversized frames, reconnect, and foreground activation use that same path. Unknown sequenced session events
still advance the cursor so a newer app can add hints without forcing false gaps.
Dashboard phase/name/count updates use a separate bounded global `session.summary`
projection: every connected client sees active/settled rows without subscribing to
every transcript, while an opened chat receives the full sequenced snapshot and
stream/tool events. Structure, context, and resource invalidations refresh any
already-presented History, Fork, Manage Session, or Project Resources surface.
Global settings, provider/model catalog, package, and custom-model event hints each
advance a dedicated invalidation generation. Successful reads publish their projection
without advancing that generation, so a visible `.task(id:)` performs one initial read
and one read per actual invalidation rather than feeding its own reload loop.
`SettingsTrustCoordinator` is the sole owner of target-keyed disposable settings values,
per-target read admission, settings and trust event revisions, settings request/mutation
construction, and trust inspection/mutation. Clearing a saved trust decision sends an explicit
JSON `null`, while `true` and `false` remain distinct decisions. It uses the shared
confirmed-mutation executor, and profile retirement synchronously revokes suspended work
and clears settings projections. `ProviderAuthCoordinator` likewise solely owns typed-target
provider/model catalogs, per-target paging admission, event-only provider invalidation,
auth prompt/event parsing, and operation-to-target retention through completion or confirmed
cancellation. Because provider login can synchronously emit presentation or completion events
before `auth.begin` returns, a four-operation, 64-element, 16 KiB pre-response quarantine promotes only the
newest admitted operation and is synchronously revoked on failure, cancellation, or profile
retirement. Prompt submission is single-flight on iOS, and the Gateway treats bounded late
auth acknowledgements as idempotent no-ops so completion/response reordering cannot surface a
misleading operation-not-found error. Provider and model pages publish as one atomic catalog. Provider projection rejects
more than 1,000 rows, 4 MiB of strings, or duplicate IDs. Model projection rejects repeated cursors,
more than 50 pages, 25,000 models, 16 MiB of retained strings, pages above the requested 500 rows,
and duplicate compound identities. Gateway cursors bind offsets to an exact whole-catalog fingerprint,
so mutation cannot mix generations. Model pickers key rows by that compound identity, so equal model
names from distinct providers remain stable. Profile retirement synchronously discards catalogs and auth routing.
Its forced refresh and logout commands use the shared receipt executor before reloading the
exact captured target. `PackageConfigurationCoordinator` solely owns target-keyed inventories,
update markers, newest-list/check/mutation admission, event-only invalidation, closed
install/update/remove wire construction, and confirmed exact-target reload effects. The separate
`CustomModelConfigurationCoordinator` owns typed-global reads and validate-before-put mutation
admission. Both synchronously clear disposable projections and reject suspended work across
profile retirement—including A → B → A replacement—and both reuse the shared confirmed-mutation
executor rather than defining receipt policy. Every throwing mutation boundary rechecks the
captured owner admission before propagating an error: retired or superseded work becomes
cancellation, while current-profile uncertainty and application failures remain visible.
`GatewayDiagnosticsService` is the typed read-only boundary for project Git inspection and bounded
Gateway log reads. SwiftUI surfaces provide the exact path or log limit and never construct Gateway
methods or parse wire objects. The service preserves the established absent-repository, malformed-log
skip, and newest-first projection semantics; `GatewayLogRecord` carries transport-safe fields while its
color, icon, and date formatting remain UI-owned.
`AppModel` only exposes observed computed reads and forwards operations; screen-owned
revisioned draft stores remain local to their existing settings surfaces. Settings
surfaces use typed `.global` or `.project(cwd:)` targets; installed values and automatic
reload tasks are keyed by that exact target. Global reads and writes never inherit the
currently selected session's project path, different targets cannot overwrite each other,
and a newer same-target read rejects an older completion. New-session defaults are loaded
for the workspace being created rather than the previously selected session. Changing that
workspace or gateway profile clears the prior trust/model projection and closes creation admission
until matching settings and trust reads complete; stale workspace/profile completions cannot reopen
it. The toolbar identifies that preparation instead of presenting a silently inert Create action.
One synchronous creation owner admits only one command per gesture. A confirmed create returns its
profile/lifecycle-bound navigation route immediately; the `session.listChanged`-driven dashboard
projection converges independently and never blocks opening canonical state. A known configured
model default avoids a redundant follow-up mutation. If an explicit model override fails after
canonical creation, the error remains visible but the existing route opens, so retry cannot create a
duplicate session. Provider and model catalogs likewise use typed `.global` or `.session(id:)`
targets and publish each fully
paged provider/model pair atomically. Auth operations retain that target through completion or
confirmed cancellation; unknown completions never guess from dashboard selection. Package
inventory and update projections use typed `.global` or `.workspace(cwd:)` targets; the global
Settings route never inherits the default workspace, and successful update/remove mutations
clear only the matching cached update markers before refreshing that target's inventory. Project
Settings captures its session/CWD when presented rather than consulting later dashboard selection.
Trust reads and mutations require a typed nonempty project target; onboarding, project Settings,
and new-session admission discard stale workspace results, and trust invalidations reopen the
new-session readiness gate until the matching workspace is inspected again. Non-selecting pairing
from Connections preserves the existing setup-completion state and suppresses the root setup sheet
while the secondary-server pairing sheet is active. Successful first-run pairing inspects an already
selected workspace before enabling onward navigation; the initial
pre-pair view task is never treated as evidence for that post-pair target. Custom-model
documents have one explicit typed global target and generation-owned publication, so a slower
older read cannot replace a newer document. Validation and put revalidate the same profile and
mutation generation before every mutating boundary; retirement after validation never sends put.
The Save and Restart flow captures one lifecycle admission around both operations, so a confirmed
save cannot restart a replacement profile and a late restart failure cannot surface into replacement-profile
UI. Configuration screens discard cancellation while preserving current-operation errors. `ComposerDraftCoordinator`
is the sole owner of composer text, the single staged skill, staged attachments, upload admission, editor requests, and submission state.
Text, unsent attachment payloads, and skill selection are keyed by explicit `ComposerDraftScope(profileID, sessionID)` with monotonic revisions and a deterministic 24-inactive-draft LRU. Live text is never truncated; the owned `ComposerDraftStore` checkpoints up to 256 KiB of UTF-8 text plus the existing 10-item/25 MiB attachment budget in Application Support, under a 24-draft/256 MiB disk LRU. Its versioned manifest contains metadata only and points to separate exact-byte payload files beneath SHA-256 profile/session path components. Atomic protected writes, backup exclusion, and fail-closed malformed/oversized cleanup follow the disposable cache conventions, but this store is separate from `SnapshotCache` and contains no transcript, event, credential, source-path, thumbnail object, or Gateway snapshot state. Drafts survive route close and process restart until exact session/profile deletion or bounded eviction. The composer derives one immutable search index from the already bounded authoritative `session.commands`
catalog; it never fetches or mirrors resources. Catalog readiness is owned by the exact mounted presentation token, is revoked while a reload is pending, and refreshes on `session.resourcesChanged`, so A→B→A navigation cannot retire a retained draft skill from another session's transient catalog. Skill discovery is exposed only when the connected Gateway advertises
`skill-prompt.v1`, preventing a newer app from silently sending inert metadata to an older runtime. `@` token detection filters only `source == skill` entries and strips
the transport-only `skill:` prefix, while leading `/` completion excludes skills and inserts editable native command
text. The one staged skill is captured separately from user-visible text, replaced atomically by a newer selection,
restored only after a definitive send rejection, and cleared if the authoritative catalog no longer contains the exact
entry. Skill and leading slash-command choices are mutually exclusive, and a staged skill still requires prompt text or an attachment so every lifecycle has visible content. The Gateway receives its raw name as bounded prompt metadata and owns Pi invocation expansion, keeping optimistic,
queued, edited-queue, and canonical text identical. The inline glass picker remains inside the sole composer safe-area owner, below attachments and the skill chip but immediately above the input row. One permanently mounted, bottom-aligned measured host keeps editor-only height changes animation-disabled for UIKit caret ownership. Attachment chips, selected skills, and command/skill result panels use one value-scoped 240 ms smooth host-height transition, so the transcript and sole safe-area inset move continuously without adding a scroll command or root geometry feedback. While the keyboard and picker are both visible, the picker keeps its existing internal scroll owner but caps itself to three rows and the native editor to four visible lines, preventing the panel from displacing the input below the keyboard without changing transcript geometry ownership. Multiline measurement remains direct, UIKit owns keyboard motion plus the one responder, and UTF-16 selection and caret geometry stay native. The active lease is the immutable session/presentation generation plus lifecycle generation.
Unsent attachment bytes and metadata belong to draft scope, while prepared previews, concurrent upload admissions, editor requests, submission snapshots, and handoffs remain exact-presentation scoped. Revocation cancels upload work and discards disposable Gateway upload IDs without erasing the scoped strip. A newly admitted mount restores chips only for that exact profile/session target, rebuilds bounded thumbnails through the existing off-main preparation seam, and reacquires every Gateway upload ID before enabling submission. Restore never auto-sends; transient re-upload failure retains the payload and chip for a later mount/retry. In-flight bytes remain recoverable through a definitive rejection, while transport acceptance or authoritative queue/canonical settlement removes the captured submission from the durable draft without disturbing newer edits. Completed plus active uploads are admitted against one 10-item/25 MiB draft budget before network work; each image chip uses
an orientation-correct 192-pixel PNG preview with 1 MiB decoded/encoded ceilings, so normal composer rendering
never decodes the full attachment. The original bounded payload remains scope-owned for persistence and the existing
explicit preview sheet, which installs the thumbnail immediately and prepares at most one 4,096-pixel/64 MiB image
off-main through the same cancellation-aware media preparation slot before publication. HTTP response bodies
have a separate 64 KiB ceiling and must return on the captured connection epoch. Uploads are independent, so
completion order—not newest-request arbitration—orders staged IDs. An exact-target active upload disables send and is rechecked synchronously at submission admission; a stale action fails closed without clearing text, attachments, or the staged skill, then can retry after upload completion. A confirmed prompt removes only the IDs captured by its submission and never clears newer text or attachments. Admission installs one exact-target,
bounded outgoing presentation row immediately; submitted attachments leave the composer strip and remain owned by
that row until the exact tagged canonical projection installs, including Gateway pending-prompt snapshots. The
frame gate keeps one complete lifecycle representation visible until its direct canonical replacement is ready. The
admission is completed synchronously before ordinary-send keyboard dismissal, so the large prompt/photo outgoing
shape, steering/follow-up label, and responder transition share one MainActor boundary; transport is a separate
settlement of that exact admission. Prompt behavior is normalized once into ordinary, steering, follow-up, or neutral
unknown; queued-kind optimistic and pending prompts therefore render the queue-card core in their first frame instead
of flashing through an ordinary bubble. Outgoing attachment strips are right-anchored from their first frame, avoiding
a left-aligned optimistic variant before canonical reconciliation. Prompt and queue cards use one bounded
intrinsic/wrapped layout rather than a `ViewThatFits` branch swap, so large pasted text chooses its final
container geometry on the first measurement. The native multiline editor publishes its capped one-to-eight-line size through synchronous representable fitting rather than a deferred height binding, so clearing or restoring text cannot create an empty old-height composer frame. Local admission synchronously grafts only its frozen lifecycle row onto the currently complete installed transcript, then the normal newest authoritative projection replaces it; canonical generations, prepared text, runtime rows, queue facts, and source windows never advance through that graft. Queue presentation aliases are frozen into the same installed commit as its handoff and queue rows, so rendering never combines an older transcript with newer coordinator identity. The admitted operation ID aliases its exact newly admitted queue item to the immutable outgoing presentation ID. Before that response arrives, exactly one current nonbaseline queue candidate matching behavior, text, and attachment count may borrow the ID for visual continuity only; ambiguity, mismatch, malformed data, or a conflicting operation response clears the provisional alias without settling admission or canonical causality. Aliases remain bounded to the Gateway's 32-item queue capacity and are retired only when their authoritative operation IDs disappear or the presentation is revoked. A confirmed local edit,
remove, or clear retires continuity only for its exact changed operation IDs. If a canonical boundary arrives before that
command resolves and its continuity decision depends on the outcome, the newest complete capture is held behind the installed
queue boundary: success retires and excludes the changed lineage before installation, while failure restores exact settlement
before installation. Pure reordering preserves lineage. Pre-existing or unrelated queue rows
retain Gateway IDs, and canonical transcript IDs are never aliased. A prompt lifecycle consumes its role-aware
entrance only when the outgoing, pending, or queued representation first appears. That receipt is owned outside lazy row-local state and retained only while the lifecycle identity remains installed, so eviction/remount and opening-to-ready changes cannot replay it. Structural transcript transactions are disabled at the stack boundary; only explicitly tagged entrance, shallow tool-chip, and continuous native-control transactions cross it. Composer geometry owns one generation captured before mutation: pinned readers use disabled tail coupling, detached readers retain the first visible semantic locus with zero tail writes, rapid accessory/submission retargets coalesce, and direct interaction or presentation reset cancels the generation. The outgoing graft and composer collapse share that owner instead of racing a second smooth follow. A bounded layout identity separates transcript/stream/tool/queue/runtime shape from authority-only metadata, so context/model/revision updates neither rebuild projection nor arm scroll settlement. Canonical settlement consumes the exact
entrance-suppression receipt and installs directly visible without a crossfade, hidden frame, scale transition, or inherited
animation. Definitive rejection restores outgoing text before newer input,
while a possibly-sent transport outcome retains the row and captured IDs without replay. Retired completions publish neither restoration
nor errors. Extension editor requests auto-apply only to an empty exact draft; nonempty drafts require the
existing explicit Use/Keep disposition. Route-provided initial editor text seeds only an absent exact
profile/session draft; reopen and repeated preparation cannot overwrite retained edits. `SessionShellView`
observes explicit selected-profile identity through `SessionShellProfileRouteOwner`; an A → B → A change
synchronously revokes the current presentation and clears its navigation route before another profile can
reuse the screen's prior draft scope. File attachments and session imports require a regular file no larger than
25 MiB and reject changed sizes before upload. Session imports and document attachments copy through one bounded
off-main stream into protected temporary files, then release security-scoped access before the first network suspension.
Non-image documents never become full request `Data`; image files retain bytes only for the established explicit preview. Staged attachment retention beyond a
presentation remains a Phase 8D product decision; abandoned unclaimed remote IDs expire under the bounded Gateway
store rather than being transferred speculatively. Guided and advanced editor changes share one monotonic
revision owner; automatic invalidation loads cannot replace either form of unsaved input, and only
the exact submitted revision can become clean after a suspended save. Model/default
settings keep separate global/project drafts with baselines and monotonic revisions. Runtime,
resource-location, and model/default screens all use that owner. Scope changes preserve dirty input,
reloads cannot overwrite it, and a save completion can mark only the exact draft revision it
submitted. Mutations diff against the admitted baseline, so editing one project field does not
materialize inherited effective values as project overrides. Write-only proxy drafts expose only
redacted state, encode clearing explicitly, and are scrubbed after a confirmed save. Global defaults
always use the global model catalog; project defaults use the captured session catalog.
Chat exposes one logical presentation timeline rather than independently rendered canonical,
streaming, and live-tool arrays. Its cold oracle and detached worker use the same raw-atom/global-
assembler kernel; there is no output-producing test builder, suffix builder, or second cold projector.
The worker retains one complete disposable basis scoped by cache epoch, session, mounted presentation,
and runtime, plus an exact projection-key return. A newer epoch clears the older basis before reuse;
reset cancels the façade worker, skips obsolete text preparation at cooperative boundaries, and sends
monotonic cache retirement that cannot erase a newer epoch. Worker identity prevents a retiring task
from clearing its replacement. Exact source windows reuse fragments
only when the complete prior `TranscriptItem` equals the incoming item at the intersecting global
ordinal. Inexact legacy windows require one unique contiguous ordered-spine proof and still require
complete source equality; duplicates and ambiguity assemble cold. Streaming call IDs participate in
the same global result-visibility set, so a canonical result joins at its streaming call position rather
than rendering first as an orphan. Every mixed fragment set returns to the same global assembler for
joins, bootstrap filtering, grouping, ordinals, and semantic maps. Exact-bound checks use subtraction
or reporting-overflow arithmetic and conservatively reject malformed maximum values.

The random-access row collection is a flat immutable canonical base with direct index overrides and a
tiny live suffix. A global assembly resets overrides; repeated runtime payload updates share the base
and replace only affected tool-run rows rather than chaining overlays or copying 10,000 descriptors.
Rendered identity spines and sets are cached/split so ordinary text/thinking/image streaming updates
share the canonical rows and identities while the kernel constructs only the isolated live suffix.
Markdown has one pure `Sendable` cold presentation model. It classifies the existing block dialect,
constructs each inline `AttributedString` once with the established plain-`Text` fallback, and supplies
the exact immutable document to `TronMarkdownView`; tables intentionally remain raw cell `Text`.
Block and list identities combine exact content with UTF-8 source ranges, so equal duplicates remain
distinct. Code-header progress is eligible only for the one unterminated fence while its owning response
is still streaming; closed fences settle immediately and every fence is terminal when the response settles.
An unchanged exact block retains identity and its subtree-local interaction state; changed
content or block type resets identity, intentionally clearing `CodeBlock` copy confirmation and any
other stale subtree state rather than transferring it to different source. The projection worker now
prepares exact-source Markdown documents and attributed thinking segments off-MainActor under one
shared disposable LRU: 4 MiB accounted source/presentation bytes, 512 Markdown revisions, 4,096
thinking segments, and 320,000 bytes per source. Two preparations may run concurrently; one projection
warms at most 32 new Markdown and 128 new thinking values from its bounded 512-entry render-critical
tail. Installed rows receive only their tiny exact-source slice, while misses, oversized values, and
older explicitly paged history retain the unchanged cold renderer. Scope/reset replacement and memory
pressure clear both worker and installed prepared values, and generation admission prevents stale work
from restoring them. This checkpoint adds no prefix parser. A future incremental path must prove exact
cold equality and fall back to a full parse for open or closed fences, table promotion, lists, quotes,
and incomplete inline syntax because appended text can reclassify prior source across each boundary.
Any streaming fragment carrying a tool-call ID—including malformed text or extension content—is
returned to global assembly so canonical result suppression and placement remain exact.
Assembler-emitted unique tool sites retain canonical presentation bases, call classification, group
order, and placement facts. Runtime-only patching requires unchanged canonical source, exact streaming,
phase, unique membership, classification/order/start topology, stable run identity/order, and unchanged
before-streaming placement. It patches immutable tool descriptors only; canonical result changes,
membership/order/phase ambiguity, duplicate calls, or placement flips reuse fragments and globally
assemble. Status, editor, widget, and other unrelated sequenced events do not manufacture projection
work. `ChatView.body` never constructs the timeline. `ChatView` is the composition and lifecycle root;
`ChatTranscriptScrollView` is the one physical transcript/semantic-geometry owner; native geometry is admitted directly to the scroll coordinator and is never mirrored into root view state,
`ChatComposerView` renders value inputs and emits intents through the root's sole safe-area inset,
and `ChatRoutes` contains modal routing without mirrored authority. `ChatSessionPresentation`
groups disposable opening, import, queue-deferral, and entrance-ledger state while canonical facts
remain in `AppModel` and `ChatTranscriptPresentationStore`. Typing, focus, geometry, toolbar, and
sheet invalidations reuse the installed immutable value, while streaming revisions are
serialized/coalesced off-main and observable installs are limited to a display-frame boundary. Exact-tag waiters let prepend retain
its existing semantic-alias and layout-epoch transaction. This adopts the useful
pre-Gateway principles of a non-render-path measurement/projection owner and coalesced
stream updates without reviving the retired Engine, local event reconstruction, or scroll
proxy architecture. Explicit scroll commands keep their exact target until their opening, catch-up,
semantic-restore, or prepend settlement evidence arrives, then release only that token on the next presented frame; submission retires a still-applied app target
before changing layout. One mode-qualified native size-change anchor solely owns
continuous streaming, keyboard, composer, and discrete pinned growth; no persistent
`ScrollPosition` target or insertion callback competes for the same viewport delta.
`discreteContentInserted` therefore emits no physical write. A retained presentation reconciles its first native geometry sample so a view physically at the tail regains pinned authority while a genuinely displaced reader remains anchored
in an order native anchoring cannot retain; anchored readers receive no automatic follow. Compact
measured prompts may use one clipped composer-to-row morph; long prompts fail over to the row-local
fade/slide entrance. Attachment, skill, and resource accessories animate through one
value-scoped composer-height transition, while editor-only height changes remain atomic
for UIKit caret ownership. A mounted
reconnect is live only after its exact authoritative subscription is restored; retained snapshots stay
readable during retry but never authorize prompt, upload, abort, or queue mutations. Foreground entrance
suppression advances only after the mounted aggregate succeeds, so a failed reconciliation cannot consume
visual continuity for a later live row. Queue mutation responses are confirmations only: the existing
mounted synchronization path must observe the newer queue revision before local mutation presentation
state retires. Tool calls, progress, and results join by `toolCallId`; collapsed rows retain structured
request/response values without eagerly formatting JSON strings. Opening a detail sheet derives a
bounded semantic presentation only for that selected tool: exact lowercase built-ins foreground their file,
command, query, diff, and readable result, while arbitrary extension tools may foreground only the first
trusted common string key and otherwise lead with their result. Bash commands wrap to the available width
using word-preserving line breaks while outputs and other string metadata wrap; all previews bound pathological
line count, total characters, and per-line length with explicit head/tail omission markers. Small numeric
and boolean metadata remains unchanged. The final Technical details sub-sheet starts with larger, compact selectable
execution metadata, then exposes bounded Request JSON and Result JSON containers in that order. Tapping either
container opens the shared selectable, vertically scrollable raw JSON sheet directly; no intermediate structured
traversal or duplicate readable-output projection is introduced. Primary semantic content, faithful diff expansion,
technical payload evidence, and navigation chrome remain separate presentation owners while preserving one
established sheet hierarchy and detent behavior. Result JSON uses
the authoritative response first, otherwise the complete readable content string, then only a fallback distinct
from the request; request-only projections cannot duplicate themselves as results. Shared nested
structured field sheets remain available to unrelated arbitrary-data surfaces and resolve semantic paths
against each newest live root value rather than snapshotting the selected value. The Gateway supplies a
monotonic per-run ordinal for parallel calls, and the grouped
row keeps the first call's identity as it moves from invocation to completion.
Consolidation applies only to consecutive tool calls: every canonical thinking,
text, attachment, or notification boundary flushes the current group, preserving
the exact Pi content order without hiding or moving thinking traces.
The immutable navigation session ID owns one opening task and one typed
`ScrollPosition`; duplicate dashboard opens and competing proxy scroll commands are
forbidden. The complete composer is the sole structural owner of the ScrollView's bottom
safe-area inset, including wrapped text and staged attachments. Versioned extension presentation
state is a disposable live projection scoped by runtime generation, host epoch, and one aggregate
presentation revision. `ExtensionPresentationState` contains semantic state, authoritative pending
interactions, bounded generic full-frame surfaces, capabilities/diagnostics, and an optional input-lease
projection. Only `session.extensionPresentation` mutates it. Reducers accept the current epoch and exact
next revision, ignore only equal-revision duplicates, and request an authoritative session resync for a gap,
lower/reordered revision, malformed mutation, or epoch mismatch. Fitted snapshots retain bounded omitted
surface ID/revision baselines and leased/actionable state so later exact-next full frames converge; a complete
snapshot replaces the whole projection. Unknown surface kinds decode to a readable plain-text fallback; malformed upserts never erase an existing
surface, and removal is an explicit ID list. Native rendering admits only read-only widget surfaces through deterministic, horizontally-scrolling
composer pills (one opaque live pill per attributed extension; semantic widgets merge with their
host surface representation when its public surface ID decodes to the same key, while explicit provenance
provides explicit source grouping and labels without inferring ownership from the newest live run); a pill with one live run opens that run's bounded native detail sheet,
while a multi-run group opens a compact run chooser. Every detail route is created from the stable activity ID (group IDs and toolCallId/runId aliases are lookup compatibility only), so source-label changes and artifact enrichment cannot retarget a sheet. Structured extension-owned run projections carry stable
child IDs, active time, tool/turn counts, current work, and bounded output independently of rendered widget text.
Extension Activity is an additive, disposable presentation projection. Current/recent rows are admitted only from the Gateway's rich lifecycle record; exact opaque owner identity is primary and source fallback fails closed when ambiguous. `SessionPresentationStore` sequence-latches compact `session.extensionActivity` deltas without rebuilding transcript presentation, preserves newer delta state against an older full frame, and converges membership on an equal/newer authoritative snapshot. Canonical history is fetched through capability-gated `session.extensionActivity.list/get` pages by `SessionExtensionActivityStore`; iOS does not mirror history or use its cache as recency truth. The integrated hub is always the pill route, while Manage Session owns one paginated Extension Activity destination.

Completed run/tool history is retained as a bounded snapshot projection and is shown in the Manage Session
Extension History container; live work is intentionally not duplicated there. Terminal activity rows remain history even when their live composer pill is removed; they are never removed merely because a surface settles or disappears. Run detail resolves by stable
activity ID against the newest authoritative snapshot, so active time, child progress, current tool, and output
continue updating while the sheet is presented. Each child opens a read-only chat-style live session projection of its bounded task, current tool, and published output; Tron never opens the child canonical session concurrently.
The sheet translates terminal-only hints into native disclosure controls and uses the public tools-expanded
mutation with exact epoch/revision/command ownership to rerender retained surfaces. Frame runs render as
wrapping native information rows rather than a terminal viewport or per-run backgrounds, preserving only
admitted safe links. Status/service-only activity uses one conservative fallback pill. Custom, overlay,
editor, tool, message, and entry surfaces remain deferred. Unknown or ambiguous provenance fails open to
separate opaque groups, and the UI never inspects package names or extension-owned keys. Offline cache strips all surfaces,
interactions, lease/focus, capabilities/diagnostics, and ephemeral semantic values.
Native safe-area layout pushes the transcript exactly once and reverses naturally when
the keyboard or composer contracts. `ChatViewportMode` has only two states: `.pinned`
selects the native bottom size-change anchor as the sole physical size/inset owner, while
`.anchored` selects top retention and keeps the `ScrollPosition` target-free so direct
native ownership preserves the reader's position.
Transcript growth, keyboard frames, and composer measurements are not mode inputs. Consequently pinned content
and inset growth require zero app offset writes, and detached growth cannot pull the reader.
Short and empty transcripts retain top alignment.

Mode changes come only from explicit intent: native/direct/accessibility movement away from the
tail anchors; a bottom-starting pull that remains within the tail boundary or native past-bottom
rubber band stays pinned and never exposes catch-up. A physically observed direct return, catch-up, or opening pins; submission and prepend preserve
the current mode; a fresh presentation reset pins while a retained same-session reset preserves
reader authority. `ChatScrollCoordinator` owns the reducer, raw geometry and semantic frames,
unread state, and four bounded command purposes only: exact opening-tail realization, catch-up,
semantic-anchor correction, and prepend correction. Automatic growth follow, tail-correction arbitration, and callback-order compatibility flags no longer exist.

Opening still keeps the opaque surface until the exact physical marker after transcript and
queue rows is positioned. It permits one bounded bottom-edge realization command and a
750-millisecond best-effort deadline, then keeps that lease through the reveal's stable
frames before releasing to native size-change anchoring. Direct interaction abandons
opening immediately. Catch-up retains its
staged long-distance approach and unread ownership until physical settlement; interruption
restores anchored/unread state. An installed projection captured while anchored advances an
exact layout epoch and restores a surviving semantic anchor within one point, with at most two
corrections and a one-second deadline when layout evidence never arrives. Prepend uses the same
fresh semantic-and-geometry proof and bounded correction, while anchorless history still loads
through one session-owned, cancellation-aware canonical task. Starting that explicit page intent
supersedes a pending semantic-restore command; active catch-up or opening retains stronger ownership
and rejects paging. Direct interaction
cancels either correction transaction. Progress-only tool changes and ordinary streaming never
request a position. Keyboard and complete-composer layout therefore keep a pinned reader at the
latest tail and leave an anchored reader at the same semantic locus without changing durable
mode. Editor height fitting is synchronous and side-effect free; internal scrolling and caret visibility reconcile only when the installed UIKit bounds match that latest fitting result, so speculative or stale wrap measurements cannot move the editor viewport. Every stable row owns its horizontal inset instead of relying on
transient ScrollView content margins, so prompt insertion cannot expose a flush-left frame.
Existing rows never participate in stack-wide insertion or scale animations. Thinking,
Markdown, tool, and explicit custom/retry rows therefore remain stable above the composer while the user
follows the tail. Newly admitted tool rows reserve their layout before one local reveal, and status/title changes update
inside the mounted chip without recreating the row or animating its layout. The first mounted streaming/thinking frame is
fully visible; only later authoritative tokens receive the presentation fade, and the bounded thinking viewport
reserves an estimate based on the admitted line count until first measurement, capped at four lines, so TextKit
preference delivery cannot flash its height. Ordinary
default running activity owns no transcript row. Terminal output has its own monotonic sequence and reconnect replay cursor.
Output/exit frames delivered while attach or gap recovery is suspended remain in a bounded
coordinator quarantine and join the admitted replay contiguously. A reset increments an
explicit replay revision so SwiftTerm is recreated even when replacement sequences do not
increase; ordinary append/truncation does not change renderer identity. Presentation switch
or dismissal revokes terminal intake and pending resize work synchronously, while multiple
presentations sharing one terminal retain the connection subscription until the final owner
closes. Once the shell exits, the native terminal becomes non-interactive and resigns first
responder and forces a steady cursor so SwiftTerm stops its caret animation while retained
output remains readable. Terminal menus separate live terminals from exited retained
replay entries, so a quit terminal can remain available as history without appearing active.
Secondary live-runtime reads require that exact session to be opened first, so a
stale selection cannot read or render another session's context, tree, resources,
export, or terminal inventory.
Backward transcript pages carry an exact projected-entry anchor and are rejected if branch
navigation changed the requested boundary. The Gateway echoes that projected neighbor on new
responses. Raw canonical `parentId` links are not used as display adjacency because session-info,
hidden custom entries, and canonical extension receipts may legitimately sit between two projected
rows. Each WebSocket request owns its send and timeout
tasks and moves through queued, sending, and sent transmission state. Cancellation before send
is definitive; cancellation, timeout, failure, or disconnect after send begins produces a local,
non-Codable possibly-sent error that a Gateway response cannot forge. Mutations with that local
provenance wait for reconnect and poll the bounded command receipt: completed results are reused,
only confirmed-missing commands are retried with the same ID after rechecking cancellation, and
pending or cancelled uncertain outcomes are never replayed automatically. Definitive retryable
application responses remain ordinary errors rather than receipt uncertainty. Before any first transmission, the executor may wait up to eight seconds for a same-generation transient reconnect and retry one definitely-unsent `disconnected`/`replaced` attempt; this is admission delay, never command replay.
`ConfirmedMutationExecutor` is the single lifecycle-generation-bound owner of that receipt policy
for every mutation domain. `SessionMutationService` owns explicit session command IDs, DTOs, wire
methods, timeouts, and typed outcomes without reading presentation, catalog, cache, drafts, or route
state. `SessionImportCoordinator` owns the security-scoped file read, upload, and existing
`session.import` mutation pipeline under one captured lifecycle generation and selected profile.
It revalidates after every suspension boundary, so an upload ID produced for a retired profile can
never become a mutation on its replacement, and always balances acquired file access. The admitted
import result retains that exact lifecycle/profile identity through catalog refresh and the immediate
MainActor navigation handoff; a retired generation stays inadmissible even if profile selection cycles
away and back before presentation. `AppModel` retains only cross-owner orchestration: immutable
lifecycle/presentation mounting and revocation, admitted global error publication, direct no-attachment
share delivery, post-confirmation projection changes, catalog refresh, navigation results, and delete ordering.

## Sessions

A snapshot contains phase, model, thinking level, queue state, pending prompt
admission, transcript, streaming projection, context usage, pending extension
interactions, and runtime diagnostics. A pending prompt is transient Gateway
admission, not JSONL; iOS renders it until the canonical user entry replaces it
and reconstructs it from authoritative snapshots after navigation. Model identity
is always `(provider,id)`; model IDs alone are not assumed globally unique.

The composer supports text, system-keyboard dictation, images, and bounded file
uploads. It does not expose an app-owned microphone control until a proper voice mode exists.
Drafting remains available while authoritative opening finishes and throughout
an active turn; only submission waits for readiness. Default visible running state consumes no transcript
space: a nonstructural 68-point bottom-safe-area blur sits over the same chat background in both appearances
without owning a working-state animation. It uses the masked custom blur directly, with no separate tint or material
overlay, so the surface does not introduce a gray/black seam. The former traveling waveform layer is removed pending
a redesigned thinking indicator; blur edge softness is preserved without changing the configured radius.
At rest its fixed 44-point safe-area translation leaves 24
points of additional upward reach without increasing blur radius. The overlay belongs to the measured composer
but remains nonstructural. It renders in the composer's background layer, keeping the Liquid Glass input and
controls above the effect. While the editor owns keyboard focus, the blur grows from 68 to 80 points and its
downward translation grows by the same 12 points, from 12 to 24. The upper edge therefore remains fixed at 56
points behind the composer while only the lower edge extends beneath the native keyboard's rounded top corners;
native safe-area motion carries both together. On dismissal it returns to the 68-point height and 44-point device-bottom
translation, with its strongest edge beyond the layout boundary instead of forming a clipped horizontal seam.
Reduce Motion uses one static subtle emerald state, while VoiceOver retains a
nonvisual “Tron is working” status on the active blur. Custom working messages,
compaction, and provider retry attempts retain explicit compact rows so operational detail is never hidden.
A manual compaction accepted during an active turn remains a Gateway-owned pending maintenance
operation: the optional snapshot flag renders “Compaction queued” without fabricating JSONL, then
transitions through the existing compacting row to the canonical compaction entry. Successful completion
publishes an exact, cursor-bearing canonical compaction delta before full-frame settlement; iOS admits it
only against a contiguous exact tail and matching parent leaf, so the mounted progress row becomes
“Context compacted” without navigation while malformed or inexact deltas request authoritative rebaseline.
One synchronous Gateway claim spans pending and execution, handoff revalidates against newer agent ownership, and
settlement waits for durable run-marker retirement. The confirmed mutation stays pending until
canonical completion; shutdown cancels only work that has not started. Older Gateways may omit queued and effective
automatic-compaction evidence.
A non-empty active draft replaces the trailing Stop
action with Send and is admitted as a steering message, while an empty active
composer retains Stop. The keyboard remains focused after steering so multiple messages can
be queued without waiting for the current turn to settle. The send control's native context
menu can explicitly choose steering after the current turn or follow-up after current work. A press
has immediate scale/opacity feedback, admitted sends replace the arrow with a compact progress
indicator, and the composer surface acknowledges in-flight admission through the authoritative
Gateway queue or pending-prompt snapshot. A prompt that enters automatic compaction before its
canonical user entry exists remains visible as a right-anchored pending bubble and survives chat
navigation without replay. Pending attachment chips enter and leave with bounded composer-owned
motion; their height changes explicitly arm the sole scroll coordinator's viewport transition.
Authoritative queued entries render after any explicit runtime detail as right-anchored compact cards
that hug their content and wrap at the same 364-point maximum as a user prompt. They retain stable
identity, delivery stage, position, text, total attachment count, and optional photo/file counts. The
steer card keeps its delivery detail and smaller behavior icon together at the trailing edge, leaving the
message and attachment row on the full card width. Its compact top inset matches the reduced gap before
the message. Typed attachment counts render as one inert miniature rounded-square photo or file chip per
item rather than a prose count; the Gateway's ten-item prompt bound keeps this row intrinsically bounded.
Queue cards and the transcript
timeline are installed from the same exact tagged source, so consuming a queued entry cannot remove
its card one frame before the corresponding canonical prompt installs. Manageable cards use one
interactive, accent-tinted Liquid Glass surface with an explicit full-shape hit region; tapping
anywhere opens the editor without adding inline action chrome. The editor's leading toolbar owns
removal, while a long-press menu retains
same-stage reorder and clear-all. Text and behavior changes use an optimistic queue revision. Conflicts
wait for the next authoritative snapshot rather than fabricating a local queue. Steering is always
presented before follow-up to match runtime delivery order. Older Gateways retain a visibly locked
read-only string projection that directs the user to update Tron on Mac.
Camera, photo, and file actions also remain enabled during an active turn: uploads stage locally
and the eventual prompt carries the same steering behavior as text. The native attachment menu derives enablement
from the immutable viewed session and an explicit authoritative phase; a missing phase remains
unavailable. Its identity changes only when the session or effective availability changes. A transparent
UIKit button preserves the native `UIMenu`, system text styling, and 40-point hit target as a single UIKit
interaction boundary; menu symbols use emerald original-rendered images while a focused nonempty composer
keeps the keyboard visible. Menu selections enter one cancellation-aware queue and become
the active camera, photo, or file destination only after the native menu dismissal settles,
preventing a competing presentation controller from dropping the selection on physical
iOS. Camera, photo, and file importers share that enum-valued presentation state rather
than independent Booleans. `CameraModel` owns only UI-facing state and depends on narrow
camera-authorization and capture-session providers; the system provider alone touches static
AVFoundation authorization, device discovery, running sessions, and torch configuration.
Capture configuration and photo request are the two explicitly unchecked Sendable envelopes
required to move AVFoundation resources across the provider's serial queue boundary. Test providers
exercise the same owner without camera hardware and do not model a second capture runtime.
Images become native image input. Other files remain agent-readable
through a deterministic canonical path envelope, while the mobile projection
removes that path and exposes only display-safe name/type/size metadata. Sent
images and files share one attachment strip above—and structurally outside—the prompt's Liquid Glass.
Every attachment uses the same 64-point rounded-square surface as a pending photo. ImageIO renders index
zero for supported images and paged documents, while bounded UTF-8 text files render a first-page text
preview; unsupported formats fall back to a file glyph and middle-truncated filename inside that square.
Pending, optimistic outgoing, and canonical transcript attachments reuse this primitive rather than
introducing file-only capsules. Staging prepares each bounded encoded and decoded thumbnail once off-main. An exact
canonical handoff carries that immutable prepared thumbnail: file previews map by their upload blob identity, while image
previews map by order only when the complete count and MIME sequence agree. Settlement aliases the already-decoded image
into the existing bounded media cache before canonical installation, so the chip synchronously retains the image
already displayed; ambiguous mappings use normal loading. Transcript media resolves through one `ChatMediaLoader` keyed by profile,
lifecycle generation, and blob ID; views never fetch blobs directly. Authenticated blob reads and upload staging are paired-profile HTTP operations rather than disposable WebSocket-epoch operations, so a same-profile reconnect neither dismisses an open preview nor replaces its thumbnail with a retry state. Thumbnail fetch/decode is identity-single-flight behind one shared preparation slot and a
32-flight admission ceiling. Its bounded HTTP delegate rejects declared or streamed bodies over 25 MiB
while receiving them, then applies image orientation or first-page file rendering off-main at no more than
192 pixels and retains at most 64 items/4 MiB decoded under deterministic LRU. Uploads publish an explicit
content length, accept a same-profile WebSocket reconnect while the independent HTTP upload completes,
and preserve bounded Gateway error envelopes instead of collapsing quota or body-admission failures into
a generic photo error. Lifecycle replacement and the
app-lifetime memory-pressure observer advance exact invalidation generations, cancel flights, and clear
the cache; late fetch or detached-decode completion cannot repopulate it.
A preview uses one nonoptional item route. Photos open the historical medium sheet immediately with their captured
thumbnail and may replace it with one uncached full image. Every non-image file chip opens a sheet even when its
thumbnail or blob is unavailable: canonical and queued files acquire their bytes only after that user intent. Newer
Gateway snapshots add at most ten metadata-only queued/pending upload descriptors so exact remote identities survive
queue projection and replacement; older count-only snapshots still open the explicit unavailable state. A live composer
attachment retains its exact bytes only until its frozen handoff strips them. Image and file sheets
share the same single exact preview flight and priority work slot; full payloads never enter a second cache.
Markdown is parsed off-main into the established immutable document, plain/code text uses the native selectable
read-only view, and a Unicode-safe 320,000-byte prefix explicitly marks omission. PDFKit validates off-main and
presents native vertically scrolling pages, capped at 512 pages. Unsupported, invalid, missing, or pathological files
mount a concise unavailable state rather than conditional empty sheet content. Full-preview ImageIO decode applies
orientation and downsamples before publication to at most 4,096 pixels on either axis and 64 MiB of decoded rows,
preventing compressed dimensions from forcing an unbounded eager allocation. Each sheet owns an exact lease, and
dismissal cancels the underlying flight only after its final lease retires, so full-preview lifetime remains sheet-owned. One gateway runtime is the sole mutable
owner of a canonical session; terminal and mobile chat clients must attach to
that owner rather than opening the same JSONL in separate Pi processes. Its
historical context ring remains mounted at zero from the first composer frame while a resumed chat opens. It is visibly muted, disabled, and exposes a loading accessibility value until the exact authoritative transcript is ready; it then springs from zero to the canonical context percentage (or updates without motion under Reduce Motion) and opens Manage Session at the composer's trailing edge. Attachment, context, and send/stop controls share one
40-point target and 16-point visual metric, keeping their in-bar geometry stable as modes change. When a draft adds Send, the action
scales and fades in at its final in-bar position while the context ring springs left;
Reduce Motion uses a short fade.
Model and thinking configuration live in that sheet rather than as bootstrap
transcript rows. Disconnecting never
implies aborting an accepted run.

## Security

Tron registers for remote alert notifications only after a Gateway profile exists.
The user permission decision is authoritative and denial never blocks pairing or
chat. The app obtains an opaque APNs token, proves the official Beta or production
application identity to the fixed Tron Push origin with App Attest, and transfers
only the returned endpoint-scoped installation grant to the authenticated Gateway.
App Attest keys, APNs token bytes, and grants use a Keychain namespace separate from
Gateway bearer credentials. Registration is one bounded, profile-generation-owned operation:
every retry obtains a new challenge and generates a new proof, timeout/retryable 5xx uses two
bounded backoffs, and cancellation cannot commit across a profile or APNs-token replacement.
An assertion 401 or the SDK's exact typed invalid-key code may clear only the App Attest key
and permits one fresh-key attestation; fresh-attestation rejection, malformed responses,
nonretryable 4xx, persistence failure, and exhaustion stop without credential churn. APNs
tokens and existing grants are preserved. Settings exposes only a fixed local stage label,
never origins, identifiers, tokens, proofs, grants, response bodies, certificates, or bindings.
Registration reconciles on connection, foreground, profile, permission, and APNs-token changes;
Worker failure leaves push pending.
The app accepts no relay URL or private push credential from settings. Remote alerts
have no badge, inbox, background content fetch, or notification actions. Agent-completion
alerts carry only a bounded machine/session identity pair in addition to fixed product
copy and the session title. Tap admission rejects partial, oversized, or non-opaque
routes, resolves the machine only against an already-paired profile, returns to the
dashboard, and then opens that exact chat through the ordinary profile/session
navigation owner. A cold-launch tap is retained only in memory until the scene installs
that owner; it is never persisted as navigation truth. On launch and foreground
activation the app still writes a zero badge to remove state left by the retired badge
implementation.

Pairing accepts only `tron://pair` invitations containing a host, port, and
8–32-character one-time code; missing values and every duplicate query key fail closed.
`GatewayPairer` alone owns the narrow HTTP-data boundary for `POST /v1/pair`; it builds
the request and deterministically maps HTTP status and response bytes. Production transport
rejects declared or streamed responses above 64 KiB, and the pairer repeats that admission
before decoding so injected transports cannot bypass the contract. The
permanent returned device token goes directly to Keychain. Gateway profiles
persist non-secret connection metadata only.

`AppModel` admits one pairing attempt at a time. Supersession, forget, and switch
synchronously invalidate and cancel that exact task. Attempt identity is checked
immediately after HTTP returns, immediately before profile/Keychain save, before
connect, and after the connect-owned suspension boundaries. Therefore a stale
pre-commit HTTP result cannot persist or connect. Pairing attempt admission is separate from the
cohesive generation-owned `GatewayClient` connection epoch; both boundaries reject stale suspended work.

The pairing QR controller shares the camera-authorization boundary and delegates
AVFoundation setup plus serial start/stop to a QR capture-session provider. Its one
permission task is cancelled on disappearance and rechecks cancellation before capture
configuration, so a late grant cannot restart a dismissed scanner. The first admitted QR
value stops capture and permanently closes that controller's callback gate. These seams
make hardware-free boundary tests possible without creating another pairing owner.

The share extension reduces provider results through pure ordered fragment logic, writes
through `PendingShareStoring`, and opens the app through a responder-chain adapter. The app
reads through the same store boundary. Phase 0 intentionally preserves the current single-slot,
clear-before-send handoff; Phase 8 owns bounded entries, destination leases, acknowledged clear,
and retained uncertain/failure behavior. Both packaged targets declare the required-reason
UserDefaults privacy manifest, and archive verification fails if either manifest is absent.

Provider credentials and the Mac wrapper credential are never decoded by iOS.
Custom-model documents are validated through the pinned gateway runtime before
the canonical document is replaced.

Project trust UI states explicitly that trust controls project resource loading
and is not a sandbox. Device settings list gateway-authorized devices and support
immediate revocation; revoking this iPhone also removes its local profile.

## Presentation parity

The gateway migration does not define a new visual language. The pre-migration
client remains the interaction baseline. The session shell remains mounted under
the adaptive first-run sheet, and session creation retains the floating action
instead of adding a new toolbar destination. Dashboard navigation/history and the
new-session form have separate source owners without changing sheet identity,
focus, detents, configuration readiness, or creation admission. Tron preserves its bundled font
catalog, existing `fontFamily`/`monoFontFamily`/`fontAxisValues` preferences, and
variable font axes. `TronFontLoader` builds `UIFontDescriptor` instances for
custom weights, Recursive `MONO`/`CASL`, and Source Serif optical sizing; missing
bundled faces fall back to the matching system text or monospaced role.
Semantic SwiftUI font metadata and a Dynamic-Type-aware secure pairing field
keep custom typography scalable.

`TronPresentation.swift` is the app-wide presentation boundary. The app root
installs the selected type family and emerald interaction tint; every app-owned
Form/List uses the Tron collection surface; section headers, navigation titles,
search, segmented choices, fields, editors, toolbar typography, row actions,
icon buttons, loading labels, and prominent actions use shared semantic
components. Toolbar and sheet action icons use Tron emerald while their
container geometry and Liquid Glass remain default iOS styling rather than
receiving a second app-drawn container. The chat toolbar's trailing gear opens
app Settings; Manage Session is owned by the composer's context ring. Its principal title
is explicitly bounded from the mounted chat viewport and clipped after tail truncation,
so a cancelled interactive-pop transition cannot temporarily restore intrinsic-width text
across the back or Settings controls. App-owned workspace
rows, session cards, setup cards, composer surfaces, attachment chips, tool
chips and details, structured-data rows, Manage Session content, and ordinary
settings groups use Tron's tinted Liquid Glass surfaces. High-cardinality or
very tall scrolling collections use the shared static scroll surface instead:
it preserves tint, border, geometry, and hit regions without installing a live
backdrop filter for every row or a multi-screen card. Long settings screens use
lazy outer stacks, while their small divider-owned sections remain eager. The main Settings sheet is a single
list of separated row containers rather than category headers; each row carries a concise secondary
summary while retaining progressive destination construction and exact dashboard/project scope
admission. Settings rows share one semantic value policy rather than sheet-local typography: stable
explanations and identities use the selected reading family; live or user-selectable values use the
code family. A row with a distinct trailing control places its value on the secondary line and gives
the control a stable reading-family action label. Without a trailing control, the dynamic value is
right aligned. Main Settings summaries, server addresses, and model/provider descriptions are stable
copy; connection/provider state and editable selections are dynamic values. Both secondary roles share
an 11.5-point scale. Deliberately prominent summary values—such as New Session card selections and
Manage Session’s large remaining-token headline—remain bold reading-family exceptions rather than
code-family secondary values. The same policy owns New Session, Manage Session, history, and their
progressively presented subsheets. Settings action rows, value rows, and information cards share one
14-point leading inset, 22-point centered icon column, and common icon-to-text gap; multiline
resource-editor explanations center their icon against the full text block. Section-owned rows do not
add a second outer inset around the shared row geometry. The dashboard keeps search as an explicit toolbar action, aligns workspace headers to the session
status column, uses compact separated session cards, and keeps relative activity
time at each row's trailing edge. Workspace headers and session cards share the
same 28-point status-icon anchor: 16 points of outer row inset plus 12 points of
card content padding. Selectable app-owned cards have one full-card
hit region and no decorative disclosure chevron. Dashboard session rows never
retain a selected tint; their trailing swipe actions rename or request deletion of the exact
swiped canonical session without changing navigation selection. The delete swipe
uses a red tint but no destructive button role, so UIKit keeps the row mounted
until the Tron confirmation sheet completes the canonical mutation. The view does
not stage deletion beyond confirmation or suppress rows locally. The confirmed
mutation receipt reconciles the selected profile-owned catalog immediately, while
the revisioned Gateway list event repairs every connected dashboard from canonical truth.
Cancelling can therefore close and reopen the flow without optimistic row removal
or stale swipe state. Dashboard discovery and refresh never select or open a transcript and global Settings never
infer project scope. Catalog loads are latest-generation-owned, and an asynchronous import may
navigate only while its exact dashboard intent is still current. Reconnect restores only the
still-mounted presentation; it never uses a dashboard row as a subscription fallback. The mounted chat route supplies an immutable
session ID to every prompt, runtime mutation, extension response, terminal operation, and
secondary read. Those reads capture the route's exact subscription token, reject publication after
a same-session reopen, and cannot silently open another session. Presentation teardown compares
ownership per session rather than against an unrelated route's newer generation; share intake is
admitted only when exactly one presentation remains mounted. Create, import, and fork return navigation results; they do not rewrite
selection or claim subscription ownership before the destination mounts. Fork-restored editor
text travels in that route result and installs into the exact profile/session composer draft rather
than selection-backed global state. Uploaded attachments and extension editor requests are owned
by `ComposerDraftCoordinator` under session plus presentation generation; native editor debounce tasks
capture that exact target and host epoch, locally originated operation-ID echoes are suppressed, and a stale
base revision is never automatically forced through. Late uploads, stale same-session editor events,
removal, send completion, and errors cannot cross a reopen. Closing or
replacing a route synchronously revokes its intake lease and disposes presentation-transient state
while retaining only the bounded profile/session text draft. Share intake captures the sole admitted presentation target, never consumes that target's
staged uploads, and clears the shared payload only after confirmed prompt admission. Dashboard
imports use the explicit default workspace rather than a hidden transcript selection. In-app
notification projection is disposable and bounded to eight entries, 4 KiB per message, and 16 KiB total.
`InAppNoticeCenter` is the single AppModel-owned, monotonic-clock-driven center: it coalesces keyed
progress, orders foreground cards by priority while preserving FIFO ties, stacks at most three visible cards,
starts automatic dwell only when a card is foremost, and pauses timers while inactive, backgrounded, or interacted
with. Typed app, presentation, and exact session scopes retire with their owner. The content-layer
One non-key, transparent, pass-through window per app scene owns `InAppNoticeHost` above app sheets, so notice
coordinates never transfer into a presented sheet or follow its interactive drag. Content and blur modifiers do not
install notice hosts. The window receives the existing AppModel-owned center, forwards touches outside the bounded
notice region, and is retired with its scene; it never creates another notice store. Notices use regular Liquid Glass
below the safe area and toolbar reservation, keep 80 points clear on each horizontal edge, and accept input only on
the foremost card. Accessibility Dynamic
Type uses a vertical action layout. Passive errors expire after roughly eight seconds, while action-bearing errors are
persistent and expose native actions. Persistent restart, update, rollback, and package-progress cards are low priority
until completion returns them to normal priority. A session opening assigns notices to its pending presentation generation,
then retires the previous exact session scope when replacement mounts. Destructive,
security, text-entry, and ambiguous decisions remain modal.
Replaceable package, restart, and catch-up progress coalesces by owner, and profile teardown clears it. Dashboard search autofocuses in a
floating bottom safe-area bar immediately above the keyboard. The dashboard shows only
user sessions, including ordinary user forks; classified subagent backing sessions remain hidden.
Disposable caches from before session-kind classification are invalidated rather than briefly
presenting backing-process sessions as user sessions. Modal detail flows dismiss
with the native top-right check action. Shared confirmation sheets use a grey
leading cancellation action; a short primary label remains in system-owned
trailing toolbar glass, while a label that exceeds the measured toolbar budget,
contains a line break, or appears at an accessibility Dynamic Type size moves to
the shared Liquid Glass action container below the confirmation content. Other
top-left dismissal controls are reserved for navigation, not app-owned sheets. Settings containers and their nested font
or model choices disclose as progressively stacked sub-sheets rather than
horizontal navigation pushes; Appearance uses the custom Liquid Glass segmented
color-mode control and keeps font axes directly beneath each font choice before its
preview. Draft-backed settings save from a disabled-until-dirty leading toolbar
button rather than a trailing page action; its compact appearance uses the
system toolbar glass without nesting a second button surface. Resource path
editors share one padded, top-leading multiline field treatment, while numeric
settings use the shared larger numeric scale. Connected-provider logout lives in the
provider row's compact action menu while connection is a plain trailing affordance. All provider and
model catalog projections use `ModelDisplayFormatting` at the UI boundary: identifiers such as
`openai-codex` and `gpt-5.6-luna` render as “OpenAI Codex” and “GPT 5.6 Luna” without changing
canonical IDs or search/mutation values. New Session quick selections are compound
server/project identities, so selecting one switches the owning Gateway profile before
configuration admission. Source-control creation sends an explicit strategy to Gateway;
Pi receives only the resulting worktree `cwd`, while Git worktree creation and cleanup remain
Gateway-owned. Import
is owned by one progressive Import sheet, including canonical session-file import
and the bounded legacy migration path; the legacy import action is outside its
amber status/configuration card. The chat composer remains visually floating without an
opaque footer, but structurally reserves the transcript's bottom safe area. Its UIKit
text view is the sole first-responder owner; SwiftUI mirrors delegate focus only for
presentation, so transcript relayout and programmatic tail-follow cannot dismiss a
direct tap. Transcript content ends above the complete composer, and the scroll-edge
policy is attached to each concrete ScrollView/List inside its
NavigationStack, matching the working non-gateway presentation boundary. Every
edge is explicitly soft because the hard top style renders as an opaque cutoff
on physical iOS 27 hardware instead of Tron's graduated translucent blur.
System navigation-bar backgrounds remain hidden at that same boundary so
scrolling content reaches the toolbar. Dashboard and chat add bounded,
noninteractive top backdrops that are strongest beneath their toolbars and ease
completely into scrolling content; chat uses the tallest fade. Progressive
medium/large sheets and full-height settings/terminal sheets share a shorter
fade sized to navigation chrome, while immersive camera and image sheets remain
unmodified. Sheet backdrops are attached to the concrete scrolling surface
inside each NavigationStack (or its non-scrolling content surface), so toolbar
titles and controls always render above the effect. Each backdrop stays outside
scroll content so scrolling geometry and tail following remain authoritative. Provider authentication is presented only by
the currently visible Providers or Onboarding surface, preventing an underlying
sheet from deferring the login prompt until the user navigates back. Sheets never use pull-to-refresh;
session history, packages, and providers expose reload as an explicit toolbar
action while non-sheet dashboard refresh remains available.

Chat has one spatial role model: user prompts are right anchored, agent prose and tools are left
anchored, and presentation-only system events are centered. A width-aware TextKit owner lets short
prompts hug their measured content at the trailing edge, bounds longer prompts to 364 points, and
uses logical-leading line alignment inside that block at the same Dynamic Type body size as agent
prose. User prompts choose an intrinsic-width glass candidate before the bounded wrapping fallback, so
short text never expands the surface to the 364-point ceiling. They use an equal 8-point vertical inset and
the same 18-point emerald-tinted Liquid Glass geometry as steer-next cards, without header icons or action
chrome. Newly installed
canonical content uses that same role geometry for presentation-only motion: user prompts and
queued intents rise from the trailing composer edge, tool activity enters from the leading edge,
system capsules settle from center, and assistant prose uses only a shallow vertical reveal. The
exact installed-row geometry gate still owns admission, so projection preparation cannot animate a
row that was never displayed, detached readers gain no follow authority, and continuity-adjusted same-turn
assistant/tool rows preserve their mounted visual IDs instead of replaying an entrance. That identity rewrite is
strictly an optional visual optimization: reconnect can temporarily project both a settled canonical row and its
still-live predecessor, so the complete rewritten row/key set is checked for uniqueness before any semantic map is
constructed. A collision retains the authoritative next timeline unchanged rather than trapping in dictionary
construction. Submission handoffs carry a bounded one-shot canonical receipt across the synchronous reconciliation
boundary; the matching canonical row consumes it once and installs directly visible without replaying an entrance.
The composer derives one value-only submission lifecycle from those existing admission facts; it does not add a
session store or infer authority. A bounded global-frame registry may stage one composer-to-outgoing prompt flight
for that lifecycle ID. The flight joins the active layout clock, keeps destination rows visible until every endpoint
is measured, and fails open on missing geometry, Reduce Motion, direct interaction, canonical replacement,
backgrounding, presentation retirement, or foreground reconciliation. The registry is disposable on relaunch and
canonical transcript/queue state always renders without it, so reopening an active or passive session cannot replay
an old flight or delay current rows. Each complete installed transcript exposes one `ChatCommittedLedger` followed by
one `ChatLiveRegion`. The ledger contains only the frozen canonical prefix and retains its local monotonic revision
across streaming, handoff, queue, compatible reconnect, and foreground-reconciliation installs when those canonical
rows are equal. Canonical append, prepend, or replacement advances that revision once; a cold owner deterministically
rebuilds the same rows at revision one from the authoritative snapshot. The live region carries streaming/runtime,
handoff, and queue facts in the same atomic commit, never as a mirror or second store. Separate `ForEach` regions and
row-scoped text preparation keep a full streaming turn from re-evaluating settled history. Hidden thinking labels are
attached only to preparation slices that render thinking, and tool rows compare a payload-only revision instead of an
ambient installation tag. Foreground active and passive sessions therefore converge through the same complete commit:
live work may be replaced, entrance suppression is consumed once, and neither history revision nor morph entitlement
can replay. Queue-card replacements use the stricter one-removed/one-new-candidate policy and fail closed for repeated or causally
ambiguous prompts; no Gateway operation link is inferred. Canonical
compaction/branch/configuration entries, embedded assistant failures, and exact admitted custom/retry
working detail share one semantic notification projection and capsule primitive. Ordinary default running
state instead drives only the bottom-safe-area blur and never changes transcript geometry. Extension status
state remains canonical and its bounded native pill presentation is enabled generically.
Only a pill with real detail content is an interactive Liquid Glass button; no-detail events use a flat tinted
fill and stroke with identical type and geometry. Tones are Sendable semantic values resolved to
SwiftUI color only at the view boundary. Conversation turns retain one row owner for text, thinking, and
lifecycle-safe attachments; event/control capsules and tool-run/detail routes are separate presentation owners
with unchanged SwiftUI identity and private state. While an authoritative assistant message or thinking run is
streaming, `ChatStreamingInlineText` keeps the complete source in layout and reveals only newly admitted lexical
words through presentation-only foreground opacity. Stable message/block/run identities preserve the reveal ledger
across projection snapshots; a large initial/backlogged stream catches up immediately, and completion shows the
full source without replay. Reduce Motion and accessibility never hide authoritative text. Under exact tail bounds,
a pending compaction and its
canonical entry share a presentation-only global-ordinal identity, so “Compacting context” becomes
“Context compacted” in place without changing Gateway identity or semantic scroll maps.

Runtime working pills install atomically beside the exact tagged timeline. Working/status-only revisions reuse
the unchanged expensive transcript projection. Status events continue to advance chat timeline generation even
while their output is visible, so status rendering remains a projection-only policy change. Pending and admitted entrance ownership each retain
at most the 512-item page bound in deterministic FIFO order. Retired pending rows become visible
without replay, while retired admitted rows preserve their local revealed state. Candidates are
admitted by current row geometry: each pending row carries the exact displayed installation tag, so a
newer desired model source cannot suppress its reveal. Admission requires that captured tag, current
installed tag, row membership, layout epoch, and pending state to agree; hidden-thinking label value
changes also advance chat timeline generation because adding or removing that label can change mounted
row height. Only pending rows include the tag
in their geometry observation, allowing an installed replacement to re-emit exact evidence without
invalidating every realized row. Visible/pinned discrete rows fade with a small non-layout transform
exactly once, realized offscreen rows become visible without replay, and direct interaction discards
unresolved candidates. `ChatScrollCoordinator` records admitted discrete insertion semantics but emits no physical
viewport write; native pinned size-change anchoring absorbs the installed row's growth. Its bounded
rendered-ID entitlement is intersected only on actual installed transitions, so a surviving tool/group
row retains the same one-shot entrance through completion while replacement removes it.
Continuity-preserved assistant/tool rows do not manufacture a new entrance. A newly admitted visible
agent row owns only its local reveal. Continuous Markdown growth remains display-frame-coalesced while
the native bottom size-change anchor holds pinned readers at the tail. Detached readers receive no writes and
Reduce Motion removes spatial effects. Agent tool and grouped-run buttons use
the same capsule primitives while retaining left alignment, immutable routes, and detail sheets.

Every tool chip owns a tappable, top-anchored detail sheet, including
read/write/edit and filesystem search tools. Inline chips use the same native
interactive Liquid Glass touch response as the composer; their Button owns only
activation and the visible rounded hit shape, while transcript scrolling remains
authoritative for drags. Tool-state projection updates are admitted synchronously
so they cannot delay or interrupt that touch transaction. The immersive camera retains the
pre-gateway flashlight, morphing shutter/confirmation, and flip/retake controls
over a full-sheet preview. A tool call and its canonical result are presented as
one progressively updated chip when both are in the bounded transcript page; an
unmatched result remains visible when its call is outside that page. Unanchored runtime tools always follow
non-tool streaming content regardless of running/completed status; isolated streaming-suffix projection is
permitted only when every runtime tool has a canonical call anchor. Consecutive
tool-only entries collapse into a single compact run chip whose sub-sheet keeps
every tool and its individual detail available. Each exact installed projection builds one
unique call-ID descriptor index, so live detail refresh resolves from bounded installed state
without rescanning the full timeline. The run, individual tool, Changes, and
Technical details sheets share one inline navigation-chrome policy; principal toolbar titles
therefore cannot reserve an empty large-title region above the scroll view. Each medium/large
tool detail sheet explicitly top-anchors short scroll content and begins immediately below
native toolbar chrome. Tool-detail surfaces use their own 112-point top blur while the main chat uses 176 points, without changing either radius. Its medium
detent is a glance surface: a wrapping chip flow combines state and elapsed time and expresses only useful
metadata in natural singular/plural copy. The flow caches one bounded measurement per layout pass and uses the exact same width and height proposal for placement, so a dynamically updating status chip cannot under-report its row height or overlap the following section. Pulling to large selects the expanded display density without
changing the selected call or scroll ownership. Read/write/edit foreground a selectable path whose directory
uses the restrained secondary tone and whose basename uses the tool accent; command, path, pattern, and location
values share one 12-point semibold code scale and wrap without splitting words. Code results use their separate
readable-result scale.
Edit uses an authoritative returned patch when present, otherwise it previews only exact requested old/new
blocks. An admitted inline preview places its full-diff action in a full-width interactive row below the diff. Exactly one verified requested change with exactly one authoritative diff unit containing a real
addition or removal may appear inline: medium uses a compact bounded head/tail glance and large reveals the
full bounded diff. Patch admission fails closed on malformed or combined hunk headers and uses the maximum
evidence across file, `+++`, and valid unified-hunk headers, so extra header-only or binary files cannot hide
behind one text hunk. File-header-like `---`/`+++` lines encountered inside a hunk retain their source-line
rendering but make unit evidence ambiguous, conservatively preventing header-light multi-file patches from
appearing inline. Multiple or uncertain changes fail closed to a dedicated Changes sub-sheet rather than
crowding the primary sheet or claiming a false count. Its diff container keeps the existing scroll behavior but
uses the static scroll-optimized tinted surface instead of Liquid Glass. Compact and expanded lines share bounded source-derived
identities; their omission rows carry distinct range identities so a rolling tail never reuses an identity for
different visible content. Diff preparation retains only bounded head/tail lines in circular tail storage,
bounds individual rendered line width, and marks every omitted line or character while the untouched payload remains available under
the final Technical details row. Empty edit sides represent pure insertions/deletions; blank rows are retained
only when a nonempty source value actually contains them. The tool-run row owns an open detail route and its
detent above the one-tool/grouped rendering branch, resolving the selected stable call ID against every newest
run projection so a second arriving call cannot dismiss the first call's sheet. Metadata VoiceOver labels use
only concise bounded chip previews and disclose that complete values remain in Technical details. The chip
flow measures every chip against the finite available width; status and scalar text may wrap to two lines at
Accessibility Dynamic Type without escaping the sheet or changing VoiceOver order. Runtime duration samples
are authoritative for live timers; cached Sendable ISO 8601 parse strategies remain a compatibility fallback
for older Gateways and canonical history, handling both fractional and whole-second Gateway timestamps without
repeated formatter allocation. Technical execution rows use compact selectable label/value geometry; a bounded bash
preview records its completeness fact there, followed by on-demand Request JSON and Result JSON summary rows
with explicit `null` for a truly missing side. Content-only results remain JSON strings, response data wins, and a fallback
identical to Request is rejected. Running sheets consume the newest immutable tool presentation, update status, timing,
partial output, and bounded-output disclosure in place, and never move
the reader's scroll position. Tool chips retain six-point vertical capsule insets and
intrinsic label/timing geometry without a layout-inflating minimum interaction frame.
Thinking traces remain one compact inline run while they fit, but their visible viewport
is capped at four measured text lines rather than truncating canonical content. Once the run
actually overflows, the compact viewport presents only the latest four measured lines without
scrolling; the oldest visible line fades at the top to signal earlier content. Tapping opens a full
trace sheet. The sheet reads the same live presentation source, so an
active trace updates in place; it uses the shared Tron sheet title, top blur, typography, confirmation
action, detents, and hidden drag indicator. Short traces remain their natural one-line height. Adjacent
thinking parts and their nonempty lines form the run, whitespace is normalized without
adding or replacing terminal punctuation, and newly appended words fade in unless Reduce Motion is enabled. Tool chips and system
events share compact capsule geometry while preserving their role alignment and interaction semantics.
Compaction and branch-summary events use content-sized transcript pills whose sheets
contain the complete canonical summary;
compaction token counts use compact `K` shorthand.
Transcript configuration changes, errors,
bookmarks, and extension statuses share one readable notification-pill language,
and thinking text and workspace shortcuts stay above the compact-caption scale.
The hidden custom back button is paired with a UIKit navigation bridge so the
native left-edge interactive-pop gesture remains available. Transcript rows enter with the historical soft
opacity/scale transition, newly appended thinking words fade independently within
their stable four-line viewport, and tool status/result changes preserve the mounted
layout without implicit animation. User turns are trailing-aligned while assistant and tool
content remain leading-aligned. Initial model/thinking entries describe
bootstrap configuration and are omitted from chat; later canonical changes are
shown as compact notification pills. Structured result data expands recursively, with raw
JSON only as the arbitrary-data fallback. Gateway connection state is driven by
the current authenticated socket, ignores stale cancellation from replaced
receivers, and uses gateway WebSocket heartbeats to keep Tailscale/iOS idle paths
alive. Canonical settings determine the default model; catalog order is never a
default-selection policy. Dashboard Settings explicitly exposes only global configuration; project scope,
trust, and project package actions appear only when Settings is opened from a
project session. Manage Session has two primary groups: Configuration owns the
model, thinking level, peer-presented Project Resources sheet, and final Rename action;
Session owns Agent Context, recent history/audit actions, terminal, Git evidence, and
exports. Configuration row icons use the section's purple palette, while every Session row
icon—including Git states, exports, sharing, and diagnostics—uses the section's blue palette.
The compact top summary owns automatic-compaction status beside a single-line context
value, followed by the cache-hit/read-write/input/output/cost statistics row, with every
value kept to one visual line. When the runtime has reset its usage estimate, the card presents a
qualified zero-percent fresh state instead of an unavailable headline; a trailing canonical compaction
entry adds concise “Compacted” context, and the copy makes clear that the next response refreshes the
estimate. History owns the concise runtime
phase/message/tool summary. History row previews and relative timestamps are
prepared once off the main actor when the bounded tree or selected mode changes;
live session-state updates reuse those immutable rows, and dense cards use the
static scroll surface rather than one live glass filter per event. Its compact toolbar action invokes Pi's
canonical compaction through Gateway and can leave one authoritative request queued
behind an active turn. Project Resources presents resolved extensions, prompts, skills,
context files, and tools as named rows over the canonical projection; each detail sheet
foregrounds kind-specific purpose, invocation, availability, capabilities, schema/guidance,
and source evidence instead of a generic field table. Project Trust presents a high-signal
state card with an explicit status icon and decision actions before deferring the complete trust record to raw JSON.
Extension tools and commands use
separate adaptive collections instead of comma-delimited prose, while resource descriptions
keep compound words together for natural line wrapping. Arbitrary arrays derive labels from stable name/path/source fields instead of exposing
positional “Item” labels. The overview derives stable row titles, subtitles,
and identities once per admitted resource revision, then reuses that projection
while scrolling; large resource groups use the static scroll surface. Reload is owned by that sheet and publishes visible progress; the canonical
`session.resourcesChanged` revision is the sole post-mutation read owner, so mutation and projection loads cannot race one shared busy flag.
Resource Locations separates
optional discovery paths from advanced Mac runtime overrides and explains each
setting before editing it. Session storage is gateway-owned and is not exposed as
a backing-runtime location override. Package catalog admission failures remain
local to the Packages sheet, preserving the sheet while presenting a bounded retry
state instead of routing a projection error through a global modal alert. The iOS
projection validates bounded structure and paths while tolerating additive resource
categories and future metadata scope/origin values; its rejection copy identifies
whether the response exceeded the 768 KiB bound or failed structural admission.
Deep session history is projected as a bounded flat outline with depth, branch,
and current-path metadata so large canonical sessions neither overflow the
gateway stack nor exceed the mobile frame. The single History sheet explains Timeline,
Branches, Bookmarks, and Recent Log modes, and identifies JSONL export as the complete canonical audit.
Runtime, canonical-history, history-mode, and event cards share one icon width, content spacing, padding,
supporting-text scale, and vertically centered icon-to-text alignment. All text blocks use the same leading
edge; event titles intentionally use the smaller regular body style while summary and mode titles use the
headline style. The row opens details while its uncontained ellipsis control opens the native actions
menu. Forking is available from that menu and as the final action in Entry Details instead of occupying the
history summary.
Gateway produces that audit by copying the
canonical append-only JSONL under the existing idle/file/concurrency bounds rather than linearizing only the active branch.
Agent Context summarizes assembled instructions, context accounting, and capability
counts without duplicating the detailed Project Resources inventory; full instructions
open from a separate matching row. Full instructions and raw technical JSON use
the shared read-only TextKit document viewer so selectable large documents lay out
for their native viewport instead of requiring one monolithic SwiftUI `Text` to be
measured before presentation. JSON serialization is prepared off the main actor.
Every raw technical JSON affordance is the same non-disclosing row and opens selectable,
vertically scrollable protocol evidence in a wrapping single-column medium/large sheet;
technical JSON never creates a horizontal viewport; selectable raw JSON uses the shared
readable code scale across every standardized JSON sheet. Gateway runtime identities
use a protected title followed by a full-width selectable code value, so long hashes
cannot collapse the label column. A same-session reconnect that
installs a replacement Gateway runtime clears every secondary projection, advances its reload revisions, and rejects both
stale completions and stale failures by exact subscription token plus request generation.
Manage Session displays the runtime-projected latest cache-hit rate—the
same canonical formula used by the terminal footer—and never derives a ratio
from cumulative iOS fields. Export rows keep stable format identities and surface bounded
failures locally without dismissing Manage Session. Other user actions surface current
failures instead of silently changing local presentation. Extension interaction sheets serialize one response/cancellation, retain the sheet
on rejection, and dismiss only after authoritative acknowledgement. Terminal presentation retains the
historical connection indicator, options menu, native keyboard integration,
floating shortcut bar, command-key keyboard, soft edges, and selected bundled
code font over the gateway's retained PTY. Destructive Quit uses the system alert style and
waits for Gateway-observed process-group exit; Done continues to detach only. Pending and transcript images use
square previews with dedicated image sheets. A pending photo is a stable,
non-morphing preview target; its separate remove control has a 22-point visible circle
inside a 30-point target centered on the 64-point preview's top-trailing corner. The
preview alone owns rounded glass clipping, leaving the half-offset remove control visible.
Sent prompt attachment strips add three points of vertical breathing room without
changing the 64-point image/file chip geometry. Pending and sent photo chips share the historical medium-detent,
concentrically rounded preview with native pinch and double-tap zoom. Earlier-history loading, context summaries, and unread-response navigation share one
content-sized compact pill treatment while preserving 44-point semantic targets; tool-chip symbols use the
next one-point type step for slightly stronger visual weight without changing pill geometry. A
history request captures the visually first measured semantic frame intersecting the
viewport; threshold visibility cannot authorize loading. Canonical-to-rendered metadata
maps every tool call to its single compact grouped transcript chip, so page-boundary
regrouping cannot lose that visible semantic anchor. Exact detached-reader ordinary installs and
page installs advance a layout/projection epoch, and the row geometry transform includes that epoch
so an exact post-install sample is emitted even when its numeric frame is unchanged. Ordinary
installs reuse the same bounded semantic correction contract for detached readers; pinned readers remain
held solely by native bottom size-change anchoring through continuous and discrete growth, with no app write.
Detached semantic settlement waits passively for that exact sample; after each disabled-animation correction the
owner requires both a strictly newer sample of the same semantic frame and a newer scroll-geometry
revision, accepts either callback order, permits at most one late correction, and succeeds only within
one point. A corrected detached or prepend transaction then completes its bounded programmatic point correction
without moving the viewport. Prepend admission refuses active catch-up, opening-tail ownership, and any
outstanding non-prepend command rather than overwriting position authority. There is no next-frame assumption,
total content-height polling loop, unanchored success, or stale defer
that can end a newer paging token. The
multiline composer
gives its capped UIKit text view sole ownership of caret visibility and internal
scrolling. Representable measurement is side-effect free; a post-`layoutSubviews` reducer enables overflow only against final capped bounds and minimally reveals the rendered caret rectangle after text, selection, font, or bounds changes. The nested editor disables automatic content-inset adjustment because the composer itself is the transcript ScrollView's sole bottom safe-area inset. One direct geometry
observation of that complete owner signals viewport transitions; no height preference, field-specific
hook, or synthetic transcript spacer mirrors its geometry.
Diagnostics parses the bounded
Gateway log records into level-filtered rows and copyable details rather than
showing raw JSON. Gateway/session/tree/tool/interaction timestamps share immutable ISO-8601
format styles, while relative dashboard labels use one lock-serialized formatter instead of
allocating Foundation formatters per visible row. Custom models expose compact provider summary rows;
tapping a provider opens a progressively loaded editor sheet with labeled connection and model sections,
while the row keeps identity, endpoint, model-count, and format summaries visible. The complete JSON remains
an explicit advanced path and is validated before mutation. One pure transformation owns
lossless JSON↔guided conversion, preserves unknown/redacted fields, rejects ambiguous normalized identities, and
runs parsing, traversal, rebuild, and formatting off MainActor before generation-checked view publication.
System alerts, confirmation dialogs,
menus, document/photo pickers, and terminal emulation remain platform-owned, as
they did before the gateway migration. New features must compose these
primitives instead of introducing `.body`, `.caption`, stock bordered controls,
rounded UIKit fields, or system search and segmented styles.

## Offline cache

`SnapshotCache` persists only duplicate-free, bounded session summaries. It never restores or
writes `SessionSnapshot` transcript/runtime state; legacy snapshot-bearing files decode only far
enough to retain summaries and their snapshot values are ignored. File-size admission precedes reads,
which consume at most the exact ceiling. Load and save admit at most 250 unique rows in stored order;
invalid or oversized rows and duplicate IDs are dropped, while a malformed envelope is discarded as a
whole. Each admitted row is at most 128 KiB and the file remains below 8 MiB. Corrupt, obsolete, or
oversized files self-delete. Cache roots are backup-excluded, files request
complete-until-first-authentication protection as part of atomic creation, profile removal deletes only
its hashed file, and generation ordering rejects stale checkpoints. Load/save signposts report only
admitted summary and encoded-byte counts. It is disposable catalog presentation state, not session truth.

## Removed architecture

The app has no Engine transport, SQLite event store, reconstruction plugins,
Activity feed, workers, reusable-agent management, coordination dashboard, or
worker speech service. Generic runtime tools and extension interactions are
rendered directly from snapshot contracts.
