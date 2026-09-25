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
| `Sources/UI/Automations` | dashboard selector, chronological agenda, inventory, detail/run presentations, and schedule editor |
| `Sources/UI/Onboarding` | pairing/setup flow, reusable onboarding chrome, workspace, provider, and default setup |
| `Sources/UI/Settings` | settings shell plus appearance, connection, provider, agent-default, on-demand package/resource, trust, custom-model, and diagnostic presentations |
| `Sources/UI/Terminal` | sheet composition, presentation lifecycle, and SwiftTerm renderer |
| `Sources/UI/Theme` | historical Tron colors and descriptor-based bundled typography |
| `ShareExtension` | app-group share handoff |

The dashboard selector's template logo has a bounded 24-point intrinsic size in its source asset; the full-resolution SVG view box must never become UIKit toolbar layout authority.

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
owner of transcript truth. Gateway fork-boundary annotations are optional metadata, not transcript rows;
the shared assembler inserts “Session forked” / “Subagent created” pills at the exact projected gap before row
filtering and flushes tool runs across the boundary. The inherited anchor gives the pill a stable identity
before any child append, including prompt-only and projected-empty forks. Following-page ownership
plus a true-tail exception prevents duplicates across paging; checked ordinal arithmetic rejects
malformed ranges. This also preserves boundaries after tool results folded into earlier call rows. Read-only process sheets use the same annotation; their Gateway page
revision includes it, preserving canonical IDs, counts, and pagination anchors. Missing/ambiguous ancestry
produces no guessed pill, and pruned inherited content remains above the boundary.

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
Idle transport tasks do not retain an otherwise unowned client. While foregrounded, a dedicated transport task waits ten seconds between WebSocket probes. It captures the socket directly rather than re-entering the `GatewayClient` actor before each ping, so a sustained inbound event stream cannot starve the proof required by the Gateway heartbeat. It observes each CFNetwork ping completion through a bounded eight-second callback window; cancellation or a missing pong closes the captured epoch before recovery proceeds. The probe is deliberately earlier than the Gateway's 25-second heartbeat and emits no application RPC or JSON event. The probe delay remains independent of inbound event reduction; a completed probe's round-trip time adds to the interval between starts, and successful pings are not logged. WebSocket URL loading inactivity remains at 60 seconds for both initial and reconnect requests; one monotonic 15-second handshake deadline covers both hello send and receive, and transport liveness—not CFNetwork's transport timeout—owns established-connection recovery. The iOS ping, pong, handshake, inactivity, and graceful-close values live in `GatewayConnectionPolicy`; the wire-coupled ping, pong, and handshake values are checked against `packages/protocol-fixtures/gateway-connection-contract.json` by `GatewayProtocolContractTests. Deadline and cancellation retirement close the captured socket before joining Foundation operations; the ping completion gate remembers cancellation even before its continuation is installed and ignores late callbacks. Application RPCs are definitely unsent until hello admission and event activation complete. Intentional closure requests a `goingAway` frame and grants the one-task session a one-second graceful invalidation window; a bounded hard invalidation then releases dead CFNetwork epochs so reconnect loops cannot retain sessions and WebSocket buffers for the 60-second inactivity interval. Its injectable transport ends at WebSocket bytes, and its monotonic-clock and UUID inputs control only time and identity generation. The production transport is an actor-confined ephemeral `URLSession` owner and preserves the existing data frames, headers, deadlines, and random UUID behavior. Scripted test sockets contain no protocol, session, receipt,
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
projection uses exact range-safe conversion. Malformed known event data preserves its former live-reducer no-op semantics rather than becoming a transport failure; malformed
session summaries additionally request bounded authoritative catalog recovery rather than silently discarding the update,
while a non-consumable
quarantined suffix forces another authoritative attempt before its baseline can publish.
Gateway connection and disposable cache intervals use the shared typed
performance-signpost boundary. Signpost metadata is structurally limited to result
codes, item counts, and byte counts; identifiers, paths, methods, filenames, model
names, prompts, transcript content, and terminal output are never recorded. `AppModel`
is the shrinking MainActor composition façade; narrow typed owners retain lifecycle and
coordination state instead of routing facts through unrelated façade fields.
`GatewayLifecycleCoordinator` is the sole owner of enrollment attempts, focused-profile lifecycle,
connection state/info/identity, exact admissions, reconnect, foreground reconciliation, serial
retire/close transitions, and final teardown. Optional settings and paired-device reads capture the
exact transport epoch at request start, including a disconnected snapshot, and recheck it for
both success and failure publication; ordinary disconnect retirement therefore cannot let a
response from the predecessor update a successor projection. Provider authentication retains its separate retire/resume owner, and
accepted mutations remain outside this optional-read fence. A non-selecting pairing commit adds a server without
changing the focused profile; the dashboard pool owns shallow catalog connections for the other
paired profiles, admitting at most one enabled profile per verified physical-machine group, each with an independent failure boundary. Pairing responses, WebSocket hellos, and authenticated `system.info` values must carry a bounded `stable` or `dev` Gateway channel; pairing and every initial/reconnect handshake fail closed unless that asserted identity matches the saved profile endpoint’s expected channel. Port selects the expected profile, but never substitutes for the Gateway’s authenticated assertion. Pool handshakes also validate the paired machine identity; mismatches stop retrying until pairing metadata changes, while malformed bounded catalogs enter the normal retry path. Connections uses those profile-owned clients for per-server gateway metadata and authorized-device discovery. Its visible order is paired Macs, authorized devices, then this iPhone's push-notification readiness. Authorized-device names come from the Gateway's effective label projection: custom label, last exact Mac-observed name, then pairing fallback. A focused server advertising `device-label.v1` enables a leading Rename action in the authorized-device detail sheet. It opens the shared native text-entry popup used by Manage Session; cancelling changes nothing, while saving a bounded label updates the custom label and saving an empty value explicitly restores the observed default name. Label receipt completion stays with the mutation owner; presentation/read-generation fences prevent retired reads or saves from replacing visible errors or names, and accepted mutations are reconciled from the authoritative response after the popup closes. `devices.changed` from focused and secondary servers advances a presentation invalidation revision; only active Connections/detail surfaces reload, without exposing physical identifiers or awaiting a catalog read on the control-event lane. Every authorized-device row opens a device-owned detail sheet rather than nesting revocation inside the row. Administrative source/install controls still require the lifecycle-owned focused profile: a device on another server first presents **Use This Server**, preserving receipt ownership instead of adding mutations to the shallow dashboard pool. A capable supervised macOS Gateway advertises `ios-device-install.v3`; its detail sheet reuses the remote workspace browser for a separately validated Tron source checkout and confirms a fixed **Tron Device** + **LocalDevice** overwrite install for the authorized device itself. A one-time Mac-local `scripts/tron-ios-device-bind.mjs` command binds the intended connected Developer Mode physical device through the local-only Gateway control plane; subsequent installs revalidate that exact owner-only binding and fail closed when it is unavailable instead of substituting another device. CoreDevice identifiers never enter iOS models, caches, logs, or RPC projections. The detached Mac helper owns Xcode/device execution and durable requested/running/succeeded/failed status, so installation continues across the initiating socket's replacement and the rebuilt app can recover status after relaunch. Gateway update, rollback, restart, and iOS installation are mutually exclusive administrative transitions. The action cannot select Release, DevicePerformance, an executable, scheme, bundle ID, or arbitrary command; Stable remains Mac-first and app/Keychain data is never intentionally erased. Revocation removes the owner-side install mapping. Log history is isolated in a separate top-level Settings destination and Gateway records are fetched only while that sheet is presented, keeping connection and server-detail presentation independent of the bounded log payload. Typed Gateway response decode failures also enter a 200-record, in-memory-only iOS client ring and are merged into that sheet with an explicit `iOS client` source; the in-app notification action links directly to Logs. This local projection is never written to canonical sessions or Gateway logs and disappears when the app exits. Gateway update status/config reads and restart/update/rollback mutations use only the lifecycle-owned focused profile so receipt handling remains authoritative; a non-focused detail must first choose **Use This Server** and never reads update state through the dashboard pool. Runtime source/fingerprint/epoch fields remain optional, while channel identity is required. An exact provenance-bound Debug candidate plus `gateway-update.v1` enables the confirmed **Promote Debug to Stable** action and pins its version and fingerprint. The separate generic maintenance action is always **Rebuild from Source** and is user-initiated only: repository agents may prepare and validate source but never press the action or submit its RPC. It requires a valid configured source root and sends source mode; its copy explicitly does not claim that an update is pending, and an arbitrary available artifact never becomes an automatic promotion fallback. A failed deployment exposes one equally confirmed **Roll Back** action, sending only channel and command ID to the supervised helper through the same receipt path. Bounded `gateway.update.status` and `gateway.update.config.status` projections place live deployment state directly under connection state; a terminal ready state with no candidate is labeled **Installed and running**, while a verified candidate takes precedence as **Update available**. Source revision, runtime epoch, and payload identity stay behind the per-server sheet's leading info button, which presents the standard metadata tables under **Server Info**; the server sheet itself keeps no inline gateway metadata, and its lifecycle actions render as a two-column grid above one full-width, error-accent pairing action. Source configuration is one row with a selected-path capsule that reuses the Gateway-backed workspace selector, redacts the accepted Mac path to useful trailing components, and saves only that typed source-root mutation through the same admission/receipt path. Build/update and rollback remain separate confirmed actions outside the configuration container. Status polling is command-ID-bound, bounded to roughly one second, and stops at terminal state, reconnect, or view disappearance; reconnect starts a fresh authoritative read. Missing capability or malformed/unsupported status fails closed without presenting an approval action. `GatewayClient` centrally translates typed-response `DecodingError` values into bounded `invalid_response` failures containing only the RPC method, reason category, and sanitized coding path—never response values—before presentation or local diagnostics. Session-open admission identifies the rejected bounded projection (`session.extensionPresentation`, `session.extensionActivities`, or `session.processOverview`) instead of collapsing every cross-field failure to `session`, so diagnostics remain actionable without logging payload data. Session synchronization retries a malformed authoritative open response at most twice from a fresh `session.open`; a third failure surfaces a persistent actionable in-app notification with a View Logs action and byte-bounded local diagnostic instead of Foundation's generic decode text. It composes `GatewayClient` without copying that actor's
byte-transport epoch. `AppModel` supplies narrow projection hooks for cache installation, refresh,
session/terminal reconciliation, and synchronous retirement; it no longer stores a parallel lifecycle
phase, reconnect task, pairing attempt, connection identity, or transition waiters. A dedicated

Authorized-device repository configuration and terminal install status use
independent presentation failure boundaries: an invalid status cannot hide a
valid saved source checkout. The supervised installer receives the signed
Gateway payload's pinned XcodeGen path and never depends on a Homebrew or
checkout-local tool installation.

`AutomationCatalogCoordinator` owns only a bounded, in-memory disposable summary projection for each
identity-verified Gateway profile. It pages one exact catalog revision, rejects duplicate identities,
cursor cycles, mixed revisions, and aggregate overflow, retains an existing shallow bucket as visibly
stale during a partial outage, and defers invalidation reads while the Automations dashboard is not
mounted. `AutomationTimelineCoordinator` pages canonical Gateway-generated seven-day occurrence windows,
groups them by the device timezone, extends the agenda on bounded scroll demand, and never calculates
recurrence, dense-series counts, or DST locally. Full action text, run snapshots, and errors are fetched
only while their managed detail surface is visible and are neither cached nor placed in global events.
Automation mutations use command IDs and the focused profile's `ConfirmedMutationExecutor`; a background
profile remains read-only until the explicit **Use This Gateway** action gives the existing lifecycle and
receipt owner authority. Timeline refresh admission is keyed to each endpoint's profile, connection,
capabilities, and catalog revision; retained failure text does not restart an equivalent read, while
changed revisions still force fresh canonical occurrence reads. The dashboard has no pull-to-refresh surface and relies on
`automation.changed`. No second mutation-reconciliation algorithm or Automation event journal exists.
`SessionCatalogCoordinator` owns the focused profile's summaries, while the dashboard pool owns
profile-qualified shallow catalogs for non-focused profiles. `SessionSummary` carries dashboard-only
profile ownership and the dashboard aggregates by `(profileID, sessionID)`; equal bare session IDs from
separate runtimes therefore remain distinct. An ID-indexed monotonic
live-summary overlay, cached/stale/live provenance, and exact profile/lifecycle/connection load admission
remain scoped to each source. A session created by a workspace Automation carries only the Gateway-derived Automation definition identity in its shallow summary; the historical row renders the adaptive Automation clock immediately left of elapsed time, parallel to the fork marker, without an Automation catalog lookup or local run journal. Equivalent
foreground, reconnect, unknown-summary, and structural invalidations share one
catalog traversal; invalidation during a traversal sets one dirty bit and receives at most one immediate
follow-up before handing newest truth to a new bounded lease. iOS requests user scope in 500-row pages,
rejects more than 50 pages/25,000 identities, duplicate IDs, cursor cycles, and mixed revisions, and
publishes only a complete catalog. A mixed revision from an older Gateway or an expired continuation lease restarts silently once from a nil
cursor; it is expected optimistic invalidation, not the former actionable “Sessions changed while loading
the dashboard” alert. The bounded warning budget is consumed only by a current-owner request/schema/bounds failure; cancellation, stale admission, publication races, and a catalog that keeps moving are retained without warning. Repeated RPC timeouts or application-level disconnect errors still exhaust this projection budget even when the socket remains active; they never independently retire that transport epoch. `AppModelCatalogSyncTests.catalogFailureAdmissionClosesEveryEntrypoint` covers bounded failure, warning, and recovery for each case. This matters when a parent run spawns active subagents: their structural notifications may invalidate the Gateway generation even though the user-scoped dashboard rows are unchanged. Known revisioned `session.summary` events apply synchronously without a list read,
and mounted transcript snapshots cannot overwrite those global row fields. The shallow summary carries aggregate `phase` plus optional `foregroundPhase` and `hasActiveSubagents` facts: a live row whose foreground has settled while subagents remain active uses a circle-sized native solving orb instead of the foreground pulse, while older summaries fall back to the pulse. Read, unread, foreground-active, delegated-active, resuming, and interrupted indicator replacements share one stable icon column and animate with an overlapping scale/fade transition; Reduce Motion keeps only the short fade. Dashboard ordering keeps active rows first and uses the Gateway-observed `activeSince` boundary to hold their relative positions while progress and heartbeats continue; settled history orders parsed `updatedAt` instants with profile-qualified identity as the deterministic tie-breaker, so equivalent whole/fractional ISO representations never become chronology. Older Gateways that omit the additive boundary use profile-qualified identity among active rows instead of their volatile live timestamp. Visible rows use a one-second `TimelineView` cadence, gated by surface, scene, and viewport visibility, so seconds-based relative labels keep aging after completion even when no catalog event occurs. Rendering uses at least the current wall time rather than an older scheduled tick when a summary arrives between ticks; this presentation clock never mutates recency or sort order (`SessionSummaryPresentationTests.settledRowsAgeWithoutReordering`). Live Gateway summary heartbeats independently advance active foreground and detached-extension freshness without moving those active rows. An empty, actively converging session catalog uses the same centered accent pulse as chat opening; the first complete projection cross-fades into place, and later focused or background-Gateway row insertions, removals, and layout changes use one Reduce-Motion-aware dashboard animation instead of abrupt list replacement. Switching between Sessions and Automations replaces the owning surface atomically rather than overlapping two full-dashboard transitions, so top blur and bottom glass chrome are never double-composited during the handoff. Completion attention is one
of those Gateway-canonical row fields: only final settled prompt responses advance it, Mark Read/Unread
uses an absolute command-receipt mutation whose complete attention projection applies immediately even
for cold rows, and a successful open acknowledges only its returned completion revision after the
snapshot installs. As soon as the exact synchronized subscription is mounted on the active chat
presentation lineage in an active scene, `SessionPresentationStore` owns a 15-second renewal loop for its 45-second
Gateway presentation lease; opening a descendant tool, command, or detail sheet retains that lineage and presence does not wait for large-transcript scroll positioning or the first
ready frame because the mounted composer can already admit work. Visibility requests carry a monotonically increasing revision so a delayed
inactive request or renewal cannot overwrite newer intent; inactivity, route close, subscription
replacement, and connection retirement cancel the local owner, while Gateway close/disconnect and lease
expiry bound missed cleanup. Revisioned unread summaries for the mounted session feed the same exact
read-through path as a convergence fallback. Gateway latches the lease observation once per canonical
completion and uses that single disposition to commit completion/read-through atomically and suppress
the automatic completion notification without creating an inbox row. Opening and mounted acknowledgements
retry transient failures against one fixed presentation/connection owner and absolute revision;
cancellation retires them. Protocol-v5 clients require the complete attention and presentation contract
and do not attach to earlier Gateways. The local snapshot cache remains
display-only, and projections written before attention fields existed decode as
read rather than inventing unread state. The dashboard groups user
sessions by workspace and renders ten per workspace by default. Settings → Sessions → **Chats per project**
configures 1–100 through the iPhone-local `AppLocalBehaviorSettings` owner; the same count governs Show more
batches and the Show less baseline. The preference does not change Gateway catalog limits or Recent Activity
ordering. Dashboard reconciliation applies changes when visible, resets project pagination to the new baseline,
and retires staged animations without reusing their generations. Explicit Show more/Show less pagination
remains a disposable UI projection with generation-checked staged animations, so catalog refreshes cannot
expose stale rows or leave controls stuck. Successful session creation starts a shared background
catalog reconciliation without delaying chat navigation. The Gateway projects a newly created empty row
while it owns that live runtime slot; if Pi has not persisted content, the disposable row may disappear
after Gateway restart or idle slot retirement. Initial connection, structural and summary events,
reconnect, creation, and deletion own dashboard convergence without a manual refresh surface. Focused and
secondary profile owners retain an unsatisfied structural generation across responsive list failures and retry with
the shared reconnect delay policy until a complete authoritative publication; the unavailable notice appears after
three consecutive failures without ending retry. Epoch retirement, backgrounding, and profile removal cancel that
lease rather than turning it into polling. Catalog observability stays in this same ownership path: `GatewayClient` emits bounded `gateway.rpc` records for `session.list` with the sanitized request ID, outcome, failure code, duration, and profile identity, while `AppModel` emits `gateway.catalog` admission and terminal decisions with connection/lifecycle/request generations, actual failure code/reason, page, revision, retry attempt/budget, and the owning RPC request ID. The existing iOS diagnostic buffer and retained Logs export bound these records to 200 entries; they contain no session content, paths, payloads, credentials, or raw errors. A successful authoritative publication clears the catalog warning through the normal notice owner rather than inventing a second health state. Session command catalogs are loaded by the
presentation store only after exact subscription-target installation; the lifecycle restoration schedules provider, settings, and device projections only after the mounted chat is
restored, and those optional reads never gate session restoration. Opt-in diagnostic RPC records carry
only an allowlisted purpose and bounded pagination ordinal, never request parameters, cursors, or payload values.
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
until its atomic replacement arrives. The Providers sheet keeps each provider in its own rounded,
scroll-optimized row container, with Configured above Available and no enclosing section surface or
between-row dividers. Opening a provider detail retires the covered list read without clearing its
same-target usage projection, while profile or target changes still clear and fence old results. Unconfigured
waiting forms remain swipe-dismissible; only an in-flight begin or credential clear blocks dismissal, and
sheet disappearance cancels an auth operation admitted by that sheet (never an unrelated operation). Usage
refresh keeps a 26-point visible glass control vertically centered beside the usage title and trailing-aligned within its 44-point hit target with dark-mode contrast. Summary-only usage omits the empty detail stack and uses equal top/bottom insets; populated usage retains its full-width details and bottom spacing.
Stale operation responses are treated as a retryable no-op rather
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
again on the current connection before replay can publish; a profile-generation change discards them. Each reconnect executor owns one `GatewayReconnectSchedule` and keeps retrying retryable transport failures while the app is foregrounded on a satisfied path. The nominal delay starts at 2 seconds, grows by ×1.7 to 15 seconds, and receives independent 80–120% jitter with a hard 15-second cap. Foreground, path return, and explicit Retry accelerate one pending delay; a background transition or unsatisfied path pauses admission. Only unauthenticated, forbidden, protocol-mismatch, and identity-mismatch failures stop automatic recovery, until explicit Retry clears that stop. Retryable failures keep the status Reconnecting; Offline means recovery is stopped. After two consecutive failed connects whose L-10 records show `stage=transport-open` and `transportOpened=false`, the dashboard and delayed recovery notice say **No path to this Mac**, adding the known interface (for example, **No path to this Mac over Wi-Fi**). Any attempt that opened a transport, or a recovery episode that began with `ping_timeout`, stays **Reconnecting**. Successful connection clears the presentation. This classification does not change retry timing or ownership. Every handshake uses the shared 15-second deadline. The controlled monotonic clock and injected unit-interval source make delay and acceleration behavior deterministic in tests. Background scene transition cancels disposable foreground/catalog reconciliation, preserves the route and bounded profile-owned projections, retires the transport epoch before suspension, and gates event-triggered catalog reads until the next active scene starts one authoritative reconnect pass. After event activation, reconnect and foreground
reconciliation starts dashboard convergence concurrently with mounted-session restoration; terminal
reattachment follows exact mounted-session synchronization because the Gateway requires that connection's
subscription before terminal attach. Handshake plus event activation ends planned maintenance and admits exact session-route preparation. Mounted restoration, terminal reattachment, and final live-transport validation own the generation-bound reconciliation aggregate. The complete catalog traversal is independent optional work through the existing connection-refresh task. That owner preserves staged loading: catalog first, then provider/settings/device reads only after revalidating the exact live connection; neither stage gates mounted chat readiness. This also lets initial startup finish transport admission while the catalog's own loading state and retained rows remain in place. Background retirement cancels that optional owner. Healthy foreground reconciliation shares the catalog owner without cancelling or replacing unfinished connection refresh; provider/settings/device work therefore survives foregrounding whether the catalog or later reads are pending (`AppModelCatalogSyncTests.foregroundPreservesConnectionRefresh`). Already-cancelled catalog demand cannot acquire an owner, and an already-cancelled retry cannot reopen the exhausted failure budget. Provider/settings/device reads reject cancellation before advancing their read generation and again before publication, so cancelled callers cannot invalidate or overwrite a current read (`AppModelCatalogSyncTests.cancelledOptionalReadCannotSupersede`). These are not per-read connection-epoch fences after launch. Catalog failures never write a late mounted-projection failure flag. A projection failure leaves the responsive epoch connected and exposes its own retry surface instead of recycling transport or blocking another session from opening. Focused or background dashboard catalog/schema/application failures retry their projection read without replacing an otherwise responsive exact socket; only observed transport epoch loss enters reconnect. `AppModelReconnectTests.replacementReadinessDoesNotAwaitCatalog` holds either the first or a continuation page through actual background/replacement synchronization and checks restored authority, retained draft/target, and later atomic catalog publication. `AppModelCatalogSyncTests.backgroundRetiresOptionalRefresh` protects retirement of a pending optional traversal. Final teardown cancels and joins the event listener and shares one
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
installer and closes its interval only after reset, delta, and a strictly contiguous replay prefix are admitted; duplicate, reordered, or missing-middle chunks remain non-canonical and trigger a bounded follow-up reconciliation. Within one revision the retained chunks are strictly ascending and contiguous, so the native renderer resolves its pending suffix by lower bound instead of rescanning the whole retained array on every update.
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
older browsing rows. Opening never extends the synchronization quarantine. If the synchronized tail has a positive
start and fewer than 512 visible rows, one optional exact backward page is admitted inside the
still-opaque opening transaction with a one-second request deadline. It trims the combined recent
window to 512 rows and fails silently back to the usable tail. The first installed render commit
therefore receives one settled source window instead of racing a second physical spine into view
after readiness. Further history remains explicit canonical paging. Every compatible replacement/reconnect
reconciles only an exact visible prefix: the visible coverage end
is the authority tail end, sliding tails promote covered old-tail rows, backward expansion trims the
prefix, and ordinal ID overlap, parent, leaf, and runtime/total identity conflicts fail closed. A
detached reader retains loaded rows; physical return to latest never mutates transcript coverage.
A pinned mounted reader that loses a native marker during a bounded physical-tail repair retires the
old target, then keeps one target-free rebase owner until the next admitted legal-boundary geometry
sample. That sample re-applies persistent pinned mode without leasing a replacement target; a later
current marker remains the only physical proof used for further repair. Ordinary retained presentation
handoffs still require aligned marker evidence. Direct interaction and presentation replacement
cancel the rebase owner; covering the viewport cancels only its target-free branch until a fresh
foreground handoff establishes marker ownership. This prevents a stale native target from stranding a resumed
transcript without weakening the opaque opening/readiness gate.
History loading is admitted from the canonical cursor even when no rendered row or semantic scroll
anchor exists; an anchor is optional viewport-preservation evidence. Only duplicate-free bounded
summary rows enter the disk cache.
`ChatTranscriptPresentationStore` serializes snapshot-to-timeline preparation off MainActor,
coalesces a burst to one pending newest source, and keeps the last complete installed commit
visible while a replacement builds. Sparse/high-frequency layout equality checks streaming, tool,
queue, and runtime facts before the bounded canonical array, avoiding a 512-row scan for ordinary
live churn. Transcript rows and Load-earlier availability come from the installed source window.
Transcript-coupled composer chrome—phase, retry presentation, and
response signature—is frozen in that same source tag, while drafts, command admission, and the
independent process projection remain with their canonical owners. Queue management stays owned by the
installed queue revision/items and the exact Gateway capability authority; generic transcript
build lag never locks a stable queue card. An admitted Load-earlier page owns one exact token in
`ChatScrollCoordinator` from click through Gateway paging, projection installation, and anchored
restore or geometry-free completion; there is no parallel unanchored task. While that transaction
is active, disposable streaming/tool churn remains in canonical authority rather than superseding
the exact page build. A complete same-runtime commit with the same mounted start and exact prior
edge IDs at their original ordinals may restore the anchor even if a canonical suffix appended;
branch replacement and window movement fail closed. The newest desired source is submitted
immediately on settlement. Background cancellation clears prepend ownership before its terminal
callback; projection work stays suspended, and active foreground reconciliation retires stale
native target ownership before submitting the latest coalesced source.
Ordinary projection updates do not relabel or disable the pill. It installs only an exact tag
containing session, mounted presentation, runtime, canonical/timeline generations, and paging
bounds/edge identity. It retains at most one installed, one frame-gated ready candidate, one building,
and one pending immutable snapshot/timeline; every slot is disposable projection state, not a session
mirror or event journal. Text-preparation retirement uses the same half-open epoch contract as
projection installation: entries older than the retirement boundary are removed, while the boundary
epoch remains admissible for its successor build even when retirement delivery is delayed.
One deterministic `ChatTranscriptProjectionKernel` converts exact canonical entries into ordered
raw atoms and then globally assembles call/result joins, bootstrap filtering, barriers, grouping,
and semantic maps. Message presentation IDs and required content/thinking-run ordinals arrive from
the Gateway and are never rewritten: the same semantic row, thinking run, and prepared-text source
therefore survive live-to-canonical settlement even though the canonical entry ID changes. When one
snapshot briefly retains a streaming assistant after its matching presentation ID becomes canonical,
canonical ownership wins for every row shape, including finalized tool groups. Text preparation applies
the same role-and-presentation precedence, so a stale live source cannot evict the canonical row's warm value. Exact nonempty tool-call
membership is a second settlement proof for the narrow frame where canonical persistence precedes its
presentation binding. The Gateway additionally refuses to project Pi's briefly retained
`streamingMessage` after the explicit live identity retires. Other duplicate render IDs remain invalid
and fail closed before row-local preparation rather than trapping or being collision-disambiguated;
one transient invalid mounted projection requests one fresh authoritative synchronization cut in the
same presentation generation, while a repeated malformed cut fails with authored actionable copy.
Semantic identity continues to own entrance and resilience state. The
projection worker prepares immutable row-local
markdown/thinking slices with entry-local revision tokens, so render rows perform only cheap revision
equality and never reslice the transcript-wide cache. `ToolExecutionStatePolicy` is shared with
`SessionPresentationStore`, so progress-sequence, status-tie, producer-order/group-order, and call-ID
rules cannot drift between canonical event reduction and sparse rendering. Timestamps are freshness
metadata only and never establish identity, membership, or placement. Raw fragments retain the complete
currently visible disposable history—even beyond one 512-item page—because explicitly loaded
history cannot be evicted until forward reload exists. The mounted reducer caches one validated visible
transcript projection per timeline generation, and semantic-anchor selection is one indexed pass; cold
or structurally changed full-history assembly remains linear in the explicitly retained history. Projection instrumentation reports only a closed privacy-safe mode (`cold`, `fragmentReuse`,
`toolPayloadPatch`, or `isolatedStreamingSuffix`) and aggregate entry/fragment/tool/atom/rendered
counts; it carries no identifiers or content. A pure tool patch reports zero source entries and atoms,
counts every runtime membership state examined in `toolsInspected`, and reports only the distinct
descriptors changed in `toolsPatched`. Opening
a new chat presentation always synchronizes a fresh authoritative bounded latest page; disposable cached or previously paged prefixes are never revealed as
its baseline. The transcript remains behind a nonblank opening surface containing only a centered pulse, rendered at twice its former nominal size with an accessibility-only label, until the
two-phase `session.open`/`session.sync` handshake installs its authoritative tail, the
exact initial transcript projection, and a physically verified viewport at the marker
after transcript and queue rows. The positioning command targets the terminal physical row
from that installed spine (including an admitted alias), while the marker remains the separate
settlement oracle. Rows remain fully realizable beneath that opaque cover, which also extends
under the navigation bar because the transcript scrolls there, outside its safe frame
(`ChatViewScrollHarnessTests.openingCoverHidesNavigationBand`);
an opacity-zero lazy stack is never used as a layout gate. The eight-point positioning lift resolves behind that cover, and the cover is removed only after
current non-lifted marker and geometry evidence, two physically unchanged presented frames regardless of duplicate SwiftUI observation callbacks, and consumption of
the exact opening-target release. One still-covered frame then installs the settled transcript at zero opacity and an eight-point visual offset; the immutable commit rises while the cover fades in one cosmetic animation transaction. Physical settlement plus the next ready display-link frame, rather than animation completion, admits interaction, repair, paging, live projection intake, and the exact submission/layout authority. The cosmetic reveal remains `presented` until that frame revalidates the opening epoch, exact viewport activation, active scene, live presentation activity, mounted target, and installed runtime identity. Coverage retires even a final-frame attempt; a late scheduler return cannot publish ready or extension routes behind the cover. Same-target runtime replacement rejects an unfinished cut and resumes against current authority without reopening transport. A missing cosmetic completion therefore cannot strand the pulse or controls; Reduce Motion keeps only the short fade. Automatic projection intake remains
coalesced through that complete transaction. The first complete same-session/presentation/runtime commit may
position and reveal even if streaming has advanced its payload; only the newest desired source is submitted
after that lease ends. Runtime or presentation replacement still fails closed. Opening uses one exact
terminal-row `ScrollPosition` command when the target is not yet realized, rejects native overflow
overshoot as a bottom boundary, and never uses the lifted reveal frame or elapsed time as settlement proof. Every post-reveal settlement result, including the two-second deadline failure, revalidates cancellation, opening epoch, exact viewport activation, live presentation activity, and current mounted/runtime authority before interpretation. An obsolete failure uses cancellation/reconciliation rather than closing a valid same-target replacement; a covered late failure cannot publish unavailable. `ChatViewScrollHarnessTests.openingDeadlineRevalidatesOwner` holds the real frame dependency through the production deadline and covers current-owner failure, runtime replacement, and coverage after failure production. A separate two-second post-reveal deadline retires the stale target and fails the still-opaque
opening for explicit retry; it never certifies readiness or falls through to a visible repair. A retained
pinned presentation re-enters this same physical-marker positioning gate on resume;
temporary coverage preserves only its committed authority and immutable installed
projection, while a retained detached reader remains anchored and is never repinned.
A temporarily covered unfinished opening resumes against that installed commit without a new
session-open or projection install. Retirement checks the exact current mounted authority and
live coverage before closing, not cancellation alone; failures and true route loss close the
old owner. Reader retention and authority retirement are independent: cancelling a covered or backgrounded detached replacement preserves a valid current subscription, while revocation closes that owner without erasing the permitted old reader cut. A detached display cut does not bind command authority: a replacement target from
the current route/profile's mounted subscription is reconciled independently, with send and
uploads available without a scroll or keyboard event. The old immutable cut and reader position
remain untouched until returning to the tail admits one newest projection; neither its metadata
nor its geometry is relabeled as the new authority. Rendered send admission and its action share
cheap current target/snapshot/projection availability checks; only the action captures the full
projection. Active commands still exclude send, while terminal `outcomeUnknown` does not.
`ChatViewScrollHarnessTests` exercises production opening/cover cleanup through fake
`session.open`/`session.sync`/`session.close` RPCs, accepted camera-import receipts across cover,
revoked/disconnected rejection, and detached replacement sends (including replacement while
covered). The attachment representable receives the same admission through SwiftUI's disabled
environment as its UIButton update, so ambient enabled state cannot reactivate a revoked control. Native-only fixtures replace
only the opening dependency, never opening or retirement logic, and use isolated draft stores.
Its cancelled UIKit appearance-transition regression preserves subscription and native draft
identity; completed route removal closes once. Foreground
activation retires any target belonging to the suspended native scroll tree before
revalidating current marker evidence. An installed projection advances the layout epoch
when its physical row spine changes; streaming payload and shallow tool-state updates
retain their existing hosts and current geometry evidence. Newly admitted lazy rows retain their hidden one-shot state even when geometry admission precedes child mounting, then retire the entitlement only after local animation completion. An admitted outgoing lifecycle row may settle its transcript-growth lease from a positive native row frame only after current epoch, projection, physical-row, and exact materialization-lease checks; this frame proves materialization, not visual animation completion, and marker evidence still owns target release. This keeps resumed sends from depending solely on an animation completion callback that may be interrupted by keyboard or canonical handoff. Within an already-mounted assistant row, authoritative thinking and response content installs immediately but one bounded row-local height clips and smoothly expands ordinary growth; width changes, shrink/replacement, covered surfaces, Reduce Motion, and growth above 2,000 points install atomically rather than inheriting motion. Delayed frames from a replaced
spine still cannot prove the new tree. A layout-epoch callback only re-evaluates
a marker already admitted by that current epoch; when the marker's numeric frame
is unchanged, the mounted scroll view waits for a new physical marker callback
instead of re-admitting the prior frame. A visible pinned presentation therefore
requires fresh, current-layout marker proof; overflow requires alignment, while
underflow requires the eager marker to be visible after either a current terminal
physical-row geometry callback or an authoritative empty physical spine. The terminal
callback is admitted only when its captured layout epoch, viewport activation, installed
projection tag, and exact physical identity still match the mounted commit. Row existence,
forced underflow height alone, elapsed frames, or an abandoned layout generation are not proof. Ordinary
pinned resizing then belongs to the native size-change anchor. A detached reader owns one
immutable installed render commit: direct takeover cancels pending derivation, automatic
live projection intake stops, and only the scalar authoritative timeline generation is
observed to mark unread work. Canonical session authority continues advancing without
formatting, diffing, mounting, measuring, or correcting offscreen tail rows. Manual return
to the physical tail resumes one newest coalesced projection; explicit catch-up retains
the freeze through its old-tail command settlement and then admits that same newest cut
under pinned native anchoring. Explicit earlier-page loading remains separately admitted
because it is direct reader intent. Reconnect and responsive foreground refresh both freeze projection intake
under one aggregate lifecycle admission and advance one completion generation after
exact mounted restoration and live-transport validation. Catalog convergence remains
optional and publishes independently; detached readers retain their native viewport
ownership.
Native bottom alignment owns short and empty transcripts, including keyboard contraction and growth into overflow. There is no fabricated minimum transcript height or separate short-chat positioning branch. Impossible offsets below the legal short-content bottom are rejected rather than clamped into an apparent catch-up boundary. A pinned viewport that stays past the legal bottom of overflowing content, outside plausible bottom rubber-banding, is recovered by one bounded correction of its own: a disabled coordinator-owned `.tail` command that needs no marker evidence, retires a held materialization lease first, and is admitted only from sustained geometry with no send, keyboard, or growth layout transaction in flight and no opening, catch-up, restore, or prepend owner active. Marker frames use scroll-view-relative coordinates: their expected bottom is the lesser of content and container height, without subtracting the composer inset a second time. Native viewport bounds and mounted composer clearance are separate hosted verification evidence. The coalesced observation carries opening phase so geometry captured before positioning is re-admitted without a callback-order race; opening still requires a visible current-layout marker, not short-content geometry alone.
Test builds can admit one synthetic authoritative
snapshot through the same read gate and skip only the network opening handshake.
The hosted harness still mounts the production chat, lazy transcript, composer
inset, and native scroll view; a display-link recorder coalesces geometry and
semantic row-frame observations to at most one sample per presented frame. These
hooks are absent from Development and Release builds and own no session policy
or runtime state. The
composer remains mounted and visible throughout opening so transient synchronization
cannot remove the primary chat control; sending stays disabled until the authoritative
baseline is ready. A cancelled opening lease publishes a fresh resume edge when it drains, so a foregrounded connected chat cannot remain non-scrollable with disabled composer actions until an unrelated navigation gesture changes presentation activity. Failed attempts do not automatically reopen from task-revision, connection, or foreground callbacks; the explicit Retry intent survives an old lease's drain without overlapping session opens. The hosted reveal-cancellation regression checks stale-callback rejection, the enabled attachment/native-scroll controls, and a visible outgoing submission after resumption. A failed transport/sync open shows an explicit retry surface. Once that mounted chat is ready, reconnect and
resynchronization merge compatible live tails with history explicitly loaded in
that viewport; a detached reader keeps its frozen commit until returning to the tail. Explicit earlier-page loads
remain request-only, are scoped to the exact mount generation/cursor, and restore the
former visible anchor with bounded late-layout correction so the viewport does not jump.
A gesture that begins during that correction cancels every remaining position write
and its final native geometry wins over the pre-load detached state. A 256-record,
content-free in-memory chat trace correlates opening, projection-spine replacement,
layout participants, viewport intent, explicit scroll commands, submission lifecycle,
and thresholded geometry changes with local context/generation numbers. A terminal opening deadline also emits one bounded failure snapshot naming the missing authority/projection, unapplied command, stale marker epoch, implausible or non-boundary viewport, missing physical-tail alignment, incomplete two-frame stability, inactive presentation, cancellation, or replacement category; this is evidence only and never a readiness fallback. The hosted ChatView harness exercises both idle and streaming production openings, while coordinator tests inject missing physical proof. It emits automatic anomalies when a ready opening loses its installed rows or a pinned opening or
submission becomes substantially displaced. SwiftUI marker classification edges additionally record the
first loss of pinned-tail alignment before recovery with before/after displacement, offset, and content
scalars, excluding user-owned scrolling. Marker/row observations and estimated scroll geometry are
labeled separately; neither establishes what was painted between presented frames.
Materialization records include the requested physical row's signed position relative to the physical
terminal row, current active/pending semantic owners, and row-evidence freshness; positions are
collection ordinals, not transcript ordinals or exported identities. Command correlation uses a local
`commandOrdinal`, never a `token=` field. Under ring pressure, informational records are evicted
before warning/error evidence; the ring remains globally bounded and becomes FIFO when every retained
record is diagnostic priority. Records are merged into the existing Logs
destination on demand and also enter Unified Logging; they never contain session or row
IDs, prompts, transcript content, paths, filenames, model/provider names, or error payloads,
and disappear when the app process exits. The Logs surface keeps its existing bounded records and filters, removes the manual reload control, refreshes only while visible and foreground every 15 seconds after the prior read settles, and exposes native pull-to-refresh through the same coalesced load owner without resetting the reader position. The app-lifetime iOS 26 MetricKit subscriber is a separate bounded producer: it retains only compact typed daily values (CPU seconds, peak/suspended memory bytes, foreground/background seconds, bounded launch/hang bucket counts, and disk-write bytes) plus diagnostic category counts, durations, app build/bundle/OS provenance, exception codes, termination reason, and call-stack presence; it never retains raw payloads or call-stack text. These summaries share the incident store and explicit Logs Share path, remain local until user export, and are omitted or bounded honestly when unavailable; daily metrics and diagnostic delivery are asynchronous and are not live health state. Matching dSYMs remain required for symbolicated reports. Registration has an explicit stop seam for tests and rollback. iOS `AppLog` continuously retains bounded structured records in an actor-owned ring, persists info-and-higher records in batched JSONL writes, and includes debug RPC completions only in the in-memory/export projection. Logs keeps its existing records, details, and filters and replaces Diagnostic Capture with one Export Diagnostics action: when a connected Gateway advertises the export capability, the app uploads the bounded device/app/Gateway bundle and copies the private device-hash path; otherwise it shares the same bundle locally. Recording excludes content, paths, credentials, frames, and tokens. Instruments remains necessary for CPU stacks, SwiftUI rendering, memory, and actor contention. The UIKit composer keeps focus reconciliation deferred but resolves internal overflow and caret visibility only from final post-layout TextKit geometry, preventing speculative SwiftUI measurement or keyboard/safe-area callbacks from changing the editor offset.
Create and fork return navigation identity without mounting or selecting a transcript;
only the destination route may establish live presentation authority. An admitted composer
transport intentionally survives route disappearance: its target is retained by the
composer admission owner, and revocation makes any late error target-gated and silent rather
than allowing a retired view to surface stale UI state. Backgrounding cancels only disposable
opening, paging, picker, and route work. A resumed open waits for an exact current transport connection rather than trusting the previous epoch's public connected label; a target-free background-retirement interval cancels silently, and the replacement connected transition retries through the same generation checks. Already-ready active and passive chats retain their complete installed projection while the lifecycle owner synchronizes in place.

Gateway-owned automations advertise `automations.v2`; canonical agenda/preview reads additionally
advertise `automations.timeline.v1`. Automation targets are a strict union of an existing persisted
session or a workspace with `newPerRun` policy. Workspace targets support prompts only; each run's
Gateway-assigned execution session is an ordinary user-visible session and is never a subagent. The dashboard Tron logo opens a native mode menu and routes every
selection through one generic dashboard-selection callback; the persistent shell uses an exhaustive
`DashboardMode` switch, so adding a mode cannot compile while silently falling back to Sessions. Each
choice retains independent root state. The Automations root provides a chronological Upcoming
agenda and a searchable/filterable All inventory across identity-qualified paired Gateways. Its one
managed filter sheet owns the view, status, action, and Gateway choices, while All-mode search reuses
the Sessions dashboard's bottom reveal/close interaction. `SessionShellView`, which survives dashboard
switches, owns those four choices through `AutomationDashboardPreferencesOwner`. Its root binding persists
every accepted child mutation into one bounded versioned `UserDefaults` document and restores that value
when the shell is created; ephemeral search and agenda-date state remain presentation-only,
and no Automation action content or journal enters the preference. Only currently connected profiles with an
authenticated `automations.v2` capability enter this projection; disconnected and incompatible profiles
remain absent and cannot publish warning copy over the dashboard's neutral empty state. iOS admits
typed bounded automation summaries, trigger/run/detail states, and `automation.changed` invalidations,
but does not infer execution state or build a local schedule engine. List pages omit action bodies,
require one exact catalog revision, and cap each disposable Gateway projection at 1,024 definitions;
authenticated, surface-scoped detail reads remain the only path to prompt or notification content.
Repeated invalidations coalesce in the connection event hub and become one dirty catalog refresh only
while the dashboard is active. Create/edit supports only session prompts, optional skill/prompt resource
invocations, and notifications; workspace targets are prompt-only, while notifications require an
existing session. New-session interval schedules are limited to one run per 24 hours by Gateway
policy. Shell, webhook, extension-command, attachment, deployment, and Gateway lifecycle actions have
no UI or wire path. Run-now, enable, cancellation, deletion, and uncertain-outcome
resolution require explicit confirmation and retain optimistic definition revision fences.

Knowledge is a bounded, Gateway-authoritative projection exposed by the Knowledge dashboard. It uses
`Color.tronKnowledge` (deep violet in light appearance and lavender in dark appearance) for its identity,
while semantic warning, success, and danger states retain their established colors. The dashboard's
managed filter sheet owns type and scope selection, and its managed configuration, capture, note,
correction, and detail presentations inherit the same accent and Tron typography. Search,
loading, empty, evidence, coverage, and retained-object states use the shared presentation controls;
observation cards contain only statement, scope tag, and localized source date. `KnowledgeDetailSheet`
opens at medium and expands to large; observation detail shows one originating-session action and puts
revision/range/digest/attribution/certainty behind its top-left technical-details button. Navigation and
editable-draft handoffs wait for sheet dismissal and recheck the originating identity. `KnowledgeFormSheet`
composes the existing settings layout, controls, and large-sheet toolbar contract without owning form drafts
or mutations. Coverage shares the dashboard scroll owner, and floating controls have explicit content clearance.
Accepted Knowledge mutations remain owned by the confirmed executor
and are fenced by the originating presentation identity. Committed Knowledge store mutations—including agent tools and
background observations—broadcast `knowledge.changed` invalidations, coalesced by the client. The dashboard's managed
read task includes that revision in its identity, cancelling superseded reads while preserving publication fences.
It re-reads authoritative status and records without polling or a pull-to-refresh surface.

Gateway restart uses a supervised drain contract. The request freezes new mutations,
waits for accepted agent runs to settle in canonical JSONL, then replaces the Gateway
process; active PTYs must be closed first because their process state is not restartable.
iOS keeps the chat mounted, follows `system.stopping` into its ordinary bounded reconnect
loop, and installs a fresh authoritative session baseline from the replacement runtime.
A restart response may be immediate or scheduled behind active runs. Connection Settings may
briefly poll the bounded drain projection only for an operation explicitly requested in that view;
it shows fixed aggregate labels and retains nothing after the view's ownership ends. Drain phase,
counts, and ages are diagnostic presentation only: `system.stopping` and the replacement handshake
remain the sole reconnect and liveness authority. While a drain is preparing or waiting, Connection Settings offers an explicit, confirmed “Restart Now” command (the standard trailing pill on the Restart drain row) with `restartNow: true`; it goes through the same command-receipt owner and warns that unfinished work may have an unknown outcome. Assistant error pills preserve provider-authored details, except the provider's bare `Error Not Found` placeholder is expanded into actionable model/provider-connection guidance. Diagnostics routes current unsupported, busy,
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
projection mirror. Snapshot installation and subscription policy are exercised at this owner,
not through parallel façade policy helpers. A decoded close response retires the exact captured token
whether `closed` is true or false; an interrupted request retains ownership for retry, and a stale
completion never clears a replacement token. Revocation synchronously rejects every sequenced topic, not only full snapshots.
Paging, exports, and secondary reads capture an exact unrevoked target plus installed token and
revalidate both after suspension. Export archives use a file-backed URLSession download rather than response `Data`;
reservation followed by file adoption is the artifact store's only ingress.
A `session-export.v2` Gateway supplies the exact artifact size and iOS rejects declared, streamed, or final files above
the export-specific 2 GiB item/4 GiB aggregate policy; older Gateways remain on the legacy 25 MiB path. Capacity is
reserved against artifact count, aggregate bytes, and available filesystem space with a 64 MiB floor. HTTP staging
reserves its count and byte budget before transfer, and URLSession may use the authenticated Gateway byte-range contract
to resume a transiently interrupted download before atomic artifact adoption. The artifact owner retains at most eight protected,
backup-excluded values, prunes malformed/expired/non-active values by age and aggregate size, and never evicts an active
ShareLink artifact. Gateway-provided names reduce to a 160-byte last path component. Exact route revalidation removes
stale staging and artifacts, and app launch plus every new export performs bounded cleanup. Paging is read-only
at the Gateway and cannot revive event subscription ownership after close. Cold cache snapshots never
enter the store's authoritative read gate.
`session.open` uses
a two-phase subscription barrier: the authoritative snapshot and ephemeral sync
token are returned first. The snapshot and subscription token remain provisional and
unobservable until `session.sync` succeeds and the exact session/presentation intent is
revalidated. iOS admits both tokens as nonempty, printable UTF-8 values of at most 200 bytes before installation; stale or failed opens close only the already bounded provisional subscription token. The same opaque token
then becomes subscription ownership, and `session.close` only releases a subscription whose
current token matches. Protocol-v5 peers always provide explicit ownership.
Control-character membership uses an explicit scalar closure: the optimized Xcode 27
app miscompiles the bound `CharacterSet.contains` predicate and rejects valid tokens,
blocking both acknowledgement and provisional cleanup. `synchronizationTokenAdmission`
covers opaque values and UTF-8/control boundaries; `transientMalformedOpenRetries`,
`malformedOpenTokensPreserveProvisionalCleanup`, and `coveredFinalOpeningFrame` protect
the resulting wire cleanup and ready-chat behavior. Validate those cases with optimization
enabled when qualifying a device toolchain.
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
`transport.resyncRequired` fallback. Same-runtime snapshots and rebaselines must preserve both the
aggregate authority revision and the live-activity revision; a negative or regressed revision re-enters
bounded synchronization instead of installing over newer state. Malformed owned snapshot/rebaseline
frames, transcript tails above 512 items or with invalid bounds/nonempty unique identities, and
authoritative queue projections with more than 32, empty, or duplicate identities fail closed into this
same bounded synchronization path rather than advancing
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
every transcript. Its optional `activeSince` is stable for one continuous active period,
while `updatedAt` remains live freshness; an opened chat receives the full sequenced snapshot and
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
auth prompt/event parsing, browser-callback submission, and operation-to-target retention through
completion or confirmed cancellation. Dashboard Providers uses the Gateway's canonical global
catalog and can configure globally installed provider extensions without opening a session;
chat/session provider settings request that session's isolated catalog. `providers.changed` is the
invalidation edge after the Gateway reconciles global provider resources, and the next presentation
read remains the authoritative snapshot rather than a client-side union of session catalogs.
Because provider login can synchronously emit presentation or completion events before
`auth.begin` returns, a four-operation, 64-element, 16 KiB pre-response quarantine promotes only the
newest admitted operation and is synchronously revoked on failure, cancellation, or profile
retirement. `auth.begin` carries a command ID, while the active operation belongs to the authenticated
device identity rather than a disposable socket. Transient transport retirement clears prompt delivery
but retains the operation/target/provider; foreground or active reconnect calls `auth.resume`, which replays the
Gateway's latest bounded state without restarting Pi login. The matching provider sheet can reattach only to that
provider and target, preventing duplicate automatic OAuth starts after a presentation is recreated. When the app
has lost that operation ID (process loss or a fresh coordinator), a new `auth.begin` recovers the Gateway's active
operation for the same device/provider/auth-method/target and answers `recovered: true`; the sheet then shows
**Restart Login** and **Cancel Login** above the replayed flow, which is itself the Continue path. Restart sends
`replaceOperationId` for that exact operation, warns that the previous authorization link becomes invalid, and the
sheet adopts the successor so closing it cancels the live login. Changing an answered provider choice uses the
same exact-operation replacement. Because recovery is keyed on the Gateway, a fresh
command after an uncertain begin or restart response cannot admit a duplicate. A cancellation whose
acknowledgement was lost in transit is kept in a bounded four-entry list and retried on `auth.resume`; a definite
rejection settles it and profile clearing drops it. Leaving Tron
for the external browser does not cancel the operation; active-scene sheet dismissal still cancels it, while a
profile replacement revokes all local authority. The Gateway bounds login lifetime to 15 minutes. Prompt and
browser callback submission are single-flight on iOS, and the Gateway treats bounded late
auth acknowledgements as idempotent no-ops so completion/response reordering cannot surface a
misleading operation-not-found error.

`ProviderOAuthBrowserSession` owns the system authentication browser. It admits only HTTPS authorization
URLs with a Gateway-derived HTTP loopback callback descriptor and binds fixed-port POSIX sockets directly
to `127.0.0.1` and/or `::1` (`IPV6_V6ONLY`) before browser presentation. Network.framework's fixed
`NWListener` local-endpoint path fails with physical-device `EINVAL`, while wildcard listeners would expose
callback bearer data to non-loopback interfaces. One dedicated serial socket queue owns nonblocking
accept/read/write work, Dispatch-source cancellation closes descriptors before restart admission, and a
browser-session generation rejects callbacks from replaced system sessions. A browser session is view-owned, so a
restarted login can bind the same fixed port from a new session; retired listeners are registered process-wide
and every start joins them before binding, otherwise the rebind races the previous close and fails. The socket owner admits at most
eight clients, retires incomplete headers after five seconds, accepts one bounded exact-path GET, and uses a nonce-only
`com.tron.mobile.oauth` redirect to close `ASWebAuthenticationSession`; authorization codes never enter the
custom-scheme URL. iOS forwards the complete callback URL only to the matching Pi `manual_code`
prompt. When Pi exposes no such prompt, the app sends only the callback ID and encoded query to the
Gateway's fixed-destination relay. The app never handles tokens or credentials, and callback values
remain memory-only. Provider and model pages publish as one atomic catalog. Provider projection rejects
more than 1,000 rows, 4 MiB of strings, or duplicate IDs. Model projection rejects repeated cursors,
more than 50 pages, 25,000 models, 16 MiB of retained strings, pages above the requested 500 rows,
and duplicate compound identities. Gateway cursors bind offsets to an exact whole-catalog fingerprint,
so mutation cannot mix generations. Model pickers key rows by that compound identity, so equal model
names from distinct providers remain stable. Profile retirement synchronously discards catalogs and auth routing.
Its forced refresh and logout commands use the shared receipt executor before reloading the
exact captured target. Account usage is a separate bounded `provider-usage.v1` read: the Settings
presentation requests the selected target once for its configured-first list and the existing provider
configuration sheet requests one exact provider snapshot for detail. The projection is never merged with
session context usage or local token totals. Capability admission avoids a failed RPC on older Gateways;
a small ProviderUsageReadController owns latest-request admission, while profile, target, foreground,
and managed-presentation activity fences clear or reject late account data.
Detail does not seed data from list rows: only its own admitted read can publish measurements,
so opening the sheet across an account change cannot resurrect an unverified list snapshot.
Supported, unsupported, stale, rate-limited, and authentication-required statuses remain explicit.
The provider catalog's `usageSupported` flag marks rows that will answer, so a supported configured row
reserves its usage line with an animated skeleton and crossfades to the resolved summary instead of
growing mid-load; a failed read retires the skeleton, and a Gateway without the flag reserves nothing.
A balance-only provider (one that reports balances but no windows) keeps the same row treatment: the
line shows the primary balance's currency-formatted amount followed by its label (`$0.03 Available`), and the detail sheet lists every
reported balance as a window-shaped row whose secondary balances carry an emerald share bar and a
percentage-of-primary caption, or `Deficit` when the amount is negative. A negative amount formats as a
negative currency value. The catalog's `localOnly` flag marks a provider whose models all resolve to a
loopback base URL; its list row shows an emerald infinity glyph in the usage slot and its detail sheet
shows an `Unlimited` local-models row instead of any snapshot, loading, or failure copy, without a
Gateway usage capability or a `provider.usage` read.

Compaction Settings owns automatic compaction and advanced reserve/recent controls. The existing scoped draft
store/coordinator owns edits, target switching and confirmed writes. `compaction-policy.v1`
adds independent thinking (default: inherit conversation), bounded optional focus and an
explicit standard reset that preserves budgets; project scope also offers deletion of thinking/focus
fields to resume global inheritance. Deletion intent is per field: editing thinking after
choosing global values must not turn the untouched focus back into a project override.
The scoped response's global document provides the inheritance preview, and a confirmed save
installs the authoritative resolved values while consuming one-shot edit intent. The editor
uses the Gateway's UTF-16 limit. The effective
thinking level is the SDK-resolved request level, not a provider guarantee (Off may omit a reasoning
field and leave provider defaults in control). Thinking/focus apply at the next compaction; enabled/budgets apply at idle prompt or manual
compaction admission. A live authoritative session projection separately displays the selected
model, requested/resolved next thinking, actual current budgets and captured running policy.
Global Settings does not derive a model from saved defaults. Extension-override and invalid
settings warnings are displayed without claiming authority over independent extension generation.
Snapshot admission validates policy bounds, admits captured active policy during the
running successor handoff, and rejects it on an idle snapshot; existing
sequence/runtime-generation reconciliation prevents a delayed compaction snapshot
from resurrecting a completed operation. `SettingsDraftStoreTests` and
`SessionSnapshotEventAdmissionTests` cover reset, bounds, decoding and retirement.

Agent Defaults' Model Defaults section exposes a separate forced-refresh action row below its
model controls for the displayed catalog target, reloads successful updates and cached fallbacks
before reporting provider failures or timeout, and
never mutates the settings draft, saved defaults, or credentials. Models with
`contextWindowLimits` expose a per-provider/model sparse context-window default;
project edits carry the captured session ID when available so the Gateway can
validate project-scoped model settings. The effective value opens the shared
continuous glass slider with model-default/inherited reset, exact bounds, and
rounded detents, without inventing a mobile-side maximum. The editor combines
catalog capacity with the selected settings scope's `contextWindowMinimum`;
dismissing an edited slider updates the local settings draft, not persisted defaults.
Defaults affect new/cold-resumed sessions or explicit resource reloads, not already
live sessions. Manage Session exposes the same capability only when the Gateway
advertises `context-window.v1`; its idle mutation captures provider/model identity,
snapshot revision and runtime generation, and waits for the authoritative snapshot.
Late saves cannot overwrite another client or survive a model/runtime round trip.
The server's warnings expose stale saved preferences, pricing, and the SDK's
first-assistant durability boundary for new sessions. Snapshot admission accepts
bounded saved overrides outside refreshed capacity while requiring policy identity
and effective usage to agree with the snapshot. Context budgets control future context assembly and
compaction only: they do not restore history already summarized, and larger
windows may consume more provider allowance or cost. `PackageConfigurationCoordinator` solely owns target-keyed inventories,
update markers, newest-list/check/mutation admission, event-only invalidation, closed
install/update/remove wire construction, and confirmed exact-target reload effects. Package presentation performs one bounded pass over the four canonical resource arrays for totals and friendly type summaries; nested type sheets expose names and source/scope copy, while paths, metadata, and additive unknown fields remain preserved behind Technical JSON disclosure. The separate
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
Custom-model autosave validates and writes under one lifecycle admission, without restarting the
Gateway. Registry activation remains a separate manual Gateway action. Incomplete provider identifiers
and malformed/incomplete advanced JSON never reach replacement; the previous valid document remains
canonical. The stable provider editor identity is independent of its editable name. Configuration screens discard cancellation while preserving current-operation errors. `ComposerDraftCoordinator`
is the sole owner of composer text, the single staged skill, staged attachments, upload admission, editor requests, and submission state.
Text, unsent attachment payloads, and skill selection are keyed by explicit `ComposerDraftScope(profileID, sessionID)` with monotonic revisions and a deterministic 24-inactive-draft LRU. For an image-bearing canonical user message, the Gateway invocation receipt retains the exact submitted text separately from Pi's canonical text, because Pi appends generated resize-coordinate guidance to model input. Transcript presentation uses that exact receipt-owned authored text and leaves attachment parts and canonical/model-facing history untouched; it never guesses by matching or stripping annotation-shaped user text. Live text is never truncated; ordinary submission and extension-editor synchronization reject text above the Gateway's 192 KiB UTF-8 boundary before draft clearing, responder changes, layout ownership, optimistic-row grafting, or transport. The complete draft remains editable, and the owned `ComposerDraftStore` checkpoints up to 256 KiB of UTF-8 text plus the existing 10-item/25 MiB attachment budget in Application Support, under a 24-draft/256 MiB disk LRU. Its versioned manifest contains metadata only and points to separate exact-byte payload files beneath SHA-256 profile/session path components. Atomic protected writes, backup exclusion, and fail-closed malformed/oversized cleanup follow the disposable cache conventions, but this store is separate from `SnapshotCache` and contains no transcript, event, credential, source-path, thumbnail object, or Gateway snapshot state. Cleanup and explicit removal inspect the actual root/profile directory entries before touching a scoped path; a symbolic-link ancestor cannot redirect deletion into another in-sandbox owner. This guards corrupted local trees, not adversarial filesystem replacement between checks. Drafts survive route close and process restart until exact session/profile deletion or bounded eviction. The composer derives one immutable search index from the already bounded authoritative `session.commands`
catalog; it never fetches or mirrors resources. Catalog readiness is owned by the exact mounted presentation token, is revoked while a reload is pending, and refreshes on `session.resourcesChanged`, so A→B→A navigation cannot retire a retained draft skill from another session's transient catalog. Skill discovery is exposed only when the connected Gateway advertises
`skill-prompt.v1`. `AppModel` rechecks that capability at submission admission for both explicit invocations and the coordinator's staged-skill fallback, before draft or submission-ledger mutation (`AppModelComposerAdmissionTests`). Rejection retains the draft and selected skill; asynchronous picker cleanup is not command authority. `@` token detection filters only `source == skill` entries and strips
the transport-only `skill:` prefix, while leading `/` completion excludes skills and inserts editable native command
text. The one staged skill is captured separately from user-visible text, replaced atomically by a newer selection,
restored only after a definitive send rejection, and cleared if the authoritative catalog no longer contains the exact
entry. Skill and leading slash-command choices are mutually exclusive. Text, one staged skill or prompt, and attachments are each independently sendable; resource-only and attachment-only submissions render their chips without an empty user-text container. The Gateway receives the resource's raw name as bounded prompt metadata and owns Pi invocation expansion, keeping optimistic,
queued, edited-queue, and canonical text identical. The inline glass picker remains inside the sole composer safe-area owner, below attachments and the skill chip but immediately above the input row. One permanently mounted, bottom-aligned measured host keeps ordinary editor-only height changes animation-disabled for UIKit caret ownership. Attachment chips, selected skills, and command/skill result panels use one value-scoped host-height transition during ordinary editing. An admitted submission disables those child clocks and gives its single outer host sole ownership of composer collapse. Its measurement identity includes the exact submission generation, so an unchanged one-line composer still settles explicitly while multiline TextKit updates retarget one revision-checked animation; no two-frame unchanged-height guess can release the layout early. During an admitted submission, the outgoing row occupies its complete final layout immediately; only that row's opacity and 20-point vertical offset animate over 280 ms while the existing composer host and UIKit keyboard keep their established collapse. Its ordinary-prompt layout uses the same full-width proposal as the canonical user row, preventing long text from rewrapping and changing height during replacement. Text, skill/resource chips, photos, and files translate together inside that one row, with no global-frame registry, duplicate overlay surface, or animated row-height owner. The attachment strip retains an ordered local presentation projection while canonical draft state changes: ordinary batch IDs enter sequentially on a 40 ms cadence through a centered 0.5-to-1 scale/fade, removal uses the exact reverse transition, and stable sibling IDs reflow in the same smooth transaction. Submission removal installs atomically beneath the held outer height; the last chip still drives the bottom-aligned host collapse. While the keyboard and picker are both visible, the picker keeps its existing internal scroll owner but caps itself to three rows and the native editor to four visible lines, preventing the panel from displacing the input below the keyboard without changing transcript geometry ownership. Multiline measurement remains direct, UIKit owns keyboard motion plus the one responder, and UTF-16 selection and caret geometry stay native. The native bridge reads the coordinator's live per-draft text revision before publishing UIKit delegate callbacks, so autocorrection, marked-text, or selection callbacks emitted while a submission clear or another authoritative mutation is awaiting `updateUIView` reinstall canonical text instead of repopulating a superseded draft. The active lease is the immutable session/presentation generation plus lifecycle generation.
Resource detail presentation keeps description and content on the primary sheet. Its leading info button opens
`ComposerResourceInfoSheet` through the existing managed-sheet owner, using metadata from the same admitted
`session.commandDetail` response rather than a second fetch or store. Info and Done share the title's caller-supplied
accent, including prompt entries and canonical resource chips. The secondary sheet starts at medium and can expand.
Prompt and skill details retain the complete admitted Markdown body in their content container, with the sheet
owning scrolling. Only extension command source has a local excerpt limit: 480 characters or 10 source lines,
whichever is reached first. Short extension content remains complete. A muted-gray footer appears only when
content was actually omitted locally or by the Gateway. The 96-KiB transport admission, invocation identity,
canonical resource, and loaded byte-count facts are unchanged. `ComposerResourcePickerTests` covers full prompt
bodies and extension-only excerpt boundaries; `SessionSheetPresentationTests` verifies the long prompt reading
surface.
Unsent attachment bytes and metadata belong to draft scope. Prepared previews, concurrent upload admissions, editor requests, and canonical presentation handoffs remain exact-presentation scoped; the one bounded pre-canonical queue recovery handoff is keyed by `ComposerDraftScope`, while admitted submission transport is keyed by that scope plus lifecycle generation. Its original presentation target is origin metadata only: route revocation/remount projects the same sending or accepted lifecycle and never resends it. Exact canonical/queue settlement, definitive rejection, lifecycle/profile/session retirement, or bounded safe eviction retires that owner. Revocation cancels upload work and discards disposable Gateway upload IDs without erasing the scoped strip. Fresh photo and file selection installs one stable local chip and its bounded exact bytes before starting HTTP; Gateway upload identity is a disposable field on that chip, never SwiftUI or draft identity. Capacity, network, cancellation, and unknown transport failure therefore leave one upload-required chip rather than losing or duplicating user input. A newly admitted mount restores chips only for that exact profile/session target, rebuilds bounded thumbnails through the existing off-main preparation seam, and reacquires every Gateway upload ID before enabling submission. Restore never auto-sends; transient re-upload failure retains the payload and chip for a later mount/retry. Definitive rejection merges by stable chip ID, preferring the remount's current fresh/missing upload representation; a captured chip absent after route replacement becomes upload-required rather than reusing its stale Gateway ID. In-flight bytes remain recoverable through a definitive rejection, while transport acceptance or authoritative queue/canonical settlement removes the captured submission from the durable draft without disturbing newer edits. Until canonical delivery, one bounded local queue handoff retains enough accepted input to restore explicit user review if the authoritative runtime generation is replaced; it never replays transport automatically. The system photo picker and its import loop share the draft's 10-item selection ceiling. Completed plus active uploads are still admitted against one 10-item/25 MiB draft budget before network work; selecting photos does not bypass capacity already occupied by files or other attachments. Each image chip uses
an orientation-correct 192-pixel PNG preview with 1 MiB decoded/encoded ceilings, so normal composer rendering
never decodes the full attachment. The original bounded payload remains scope-owned for persistence and the existing
explicit preview sheet, which installs the thumbnail immediately and prepares at most one 4,096-pixel/64 MiB image
off-main through the same cancellation-aware media preparation slot before publication. HTTP response bodies
have a separate 64 KiB ceiling and must return on the captured connection epoch. Uploads are independent;
local invocation order owns chip order while each completion updates only its exact stable chip. An exact-target active upload disables send and is rechecked synchronously at submission admission; a failed upload releases that active gate but its upload-required chip blocks only a prompt that still includes it. Removing a fresh or restored actively uploading chip cancels and retires only that chip's admission immediately, so discarded work cannot keep send disabled; every late successful HTTP completion that can no longer claim its exact chip/presentation discards the resulting Gateway staging ID. A multi-photo selection stages every chip in order before the proven serial HTTP transport begins, avoiding global Gateway body-capacity contention while keeping chip publication immediate. Transport failure releases the active gate and never starts another blocking upload from a send attempt; exact bytes remain available for explicit removal or remount retry. Text remains editable, removal and later remount retry remain available, and no transport failure clears text, attachments, or the staged skill. A confirmed prompt removes only the IDs captured by its submission and never clears newer text or attachments. Admission installs one exact-target,
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
container geometry on the first measurement. The native multiline editor publishes its capped one-to-eight-line size through synchronous representable fitting rather than a deferred height binding, so clearing or restoring text cannot create an empty old-height composer frame. Local admission synchronously grafts only its frozen lifecycle row onto the currently complete installed transcript, then the normal newest authoritative projection replaces it; canonical generations, prepared text, runtime rows, queue facts, and source windows never advance through that graft. Queue presentation aliases are frozen into the same installed commit as its handoff and queue rows, so rendering never combines an older transcript with newer coordinator identity. The admitted operation ID aliases its exact newly admitted queue item to the immutable outgoing presentation ID. Before that response arrives, exactly one current nonbaseline queue candidate matching behavior, text, optional resource invocation, typed attachment counts, and any supplied exact attachment descriptors may borrow the ID for visual continuity only; ambiguity, mismatch, malformed data, or a conflicting operation response clears the provisional alias without settling admission or canonical causality. Aliases remain bounded to the Gateway's 32-item queue capacity and are retired only when their authoritative operation IDs disappear or the presentation is revoked. A confirmed local edit,
remove, or clear retires continuity only for its exact changed operation IDs. If a canonical boundary arrives before that
command resolves and its continuity decision depends on the outcome, the newest complete capture is held behind the installed
queue boundary: success retires and excludes the changed lineage before installation, while failure restores exact settlement
before installation. Pure reordering preserves lineage. Pre-existing or unrelated queue rows retain Gateway IDs. Canonical transcript IDs remain immutable semantic authority; one bounded causal map may assign an exact operation-bound canonical ID (or one unique installed pending replacement) the prior lifecycle's physical SwiftUI row ID. Repeated text and ambiguous candidates cannot establish that alias. A prompt lifecycle consumes its role-aware
entrance only when the outgoing, pending, or queued representation first appears. That receipt is owned outside lazy row-local state and retained only while the lifecycle identity remains installed, so eviction/remount and opening-to-ready changes cannot replay it. Structural transcript updates do not inherit unrelated ambient transactions: suppression is value-scoped to installed-projection identity changes, while explicitly tagged row entrances and shallow tool-chip motion retain their own animation ownership. Native Liquid Glass touch-down and continuous drag transactions bypass that projection-only transform. Prompt submission inserts one already-sized outgoing row at its final horizontal alignment, then applies only a short straight-up translation and fade to that complete row. Prompt text, skill/resource chips, photos, files, and steering/follow-up card content therefore move together without source measurement, destination tracking, scaling, overlay bridges, duplicated Liquid Glass, or animated row height. Canonical authority may advance during the entrance; the exact causal physical host retains the same transform owner while queued/pending/outgoing payloads replace beneath it atomically, so a fast local acknowledgement neither cuts the entrance short nor replays motion. Composer geometry owns one generation captured before mutation: pinned readers use disabled tail coupling, detached readers retain the first visible semantic locus with zero tail writes, rapid accessory/submission retargets coalesce, and direct interaction or presentation reset cancels the generation. The outgoing graft and composer collapse share that owner instead of racing a second smooth follow. A bounded layout identity separates transcript/stream/tool/queue/runtime shape from authority-only metadata, so context/model/revision updates neither rebuild projection nor arm scroll settlement. Canonical settlement consumes the exact entrance-suppression receipt and installs directly visible in the same physical row. An ordinary lifecycle-to-canonical prompt replacement stays atomic and animation-free because the lifecycle row already renders the canonical bubble; only a queued-card lifecycle row (a queued prompt, a steering/follow-up pending or outgoing row, or an ordinary prompt queued behind compaction) cross-fades and shrinks into its sent row inside that retained host. Unrelated transcript projection and scroll geometry never inherit the entrance transaction. Definitive rejection restores outgoing text before newer input,
while a possibly-sent transport outcome retains the row and captured IDs. Once transport crosses the wire, its exact submission admission owns completion across connection retirement; a returned operation ID becomes canonical reconciliation identity. Before operation acknowledgement, bounded text and attachment evidence bridges projection ordering. A later sequenced operation failure restores the exact accepted submission once, retires its lifecycle row, and releases the composer. The exact active target owns restoration and error presentation. If lifecycle or task cancellation wins after optimistic admission but before the transport operation begins, that boundary is definitely not sent: it restores the captured draft and attachments, retires the local lifecycle row, and releases the composer for an explicit retry. Cancellation after transport admission continues to use the socket's queued/sending provenance and command receipt rather than guessing from reconnect timing. Extension editor requests auto-apply only to an empty exact draft; nonempty drafts require the
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
resource-location, compaction, and model/default screens share `SettingsAutosave` bindings and
`ConfigurationAutosaveCoordinator`. Only user input admits writes; loading projections and switching
scope never do. Input bindings pin profile and scope generation separately from accepted receipt
revisions, so a scope round trip revokes stale input without invalidating an unchanged accepted write.
The profile-owned queue briefly debounces input, serializes configuration mutations, merges consecutive
sparse leaf patches for the exact target/session, and replaces pending complete custom-model documents.
Reversions and explicit null resets are retained even while an earlier write is in flight. Up to 64
queued/failed batches are retained; backpressure rejects further edits visibly rather than dropping
accepted commands. Sheet dismissal flushes the debounce but does not cancel accepted commands. Profile
retirement revokes queued dispatch and stale completions; the existing receipt owner settles any write
already sent. Failed edits remain retryable, and uncertain outcomes require an explicit Retry rather
than automatic replay. Only the latest observer of a coalesced batch is retained. This is an in-memory
command queue, not a persisted settings mirror. Exact-revision completion protects newer typed input.
Sparse user-event patches avoid materializing untouched inherited values. Executable resource paths
and write-only proxy URLs are accepted when their text editor closes, never from partial strings;
clearing is explicit and proxy drafts are scrubbed after confirmation. Numeric inputs likewise stage
plain integer text until editing ends, rejecting malformed/overflowing strings instead of writing a
parsed prefix or a partial budget. Their captured input scope and binding retire together on profile
or scope changes, even when the successor's value is identical. Global defaults
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
Canonical and runtime ownership is preserved through assembly: only canonical rows enter
`ChatCommittedLedger`; streaming and runtime-only rows enter `ChatLiveRegion`. Matching group or
producer-segment metadata may preserve identity only within one of those ownership regions and can
never move canonical history into the live suffix or runtime calls into the ledger. A finalized group's
reported member count is declaration completeness, never execution liveness, so a partial historical
page cannot create a spinner. Runtime patch sites carry their canonical/live region and exact row index.
Rendered identity spines and sets are cached/split so ordinary text/thinking/image streaming updates
share the canonical rows and identities while the kernel constructs only the isolated live suffix.
Markdown has one pure `Sendable` cold presentation model. It classifies the existing block dialect,
constructs each inline `AttributedString` once with the established plain-`Text` fallback, and supplies
the exact immutable document to `TronMarkdownView`. Table header and body cells use that same prepared
inline representation, preserving bold, italic, combined emphasis, strikethrough, inline code, links,
and escaped literals instead of displaying Markdown delimiters. Their attributed storage participates
in the existing document byte accounting; rendering does not reparse cell strings. Markdown soft
source wraps reflow to spaces only in attributed presentation; blank paragraph boundaries and explicit
Markdown hard breaks remain breaks (including inside quotes), while backtick/tilde fences and indented
code retain literal lines. List continuations prepare one inline value per item, not per source line.
The exact source continues to own block identity, accessibility text, and source-backed copy actions;
native text-selection copy follows the rendered text, including its reflowed spaces. Commit bodies
use the same block boundaries to reflow prose only, leaving lists, quotes, code, and Git trailers
verbatim without adding Markdown styling. Thinking traces opt out because their line boundaries
carry their own meaning. Table sizing, horizontal scrolling, ragged-row padding, and block identities
remain unchanged.
Block and list identities combine exact content with UTF-8 source ranges, so equal duplicates remain
distinct. Code-header progress is eligible only for the one unterminated fence while its owning response
is still streaming; closed fences settle immediately and every fence is terminal when the response settles.
An unchanged exact block retains identity and its subtree-local interaction state; changed
content or block type resets identity, intentionally clearing `CodeBlock` copy confirmation and any
other stale subtree state rather than transferring it to different source. Code-copy feedback is owned by
that mounted block's lifecycle: its view task resets only the current tap generation after 1.2 seconds,
and disappearance retires the mount before any delayed reset can publish; a retained block reactivates
that same owner on appearance before accepting another tap. The projection worker now
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
Mounted notification details use the separate `ChatDetailDocumentPreparation` owner: it keeps one
immutable source document and one cancellation-drained parser for the active detail sheet, retains the
last complete document during replacement, and publishes only when the exact route, activity, and
preparation generation remain current. Its mounted callback is diagnostic evidence of attachment, not
proof of a rendered frame; native sheet chrome, detents, selection, and Markdown layout remain owned
by the existing detail view. Compaction summary details keep this full Markdown content in the original 12-point rounded container with 14-point inner padding, a flat tinted fill and border instead of Liquid Glass. Provider error footers retain their exact raw message as detail content; native title measurement promotes only a clipped footer to an interactive Liquid Glass surface, while short errors remain flat. Any streaming fragment carrying a tool-call ID—including malformed text or extension content—is
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
groups disposable opening, import, queue-deferral, and entrance-ledger state. Canonical truth remains
in Gateway/Pi; `SessionPresentationStore` owns the admitted mounted iOS authority, `AppModel` is its
cross-domain façade, and `ChatTranscriptPresentationStore` owns only immutable disposable rendering. Typing, focus, geometry, toolbar, and
sheet invalidations reuse the installed immutable value, while streaming revisions are
serialized/coalesced off-main and observable installs are limited to a display-frame boundary. Exact-tag waiters let prepend retain
its existing semantic-alias and layout-epoch transaction. This adopts the useful
pre-Gateway principles of a non-render-path measurement/projection owner and coalesced
stream updates without reviving the retired Engine, local event reconstruction, or scroll
proxy architecture. Explicit scroll commands keep their exact target until their opening, catch-up,
semantic-restore, or prepend settlement evidence arrives, then release only that token on the next presented frame. Every physical row, including an ordinary outgoing prompt, remains in the same `LazyVStack` across canonical acknowledgement and successor insertion. The surrounding transcript stack registers one target layout containing both the lazy rows and eager marker; neither child registers a competing layout. Explicit physical row IDs remain the materialization targets. Ordinary sends target the exact natural-height prompt, not a sibling marker positioned using estimated lazy height. The `ChatLayoutTransaction` shared by row admission, keyboard, and composer settlement must finish before displacement can retarget that lease: intermediate lazy estimates cannot interrupt native realization. Canonical acknowledgement consumes the existing entrance entitlement and transfers the semantic evidence identity without admitting another physical materialization. While an exact terminal row owns its lease, its target includes the full 12-point affordance and the full-size eager marker overlaps that same empty band. Both targets end at the identical physical edge; releasing ownership never splits or recombines fractional heights that pixel-round into a second movement. The outgoing row's visual-only fade/translation cannot alter target geometry; other compact row entrances retain bounded growth. Materialization is necessary but not sufficient: after every participant settles—including the revision-current composer measurement and any keyboard dismissal—two unchanged display boundaries and a final evidence check must cross before the binding is cleared. One mode-qualified native size-change anchor then owns continuous streaming and payload growth. A genuinely new lazy physical row
may lease its exact physical ID; compatible status, progress, and completion updates retain that
`ScrollPosition` target, while physical replacement releases it through the exact token before native pinning resumes.
Physical-spine reconciliation also transfers active and pending leases to each host's current semantic geometry ID.
Tool finalization/grouping can change that ID without replacing the native host; waiting for the retired ID would unnecessarily hold the target until its fallback.
This transfer invalidates old release evidence, accepts a current-epoch sample in either callback order, and neither replays the native target nor extends its fallback deadline.
`ChatScrollCoordinatorTests.toolHandoffTransfersMaterializationEvidence` and `pendingToolHandoffTransfersMaterializationEvidence` protect this boundary independently of entrance animation. A retained pinned presentation re-enters physical-marker positioning and accepts only same-presentation evidence before repair, while a genuinely displaced reader remains anchored; anchored readers receive no automatic follow. Stale applied targets are retired when the native tree is rebuilt, and projection layout epochs invalidate delayed marker callbacks. Compact non-prompt rows may use measured height admission so existing pinned content moves continuously rather than jumping. Outgoing prompts of every size instead use the same full-height, row-local fade/slide entrance. Its vertical reveal clip owns a
layout-neutral effect gutter: the hidden row remains bounded, but settled Liquid Glass shadows and
native press expansion render beyond the semantic row instead of meeting a permanent rectangular
boundary. Payload-only prompt updates remain layout-animation free. The unified notification row retains one physical and child host when
active compaction becomes canonical compaction; progress, icon, title, and tone update
inside that shell without animating unrelated projection updates.
Attachment, skill, and resource accessories animate through one
value-scoped composer-height transition, while editor-only height changes remain atomic
for UIKit caret ownership. Live composer-height samples stay in a non-observable settlement ledger,
so a structural animation does not invalidate the transcript tree on every display frame. The prompt row and its spacing install at full natural height in one layout pass; only a transform and opacity change afterward, eliminating a second geometry clock. A mounted
reconnect is live only after its exact authoritative subscription is restored; retained snapshots stay
readable during retry but never authorize prompt, upload, abort, or queue mutations. Foreground entrance
suppression advances only after the mounted aggregate succeeds, so a failed reconciliation cannot consume
visual continuity for a later live row. Queue mutation responses are confirmations only: the existing
mounted synchronization path must observe the newer queue revision before local mutation presentation
state retires. Producer-triggered extension/session-input messages occupy one compact
status row in the transcript and retain their full message, origin, canonical identity, and
JSON payloads in the existing detail sheet. Tool calls, progress, and results join by `toolCallId`.
The Gateway stamps every live and canonical declaration with a producer-owned `toolSegmentId` for one visible
conversation segment. The segment survives lifecycle-operation rotation across tool-only continuations and rotates
at user, visible assistant/custom, and compaction barriers. A provisional no-match generation covers the gap until
an assistant receives its stable presentation identity. The authoritative snapshot also names the exact segment owned by the currently
running agent tool segment, excluding retry, compaction, and settlement phases. An unresolved declaration remains an active **Invocation** only when it belongs to that segment;
starting a later prompt, retry, or compaction cannot revive an unmatched tool left by an interrupted older run.
Older compatible Gateways without segment authority retain the existing broad active-phase fallback. Read-only
child transcripts derive the newest declared segment from their canonical page and apply parent process activity
only to that segment; a later canonical turn or barrier interrupts older unresolved calls. Only equal
nonempty segment IDs authorize distinct finalized groups to share one consecutive tool-only display run; missing or
conflicting identity fails closed to separate rows. At the canonical/live
boundary, a bounded display-only composition may fuse directly adjacent runs with one equal segment, preserving
the first run's physical host while canonical and live authority remain separate. Canonical descriptors win
handoff duplicates, and any member running keeps the aggregate spinner/count live until the same host settles.
Visible thinking, text,
user input, notifications, and transcript barriers end the physical run even inside one segment. Cold canonical
projection derives segment boundaries from authoritative conversation input, so foreground catch-up and continuous
delivery reduce identically without speculative adjacency. A bounded previous-install call/group lineage aliases
only the physical SwiftUI host when finalized grouping arrives after execution starts or a bounded page boundary
changes the first visible group; semantic run IDs remain producer-owned. Running/completed status changes keep one capsule and one
stable glass surface while shallow icon, text, and timing slots animate in place. Shallow streaming and tool-state
installs with an unchanged physical row spine retain their semantic layout epoch; only structural row changes clear
geometry evidence. Streaming inline tokenization is cached per mounted source, and thinking measurements ignore
subpixel feedback, avoiding full visible-tree geometry churn during each fade tick. The projection worker also
constructs and validates the immutable installed indexes off MainActor; publication is a shallow complete-value swap.
Collapsed rows retain structured
request/response values without eagerly formatting JSON strings. Opening a detail sheet derives a
bounded semantic presentation only for that selected tool: exact lowercase built-ins foreground their file,
command, query, diff, and readable result. Extension-authored Pi tool labels are projected separately from canonical
invocation names and become the native row/detail title (for example, `subagent_wait` displays as **Subagent Wait**),
while arbitrary extension tools may foreground only the first
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
surface, and removal is an explicit ID list. Ambient extension statuses, widgets, and service activity are not transcript or composer content. Retained extension *state* is reachable only through one explicit user-opened **Activity** sheet: one compact composer control appears while presentable retained content or admitted subagent activity exists, renders nothing inline, and opens a read-only list ordered as running subagents, non-subagent retained state, and completed subagents. String widgets, bounded read-only widget frames, and owner-attributed keyed statuses are grouped by producer; retained state whose trusted source is `npm:pi-subagents` (with an optional version suffix) is excluded here because the native subagent tracker owns that presentation. Discrete extension events remain notification pills, so a status counter update never becomes a chat row. The semantic extension host remains the transport owner for interactive prompts, editor leases, and form v1 interactions. A form is one authoritative, epoch/revision-scoped batch of one to four choice questions. The app keeps a bounded device-local ID-keyed draft for only pending interactions and presents each question as an independent horizontally swipeable page beneath fixed page dots and index; each page owns its own vertical scroll and direct option/Other rows. Closing the sheet preserves that draft and never settles or cancels the Gateway interaction. The mounted chat route is the sole sheet owner: pending interactions are withheld until the transcript crosses its first ready frame, then presented once, so a sheet can never cover and cancel session opening. Its managed item-sheet identity includes the exact session, interaction ID, host epoch, and presentation revision; a same-ID successor therefore retires the old presentation token before replacement. Post-await sheet effects consult that shared token authority; a coordinator without a token fails closed, while only standalone sheets use ambient activity. Local dismissal records an exact scope suppression, while the pending Tron-owned or explicitly admitted compatibility `ask_user` tool chip sends an explicit reopen intent to that same route and matches by operation plus extension owner (with one unambiguous admitted-owner fallback for cold canonical segments). After submission, canonical tool-result details reconstruct the questions and answers read-only, reuse the form title in the sheet chrome, tint the completed sheet green, and keep the submitted choices selected. The toolbar submits every answer atomically only after the whole form is complete, then clears the draft. Drafts survive navigation and app restart but cannot outlive authoritative interaction retirement or a Gateway process loss, because the in-memory extension promise itself is not durable. The app never mirrors or replays the authoritative form; read-only extension presentation does not create a Manage Session destination.

Subagent activity is a separate package-neutral, disposable projection. Only admitted synchronous/asynchronous subagent lifecycle producers publish bounded `SessionProcessActivity` rows plus one shallow `SessionProcessOverview`; assistant bash remains ordinary transcript/tool activity. `processOverview` is the shallow snapshot authority; `processActivities` carries its bounded nonempty rows and is omitted when the overview is hidden. Compact `session.processActivity` deltas carry an optional exact upsert, bounded explicit removals, and the overview's same revision and observation time so replacement and output churn cannot tear composer visibility. `SessionPresentationStore` applies that set atomically, sequence-latches rows, prevents terminal resurrection, resynchronizes on a rejected row/overview pairing, and deliberately does not rebuild transcript presentation or issue a scroll command. The Gateway owns the exact five-minute recent boundary and publishes expiry; a local monotonic deadline may only hide a stale recent button early and can never extend authority.

One leading unified activity control inside the composer's existing `GlassEffectContainer` replaces every per-extension pill and the former separate subagent control. Its icon precedence is active admitted subagents, presentable non-subagent retained state, then non-expired recently completed subagents; the shared composer container animates one coherent icon selection so button appearance and deadline disappearance also resize the input bar continuously. The orb/extension glyphs crossfade inside the same glass identity. `ChatViewScrollHarnessTests.recentSubagentExpiryAnimatesComposerWidth` observes intermediate native input widths on both insertion and expiry; disabling the shared animation fails that regression. A permanently mounted control owner receives optional overview and admitted-row facts, so authoritative final-row removal, projection loss, and the local recent deadline all remove the orb through one scoped spring transition rather than removing its transition owner. Local expiry state is keyed by the exact recent deadline, preventing a canceled stale timer from hiding newer process evidence. The matched-geometry Liquid Glass transition is the sole geometry path between the composer and the control; orb content only fades, avoiding a competing move/scale transform. It renders a sparse sphere of larger seafoam points while any admitted subagent is active and eleven rounded continuous strands retaining the original spherical ribbon wave while only recent terminal subagents remain; the stable Canvas owner crossfades both live geometries during that mode change and returns to rendering only the selected geometry after settlement. Its tiny bounded frame draws synchronously so Canvas pixels and the glass host commit in the same presentation transaction during transcript churn. The retired separate Pi Subagents composer pill and extension-only route have no source route or fallback. This does not suppress transcript evidence: every actual `subagent` invocation remains an ordinary tool chip and opens the normal tool detail path like any other tool. The unified **Activity** sheet is the sole above-composer progress reference and reads mounted active/recent rows alongside non-subagent retained content. Active rows hold their order at the immutable run-start boundary while progress observation timestamps advance; recent rows use their fixed terminal boundary. Manage Session owns **Subagent History**, whose cancellation-owned store pages only terminal subagent receipts through `session.processHistory.list/get` with `kind: subagent`. Both the bounded Activity sheet and Subagent History start each presentation at medium and allow expansion to large; refreshes and child-sheet round trips do not reset the chosen detent. Subagent History keeps the originating Manage Session teal title and Done action; its content and child sheets use the distinct subagent seafoam theme. `tronSubagent` is based on `#03C3A8`, with darker `#007D6C` light-mode ink for readable controls. The orb, child-session chrome, history cards, and subagent update/fork pills share this identity; the unified Activity title, Done action, extension glyph, and retained-content cards use emerald. Activity section labels use the shared `sheetSectionHeader` with primary text; native tracker titles match the standard 14-point semibold row title, while metadata and output previews use `secondaryDescription` in the reading family. Monospace remains reserved for durations and tool identifiers. The mixed-sheet hosted capture covers standard and accessibility text sizes. Destructive stop controls remain red, and transcript tools retain their ordinary tool semantics. Both lists share one compact row composition: title and plain duration lead the row without a per-row animated orb. Orb-sheet rows also show **Started** with the producer's start time in the device locale/time zone (time only today, abbreviated date and time for older starts), immediately left of elapsed time in the header with a narrow-layout vertical fallback; missing starts are omitted rather than inferred from progress. One visibility/scene-gated sheet clock refreshes running elapsed counters once per second from receipt-local monotonic anchors, without Gateway polling or per-row timers. Those anchors stay with the duration sample across row/sheet remounts, are excluded from Codable and value identity, and survive progress frames repeating the same sample in `SessionProcessPresentation`. New samples and final durations remain authoritative; queued/paused/terminal states never accrue local runtime. `SessionProcessModelsTests` covers local timestamp copy, clock skew, repeated samples, and frozen terminal duration. Execution metadata remains below the heading: execution mode, tool count, and turn count use one standardized caption-scale pill primitive with shared padding and one square icon frame in a single wrapping flow, so different SF Symbol bounds cannot change pill height. Their labels use a half-point readability increase and inherit the owning activity card's lifecycle accent (amber in progress, green success, red failure); lifecycle has no redundant pill and colors only the active-sheet container amber for in-progress, green for successful completion, or red for failure/interruption, while history containers remain seafoam regardless of lifecycle; row-owned theme scoping prevents a parent sheet from overriding these colors; queued and paused canonical runs use explicit `QUEUED`/`PAUSED` activity headings rather than being mislabeled as live execution; and one bounded activity block combines the current tool/path action with at most the newest three output lines; completed tool history is not inferred when the canonical producer does not publish it. Sentinel path values are omitted rather than shown as filenames. The mounted subagent sections in **Activity** retain one noninteractive Liquid Glass card container because it is naturally bounded, while the potentially long **Subagent History** list uses the provider-settings scroll-optimized container surface and plain nested pills. Every admitted row is one button-owned tap surface and presents its read-only child transcript as another standardized medium-first bottom sheet rather than pushing the list's navigation stack. An active row may open before its child binding exists: the sheet remains mounted, observes the authoritative process projection, and performs a bounded transcript open when the binding appears. It also makes at most two short canonical-RPC retries while the same admitted tool/run row remains active, allowing the Gateway to reconcile a just-created child file before its process delta arrives; iOS never infers a path or child identity. Transcript opening and history paging use their canonical RPC as the capability authority rather than waiting for a separate `system.info` projection; initial tail pages render immediately, earlier transcript pages remain explicit, live tail refresh merges append-only overlap, and history retains up to 400 lazily rendered rows without re-flattening every page during each view update. Read-only child pages feed the same canonical transcript assembler and physical row rhythm as main chat: exact child tool-call IDs reconcile invocation/result evidence into one stable run chip across paging and refresh, every rendered row uses the shared horizontal inset, eight-point trailing spacing, and tail affordance, standalone orphan results remain visible, assistant text and thinking use the shared Markdown preparation path, and parent process summaries never fabricate a second unkeyed live tool/output row. Empty, waiting, unavailable, conflict, and child-session failure states use the same Tron glass-card typography as other sheet placeholders rather than stock system unavailable content. iOS keeps no durable process mirror and cached projections never own recency.

A subagent row can open a canonical-live read-only transcript only when the Gateway supplies an opaque, validated child-session reference. An unbound active child waits for the Gateway-authored binding-availability transition. One finite recovery allowance owns transient viewer failures; repeated terminal updates cannot reset it. Exhaustion offers explicit Retry. Reopening the same viewer preserves loaded transcript content while replacing its lease, with all stale results fenced by the existing presentation generation. `ReadOnlySubagentSessionStore` owns a connection-scoped `session.processTranscript.open/page/close` lease, exact revision and page anchors, and bounded same-lease invalidation refresh. When the independently advertised `process-transcript-abort.v1` capability is present, an active sheet mounts one leading muted-gray stop icon immediately in its disabled state so lease loading never shifts the toolbar. It transitions to enabled red only after the open response grants `canAbort`, then sends the lease ID through the same confirmed-mutation executor to `session.processTranscript.abort`; Gateway revalidates exact parent/process/run and file identity before routing synchronous work through the parent session's ordinary settled agent abort and asynchronous work through the trusted installed subagent controller's exact run/child stop. Synchronous leases capture the exact foreground operation ID so stale UI cannot stop newer parent work. Terminal sheets never expose the control, and an admitted request remains disabled until canonical lifecycle converges. Invalidations cannot bypass a scheduled recovery delay or an exhausted recovery budget: all page entrypoints share the viewer's recovery owner, and exhaustion requires explicit retry. A same-revision page response clears only the invalidation it actually admitted, then drains any newer hint; it never erases later refresh intent. Gateway serializes page/refresh reads per lease and rechecks the expected generation inside the lane, because canceling the iOS task does not prove its already-sent request stopped. The newest page is reconciled by exact canonical overlap, preserving loaded earlier pages and stable scroll identities for append-only growth; zero-progress earlier pages fail closed, and incompatible branch replacement falls back to the new canonical tail. The sheet opens only while connected and keys its task to connection plus presentation generation so reconnect starts a fresh lease. The transcript opens overflowing newest pages at the tail while short content and empty-state copy remain top-aligned. Native size-change anchoring stays bottom-owned while near the tail, so lazy Markdown measurement and medium/large sheet resizing cannot leave the viewport below its content; readers who scroll away retain top-owned size-change anchoring. `SessionSheetPresentationTests.testCompletedSubagentTranscriptOpensWithVisibleContentWithoutScrolling` checks actual scroll geometry for empty, short, and long RPC-loaded transcripts without an initial user gesture. It presents an authored placeholder rather than an empty sheet when no messages are present. Ordinary viewing never acquires another runtime, exposes a path, embeds writable `ChatView`, or fabricates transient activity as a canonical transcript row; the capability-gated stop is its sole mutation. Completed child JSONL entries render through native transcript rows; current process summaries remain in the owning activity list. Token-by-token child assistant text is intentionally outside this canonical-live contract.

Subagent history paging and detail requests belong to `SessionProcessHistoryStore`,
constructed by the mounted history sheet. Covering it cancels disposable requests but retains complete pages and their cursor. Revealing it only resumes an unfinished initial load; it neither advances pagination nor replays the first page after cursor exhaustion. Load More owns subsequent pages, and real revision/duplicate-page conflicts still fail closed rather than mixing history. `SessionProcessHistoryStoreTests` exercises these boundaries through the real Gateway client with a scripted transport. Live extension activity remains a separate bounded snapshot projection; it has no independent mobile history cache.

Offline cache strips all extension surfaces, interactions, lease/focus, capabilities/diagnostics, and ephemeral semantic values; it also never persists process overview, current/recent rows, history pages, or child transcript leases.

Knowledge reads are presentation-owned bounded projections. `KnowledgeCoveragePresentationStore` requests coverage by disposition (`knowledge-coverage-filter.v1`), so it holds cuts needing attention and never the settled ledger, retains its page/cursor across cover/uncover, skips a refresh when the Gateway's state revision is unchanged, and replaces changed coverage only after the new page arrives. A new Gateway identity clears the projection immediately; only initial reads show a loading placeholder. A continuation appends across a changed revision—the ledger is ordered by `recordedAt` and only appends or moves a cut forward, so a re-recorded cut replaces its retained copy by id instead of restarting the page at the head. Clear on a failed/unavailable cut uses the confirmed mutation executor, an exact revision fence, and the Gateway's terminal-skip operation; it never deletes history or excludes the surrounding conversation. `KnowledgeObjectReaderStore` owns one bounded bytes/offset/loading/error state for the exact selected record/revision/object reference; switching primary, provider API, or linked-article representations releases the previous buffer, and late responses are retired by the selection request generation. Its Gateway boundary rejects mismatched hashes/media, count/offset/continuation envelopes, and decoded byte lengths before publication. Linked-record citations remain in the initiating detail through `KnowledgeLinkedRecordReaderStore`, including visible unavailable/error state. Catalogue refreshes fence every response by Gateway presentation identity. Knowledge-origin session citations pass the existing `SessionHistoryEntryStore` and admitted `SessionHistoryEntryPage` exact-entry request; an off-page entry opens directly without searching a first-page cache, while missing evidence settles as unavailable. `KnowledgeModelsTests` covers 53-cut continuation/revision-advancing paging, retry, the disposition filter contract, multichunk representation switching, malformed envelopes, partial UTF-8, and stale response retirement; `SessionSheetPresentationTests.testKnowledgeOriginCitationOpensExactOffPageHistoryEntry` covers rendered exact-entry history presentation. Knowledge mutations publish their returned record into the selected detail before refreshing the catalogue, so triage, note edits, and corrections immediately expose the new revision while retaining canonical qualifications and evidence.
Native safe-area layout pushes the transcript exactly once and reverses naturally when
the keyboard or composer contracts. `ChatViewportMode` has only two states: `.pinned`
selects the native bottom size-change anchor as the sole physical size/inset owner, while
`.anchored` selects top retention and keeps the `ScrollPosition` target-free so direct
native ownership preserves the reader's position.
Transcript growth, keyboard frames, and composer measurements are not mode inputs. Consequently pinned content
and inset growth require zero app offset writes, and detached growth cannot pull the reader. The status-bar
scroll fallback admits only an offset-only retreat in genuinely overflowing content, so empty/short composer
reflow cannot fabricate reader takeover or expose catch-up. Short and empty transcripts remain physically
bottom-aligned; blank space belongs above the newest content.

Mode changes come only from explicit intent: native/direct/accessibility movement away from the
tail anchors; a bottom-starting pull that remains within the tail boundary or native past-bottom
rubber band stays pinned and never exposes catch-up. A physically observed direct return, catch-up, or opening pins; submission and prepend preserve
the current mode; a fresh presentation reset pins while a retained same-session reset preserves
reader authority. `ChatScrollCoordinator` owns the reducer, raw geometry and semantic frames,
unread state, and six bounded command purposes only: exact opening-tail realization, catch-up,
semantic-anchor correction, prepend correction, lazy tail materialization, and a token-guarded
physical-tail repair. Repair evidence carries the bottom marker's own sample revision, never an unrelated row's global semantic revision. A physical-spine/explicit-intent episode permits at most two repair commands; alignment jitter and changing displacement cannot renew that budget. Automatic growth follow, tail-correction arbitration, and callback-order compatibility flags no longer exist.

Chat interaction diagnostics remain a 256-record in-memory projection in Logs, not a session journal. Content-free composer availability transitions record connection/reconciliation, mounted authority, projection availability, opening/scroll ownership, pending uploads/submission, and live surface activity; blocked send admission records the same inputs. Visible-reveal and ready-frame-await milestones separate physical settlement from presentation publication. Compact entrance admission/completion and queued physical-target ordinals correlate growth with target retarget/release, including the callback's captured versus current layout epoch. Geometry scalars are explicitly labeled `geometrySource=swiftui`: lazy estimates are not independent UIKit visibility or composited-frame proof. These event-driven diagnostics add no polling, native-view scan, or second state authority. Structural native continuity remains a known separate limitation; the trace helps localize the next incident without claiming that a later aligned marker proves uninterrupted visibility. Schema 2 context records include numeric app/build metadata. Closed lease events distinguish requested, frame-ready, actually consumed, retargeted, canonical-handoff, fallback, and exhausted-repair boundaries. Geometry/semantic/marker/materialization revisions, layout settlement, repair counts, and sampled row geometry explain evidence provenance; a cached row frame is not a claim of current native visibility. At most 64 short in-memory identity entries assign local non-reused ordinals to physical/semantic IDs without exporting IDs, hashes, text, filenames, or credentials or scanning the transcript spine. Retirement revokes delayed checkpoints while retaining the ended context, so a truly lost active projection remains diagnosable. Hosted tests use test-only mounted UIKit row/composer markers plus the SwiftUI host's state identity, rather than retained semantic frames or estimated content height, to exercise send → acknowledgement (before and after release) → first successor with short history, an oversized send crossing into overflow, and 160 mixed-height rows. Separate cases cover short streaming/appends through the composer-inset boundary and viewport contraction. These are mounted-frame/clearance checks, not a substitute for full physical-device visual acceptance.

Opening still keeps the opaque surface until the exact physical marker after transcript and
queue rows is positioned. Initial opaque-surface geometry is retained as evidence without
admitting ordinary scroll side effects. The 750-millisecond acknowledgement cadence starts only
after an exact command crosses the application boundary, requires fresh post-application marker
and viewport evidence, and permits at most three corrective commands; it never converts missing
or cross-frame evidence into a user-visible failure. The 30-second opening owner is the sole
terminal deadline. The lease remains through the reveal's stable frames before releasing to native
size-change anchoring. Direct interaction abandons
opening immediately. Catch-up retains its
staged long-distance approach and unread ownership until physical settlement; interruption
restores anchored/unread state. Command application re-evaluates an already-admitted tail boundary,
so geometry/application callback inversion cannot strand catch-up or composer submission authority.
An installed projection captured while anchored advances an
exact layout epoch and restores a surviving semantic anchor within one point, with at most two
corrections and a one-second deadline when layout evidence never arrives. Prepend uses the same
fresh semantic-and-geometry proof and bounded correction, while anchorless history remains inside
the same coordinator-owned operation and eight-second terminal deadline. Starting that explicit
page intent supersedes a pending semantic-restore command; active catch-up or opening retains stronger ownership
and rejects paging. Every `ChatLayoutTransaction` publishes an exact settled or abandoned terminal
event. Watchdog abandonment retires only its matching materialization lease and promotes a newer
pending insertion when safe; a bounded physical-ID handshake preserves entrance completion that
arrives before local lifecycle admission. Repeated keyboard participants use revisioned tickets, so
an older completion cannot settle newer work. UIKit remains the keyboard-motion owner; the layout lease waits on its one frozen duration rather than treating completion of an empty SwiftUI animation as physical keyboard evidence. Terminal-event overflow cancels transient viewport
leases rather than dropping unknown ownership. Background suspension cancels the same coordinator-owned
history/deadline task while preserving pinned/detached intent. Direct interaction
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
nonvisual “Tron is working” status on the active blur. Compaction and retry waiting retain
explicit compact rows. The retry pill says only “Retrying” and is owned solely by the
canonical retrying phase; running resumes the ambient indicator immediately even when
attempt metadata remains until the retry finishes. No local timer or transcript-text heuristic
controls its lifetime.
A manual compaction accepted during an active turn remains a Gateway-owned pending maintenance
operation: the optional snapshot flag renders “Compaction queued” without fabricating JSONL, then
transitions through the existing compacting row to the canonical compaction entry. Completion publishes
one immediate fitted authoritative snapshot containing the current canonical tail/leaf—including any
hook-appended suffix—and restored prompt/automatic-idle operation state; manual marker cleanup retains
its compacting phase without retaining the spinner. The mounted progress row therefore becomes
“Context compacted” without spending a cursor on a single-entry delta that may already be a non-leaf.
One synchronous Gateway claim spans pending and execution, handoff revalidates against newer agent ownership, and
settlement waits for durable run-marker retirement. The confirmed mutation stays pending until
canonical completion; shutdown cancels only work that has not started. Older Gateways may omit queued and effective
automatic-compaction evidence.
A non-empty draft replaces the trailing Stop action with Send. The Gateway's
`acceptsQueuedPrompts` snapshot fact, derived from live Pi streaming state, decides whether
that draft can steer; broad running/compacting/retrying presentation phases and queue CRUD
capability do not. Without that exact capability the draft remains an ordinary prompt and
retains the neutral post-compaction presentation. An empty running composer retains Stop. Stop is a preemptive control rather than an ordinary serialized
composer mutation: the mounted route's session ID and optional authoritative operation ID
travel through the confirmed executor even when presentation authority is temporarily handing
off. Gateway fences that operation ID, treats the projected kind only as advisory metadata,
and acknowledges success only after every foreground controller and owned built-in bash process
settles. The abort either reaches that exact session after reconnect or surfaces failure; it is
never silently discarded by presentation or ordinary send-readiness gating. Keyboard dismissal remains responder-owned after steering; the already-sized outgoing row entrance never delays or redirects it. The send control's native context
menu can explicitly choose steering after the current turn or follow-up after current work. The
menu and its stale action closures use the same pending-submission gate as the main button, so an
accepted operation still reconciling cannot start a second send or surface a misleading error. A press
has immediate scale/opacity feedback, admitted sends replace the arrow with a compact progress
indicator, and the composer surface acknowledges in-flight admission through the authoritative
Gateway queue or pending-prompt snapshot. A semantically ordinary prompt that enters automatic
compaction in its own preflight is not fabricated as a Pi queue item; its authoritative pending state
uses the shared right-anchored emerald queue-card visual with truthful “Message” / “After compaction”
copy, then hands directly to the
operation-ID-bound canonical user row and survives navigation without replay. Pending attachment chips enter and leave with bounded composer-owned
motion; their height changes explicitly arm the sole scroll coordinator's viewport transition.
The horizontal attachment collection stays mounted across empty/nonempty changes, with no empty
height or spacing. Every chip—including the first insertion and last removal—owns the same
centered scale/fade; the full-width scroll container never scales toward the screen center.
Authoritative queued entries render after any explicit runtime detail as right-anchored compact cards
that use one intrinsic-or-wrapped layout, hug their content, and stop at the same 364-point maximum as a user prompt. They retain stable
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
read-only view, and a Unicode-safe 320,000-byte prefix explicitly marks omission. Native selectable readers use the
same progressive custom top-blur contract as Markdown, including JSON and code sheets. The UIKit reader host extends
into the top safe area so the shared blur owns the navigation boundary and the system bar cannot introduce a solid
border; native selection, wrapping, Dynamic Type, and bounded scrolling remain unchanged. No second opaque toolbar
layer is added.
PDFKit validates off-main and
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
chat. The app obtains an opaque APNs token, proves its signed Development or Release
application identity to the fixed Tron Push origin with App Attest, and transfers
only the returned endpoint-scoped installation grant to the authenticated Gateway. Each grant records the normalized relay origin and APNs/App Attest route that issued it; a legacy or mismatched grant is replaced through the configured Worker rather than transferred across relay authorities.
App Attest keys, APNs token bytes, and grants use a Keychain namespace separate from
Gateway bearer credentials. Registration is one bounded, profile-generation-owned operation:
every retry obtains a new challenge and generates a new proof, timeout/retryable 5xx uses two
bounded backoffs, and cancellation cannot commit across a profile or APNs-token replacement.
An assertion 401 or the SDK's exact typed invalid-key code may clear only the App Attest key
and permits one fresh-key attestation; fresh-attestation rejection, malformed responses,
nonretryable 4xx, persistence failure, and exhaustion stop without credential churn. APNs
tokens are preserved. A Gateway-certified relay rejection invalidates only that endpoint grant; the next bounded reconciliation rotates it while retaining the APNs token and App Attest recovery rules. A Gateway whose product relay origin differs from iOS is treated as unavailable rather than accepting a cross-origin capability. Settings exposes only a fixed local stage label,
never origins, identifiers, tokens, proofs, grants, response bodies, certificates, or bindings.
Registration reconciles on connection, foreground, profile, permission, and APNs-token changes;
Worker failure leaves push pending.
The app accepts no relay URL or private push credential from settings. Remote alerts
have no app-icon badge, background content fetch, or notification actions. They request the bundled `tron-notification.caf` custom sound; iOS falls back to its default alert behavior if that resource cannot be resolved. A foreground synchronized chat anywhere on the active lineage—including while one of its descendant detail sheets is visible—retains the exact Gateway presentation lease that suppresses its product-authored agent-terminal alert globally before relay or inbox admission; explicit model `notify` remains independent, and input-needed alerts retain their interaction-admission policy. The Settings leading toolbar bell opens a profile-aggregated inbox backed by Gateway's bounded `notification-inbox.v1` resource; `NotificationInboxCoordinator` retains only a bounded local projection, while Gateway list revisions and command-receipt read mutations remain authoritative. Connect and invalidation load one newest page with the Gateway unread count; older pages are fetched only by the mounted history scroll sentinel, fenced to that page's revision and connection. The bell uses `bell.badge.fill` and an exact unread accessibility count. The primary sheet shows at most the newest 15 filtered rows, then one View More container opens the full bounded history. Primary rows retain their glass container, while history uses a lazy stack of plain tinted rows so large retained projections do not create one glass compositor per row. Unread rows use an emerald icon/container; read rows use muted gray, with no redundant dot or disclosure chevron. Opening a notification detail marks that row read; opening a synchronized chat acknowledges all notifications in that session's opening cut through the existing visible-presentation lease. Gateway-owned retries persist captured IDs even after navigation or socket loss, without consuming newer notifications, and the existing inbox invalidation reloads authoritative read state. No client-side session-read mirror or second RPC is added. Mark Read clears all Gateway buckets, and details use standard Tron sheet/glass/metadata presentation with Open Chat in the leading toolbar. The primary inbox defaults to Unread; All and full history remain available. The All/Unread control sits directly in each list sheet without a redundant outer card or section label; each empty filter uses explicit Tron icon, headline, and body typography rather than the system `ContentUnavailableView` style. The persisted `agent_finished` kind covers successful, limited, failed, stopped, and uncertain terminal outcomes; its neutral “Agent finished” label and stop icon do not imply success. The fixed body names the outcome without exposing provider errors or partial response text. Agent-terminal
alerts carry a bounded APNs request ID and machine/session identity pair in addition to fixed product
copy and the session title. Tap admission rejects partial, oversized, or non-opaque
routes and request IDs, resolves the machine only against an already-paired profile, and marks the matching canonical inbox item read without delaying navigation. The route joins an in-flight same-profile foreground reconnect at the exact activated-transport boundary instead of replacing it or waiting for unrelated dashboard, settings, device, terminal, or mounted-session reconciliation. A different owning profile still transitions through the sole lifecycle owner. The admitted payload identity creates the route directly; canonical `session.open` owns existence and permission, while paginated catalog convergence remains independent. The currently mounted chat stays visible while transport preparation runs, an exact same-route tap is a navigation no-op, and only a genuinely different target pops and pushes through the ordinary navigation owner. A tap from Knowledge or Automations first switches the shell to the Sessions dashboard before mounting the route, retiring any dashboard-owned conflicting sheet instead of leaving a pending route until the user selects Sessions. A background or cold-launch tap is retained only in memory until the scene installs that owner; activation generations prevent stale work from committing after another scene transition. The tap is never persisted as navigation truth. On launch and foreground
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

The share extension admits at most 32 providers, 64 KiB per UTF-8 fragment, and
128 KiB across extracted fragments before pure ordered reduction. Prompt construction
retains a 192 KiB ceiling aligned with Gateway admission, and `PendingShareStoring`
rejects encoded documents above 256 KiB, removes malformed or oversized persisted data,
and reports save failure so the extension opens the app only after a successful write.
The app reads through the same store boundary. The current single-slot, clear-before-send
handoff remains unchanged; a future multi-entry inbox still owns destination leases,
acknowledged clear, and retained uncertain/failure behavior. Both packaged targets declare
the required-reason UserDefaults privacy manifest, and archive verification fails if either
manifest is absent.

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
lazy outer stacks, while their small divider-owned sections remain eager. The main Settings sheet places its
divider-owned rows in four category containers rather than one backdrop per destination, grouped by what the user
configures: emerald This iPhone (Connections, Appearance, Sessions), purple Agent (Model Providers,
Custom Models, Agent Defaults, Compaction), cyan Tools & Extensions (Packages, MCP Servers, Connected
Services, Project Trust, Locations and Overrides), and blue Data & Diagnostics (dashboard-only Import, Logs). Row icons and dividers use the owning
container accent. Connections retains the authorized-device detail identity across a server switch and refreshes its content in place; a transient device-list projection cannot dismiss the nested settings stack. Each progressive destination installs that row accent as an environment-owned visual theme
for ordinary titles, controls, icons, dividers, fields, and containers, including nested sheets; informational
text cards mix the same hue toward slate. Settings action text resolves to white against dark Liquid Glass and to
the button accent in light mode. Project Trust and Gateway actions opt into semantic container accents rather
than inheriting the section tint, while warning, error, destructive, and log-level state colors remain semantic. Each row carries a concise secondary summary while retaining progressive destination construction
and exact dashboard/project scope admission. Settings rows use placement-based typography rather than separate stable/dynamic subtitle roles: all left-aligned secondary copy uses the selected reading family (serif with the default selection), including live state, branch names, and editable selections. Monospace is reserved for right-aligned values. The same subtitle rule applies to provider, Automation, and Session History rows. A row with a distinct trailing control places its value on the left secondary line in the reading family and gives the control a reading-family action label. Without a trailing control, the dynamic value is right aligned in the code family. Both placements share an 11.5-point scale. Deliberately prominent summary values—such as New Session card selections and Manage Session’s large remaining-token headline—remain bold reading-family text. The same policy owns New Session, Manage Session, history, and their
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
swiped canonical session without changing navigation selection. Rename uses emerald, while both leading attention actions—Mark Read and Mark Unread—use neutral gray. Dashboard and Manage Session rename flows share one native text-entry alert whose fixed trailing circle-x clears the value; UIKit owns horizontal text scrolling beneath that control, so long names cannot displace it. The delete swipe
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
by `ComposerDraftCoordinator` under session plus presentation generation. Native editor synchronization uses one 300 ms trailing debounce and one serialized request per exact target and host epoch; locally originated operation-ID echoes are suppressed, and authoritative revisions gate each update. Late uploads, stale same-session editor events,
removal, send completion, and errors cannot cross a reopen. Closing or
replacing a route synchronously revokes its intake lease and disposes presentation-transient state
while retaining only the bounded profile/session text draft. Share intake captures the sole admitted presentation target, never consumes that target's
staged uploads, and clears the shared payload only after confirmed prompt admission. Dashboard
imports use the explicit default workspace rather than a hidden transcript selection.

Knowledge evidence citations navigate to the originating mounted session and open the cited entry through
the managed history sheet rather than issuing a parallel history read: `SessionHistoryEntryStore` reuses
`SessionHistoryReadIdentity`, `SessionHistoryEntryPage.admitted`, the runtime generation, and the installed
subscription. Knowledge status projects settled and remaining coverage dispositions without mirroring coverage
records. Reflected observations publish the generated unconfirmed note as an explicit editable handoff, while
source corrections retain the captured text/object and append a user-authored correction with new provenance.
Knowledge detail and linked-record presentations fence activity, Gateway identity, and latest
request generation before and after every await.

In-app notification projection is disposable and bounded to eight entries, 4 KiB per message, and 16 KiB total.
`InAppNoticeCenter` is the single AppModel-owned, monotonic-clock-driven center. It presents one readable
card at a time in FIFO order; up to two decorative backing shapes indicate pending feedback without exposing
another card's text. Higher-priority arrivals never interrupt the current card. Overflow sheds the lowest-priority
pending notice, preserving the reader and bounding the queue. Keyed updates retain position and the original
visible deadline; semantic duplicates do not extend it either. Replacement enforces the same aggregate byte bound
as admission. All notices are informational: there is no action/handler or persistent-lifetime API. A single
identity/token-fenced timer starts when a card becomes foremost, clamps dwell to 2–12 seconds (normally four,
eight for errors), and retains only remaining reading time across inactive/background transitions. Touches cannot
pause expiration. Typed app, presentation, and exact session scopes retire with their owner. One non-key, transparent,
pass-through window per app scene owns `InAppNoticeHost` above app sheets, so notice coordinates never transfer into
a presented sheet or follow its interactive drag. Content and blur modifiers do not install notice hosts. The window
receives the existing AppModel-owned center, forwards touches outside the bounded notice region, and is retired with
its scene; it never creates another notice store. The host discovers the foremost visible navigation bar in the scene and uses the compact card height only as a toolbar reference; its top edge is clamped below the overlay window's safe-area/status region, so multiline content grows downward without moving the first line. It retains 80 points for its leading and trailing controls at ordinary type sizes; accessibility sizes use 16-point side insets and move below the toolbar instead. Every notice uses the same 24-point continuous corners, 18/12-point padding, title/body typography, and opaque surface backing under regular tinted Liquid Glass; only the semantic icon/tint changes. The leading icon is vertically centered against the complete text block, including multiline details. Titles wrap to three lines and details to four, with the full text available to VoiceOver. Outgoing cards fade and move upward while the next card enters over 240 ms; Reduce Motion uses an opacity-only 180 ms fade. Removal from the notice center immediately revokes the outgoing card's hit target; SwiftUI alone retains its transient exit rendering. Notices have no buttons or tap actions; an optional horizontal/upward swipe or accessibility dismissal advances the queue without pausing its timer. Retry Connection and Logs remain in Settings; failed conversation synchronization is retried in Manage Session, and the dashboard session list supports pull-to-refresh. Notices never own navigation or recovery commands. `InAppNoticeCenterTests` cover burst ordering, finite expiry, duplicates/replacements, overflow, retirement, and background resume; `SessionSheetPresentationTests` capture compact/detailed queues in both appearances and check absence of native controls. A session opening assigns notices to its pending presentation generation,
then retires the previous exact session scope when replacement mounts. Destructive,
security, text-entry, and ambiguous decisions remain modal.
The queued-message editor uses the shared settings selection row and native menu for delivery, standard multiline
editor and captions, and the native trailing checkmark to save; draft and exact queue mutation ownership are unchanged.
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
color-mode control with a compact 40-point color-mode height and keeps font axes directly beneath each
font choice before its preview. Every font-selection title renders through `TronFontLoader` with that candidate family (and Recursive's mono axis in the code list), while the description retains the selected reading typography. Text and code previews share the same 14-point row padding without an
extra code-only minimum height. Passive Settings explanations use `TronSettingsCaption`: reading-family
secondary text directly on the sheet, without a card, icon, or tap affordance. `tronSettingsCaption`
attaches that copy eight points below the group or action it explains. Actionable failures instead use
`TronSettingsNotice`, with standard row/icon geometry and a right-aligned Retry capsule. Main Settings and progressive
sub-sheets apply `tronSettingsLayout`: Manage Session's icon column, row/divider insets, reading-family
labels, metadata scale, and 28-point visual capsules inside 44-point targets. The larger model headline
remains specific to Manage Session. `TronValueRow` delegates geometry to `TronSettingsRow`;
`TronSelectionRow`, `TronNumberSettingRow`, and `TronTextSettingRow` share the same layout. Chosen values
appear in their popup capsule without duplicated value subtitles; typed and read-only trailing values
use the same code-family face and size. Enabled toggles use a light thumb over a stronger tinted track
in dark mode, preserving light-mode colors. Ordinary settings have no Save toolbar: valid edits save
automatically, with target-local error/Retry notices. Resource text editors retain one padded multiline
field treatment. Authentication, package installation, and maintenance remain explicit commands. Provider rows use icon-free trailing Connect or Configure text actions instead of local menus. Each action
opens one medium/large standardized configuration sheet at normal inline-navigation content height:
runtime-advertised API-key and account-login methods are presented together, configured providers expose
replacement credential or alternate-account login plus credential clearing, and the same visible sheet owns
the exact operation-keyed auth prompt/event lifecycle. The Connection Method group stays visible with the
active method checked; choosing another method cancels the owned operation and starts that one. Each step
appears below the method group without insertion animation: provider choice prompts render as the same
standard selectable group (radio rows), answered choices stay checked in place, and credential prompts show a
header, field, and value-gated Save action. Changing an answered choice restarts the same method with
`replaceOperationId` and replays the kept answers onto matching successor prompts
(`ProviderAuthSelectionTrail`); a prompt that no longer matches ends the replay. Nothing presents another
page or sheet.
Custom-model rows have one Configure capsule; the editor owns a leading Remove toolbar action and
its standard destructive confirmation sheet. Stable provider UUIDs, not editable identifiers, own
presentation and field bindings. Removed/reordered rows cannot be indexed or resurrected by a late
native callback. Catalog choices display each model's authoritative `name` (including distinctions such as “Claude Haiku 4.5 (latest)” versus “Claude Haiku 4.5”); `ModelDisplayFormatting` is the ID-only fallback for session references and never changes canonical IDs or search/mutation values. Thinking choices come from the active model's SDK-advertised capabilities, not the global settings list, so the picker does not assume every reasoning model offers Off.
New Session quick selections are compound server/project identities, so selecting one switches the owning Gateway profile before
configuration admission. Source-control creation sends an explicit strategy to Gateway;
Pi receives only the resulting worktree `cwd`, while Git worktree creation and cleanup remain
Gateway-owned. Import
is owned by one progressive Import sheet for canonical session-file import. The chat composer remains visually floating without an
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
sheet from deferring the login prompt until the user navigates back. Sheets never use pull-to-refresh; session history, packages, and providers expose reload as an explicit toolbar
action, while Sessions, Automations, and Knowledge dashboards converge through their live Gateway invalidations without a manual refresh gesture.

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
session store or infer authority. The outgoing row is installed at full natural size and animates only opacity plus a
short vertical offset. No source/destination frame registry or overlay exists, so missing geometry, canonical
replacement, backgrounding, presentation retirement, and relaunch cannot strand or replay a visual handoff. Each complete installed transcript exposes one `ChatCommittedLedger` followed by
one `ChatLiveRegion`. The ledger contains only the frozen canonical prefix and retains its local monotonic revision
across streaming, handoff, queue, compatible reconnect, and foreground-reconciliation installs when those canonical
rows are equal. Canonical append, prepend, or replacement advances that revision once; a cold owner deterministically
rebuilds the same rows at revision one from the authoritative snapshot. The live region carries streaming/runtime, handoff, and queue facts in the same atomic commit, never as a mirror or second store. Rendering uses one physical row namespace. One bounded lazy stack permanently owns committed, live/runtime, lifecycle, and authoritative queue rows, including ordinary outgoing prompts. Its surrounding transcript stack owns the single target-layout registration shared with the eager tail marker. Native anchoring owns routine size and payload changes. A genuinely new lazy physical row may receive one disabled command targeting its exact stable physical ID. An ordinary local send arms its exact physical-row target synchronously with the outgoing-row graft and carries its layout-transaction identity; row appearance alone cannot release it while the entrance, keyboard, or composer mutation remains active. After exact participant completion, two unchanged presented frames and release-consumption evidence prove the handoff to native anchoring. A zero-height lazy child that emits no frame receives one visual-only two-frame entrance admission and exact-target retry; a one-second missing-evidence boundary releases the target without treating elapsed time as physical success. When another insertion is already waiting, the lease transfers directly to the newest exact row without a target-free frame. Every installed commit reconciles those leases against its complete physical-row namespace; a lifecycle row that settles away before publishing geometry crosses the same settlement gate rather than leaking permanent target ownership. Foreground resume retains the native viewport and admits repair from current same-presentation marker evidence. Both paths preserve stable row identity, bounded realization, and the single scroll owner; outgoing prompts never relocate across structural parents when a successor arrives. This lets a global-ordinal compaction spinner become its canonical pill and lets a causal prompt alias replace lifecycle content without crossing collection owners. Installed base IDs remain validated once, while the zero-copy random-access row adapter takes an O(1) no-alias path and checks only bounded aliases against prebuilt transcript/presentation indexes. Alias collisions fail closed without changing canonical semantic geometry/anchor IDs. `ChatCommittedLedger`, equatable rows, sparse tool payload revisions, and row-scoped text preparation still keep a full streaming turn from re-evaluating settled history. Hidden thinking labels are
attached only to preparation slices that render thinking, and tool rows compare a payload-only revision instead of an
ambient installation tag. Foreground active and passive sessions therefore converge through the same complete commit:
live work may be replaced, entrance suppression is consumed once, and neither history revision nor a retired entrance
can replay. Queue-card replacements prefer the Gateway operation ID carried as the canonical user
row's bounded presentation identity; rolling compatibility falls back to the stricter one-removed/one-new-candidate
policy and fails closed for repeated or causally ambiguous prompts. Canonical
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
across projection snapshots; a large initial/backlogged stream catches up immediately, oversized bodies bypass
per-word tokenization, and completion shows the full source without replay. The eager Markdown block stack publishes its exact wrapped vertical ideal even when its
single outer transcript row receives a finite lazy-stack proposal; long responses therefore cannot leave viewport-sized
or stale row estimates that separate later rows, inflate the tail, or compound across turns. Reduce Motion and
accessibility never hide authoritative text. Under exact tail bounds,
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
unresolved candidates. Native pinned size-change anchoring absorbs installed discrete row growth without a coordinator
viewport write. Each height-coupled row entrance caches one natural measurement for its exact width and reuses it for placement across the 180 ms reveal. Compact tool, status, and assistant rows use the same monotonic smooth curve; outgoing prompts remain full-height and transform-only. Pending compact entrances retain a one-point layout footprint (never larger than their natural height) while opacity hides their content. A zero-height run of command/notification pills in an empty lazy stack can otherwise be culled before placement, withholding the geometry required to reveal them even though projection and opening are complete. `ChatViewScrollHarnessTests.emptySessionMaterializesExtensionPills` checks actual mounted pill/reply frames and retained row identities from an initially empty session; projection counts or tail-marker alignment alone are not its oracle. A row taller than 8,000 points installs at natural layout height while retaining its existing opacity/transform entrance, preventing pathological content from interpolating tens of thousands of layout points. No clamped spring overshoot can stall or reverse the native bottom-anchor movement of preceding content. Its bounded
rendered-ID entitlement is intersected only on actual installed transitions, so a surviving tool/group
row retains the same one-shot entrance through completion while replacement removes it.
Continuity-preserved assistant/tool rows do not manufacture a new entrance. A newly admitted visible
agent row owns only its local reveal. Continuous Markdown growth remains display-frame-coalesced while
the native bottom size-change anchor holds pinned readers at the tail. Detached readers receive no writes and
Reduce Motion removes spatial effects. Agent tool buttons retain the capsule primitive,
while aggregate run sheets use bounded static summary rows with immutable call-ID routes and
individual detail sheets.

Canonical Automation prompts remain ordinary model-input user entries, but an exact Gateway-authored invocation binding projects their boundary origin, Automation ID, and generic `Automation` producer title. The transcript admits the dedicated right-aligned Automation-accent prompt container only when that complete semantic tuple is present, including UUID Automation/invocation identities and the Gateway-owned `automation:<run UUID>` operation namespace; missing or partial provenance fails closed to the ordinary user prompt container. Classification never matches message text, timestamps, or the presentation title and never reads or mirrors the Automation catalog. Only the triggering prompt is classified; its TextKit content uses a darker adaptive Automation blue instead of the ordinary user emerald, while assistant output remains an ordinary assistant row. The Automation dashboard likewise replaces its labeled initial placeholder with a centered Automation-accent pulse, cross-fades the first complete inventory or agenda, and smoothly animates later bounded catalog/timeline changes.

Visible `custom_message` entries are conversation input rather than tool activity. They use a distinct right-aligned interactive glass container whose complete rounded geometry is one hit target. The generic compact row is deliberately schema-stable—**Producer · Context** plus one admitted finite lifecycle status, or **Received** when no single standard status exists—and never includes message text, raw custom type, objectives, or arbitrary detail values. Exact subagent message categories instead use a seafoam **Subagent** chip: supervisor `reason` maps to **Progress Update** or **Needs Attention**, and control `event.type` maps to **Needs Attention** or **Still Working**. Unknown fields on those known types use **Update**. Exact `subagent-wait-subscription` messages use the same seafoam chip and **Wait Update**, without claiming that a wake means success. A `subagent-notify` message says **Result Received**, never **Completed**, because its emitter does not supply structured status and can report failed, paused, or mixed results. These are message-category labels only, not producer evidence; their sheet is titled **Subagent update**, while its Origin metadata retains the canonical producer and confidence unchanged. `InboundContextPresentationTests` covers exact types, malformed fields, and truthful unknown origins. Its medium/large technical sheet shares the standard technical-detail title, close control, role-matched color, blur, metadata-card, and drill-in JSON presentation used by tool details while exposing the full message, canonical identity, delivery semantics, message type, context payload, and exact extension attribution when available. When canonical producer evidence is absent, the generic compact row omits the producer instead of exposing an internal “Unattributed” label; the detail sheet reports **Unknown source** and technical origin remains `unknown`. iOS never promotes custom type, title, text, or timestamp into invented producer attribution.

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
tool-only entries with one equal nonempty Gateway-owned segment identity collapse
into a single compact run chip whose aggregate sheet presents every invocation as a
full-width bounded summary row; tapping a row opens its individual detail surface.
Missing or conflicting identity remains separate. Each exact installed projection builds one
unique call-ID descriptor index, so live detail refresh resolves from bounded installed state
without rescanning the full timeline. The run, individual tool, Changes, and
Technical details sheets share one inline navigation-chrome policy; principal toolbar titles
therefore cannot reserve an empty large-title region above the scroll view. Each medium/large
tool detail sheet explicitly top-anchors short scroll content and begins immediately below
native toolbar chrome. Top blur uses one shared implementation with a continuous proportional fade, not a solid navigation band. `TronTopBlurStyle` centralizes the depths: sheets use 116 points and tool details 100, each reduced by 8 points from its previous depth without changing the mask, tint, or radius. Main chat and dashboard remain 176 points and logs 184. Its medium
detent is a glance surface: aggregate runs use lazy full-width summary rows with
state, elapsed time, high-signal request context, and at most the newest two bounded
readable output lines. Each row vertically centers status with its title, places the
primary command/path below its label at full width, fades an overflowing primary value
at the bottom, and fades a bounded result tail at the top to disclose earlier output
without a separate warning line. Single-tool detail retains its wrapping metadata flow.
Gateway-bounded argument objects (`truncated: true`, optional `preview`) show an
**Arguments abbreviated** metadata chip; preview JSON is never interpreted as an
executable request or given an invented default directory. Canonical arguments
replace the preview under the same call identity. Argument abbreviation does not
change Invocation into Running. `ToolDetailPresentationTests` and
`ChatTranscriptProjectionKernelTests.boundedArgumentsCanonicalHandoff` protect this
presentation and the overlap with canonical settlement.
The flow caches one bounded measurement per layout pass and uses the exact same width
and height proposal for placement, so a dynamically updating status chip cannot
under-report its row height or overlap the following section. Pulling to large selects
the expanded display density without changing the selected call or scroll ownership.
Read/write/edit foreground a selectable path whose directory uses the restrained
secondary tone and whose basename uses the tool accent; command, path, pattern, and
location values share one 12-point semibold code scale and wrap without splitting words.
Command and file detail surfaces move their semantic icon from the primary value
container to the left of the centered sheet title, leaving primary content aligned like
the result container. Edit results precede any Changes action. Code results use their
separate readable-result scale.
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
different visible content. Git working-tree and historical file diffs, edit-tool metadata, and the expanded Changes
sheet share `ToolDiffCountChip`: green `+` additions and red `−` removals in one metadata capsule. Counts belong
to the specific admitted diff, not the commit or workspace, and are accumulated before local head/tail omission;
changing display density cannot change them. Returned patches win over requested old/new blocks, whose counts
remain explicitly requested-source evidence rather than proof of applied changes. Headers/context are excluded,
CRLF is recognized, and a terminating newline does not fabricate another changed line. Gateway-truncated sources
show a Partial qualifier; malformed/combined hunks or ambiguous file headers show counts unavailable rather than
inventing totals. Binary/absent diffs keep their existing non-text states. `ToolDetailPresentationTests` protects
count scope and omission boundaries; native summary/sheet tests cover the shared pill's colors, fit, and placement.
Diff preparation retains only bounded head/tail lines in circular tail storage,
bounds individual rendered line width, and marks every omitted line or character while the untouched payload remains available under
the final Technical details row. Empty edit sides represent pure insertions/deletions; blank rows are retained
only when a nonempty source value actually contains them. The tool-run row owns an open detail route and its
detent above the one-tool/grouped rendering branch, resolving the selected stable call ID against every newest
run projection so a second arriving call cannot dismiss the first call's sheet. Metadata VoiceOver labels use
only concise bounded chip previews and disclose that complete values remain in Technical details. The chip
flow measures every chip against the finite available width; status and scalar text may wrap to two lines at
Accessibility Dynamic Type without escaping the sheet or changing VoiceOver order. Runtime duration samples
are authoritative for live timers. iOS records each sample's device-local monotonic receipt anchor, preserves elapsed time across pill and detail-sheet remounts without comparing Mac and iPhone clocks, and advances a stale newer running frame from the prior accepted sample rather than restarting it. Cached Sendable ISO 8601 parse strategies remain a compatibility fallback
for older Gateways and canonical history, handling both fractional and whole-second Gateway timestamps without
repeated formatter allocation. Technical execution rows use compact selectable label/value geometry; a bounded bash
preview records its completeness fact there, followed by on-demand Request JSON and Result JSON summary rows
with explicit `null` for a truly missing side. Tool sheets foreground readable live/completed output before generic extension
metadata. Actual JSON text and structured-only results use the same `TronMetadataTable` every technical-detail sheet
uses, so the section title, divided card, and row geometry are one implementation; the JSON table simply drops
the leading icon and shows the field name, its short data type in the smaller secondary scale, and a
right-aligned code-family preview on one row; Accessibility Dynamic Type stacks those values.
Complete values remain available by tapping the row. SDK content/details envelopes are unwrapped, and empty envelopes
show the waiting/no-output state rather than transport fields. Raw JSON stays behind Technical details; response data
wins over JSON-text fallback, and a fallback identical to Request is rejected. Raw JSON sheet edit/done controls inherit
the same accent as their title, including Custom Models' purple Advanced JSON sheet. `ToolDetailPresentationTests`,
`StructuredJSONPathTests`, and focused `SessionSheetPresentationTests` protect these behaviors. Running sheets consume the newest immutable tool presentation, update status, timing,
partial output, and bounded-output disclosure in place, and never move
the reader's scroll position. The live Running timer is the sole freshness indicator in a tool detail sheet; the redundant Updated-age chip is absent. Tool chips retain six-point vertical capsule insets and
intrinsic label/timing geometry without a layout-inflating minimum interaction frame. Every compact chat pill and tool-detail status or metadata chip uses the metadata-pill leading rhythm: a 13-point symbol or a pulse with a nominal 13-point size and 20%-compensated visual footprint, followed by a five-point gap, with no legacy 18-point icon reservation.
The reserved first-party display tool adds a strictly typed `tron.display.v1` projection without interpreting arbitrary extension details. Its isolated one-tool run keeps one physical identity while a running pill settles to the default sheet pill, an unclipped measured inline host containing either an adaptive lavender text card or enlarged photo chip, or a completed pill plus one session-local draggable Liquid Glass panel. Sheet routing remains centralized in `ChatRoutes`; floating and deferred-route ownership is disposable `ChatSessionPresentation` state; artifact bytes stay outside snapshots and load through the exact authenticated session route. Unsupported mode/content combinations fall back to sheet, and an installed-transcript completion baseline prevents background, reconnect, cache, history, or route restoration from replaying floating auto-presentation. Generated HTML is nonpersistent, script-disabled, CSP-isolated, network/navigation-blocked content; public webpages remain explicit Safari presentations. See [Display artifacts](display-artifacts.md) for the complete surface, security, lifecycle, and accessibility contract.

Thinking traces remain one compact inline run while they fit, but their visible viewport
is capped at four measured text lines rather than truncating canonical content. Once the run
actually overflows, the compact viewport presents only the latest four measured lines without
scrolling; the oldest visible line fades at the top to signal earlier content. Tapping opens a full
trace sheet. The sheet reads the same live presentation source, so an
active trace updates in place; it uses the shared Tron sheet title, top blur, typography, confirmation
action, detents, and hidden drag indicator. A completed trace opens at its beginning, at the same resting position
every time; only a trace that is still arriving follows its tail. Short traces remain their natural one-line height. Adjacent
thinking parts and their nonempty lines form the run, whitespace is normalized without
adding or replacing terminal punctuation, and newly appended words fade in unless Reduce Motion is enabled. Tool chips and system
events share compact capsule geometry while preserving their role alignment and interaction semantics.
Compaction and branch-summary events use content-sized transcript pills whose sheets
contain the complete canonical summary. Detail-bearing pills attach their action and button accessibility semantics directly to the interactive glass surface rather than wrapping it in a second native button press phase;
compaction token counts use compact `K` shorthand.
Transcript configuration changes, errors,
bookmarks, and extension statuses share one readable notification-pill language. Compact semantic chrome uses a fixed
cross-extension role palette—indigo commands, emerald tools, violet extension context, blue informational notifications,
slate unknown/system state—with amber warning and red failure overrides. Command pills show producer, exact command name,
and lifecycle but never arguments; extension notification pills show producer, **Notification**, and severity while the exact
message remains in the detail sheet,
and thinking text and workspace shortcuts stay above the compact-caption scale.
The hidden custom back button is paired with a UIKit navigation bridge so the
native left-edge interactive-pop gesture remains available. Transcript rows enter with the historical soft
opacity/scale transition, newly appended thinking words fade independently within
their stable four-line viewport, and tool status/result changes preserve the mounted
layout without implicit animation. User turns are trailing-aligned while assistant and tool
content remain leading-aligned. Provider/model attribution is absent while an assistant
message streams and appears only on its finalized footer-owning text slice, at the same
boundary that settles Markdown reveal. Canonical completion wins over a lingering matching
stream projection; historical messages retain attribution even while a later response runs.
Error notices remain independent of attribution visibility. Initial model/thinking entries describe
bootstrap configuration and are omitted from chat; later canonical changes are
shown as compact notification pills. Structured result data expands recursively, with raw
JSON only as the arbitrary-data fallback. Gateway connection state is driven by
the current authenticated socket, ignores stale cancellation from replaced
receivers, and uses gateway WebSocket heartbeats to keep Tailscale/iOS idle paths
alive. Canonical settings determine the default model; catalog order is never a
default-selection policy. Dashboard Settings explicitly exposes only global configuration; project scope,
trust, and project package actions appear only when Settings is opened from a
project session. Manage Session begins with an emerald usage card and a purple model card matching Settings' Agent group.
The model card replaces the Configuration section. Its selected model name uses the same
large bold reading-family heading as remaining tokens, with a serif provider line beneath it; exact
provider/model identity chooses the catalog display name. Switch Model opens the shared
model picker. Capability-gated Context Window and Thinking place their current values in
slim trailing capsules, not beneath their titles. Both morph into the same anchored Liquid
Glass slider above the sheet, without relaying out the scrolling rows.
`ConfigurationSliderPresentation` admits one exact editor per host; replacement, source
retirement, and duplicate dismissal cannot commit or cancel a successor editor.
`ConfigurationSliderSurface` interpolates one presentation-time rectangle
and corner radius for the glass and its content clip, so the destination-sized contents never
escape the visible container on either leg of the morph. A finite 280 ms ease-in-out avoids
spring overshoot against that clamped geometry and interaction boundary. Content and label
values are built on input changes, never rebuilt by each interpolated geometry sample.
Clear Liquid Glass with a restrained neutral surface fill provides a softly translucent
panel and refractive rim; a public native `UIVisualEffectView` softens its backdrop.
The effect stays at alpha 1 and its own elliptical UIView gradient mask feathers strength to
zero before the bounded halo edge. UIKit forwards that mask to its backdrop internals; the
owner reinstalls it after size/strength changes rather than masking an ancestor/CALayer or
fading composited SwiftUI material. No private filter, screenshot, or sheet-wide blur is used. The larger header title/value
share a center-aligned row (stacking only when accessibility text cannot fit). Minimum/maximum
labels center beneath the track endpoints; the
non-button Default label centers beneath its actual detent. If it would collide with an endpoint
label (for example, a default at the maximum), Default slides just inside that label on the same
row; only when the row lacks room does it wrap to a second line, clamped inside the bounds. The continuous thumb gently gravitates toward point-sized detent wells;
release settles only near a detent. Bounds remain exact, the configured default is a detent,
and rounded quarters avoid crowding it (million-token windows use familiar 500k/750k stops).
Context values retain whole-token precision; accessibility exposes token units, source,
bounds, warnings, adjustable detent steps, reset, Save and close, and escape. Reduce Motion uses a short
fade instead of the expanding geometry. Thinking uses discrete, evenly spaced supported
levels, selection haptics and accessible stepping. Its raw runtime order is preserved after
deduplication. Thinking has no labels beneath the rail: the top-right header value updates live
from the local draft as the knob moves. Its nominal panel height is 140 points, versus Context
Window's unchanged 170 points; both scale with Dynamic Type. VoiceOver retains the supported
level names and current value. Empty lists and a sole already-selected level are read-only. An unlisted
current value stays visible without a fabricated selected stop; only explicit selection of
an available raw level can change it. Both editors retain one content tree in a size-bounded
native scroll surface so large text and short viewports remain reachable.
All rows beneath the model header reuse `TronSettingsRow` and `TronSettingsDivider`: standard icons,
leading insets, title scale, and indented separators match the Session container below.
Compact rows pad their labels, not the already padded action target, so single-line and
subtitle rows retain the same content-driven heights as ordinary Session rows. Accessibility
sizes still stack the full-width labels and actions. Small actions keep a 28-point visual
capsule inside a 44-point target; regular settings
menus retain their existing size. Accessibility text stacks the model and setting actions
below their full-width labels instead of forcing names into a narrow side column. Automatic Compaction status and Compact Now occupy the
model card's final row. The leading native toolbar group contains only Rename Session and
Terminal icons, mirroring the dashboard's grouped actions, while Done stays trailing.
Rename keeps the dashboard's clearable native text-entry alert and trimmed nonempty admission.
The model action opens the progressive searchable `ModelPicker` with purple title, controls,
and cards. Its sheet title is **Models**, also used by the picker within Settings → Agent Defaults → Model Defaults;
the parent settings destination retains its existing name. The model card scopes the same purple theme to
its inline controls and nested sheets. An in-flight choice appears immediately without replacing canonical authority.
Context-window model/revision guards, Thinking's available-level list, and compaction
queue/export/active-operation admission stay owned by the existing session mutations.
Both sliders keep ephemeral local drafts and commit at most once when an outside tap or
accessibility Save and close/escape collapses them. Manage Session's Done first closes an open
editor. Opening without editing sends no mutation; returning Thinking to its original value
also sends nothing. Context's default detent clears its override. Model/runtime, limits,
effective-value, supported-level, disabled-state or presentation replacement discards an open
draft. Completion rechecks the live presentation registry as well as the exact editor identity,
so a retired surface cannot publish during its closing animation. Live Thinking revalidates
session/model/runtime, idle phase, available levels and the displayed base value before
submission, retaining the existing serialized/idempotent mutation and rollback owner.
The shared Agent Defaults Model Defaults controls keep local slider drafts until dismissal, then submit the
single final change through settings autosave. Their information subtitles describe behavior rather
than repeating the chosen value. Model Catalog has a distinct list icon and a trailing Refresh capsule. Defaults keep the full model-independent
thinking list, not a live model's subset. Exact settings-target row identity and binding admission
prevent a closing editor from writing into a successor scope, including same-valued scopes.
Context and Thinking selections update their capsules as their sliders close, using one pending
choice per control scoped to the exact session/model/runtime.
The exact command completion plus matching canonical projection retires that choice;
failure rolls back only its exact request,
and model/runtime replacement discards it. Reset-to-default remains distinct from no
pending choice. Shared Thinking labels render `xhigh` and extra-high spelling/case variants
as **Extra High** in settings, sliders, transcript notices, and typed history previews without
rewriting wire values, canonical content, or authored labels.
The blue Session container orders Current Branch, Agent Instructions,
Project Resources, Session History, and Subagent History, followed by any diagnostics.
Its Current Branch row is a button in every state and is backed only by the
session-bound `workspace-inspector.v1` projection; it never reuses the path-based New Session
Git probe or a locally remembered branch. The progressive Workspace sheet owns three
mobile-native views over that projection: lazy Files navigation rooted at the runtime's
canonical `cwd`, atomic staged/unstaged/untracked Changes with on-demand bounded unified
diffs, and tip-pinned paginated current-branch/all-reference History. File content is captured
on demand into the existing bounded authenticated blob transport and uses the shared
Markdown/text/code/PDF/image preview pipeline. The sheet has an isolated observable owner;
the onboarding selector's global folder listing can neither overwrite it nor become canonical
workspace state. Selector visibility is a local projection over the entries that listing already
returned: toggling hidden folders issues no additional filesystem read. Initial inspection and
root-directory reads overlap for the Files tab, while a History or Changes activation inspects first
and reads the directory only when the showing tab actually needs it, rechecking the tab after the
inspection await. Bounded DTO decoding,
change indexing/grouping, history graph preparation, reference collection, relative timestamps, and
unified-diff parsing execute off the main actor. The owner publishes equal inspection revisions as
no-ops, indexes changes by path for constant-time Files annotations, and retains at most 400 prepared
history rows so repeated pagination cannot create unbounded memory or graph work. One tab-scoped scroll owner contains the workspace identity, tab switcher, and
active collection, so the established top blur begins directly below navigation chrome and content
scrolls continuously beneath it instead of splitting the toolbar from a lower blurred region; tab
changes return that owner to its top boundary. The sheet opens progressively at medium height, uses the Session
section's blue accent across controls and status evidence, keeps path context and overflow-scrollable repository
chips on one adaptive row, and matches the workspace selector's compact file-navigation actions. File previews are
large-only and every SwiftUI/UIKit document owner uses soft edges plus the same top blur. The root leaves the
system sheet material visible, matching Session History instead of painting an opaque black navigation surface.
Changes collapse state into one trailing chip per compact row. Background reconciliation and detail admission never
insert transient progress glyphs into established headers or rows; fixed row geometry and status accessories remain
stable until the destination sheet is ready. History uses a bounded, deterministic lane projection over each commit's
parent OIDs, with uniform-weight lane-colored rails, matching hash/reference accents, larger row text, merge markers,
and reference chips; `All References` therefore shows where branch tips fork and reconnect without treating the mobile
projection as Git authority. Commit detail strips the subject duplicated by Git's full message, fills the available card
width, and capability-gates per-file historical diffs through `workspace-history-diff.v1`; those patches are fetched only
after selection and use the shared diff renderer. Detail admission lives in an unobserved single-flight owner, so taps
cannot launch request bursts or invalidate every visible row while the selected destination is prepared. While uncovered and foregrounded, the sheet and Manage Session reconcile at
a four-second bounded cadence, retain their last useful values through transient failure, and
reject replaced profile/session/path generations. A worktree-only change does not rebuild tip-pinned History, and
Directory is refreshed only while Files is visible or when the user returns to it. Polling starts only after the
parallel initial load and stops under coverage, background, or dismissal. Failed directory navigation keeps the prior
path and rows as one atomic projection instead of labeling stale contents with the requested path. Git/file responses are point-in-time revisions; later workspace truth replaces
lists atomically and never mutates an already-open diff beneath the reader.
The model summary's controls and dividers use purple; Session row icons—including all
Git states, resource/history destinations, and diagnostics—remain blue. The Workspace Changes tab's clean-state container also uses blue. The Current Branch row puts the branch name below its title in the reading family and the clean/uncommitted-change status on the right in monospace. The Session container has no section header or duplicate workspace path; Workspace itself retains the path. Export and sharing rows use a headerless neutral slate container, labeled **Export as HTML** and **Export as JSON**; the latter still exports the canonical newline-delimited `.jsonl` audit without changing the wire format.
The usage summary combines counts and percentage as `162K/272K • 60% used` beside the
remaining-token heading in primary monospaced text (black in light mode), moving that complete metadata line below the heading only when
width or Dynamic Type requires it. That left-aligned fallback uses the reading family, consistent with other left subtitles. The progress line directly separates this header from
the cache-hit/read-write/input/output/cost statistics; there is no second divider or
compaction label in the usage card. Statistic captions use the reading family (serif by default), while values remain semibold monospace. Both share the same point size and secondary gray color. Labels scale within their single-line column at ordinary text sizes; accessibility sizes stack the statistics vertically. All Manage Session secondary text is one-half point
larger than its corresponding ordinary type scale, including metric values, labels,
workspace status, and group details; headings are unchanged. A content-scoped adjustment
keeps shared settings rows consistent without enlarging other sheets or model-picker text. When the runtime has reset its usage estimate, the card presents a
qualified zero-percent fresh state instead of an unavailable headline; a trailing canonical compaction
entry adds concise “Compacted” context, and the copy makes clear that the next response refreshes the
estimate. History owns the concise runtime
phase/message/tool summary. History row previews and relative timestamps are
prepared once off the main actor when the bounded tree or selected mode changes;
live session-state updates reuse those immutable rows, and dense cards use the
static scroll surface rather than one live glass filter per event. Manage Session's model-card
Compact Now action invokes Pi's canonical compaction through Gateway and can leave one authoritative request queued
behind an active turn. Project Resources presents resolved extensions, prompts, skills,
and tools as named rows over the canonical projection. Manage Session also exposes
Project Hooks as a separate current-runtime registration inventory: each extension
is grouped by its truthful User/Project/Runtime provenance, with event names and
handler counts from the Gateway's public loader projection and load issues shown
separately. Registration is not execution history or health. The bounded Gateway
projection reports omitted extension/event/error/long-metadata counts and the
sheet renders an incomplete notice rather than implying completeness. Resource
read failures are fenced to the mounted session and render retryable error state.
Instruction files such as `AGENTS.md`
have no duplicate row or Context Files section there: their assembled guidance belongs in
Agent Instructions, which opens the complete document directly. Canonical resource discovery
is unchanged. Project Resources, Session History, and Subagent History use the originating Manage Session teal titles and
toolbar actions to match their originating Session rows. Project Hooks keeps one native scroll owner across loading and By Event/By Extension changes, so lazy content starts at the platform top anchor without imperative scroll resets. Hook event technical info opens the Event Details JSON reader directly rather than an intermediate technical-details card. Resource detail chrome instead
matches its own category accent. Project Resource titles prefer authored labels, otherwise
humanize tool/skill/prompt names using the shared composer formatter. Extension titles derive
from npm/Git package names, meaningful local entrypoints, or named inline extensions rather
than generic `index.ts` filenames and `<inline:…>` wrappers. First-party inline names read as
Tron Core, Tron Context Window, Tron Display, Tron Automations, and Tron Notifications. Exact invocation
names, package sources, paths, schemas, and JSON remain unchanged. Each detail sheet
foregrounds kind-specific purpose, invocation, availability, capabilities, schema/guidance,
and source evidence instead of a generic field table. Prompt details additionally fetch the exact loaded template through `session.commandDetail` only while opened and display its full admitted Markdown body, consistent with prompt details in Commands. The canonical resource revision refreshes that read; canceled or retired reads cannot publish, and failures offer local retry. A completed reader for the exact selection and revision stays mounted across coverage, so returning from Resource Info neither blanks the body nor repeats the same fetch. The Gateway's 96-KiB content bound remains authoritative and any truncation is explicitly disclosed with the source file retained below. `ChatCompactPillTests` covers exact prompt identity and `SessionSheetPresentationTests` covers the full-body reading surface. The Install Package source field resolves its tint and border from the Settings accent (blue), matching the rest of the sheet rather than hard-coding green. Project Trust presents a high-signal
state card with an explicit status icon and decision actions before deferring the complete trust record to raw JSON.
Extension tools and commands use
separate adaptive collections instead of comma-delimited prose, while resource descriptions
keep compound words together for natural line wrapping. Arbitrary arrays derive labels from stable name/path/source fields instead of exposing
positional “Item” labels. The overview derives stable row titles, subtitles,
and identities once per admitted resource revision, then reuses that projection
while scrolling; large resource groups use the static scroll surface. Reload is owned by that sheet and publishes visible progress; the canonical
`session.resourcesChanged` revision is the sole post-mutation read owner, so mutation and projection loads cannot race one shared busy flag.
Packages starts with resource scope and inventory counts (Project Trust is its sibling Settings row, not repeated inside),
then installed packages, a standalone Install Package action,
then inline Skills, Prompts and Themes containers using Manage Session's emerald/cyan/teal resource
accents. Resolved extensions are not duplicated beneath the installed list. Opaque, no-space source
titles remain continuous and horizontally inspectable; ordinary titles and provenance wrap naturally,
with complete source/status information retained for accessibility. Resolved resource names use the
same friendly title formatter as session resources, stripping Markdown/JSON suffixes and deriving a
skill name from its directory. Raw paths, IDs and metadata remain untouched. Shared source/scope
information appears once as a category caption, not repeated in each row; mixed sources retain row
provenance. Empty categories use captions rather than empty info cards. Scope counts describe inventory,
not tools loaded into every existing conversation. Full technical resource data remains available separately, including extension-only
or additive categories. Locations and Overrides is a separate sibling sheet in Tools & Extensions, retaining optional discovery paths, advanced Mac overrides and autosave. Session storage remains
Gateway-owned and is not exposed as a location override. Package catalog admission failures remain
local to the Packages sheet, preserving the sheet while presenting a bounded retry
state instead of routing a projection error through a global modal alert. Visible Settings reads include
the successful `foregroundReconciliationGeneration` in their task identities and publication fences.
Foreground/reconnect readiness therefore reloads the current sheet and replaces stale offline errors;
scene activation alone does not claim connectivity. The Gateway lifecycle still owns reconnect, and
this revalidation never retries or replays accepted mutations. The iOS
projection validates bounded structure and paths while tolerating additive resource
categories and future metadata scope/origin values; its rejection copy identifies
whether the response exceeded the 768 KiB bound or failed structural admission.
Session History uses one prominent teal Liquid Glass summary (20-point vertical/trailing padding, 12-point leading inset, 16-point corners, a compact teal history icon with an 8-point text gap and bold body-size statistics), with 4 points of additional summary separation above flat, scroll-efficient event rows in one tagged feed, newest **recorded** entry first. The top Older/Newer control adds only 2 points of lower padding to the feed's standard row spacing; the bottom control retains the regular feed spacing.
Canonical append order, not device timestamps, resolves ties and clock skew. Messages, tool-only/thinking
responses, custom logs, compactions, branch summaries, model/thinking changes and bookmark receipts share
icon-free rows with semantic color and actual content previews. There is no separate Timeline/Branches/Log
mode or duplicated History heading. `SessionHistoryStore` retains one at-most-100-row window from
`session.history.list`. Matching compact teal icon pills (Older then Newer, grouped left) and exact one-based canonical entry ranges (right aligned and vertically centered) appear above
and below each batch. Pills retain 44-point tap targets; accessibility text sizes stack the controls and range rather than squeezing them. Ranges come from admitted cursor ordinals and the response total, not a page number
inferred from a moving head. On successful explicit Older/Newer navigation or Reload, the store commits the
new window and a new native scroll viewport identity in one fenced MainActor turn. SwiftUI materializes the
new lazy stack at its initial top and crossfades the batch, labels and controls; this deliberately replaces
an unreliable immediate `scrollTo` against an unrealized header. Reduce Motion disables these transitions.
Failed or obsolete reads never advance viewport identity. Errors overlay the retained page without moving
its rows; Retry preserves the failed request's intent. Bookmark/label refresh and unchanged-identity
covering/revealing retain the native viewport rather than replaying the first page. This is bounded loading beyond the former 1,000-entry outline, not merely
a lazy stack over a capped snapshot. A Gateway advertising `session-history-pages.v1` is required; an
older Gateway shows an explicit update notice, not an incomplete fallback.

A row opens `HistoryEntryDetailsSheet`; only its theme-matched ellipsis offers valid continuation, fork
and bookmark commands. Prompt continuation restores the prompt for editing; branch continuation stays
in the same canonical session. Forking opens only the new session identity returned by the existing
mutation receipt owner—branch entry IDs never become fabricated session links. Bookmark receipt actions
resolve the actual canonical target, and missing targets have no bookmark action. Accepted commands stay
with AppModel's mutation/receipt coordinators, independently of disposable presentation reads.

Entry content is fetched only after selection through `session.history.entry`, in at-most-24,000 UTF-16-unit
parts with explicit Continue reading/Previous part controls. The native selectable reader preserves authored
Unicode and line breaks; no preview or transport truncation is presented as the full body. Metadata is
separate under Entry information; there are no duplicated mutation rows in details. Images are identified
as attachments rather than dumped as base64. Arbitrary tool arguments/custom-log data belong in paged
content, never an unbounded metadata side channel. Scalar metadata is bounded and marks any clipping;
JSONL export remains the complete canonical audit, including media and producer metadata.
Both read owners deduplicate matching requests, fence all post-await outcomes by exact profile, mounted
target, runtime, reconciliation generation, presentation activity and latest request, and retain the last
completed page on transient errors. Retiring activity invalidates in-flight publication. Focused
`SessionHistoryStoreTests`, `ChatCompactPillTests`, and the production-sheet native-reader witness in
`SessionSheetPresentationTests` cover these contracts; synthetic light/dark captures are not device or
performance measurements.
Gateway produces that audit from a newline-terminated canonical byte cut captured briefly under the live runtime lane.
The bounded file copy and HTML rendering continue outside that lane, so running, retrying, compacting, and Bash-active
sessions remain exportable while later appends are deterministically excluded. JSONL does not linearize only the active branch.
Agent Instructions presents only the complete assembled `systemPrompt` from the existing
subscription-scoped context projection, rendered with the shared `TronMarkdownView` block renderer
(headings, lists, tables, quotes, and code) in a selectable scroll surface. Its Markdown document is prepared by the shared detached detail-preparation owner, keyed to the exact assembled source, so a covered or reopened sheet reuses the completed document instead of re-parsing the prompt on the main thread. There is no intervening summary, accounting,
capabilities inventory, or Read Full Instructions navigation step. It shares `TronDocumentSheet`
with file previews: large-only presentation, blue title and icon-only Done, hidden native
navigation background and bottom toolbar, a continuous document background, and the custom
top blur supplied by the scroll owner. Plain file-preview native document viewports extend through the bottom
safe area rather than ending at a blank strip; their internal insets protect the last line.
The plain native reader also extends behind the navigation title. Its actual UIKit navigation
safe area plus one 18-point TextKit inset protects the first line; the decorative blur's
full fade height is not a second header gap. Horizontal padding belongs only to TextKit,
and native layout never normalizes `contentOffset` (near-zero values are valid bounce
samples). Technical JSON attaches its blur to the viewport **inside** NavigationStack,
never above the title/actions. Medium/large, light/dark and editable/read-only readers are
covered by `SessionSheetPresentationTests`; native bounce/selection samples are covered
by `TronReadOnlyTextViewTests`. Full instructions and raw technical JSON use the
read-only TextKit viewer so selectable large documents lay out for their native viewport
instead of requiring one monolithic SwiftUI `Text` to be measured before presentation.
JSON serialization is prepared off the main actor and publication is fenced by the current managed activity and latest task. The completed document is keyed to its exact source and survives coverage/foregrounding without clearing native text, scroll or selection; source replacement alone prepares a new document. Table value labels use native head truncation and a bounded tail preview instead of a prefix preview, preserving the meaningful suffix without changing the underlying/copyable value or asking SwiftUI to measure an arbitrarily large field.
Nested structured JSON field sheets use the selected field name as their toolbar title, with an icon-only Done action and the value table directly below. They omit the selected-path block, repeated section heading and raw disclosure; descendants use the same presentation and retain exact root/path resolution. Their single scroll-owned blur stays inside NavigationStack, below the toolbar.
Every raw technical JSON affordance is the same non-disclosing row and opens selectable,
vertically scrollable protocol evidence in a wrapping single-column medium/large sheet;
technical JSON never creates a horizontal viewport; selectable raw JSON uses the shared
readable code scale across every standardized JSON sheet. Gateway runtime identities
use a protected title followed by a full-width selectable code value, so long hashes
cannot collapse the label column. A same-session reconnect that
installs a replacement Gateway runtime clears every secondary projection, advances its reload revisions, and rejects both
stale completions and stale failures by exact subscription token plus request generation.
Manage Session's Current Branch read is keyed to live presentation activity, exact
mounted target, profile, runtime, workspace and completed foreground reconciliation.
Activation before reconnection stays loading; admitted authority immediately restarts
the existing bounded inspection loop. Every response/error revalidates that identity,
so covered or replaced work cannot publish. Workspace folder/Go Up replacements use a
path-keyed 160ms fade at the row owner (disabled for Reduce Motion); loading, polling
errors and stale responses are not animation triggers.

Agent Defaults holds Model Defaults, Message Queue, Image Input, Retry, and Provider Transport (including the provider-attribution toggle backed by the SDK's install-telemetry setting). Branch-summary reserve lives with the other summary budgets in Compaction. Terminal-only SDK settings (thinking-block hiding, cache-miss notices, skill-command autocomplete, markdown rendering, Anthropic extra-usage warning, analytics, branch-summary skip prompt) have no Tron consumer and are not shown.
Free-text settings show a muted gray `(empty)` placeholder when their value is empty; the placeholder never changes saved text, and whitespace remains an authored value.
Context slider endpoint labels are bold monospace; Default remains purple/semibold in
the code face. Its title and endpoint labels are white in dark mode. Custom Models uses
the standard purple settings tint, while technical-detail rows retain their gray surface
independently of the destination's toolbar accent. Additional Locations uses plural
Extensions, Skills, Prompts and Terminal Themes row titles; empty resolved resource sections,
including Themes, retain a standard Liquid Glass placeholder row.

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
content-sized compact pill treatment while preserving 44-point semantic targets; every leading symbol uses the shared 13-point metadata scale, while progress pulses apply the shared 20% visual-footprint compensation to that nominal size, followed by the same five-point icon-to-label gap. A
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

## Presentation activity

A scene-owned `PresentationActivityCoordinator` owns the ephemeral stack of
mounted UI surfaces, including the scene's separately hosted notice window. It
is separate from Gateway session visibility and canonical state.
Only the topmost surface receives surface-owned publication, continuous animation, and viewport work. Its mounted ancestors continue only bounded data publication needed by the visible descendant; this keeps tool output plus tool/command completion and failure state current without running covered-surface loads, polls, automatic presentations, animation, or transcript viewport observation. Chat retains the exact pre-cover installed projection, coalesces live tool updates through the bounded projection worker, suppresses hidden native callbacks and row/chip motion, then performs one viewport rebase against the newest complete installation on uncover. Surfaces outside the active lineage retain their installed frame while authority
intake and user-started operations continue. On uncover, each inactive branch's presentation
owner derives one current aggregate and installs it atomically. Surface tokens
are generation-qualified, and a bounded exact-token tombstone ledger rejects content or descendants that arrive after their owning generation retired, so stale route callbacks and asynchronous results are
ignored. Binding intent registers a child before its transition begins. A
dismissal lease retains the exact retiring generation until SwiftUI's dismissal
callback, so cancellation and rapid re-presentation cannot retire a replacement.
All app-owned sheets and binding-owned system picker
and alert boundaries use the managed presentation modifiers; direct sheet
ownership outside that boundary is rejected by `packages/ios-app/scripts/test-source-policy.sh`.
The lexical guard rejects raw native sheet calls outside that owner, including
whitespace variants; it is not a proof of arbitrary system-picker/alert binding
semantics. Those bindings retain behavioral lifecycle tests.

Disposable view loads and polls include surface activity in their task identities:
cover cancels them and uncover restarts from current inputs. Success, error, and
loading-state publication must reject cancellation as well as stale source/request
ownership: cancellation of a sent read can throw `GatewayPossiblySentError`, not
`CancellationError`. Automatic and manual reloads share the surface's latest-read
lane. Keep useful last-complete data; Automation detail publishes record and run
reads together (not as a server transaction), and form preview/trust refreshes
never replace an initialized draft. Upcoming timeline demand stops under a sheet;
its catalog remains active to supply visible descendants' narrow revision facts.
Accepted saves, trust changes, terminal connections, canonical event intake,
receipt reconciliation, and foreground notification observation retain their domain
owners and are not cancelled merely because a surface is covered.

Manage Session's semantic projection contains no causal revision. Context-window
commands read the current authoritative revision/runtime at admission, while
pending settings retain exact request/runtime identity and wait for both RPC
confirmation and authoritative agreement. Native controls retain runtime/model
identity rather than being recreated on every progress revision. History, process,
queue, and tool-detail selectors belong to the session presentation store and
publish only changed bounded facts, never another canonical journal. A visible
queue editor passes its displayed queue revision/items into mutation admission;
a tool sheet resolves its selected calls from current bounded facts with the
existing live/canonical/terminal rules. An offline gap retains its last complete
read-only detail; a proven runtime replacement retires the old detail owner.
Neither requires a covered chat installation.

Cover suspends already-admitted transcript preparation as well as future intake,
retaining the installed frame. Native geometry and command callbacks carry an
activation that changes on cover and uncover, so delayed pre-cover geometry cannot
be admitted after reactivation. Exact target-lease cleanup remains allowed while
covered. Uncover retains its pre-cover baseline until the current source installs;
a new pinned tail uses the existing exact materialization/settlement lease so lazy
height estimates cannot leave the latest row invisible. Detached readers do not
enter that path. This reconciles the native viewport without resetting chat
identity. The dashboard likewise retains its atomic rows/activity snapshot
while covered. The composer's derived command-picker index also pauses beneath
managed sheets and outside the active scene, without pausing canonical command
intake or clearing its last installed value. The installed index retains its complete source identity atomically with its value. Picker rows, delayed menu actions, and selection require that source to match the current ready catalog; retained rows are not actionable during reload or replacement derivation. The native Add Commands and Add Prompts actions remain visible but disabled until the exact index is ready, independently of skill support (`ComposerResourcePickerTests.attachmentMenuResources`). Skills additionally require the current capability at discovery/menu admission (`ChatViewScrollHarnessTests.pickerRejectsRetiredCatalog`). Its existing task carries activity
plus exact command/target/capability identity, cancels detached preparation on
retirement, and rechecks activity/source ownership before publishing or reconciling
a selected resource. Uncover prepares only the newest complete command set.
The same catalog owns distinct extension-command, prompt, and skill partitions.
Menu pickers are category-exclusive; leading slash completion combines commands
and prompts without losing canonical source identity, while @ remains skill-only.
Initial derivation and typing share the same picker-scope resolver. Resource
presentation uses indigo for commands, purple for prompts, and cyan for skills.
Project scope takes precedence: every project entry shows only Project. User
requires both top-level origin and user scope; global package resources and
unknown/temporary scope do not receive User. The tags are mutually exclusive. Picker,
selected-chip, and detail titles share the same badge policy and styling.
Detail sheets can resolve provenance from their
admitted response when opened from a canonical transcript chip.
Receipt-bound prompt-template user messages display only unaltered invocation
arguments rather than expanded template instructions. The chip identifies the
prompt; no placeholder or empty user bubble is added for a prompt-only message.
The same display-only policy applies to optimistic, pending, queued, and
Automation prompt containers. Canonical transcript bytes, invocation identity,
queue editing, submission, and attachment identities remain unchanged; snapshots
and history rederive the input text from resource provenance, never text matching.
Messages without prompt provenance, skills, and commands keep their existing
presentation. The resource chip still opens the template detail sheet.
`ChatViewScrollHarnessTests.coveredChatDefersComposerCatalog` drives real command
responses under a native managed sheet or an explicitly inactive hosted scene and
checks suppressed worker admission, retained picker data, current canonical intake,
and the latest index on resumption. `retiredComposerCatalogDoesNotPublish` holds a
completed build through native coverage and source replacement, checks its rejected
publication and preserved staged skill, then verifies current reconciliation on
uncover plus retained native draft text/selection and tail geometry.
These hosted scene inputs do not certify physical lock/unlock behavior.
The stack is never persisted and is not a second state authority.

## Integration management projection

`IntegrationsRPCClient` and `IntegrationsSettingsView` expose the Gateway connection-owner contract as a native management surface. Lists remain lightweight account/server rows; capability names and effect-specific diagnostics are progressive details in the selected connection sheet. Definitions, account instances, capability status, and setup operations are redacted projections: the instance ID is the identity used by every action, never a provider name or account key. Same-provider accounts therefore retain independent policy, health, and disconnect state. Reads are fenced by the selected Gateway profile, lifecycle generation, connection epoch, presentation activity, and a latest-load ticket; a failed or unavailable child is not rendered as an empty success.

Settings exposes separate Connected Services and tools-only MCP Servers surfaces, both backed by this owner and filtered from its advertised definitions. Setup is owner-typed (`token`, `endpoint`, or `local-command`) and uses the Gateway's confirmed mutation receipt executor. The iOS form accepts only an opaque Mac Keychain credential reference, never token values or generic agent-readable secret fields. Endpoint and local-command configuration remain explicit; local commands are presented as trusted local code and are not shell-interpolated by the client. Policy controls (enabled, writes, paid, and recurring) are independent and instance-scoped. Capability availability is effect-specific: write capabilities require write approval, paid capabilities require paid approval and a positive bounded budget, and every capability still requires admitted credentials/runtime health. Mixed-effect MCP tools remain unavailable without write approval because the adapter's runtime prerequisite is write-enabled; the adapter also rechecks policy before each call. The same checks run at runtime binding admission; explicit Knowledge intake/approval flows retain their separate bounded semantics. Dismissing a sheet retires only presentation reads; an accepted setup, policy, or disconnect mutation continues with its owner, and reconnect never replays it. Capability rows distinguish setup-required, disabled, unavailable, unsupported, and available states and surface owner-provided error detail.

Policy writes include the instance's observed `expectedSetupRevision`; stale sheets fail closed rather than
replacing newer approvals or budgets. Accepted mutation tasks remain with the receipt executor. Their
activity-scoped observers rejoin on foreground return without replaying a command or publishing into
retired sheets. Setup checks the exact Gateway identity between begin and complete, because completion
is a separate command; a profile replacement leaves the original pending operation with its original owner.
Account technical details expose credential availability and account verification, never credential references.

Package/resource installation, trust, provider-model authentication, and Gateway pairing remain their existing owner routes rather than generic integration actions.

## Knowledge projection

`KnowledgeRPCClient` is the typed iOS consumer of the Gateway Knowledge contract. It
uses the existing confirmed-mutation receipt owner for every change and bounds
search and pages before exposing them to SwiftUI.
`KnowledgeDashboardView` presents All Knowledge (including All Links), filters by
record kind and Personal/Research scope, and loads detail evidence on demand. The catalogue is dense by
design—statement rows use one type step below the detail sheet with a bounded statement preview, and
non-observation rows use a smaller title, two-line summary, and caption metadata—so many retained
records stay visible. The dashboard's **Needs attention** menu item opens `KnowledgeCoverageDetailSheet`,
a standard medium/large managed sheet listing the cuts that need attention; the Gateway page is filtered to
`pending`/`failed`/`unavailable` (capability `knowledge-coverage-filter.v1`) so settled rows never enter
the list, and each cut keeps its own
Open and Clear controls so the sheet never merges them into one inaccessible element. Observation
rows use a
statement, scope tag, and source date; detail is a standard medium/large managed sheet with a single
originating-session row, not a repeated list of entry IDs. Its info button opens shared technical
metadata and the exact retained-record JSON, preserving all evidence/qualifications without duplicating
the statement in an Observed items section. Reflection is an explicit actions-menu operation.
Source object reads use the Gateway's authorization-checked `knowledge.object.read`
projection with the exact owning record ID and committed revision, and report
verified bounded bytes rather than caching a second corpus;
loaded chunks remain visible and can continue by the returned offset. Primary
source objects and retained provider-api/linked-article representations remain
in the typed DTO and are labeled in the same bounded object reader; corrections
copy those references rather than dropping canonical evidence. The originating-session action keeps
its exact history-entry citation through sheet dismissal; the existing session/history owner then
reads and presents that entry with bounded continuation, including when it is absent from the first
history page. Detail renders structured field values,
subjects, validity, qualifications, contrary evidence, and nested record/session
citations for source/note records; observation technical details retain the full protocol evidence.
Handoffs carry record/revision and Gateway identity metadata with explicit
untrusted-evidence wording, bounded structured qualifications/evidence, and a
bounded preview. The existing New Session owner still owns workspace/model/trust
inspection and preserves the user's edits; Knowledge records do not infer those
choices. Note confirmation is sent as
an explicit user action rather than defaulting an inferred or imported note to
confirmed; its original provenance remains unchanged.
Observation configuration requires an explicitly selected existing model and
either **All Tron conversations** or at least one selected session/project.
Global selection is an explicit `eligibility.allSessions: true` grant for future
turns across workspaces on the selected Gateway, not other apps, delegated
transcript ingestion, or historical backfill. Turning global selection off omits
the grant and restores the retained individual selections; empty selection never
grants global access. The switch and RPC admission require
`knowledge-global-observation.v1` so an unsupported Gateway cannot silently
ignore the setting. Exclusions always override either scope and remain
Gateway-authoritative. Editable current interests are persisted in the Gateway configuration and do not enable observation; source triage is an explicit `knowledge.source.triage` mutation that resolves those interests server-side. Starting a
session from an entry pins the originating Gateway and opens the existing New Session sheet for workspace/model/trust choices, then seeds only an unsent draft;
no prompt is replayed or automatically sent.

### Session search

The dashboard keeps title/path filtering local for immediate feedback. Content
search fans out only to the first eight eligible Gateway profiles selected by the
managed server filter; omitted profiles remain visible as skipped states. Local
catalog matches and remote passage matches are unioned into profile-qualified
session groups, with each profile reporting ready, partial, offline, error, or
skipped coverage independently. Content search uses the optional
`session-search.v1` capability and is request-fenced by the active Gateway
connection/profile; selected-profile requests use the foreground lifecycle
client, while background profiles use the dashboard connection pool. A short
input debounce coalesces remote fanout, and dismissal, reconnect, and profile
changes cancel owned disposable requests without cancelling accepted commands.
Neither a stale request nor a stale presentation activity may publish results.
Optional Jev reranking is
explicitly disclosed as sending the query and selected snippets to the
configured provider, and is never enabled without the user's consent and
allowance state.

Search results retain the canonical session, entry ID, branch/file anchor
revision, and nested passage identity. Selecting a result asks
`session.search.anchor` for a revision-checked bounded historical window, then
uses the existing presentation store and scroll coordinator; results never own
a second transcript cache or scroll position. The historical window carries its
own exact global ordinals/runtime/leaf identity and is explicitly separate from
the live tail, with a return-to-latest action. Branch, reconnect, or identity
changes expire it rather than mixing disconnected rows. Historical page values
and failures revalidate the exact presentation, subscription, connection, and
window after the final await; a same-session remount cannot inherit old work.
Render scroll is admitted after the mounted projection exposes the target
semantic ID and the viewport reports its current layout. Offscreen lazy rows
are materialized without requiring their not-yet-existing frame; relative
position restoration still requires frame evidence. Missing render targets
expire without issuing a stale scroll; anchor admission failures surface retry
guidance. Per-profile persisted policy is restored via
fenced `session.search.policy.get` after lifecycle/pool admission, with false-
safe visible errors. A Gateway that reports partial or unavailable semantic
coverage is displayed as such while lexical results remain usable.
