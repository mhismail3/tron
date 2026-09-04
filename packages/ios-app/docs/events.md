# Gateway events

## Protocol v4 chat semantics

Session events are live invalidation hints; the authoritative snapshot and
canonical Pi JSONL determine transcript order and lifecycle truth. Typed chat
metadata separates direction, context effect, provenance, visibility, delivery,
semantic kind, and causal invocation/operation IDs. Inbound model context is
right aligned; assistant output and agent-requested tools remain left aligned;
non-context status is centered; hidden internal state has no chat row. Compact semantic
chrome has one cross-extension palette: user input stays emerald, commands are indigo,
tools are emerald, attributed extension context is violet, informational notifications are
blue, unknown context is slate, warnings are amber, and failures are red. Producer and
category remain explicit text so color is never the only signal.

Every compact command/context/tool/notification pill is payload-free: it shows the trusted
producer when available, the command or semantic category, and lifecycle/status only.
Arguments, notification bodies, context text, objectives, and arbitrary values live in the
tappable detail sheet and may wrap there without expanding transcript rows.

`custom_message` is model context regardless of whether it triggers a turn or is
producer-visible. Producer-hidden messages remain hidden in ordinary chat.
`custom`/`appendEntry` is context-free extension state and is hidden unless a
trusted typed adapter promotes it to a centered status. Extension `ui.notify`
callbacks are canonical bounded centered status receipts, never app toasts; their compact
row shows producer, **Notification**, and severity while the exact message stays in its
detail sheet. App notices remain reserved for product/system events. No generic extension message/state
is rendered as a ToolCard. Invocation receipts are bounded
canonical records used to reconcile accepted commands and resource prompts after
restart; uncertain side effects are never replayed automatically.

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

Provider authentication is the deliberate exception to ordinary transport-scoped presentation work.
`auth.event` and `auth.prompt` remain bounded disposable projections, but the Gateway operation belongs
to the authenticated device identity. A socket loss clears the presented prompt and foreground
`auth.resume` rebinds delivery without starting a second Pi login; `auth.completed` may therefore be
replayed from a bounded Gateway tombstone. An `auth_url` can also carry a Gateway-derived
`callbackCapture` descriptor containing only an opaque callback ID and exact loopback host/port/path.
The authorization code/state remain in the iOS listener's memory and travel either as the existing
Pi manual-code response or as the query-only `auth.callback` relay; they never enter snapshots, caches,
logs, or durable events.

`AppModel.handle(_:)` owns cross-domain routing; `SessionPresentationStore` exclusively
admits and reduces mounted-session topics:

- `session.summary` enters `SessionCatalogCoordinator`'s ID-indexed monotonic
  phase/name/count projection, so runs started by terminal or another mobile client update
  known dashboard rows synchronously without subscribing every device to every transcript or
  issuing a list request. A summary makes only that row live before full catalog completion;
  unknown summaries request discovery without fabricating a row. The same row projection carries
  Gateway-canonical completion/read-through attention. Additive `foregroundPhase` and
  `hasActiveSubagents` facts distinguish a settled parent response with delegated work still active;
  the dashboard maps that live combination to its subagent orb and treats omitted legacy facts as
  ordinary active foreground work. Additive `waitingForUser` is independent of phase and takes row-icon priority only on a live catalog projection; it shows an amber question bubble while an authoritative semantic interaction is pending, defaults false for older Gateways, and stale cached rows continue to use reconnecting activity rather than claiming current input authority. Its additive `activeSince` remains fixed for one
  continuous active period, so live `updatedAt` progress and heartbeat updates refresh row content
  without repeatedly reordering concurrent work; older Gateways fall back to stable profile-qualified
  identity for active-row ties. A final prompt response becomes unread only
  at truthful settlement. Once an exact synchronized chat is mounted on the active presentation lineage in an
  active scene, `SessionPresentationStore` publishes and renews a token-bound, revision-ordered
  `session.presentation.set` lease without waiting for scroll positioning or a first-ready-frame delay.
  Descendant tool, command, and detail sheets retain that lineage; an unrelated covering branch, inactivity, route retirement, subscription replacement, or
  connection retirement revokes it. Gateway uses the completion entry's one latched lease disposition
  for both canonical read-through and automatic completion-alert suppression. Opening still
  acknowledges only the completion revision installed by that exact presentation/connection owner,
  mounted unread summary revisions converge through the same absolute read operation, transient
  retries retain that revision, and explicit Mark Read/Unread mutations use command receipts and apply
  the returned monotonic attention projection immediately, including for a cold row with no live summary.
  Cached rows may show stale offline attention but never own it, while foreground and background
  profile event streams converge every dashboard; Gateway invalidates the catalog when it cannot
  broadcast a full summary rather than fabricating an unknown row. `session.listChanged` marks
  the shared traversal dirty instead of cancel/restarting it. User-scoped 500-row pagination
  has exact page/item/identity/cursor bounds and publishes atomically. Mixed page revisions
  and expired continuation leases restart once from a nil cursor and then retain the previous catalog silently; this expected
  optimistic invalidation no longer creates the intrusive “Sessions changed while loading the
  dashboard” in-app notification or another routine synchronization notice;
- `automation.changed` is a global, coalescible invalidation containing only the Gateway catalog revision and an optional opaque automation ID. It carries no name, prompt, notification text, target content, or run error. The typed client admits the payload bounds but does not create a local automation journal; the Automations dashboard pages `automation.list` under one exact revision and fetches full action content only through authenticated `automation.get`; its Upcoming agenda uses `automation.timeline.list` and requires `automations.timeline.v1`. Timeline windows are Gateway-generated, bounded to seven days per load, and grouped by the device timezone only for presentation;
- `notification.inbox.changed` is a global invalidation only. The selected lifecycle client and each admitted background dashboard connection reload that Gateway's bounded, revisioned notification pages; they never synthesize content or unread counts from the event. Mixed page revisions restart once, profile buckets aggregate newest-first, and Gateway command receipts own mark-one/mark-all read settlement. APNs taps may use their bounded request ID to mark the exact canonical row read, but that best-effort mutation never delays exact machine/session navigation;
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
  queued-message cards atomically rather than applying per-row mobile deltas. Protocol v4 requires
  both rich fields; iOS admits Edit/Remove only for that authoritative pair. A mutation response
  never rewrites queue projection locally: clear,
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
- `compactionQueued` is a bounded snapshot field owned by the Gateway's
  single pending maintenance slot. iOS renders it as explicit runtime feedback and never
  inserts a transcript entry or retries the mutation. The row is replaced by existing
  compacting feedback when the Gateway picks up the work, then by the canonical JSONL
  compaction entry. Current Gateways publish one immediate contiguous authoritative snapshot
  at `compaction_end`; it contains the fitted current tail/leaf (including hook-appended suffix)
  and truthful restored prompt/automatic-idle operation state; manual marker cleanup remains compacting
  until durable settlement. The typed `session.compaction` delta must identify one exact
  canonical compaction item; an inexact delta requests rebaseline.
  Stop includes the projected abort kind as advisory metadata and the authoritative operation
  ID as its safety fence. Gateway rejects a delayed tap if a newer operation has replaced it,
  preventing a stale control from aborting its successor, but never lets a stale kind narrow
  the escape hatch: every foreground cancellation controller and exact built-in bash process
  owner is invoked, and success is returned only after the fenced foreground work settles.
  `pendingPrompt` is the companion transient admission for a prompt
  whose canonical user entry is still being prepared, including automatic compaction
  during prompt preflight. The snapshot's `acceptsQueuedPrompts` fact comes directly
  from live Pi streaming state and is distinct from broad session phase and queue CRUD
  capability. Without it a prompt remains semantically ordinary (never a fabricated
  `queuedItem`) and uses the shared
  emerald queue-card visual with “Message” / “After compaction” until its
  canonical user entry arrives. Gateway binds that entry's
  bounded `presentationId` to the prompt operation ID, which iOS consumes before legacy text
  matching. Once the operation ID is known, text/attachment equivalence is never accepted as causal settlement. `session.operationFailed` is reserved for an exact operation proven unable to produce canonical input; only that sequenced fact retires and restores the matching admission. Receipt, binding, and runtime failures after queue or user-message disposition remain non-settling `session.diagnostic` events. A queued Pi call that rejects before either disposition is definitive RPC failure and releases its exact admission. Submission transport ownership is profile/session scoped across route generations, so leaving and reopening projects the same sending/accepted row without replaying the RPC. If the authoritative runtime generation changes before an accepted operation reaches canonical delivery, the coordinator retires any remaining optimistic row, restores its draft for review, and posts an outcome-unknown notice; Tron never automatically replays that prompt. One bounded local handoff preserves the same recovery after exact queue evidence has already retired the optimistic row. One unified physical row namespace spans committed, live/runtime, lifecycle, and queue content: Gateway projection binds the compaction operation ID to its canonical compaction entry, so the spinner and canonical pill update under one operation-based physical ID even when transcript bounds move from inexact to exact. The canonical entry ID remains its semantic identity. An exact operation-bound canonical handoff may likewise reuse the prior lifecycle's physical ID while retaining its canonical semantic ID. Skill, prompt-template, and extension selection travels as one bounded typed `resourceInvocation` rather than editor command text. The Gateway validates exact live `(source,name)` identity and extension precedence, retains the visible arguments in pending/queue projections, and removes Pi's expanded skill envelope during bounded transcript projection. Canonical binding receipts restore the resource chip after reconnect without exposing skill contents or private paths. Picker metadata comes from the bounded catalog; opening one resource detail performs a separate exact `session.commandDetail` read for that current `source:name`, bounded source body, and truncation facts. `session.resourcesChanged` revokes command-catalog readiness and starts one generation-gated reload for the exact mounted subscription before retained resource state can reconcile. An active upload for the exact presentation closes send admission synchronously; stale UI actions retain the draft, attachments, and selected resource until upload completion. Its initial role-aware entrance remains one-shot; composer collapse and the outgoing graft share one pre-mutation viewport generation. Every outgoing prompt is installed at full natural height using the canonical user row's full-width proposal and final horizontal alignment, then the complete text/resource/attachment row receives only a 20-point, 280 ms vertical translation and fade. Long text therefore keeps identical wrapping through canonical replacement. There is no source/destination measurement, row-height interpolation, overlay bridge, or handoff wait. Canonical authority may replace the payload atomically beneath the exact aliased physical row's retained transform owner without truncating or replaying the entrance. All sends use the same revision-current composer-height owner instead of a frame-count settlement guess. Optimistic composer settlement consumes every
  authoritative session-reducer publication directly rather than waiting for delayed transcript formatting. Lifecycle/queue-to-canonical header, status, attachment, resource, and container payloads install atomically and without prompt-container animation in the persistent physical host. Unrelated transcript updates do not inherit that transaction, and the terminal target contains its visual tail affordance so target release cannot add a second scroll correction. For queued steering/follow-up, the returned prompt operation ID is also the Gateway's
  stable queue-item ID, so a concurrent same-text item cannot settle the wrong optimistic admission. That exact
operation identity may coalesce the optimistic queue-kind row with its newly admitted authoritative queue card; baseline
operation IDs are never reused for aliasing, and aliases retire when authoritative queue items disappear. The queue row
never borrows an identity from pre-existing or unrelated items. Behavior is normalized before first render,
unknown values stay neutral, and each newly admitted prompt uses its role-aware entrance animation exactly once.

Resource invocation is one typed contract across composer, pending, queue, and canonical rows: the
source/name identity is captured once, arguments are the exact visible composer text (bounded to
5,000 UTF-8 bytes), and empty
arguments are valid for no-argument resources. Extension arguments are opaque and passed exactly;
Tron never lowercases or otherwise rewrites case-sensitive command syntax. Leading manually typed extension and skill resources
use Pi's literal ASCII-space delimiter; prompt templates use Pi's whitespace delimiter after extension
precedence. Embedded slash text remains ordinary prose. The
Gateway owns UTF-8 byte/control validation and rejects mismatched display/execution text. Canonical
invocation start receipts own immutable resource identity, binding receipts contain only the canonical
user target, and a binding persistence diagnostic never retires a successful operation. Queue edits
terminalize the prior immutable invocation and append a replacement under the stable queue operation
identity; explicit removal is an interrupted terminal outcome. Reconnect never replays an unresolved invocation.
Every pending, queued, optimistic, and canonical resource chip uses its composer resource theme
(cyan/blue for skills, violet for prompts, and indigo for extension commands), leads with the friendly resource
name, and shows the smaller resource kind second. The
entire chip is a tool-chip-style detail action; it reconstructs the exact catalog `source:name` and
opens the same bounded `session.commandDetail` sheet as the selected chip above the composer.
Queue admission and canonical handoff receipts suppress every later entrance; pending/queued-to-canonical replacement preserves canonical semantic IDs while one bounded one-to-one causal alias retains physical row identity. Compatibility matching includes exact optional resource invocation plus typed attachment facts, and exact attachment descriptors retain upload-derived chip identity across ordering changes; repeated text, unrelated resources, unrelated rows, and alias collisions fail closed. Replacement installs directly visible with an atomic authoritative payload; it has no hidden mount, height animation, or whole-container interpolation state. Exact off-main-prepared file
previews map through upload blob identity, and prepared image previews transfer by order only when complete count/MIME facts
agree; settlement performs no decode, while ambiguity uses normal media loading. Attachment-only canonical settlement uses an exact attachment metadata multiset even when Pi
  persists synthesized envelope text. `automaticCompactionEnabled` reports runtime truth rather than a mobile inference.
  Transcript projection captures the authoritative snapshot and composer handoff
  as one immutable commit; pending/outgoing rows render only from installed
  handoff state, while canonical reconciliation installs handoff `none`. A
  frame gate retains the previous complete commit until the replacement is ready;
- provider, package, settings, trust, and custom-model mutation invalidations
  advance owner revisions across connected clients; each visible surface reloads
  its explicit global or project scope instead of sharing a wrong-scope payload;
- authentication prompts drive the generic secure prompt sheet;
- `session.extensionPresentation` v3 remains the leased transport for semantic updates and native select/confirm/input/editor sheets plus one bounded atomic form sheet. Closing an interaction sheet is local presentation intent, never a cancellation response: the pending Gateway interaction continues waiting, and a bounded device-local draft keyed by session/interaction/epoch/revision restores selections, text, Other activation, and form page across navigation or app restart. Successful response or authoritative retirement removes that draft. The mounted chat route waits for its first ready transcript frame before presenting a pending interaction and remains the sole sheet owner, preventing sheet coverage from cancelling session opening or creating presentation loops. A dismissed pending audited `ask_user` form reopens through that route from its operation/owner-matched tool chip, while canonical completed tool-result details reconstruct the same questions and submitted answers read-only without retaining a second interaction mirror. Read-only statuses, widgets, and service activity no longer create an ambient composer or Manage Session surface; interactive prompts and editor ownership are unchanged. In particular, there is no Pi Subagents composer pill or generic extension summary route. Normal canonical `subagent` calls remain ordinary transcript tool chips, while the process orb/native **Subagents** sheet is the sole above-composer progress surface;
- the snapshot `processOverview` authority with its optional nonempty `processActivities` rows and compact `session.processActivity` events drive the current/recent projection only for admitted synchronous/asynchronous subagents; assistant commands remain ordinary transcript/tool activity. A delta carries an optional exact process upsert, bounded explicit removals, and one same-revision shallow overview. `SessionPresentationStore` applies that replacement atomically and resynchronizes instead of installing an overview around a stale or rejected row; it never rebuilds transcript projection or moves chat scroll state. Terminal lifecycle is latched; delayed full frames cannot resurrect or erase newer process evidence. The Gateway emits a replacement at the exact five-minute expiry even without another chat event. A mounted read-only sheet follows a replaced aggregate only when exactly one admitted row retains the same tool-call and root-run correlation; ambiguous replacements fail closed. The composer sheet reads mounted rows only, while `SessionProcessHistoryStore` loads canonical pages from `session.processHistory.list/get` for the exact presentation/history generation;
- `session.processTranscript.changed` is a lease-scoped invalidation, not a parent session-cursor event. `GatewayProtocol` dispatches it before the generic `session.*` envelope path. A mounted `ReadOnlySubagentSessionStore` accepts only its exact lease and newer revision, refreshes the newest page through that same lease, and retains already loaded earlier pages when canonical overlap proves append-only continuity. `session.processTranscript.abort` is a confirmed, capability-gated mutation for an active viewer only: it carries the exact lease rather than trusting a child ID from iOS, and Gateway revalidates the bound parent/process/run plus file identity before using the parent runtime's ordinary settled abort for synchronous work or the trusted subagent controller's exact root-run/child-producer stop for asynchronous work. The open response advertises per-lease `canAbort`; synchronous leases additionally fence the mutation to the foreground operation ID captured at open. Branch replacement or an unbridgeable gap falls back to the new canonical tail rather than fabricating adjacency. `open/page/close` responses preserve page range, canonical boundary, unique ID, and generation checks; transient current tool/output remains outside canonical transcript rows;
- producer-visible `custom_message` entries enter the ordered timeline as right-aligned inbound context, whether stored for a later model turn or triggering work immediately. Their compact row is **Producer · Context** when producer evidence exists, or simply **Context** when it does not, plus one status from Tron's finite lifecycle vocabulary (or **Received**); unknown/ad-hoc status strings are not promoted. It never includes custom type, message text, objective, or another payload value. Those values remain in the detail sheet. Gateway-authored context-delivery receipts preserve exact producer attribution and delivery mode after reconnect; unknown provenance stays neutral and is never guessed from custom type, text, or details. Producer-hidden custom messages remain absent from ordinary chat, while `custom`/`appendEntry` state never becomes a tool or message row;
- chat rendering joins canonical calls, live progress, and canonical results by
  `toolCallId` into one ordered timeline. At finalized assistant `message_end`, the
  Gateway publishes complete contiguous declaration groups before their tool starts.
  Runtime-only `groupId`, `groupIndex`, `groupCount`, and `groupFinalized` facts derive
  from the stable assistant presentation identity and first projected content ordinal;
  they describe declaration membership, never inferred parallel execution, and are not
  persisted to Pi JSONL. Provisional streaming calls remain hidden until that boundary.
  When finalized metadata arrives after a running chip mounted, one unambiguous prior call/group owner may retain the physical host; producer group and call IDs remain semantic authority. Tool status retargets icon/text/time inside one capsule with a lifecycle-stable glass surface rather than replacing the chip.
  Each call still carries a Gateway-issued monotonic execution ordinal and progress
  sequence so equal wall-clock timestamps cannot regress output. A display run keeps
  its first finalized group identity from invocation through completion, reconnect,
  and canonical settlement so final assistant text cannot jump ahead of or reinsert it.
  Gateway snapshots require a still-owned live presentation identity before projecting Pi's
  streaming message; canonical settlement cannot rotate a stale SDK frame into a duplicate group.
  Exact call membership also lets canonical projection suppress that one transient handoff frame
  if presentation binding and persistence are observed in opposite order. Gateway-owned `toolSegmentId`
  identifies one exact active conversation turn across live execution, canonical tool-only messages,
  and foreground catch-up. Equal nonempty segment IDs authorize consecutive producer groups to share
  one display run under its first finalized group ID; missing or different IDs fail closed to separate
  rows. Every call and source group remains independently indexed for detail, payload, and canonical-
  result ownership. Visible thinking, text, user input, notifications, and other transcript barriers
  flush the run in exact order even inside one segment. The Gateway retires runtime segment membership
  at agent settlement and deterministically reconstructs canonical segment boundaries on cold reopen,
  so continuous delivery and catch-up assemble the same bounded physical rows without cross-turn merges.
  `SessionSnapshot.activeToolSegmentId` is present only for an exact running-phase streaming agent segment,
  never retry, compaction, settlement, or idle ownership. User, visible assistant/custom, and canonical
  compaction barriers rotate that authority; a provisional no-match generation is published before any
  subsequent tool progress and is replaced by the next assistant's stable presentation identity. iOS combines it with the exact
  `acceptsQueuedPrompts` streaming fact: an unresolved declaration outside that segment, any declaration in
  retry/compaction, or any unresolved declaration when streaming is authoritatively false is terminally
  interrupted rather than being reactivated by a later prompt's broad active phase. Older compatible snapshots
  without active segment authority use the streaming-capability fallback when present; snapshots omitting both
  ownership facts retain the existing broad active-phase behavior.
  The Gateway supplies monotonic duration samples while a call is running and the
  authoritative final call-to-return duration when it completes. Visible running chips
  rebase each sample onto device uptime and advance locally between progress events;
  producer output cadence never acts as the clock. Declared invocations do not accrue
  execution time before the Gateway starts them. Terminal reduction and canonical handoff
  preserve the greatest accepted monotonic sample, so settlement cannot replace a longer
  execution with a near-zero late callback. The runtime-only
  tail overlay admits every authoritative execution without canonical or streaming placement. iOS
  preserves this ownership through projection: runtime-only and streaming rows stay in
  `ChatLiveRegion` and never become `ChatCommittedLedger` rows; canonical terminal results dominate
  any stale running runtime descriptor. Terminal unanchored executions
  remain visible until exact canonical transfer or authoritative operation retirement; they appear only through their
  canonical or streaming transcript position, while anchored terminal calls remain visible. Group counts never imply
  liveness: the chip spinner is driven only by an actually running descriptor. Structure-change notifications with
  `branchChanged: false` preserve an installed earlier-message prefix until an authoritative snapshot proves its overlap;
  only branch replacement retires that prefix.
  Older Gateways without live duration samples use the same bounded local monotonic clock
  from the execution start timestamp. Direct `session.bash` canonical rows from the current
  Gateway also carry optional exact start, completion, and duration metadata and render the
  same terminal elapsed treatment; older Bash history remains valid without timing. The open detail
  sheet continues to consume the newest immutable call presentation, showing status and all bounded readable
  latest bounded live-output frame. Each newer nonempty frame replaces the displayed frame in place rather than
  accumulating repeated status snapshots; an empty advisory frame preserves the last readable output so an open
  sheet never flashes blank. A terminal live projection whose output/result was intentionally stripped after canonical settlement enriches status and timing only; it cannot erase the canonical tool-result text used by detail sheets. The terminal nonempty result remains authoritative. Gateway and iOS apply the same
  replacement rule so reconnect or projection replacement cannot resurrect discarded frames or erase readable output. Explicit output-truncation state appears only when the runtime flag or
  structured truncation contract says `truncated: true`, and the age of the most recent
  runtime update without automatic scrolling. One mounted tool chip hierarchy presents the
  trusted producer plus tool name for a single invocation and **N tools** for an aggregate;
  extension provenance never substitutes **Extension activity**. Structural chip targets
  exclude duration and payload churn, coalesce for one display frame, and use a monotonic
  latest-target token for local interruptible animation while transcript and scroll
  projection transactions remain stable while the transcript boundary scopes suppression to installed-projection identity changes, preserving both the discrete Liquid Glass touch-down and its continuous drag transactions. The physical row host installs no second content transition around the chip; only the chip's shallow value owner animates, preventing overlapping snapshots of rapid parallel-group updates. Measured row entrance clips retain a layout-neutral effect gutter only during admission, then remove the clipping node entirely so the stable transcript chip retains its unconstrained native press-and-drag region. The one stable chip surface retains semantic tint as its value changes: running is amber, failure is red, and successful completion uses the emerald tool role. Legacy and consolidated transcript tool chips use native interactive Liquid Glass as their sole press-and-drag owner. Aggregate tool detail sheets instead use lazy full-width static summary rows, each with one accessible tap target. Transcript chip surfaces handle taps directly and expose explicit button accessibility semantics; they are not wrapped in a second native `Button` press phase, preserving the system drag morph without an immediate stacked zoom or custom scale/opacity effect. Multi-tool run chips show accumulated time as the sum of their
  invocation durations. Aggregate row summaries and individual detail routes install atomically for one projection tag,
  and rows remain in reverse canonical invocation order rather than switching when optional
  timing metadata arrives. Aggregate rows center status with the title, place command/path
  content below its label at full width, and show only bounded semantic context plus the
  newest two readable output lines. A bottom edge fade discloses more primary content and a
  top edge fade discloses earlier result content; no separate bounded-output warning line is
  rendered. Rows do not accumulate output frames. Raw protocol tool names drive built-in kind and icon
  selection while optional registered labels remain user-facing. Known built-ins derive only a
  semantic primary summary from exact request/result keys; compact protocol
  identifiers, timing, and progress remain first in Technical details, followed directly by
  complete Request JSON and Result JSON in that order. Result JSON prefers the response, then
  content-only output, then only a fallback distinct from Request. Exact current-runtime
  monotonic start-to-end durations are authoritative when available; older canonical history derives only
  an observed call-to-result interval because Pi JSONL does not persist tool execution timing;
- transcript structure has one explicit animation boundary: only rows with positive
  semantic-novelty evidence reserve their measured layout and reveal once after
  exact current-generation geometry admission, with one two-frame visual-only fail-open when an exact targeted zero-height child emits no frame. A page-bounded semantic ledger preserves
  displayed identities, suppresses duplicate entrances, and cannot evict currently visible
  rows. Pinned lazy insertion leases only its exact physical row target until fresh semantic
  geometry proves the requested row mounted; anchored/offscreen entrances are consumed by
  direct interaction or catch-up rather than a wall-clock reveal race. Installed-row
  updates, live-to-canonical settlement, thinking-height measurement, and tool status changes
  inherit no stack-wide animation. Already-mounted streaming assistant rows instead own one bounded local height transition for ordinary new thinking/response lines, while newly admitted tool and content rows keep their one-shot measured entrance even when lazy geometry admission precedes child mounting. The stable transcript transaction runs only when the installed projection identity changes and still admits explicit entrance/tool-chip markers; native-control touch-down and drag transactions do not cross that projection-only transform. Thinking height/tail motion is row-local downstream of that boundary. Authority-only changes whose bounded transcript/stream/tool/queue/runtime layout identity is unchanged take a synchronous metadata path and cannot arm settlement. The sole composer inset exposes one bottom-aligned measured height; a generation captured before structural mutation keeps pinned tail coupling nonanimated, preserves a detached semantic locus with zero tail commands, coalesces retargets, and yields immediately to direct interaction. Reduce Motion removes spatial transitions. Tool status text
  updates inside its stable row. Ordinary pinned growth and shrink remain coupled by one
  mode-qualified native bottom size-change anchor. A genuinely new lazy physical row may
  request one disabled exact-row materialization lease; payload, progress, completion,
  and canonical settlement create no command stream. Native
  bottom distance is bounded for display only: a visible rect beyond the physical content edge is
  not tail settlement. A deliberately detached reader retains the same viewport authority;
- structure/context/resource invalidations reload an already-presented History,
  Manage Session, Agent Context, or Project Resources surface from the runtime. Context,
  tree, and resource reads each carry a subscription-scoped request generation, so an older
  overlapping completion cannot overwrite newer evidence. Manage Session and its Workspace
  sheet read `workspace-inspector.v1` through the open session, so Gateway derives the root
  from the authoritative runtime `cwd`; no mobile path or cached branch can replace it.
  Filesystem/Git state has no canonical session event stream. Visible uncovered sheets perform
  bounded four-second reconciliation without publishing progress accessories into already-presented
  rows, retain the last useful projection through transient failure, and stop on coverage, background,
  or dismissal. Equal revisions do not republish, working-tree-only changes do not restart History, and
  Files metadata refreshes only while that tab is visible or on entry. A branch/tip identity change resets
  the prepared bounded History projection before a replacement page is admitted, rather than mixing generations.
  `workspace-history-diff.v1` admits a selected commit/file pair only through that same subscribed
  session and returns one bounded immutable patch for the nested shared diff sheet;
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
  An authenticated replacement handshake plus event activation returns the connection to `Connected`
  immediately; session, terminal, settings, provider, device, and mounted-presentation reconciliation
  remains subordinate and cannot strand a usable replacement in `Restarting`. Connection Settings
  polls file-authoritative update progress under one exact command identity, ignores an older command
  marker until the acknowledged helper publishes its own first state, and keeps that observer alive
  across the planned socket replacement. Its bounded drain aggregate never declares success,
  disconnects transport, or starts reconnect.
  Duplicate transport signals cannot replace the lifecycle owner or revive work after profile teardown. A supervised iOS device install intentionally emits no transport lifecycle event: receipt acknowledgement means only that the detached Mac helper was admitted, while the focused authorized-device sheet polls bounded `device.install.status` for its exact paired-device owner and stops at terminal state, focus replacement, backgrounding, or dismissal. The app overwrite may replace the socket and process; the next app launch performs an authoritative status read rather than replaying the install mutation. Its
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
bounded attempt fails closed and the opening surface presents its retry path; elapsed time never substitutes for
viewport evidence. The physical positioning lift resolves behind the opaque surface while the tail binding remains
owned through its completion, current non-lifted marker/geometry evidence, two unchanged display frames, and the exact target-release callback. A separate visual entrance then installs for one covered frame and crossfades that surface into the settled transcript's slight upward motion. The opening lease continues to exclude repair, paging, submission, and live projection until animation completion and the first ready frame; only then is the transcript interactive. A separate two-second post-reveal deadline retires the stale target and fails behind the opening surface; it cannot certify missing evidence or expose a displaced transcript. Direct user or accessibility interaction
cancels that arm. The composer
remains visible throughout opening, while sending stays disabled until readiness. Opening tail
positioning and post-reveal settlement are owned by the coordinator's mutually exclusive opening
phase. Automatic live projection intake remains coalesced through that phase and its applied target release, then submits only the newest desired cut. Ordinary pinned growth, shrink, streaming, and existing-row settlement create no command ownership. A genuinely new lazy physical row may own one exact-row materialization lease until fresh row geometry arrives; a one-second failure boundary releases missing geometry back to native pinning. Explicit
opening, catch-up, semantic restore, prepend, retained resume, and the bounded physical-tail repair remain distinct command owners; after they release, pinned mode
keeps `ScrollPosition` target-free and uses the native bottom size-change anchor with no recurring command stream. Repair is admitted only from current signed marker evidence and is cancelled by interaction or a newer layout epoch.
Short-content alignment remains bottom-owned by the native anchor; blank space stays above the tail. Editor-only composer height changes install atomically;
attachment, selected-skill, and resource-result identity changes use one value-scoped 240 ms smooth
host-height transition, disabled under Reduce Motion. Direct user movement away from the tail and
anchored mode select top retention and remain target-free. A pinned bottom rubber band remains pinned only within a bounded physical overscroll tolerance;
extreme past-bottom geometry cannot preserve automatic ownership, and catch-up appears after valid
direct geometry moves beyond the tail boundary.
Session subscription ownership is token-scoped end to end. The open response remains
provisional until sync acknowledgement and exact route-intent revalidation; both sync and subscription
credentials must be nonempty, printable UTF-8 tokens no larger than 200 bytes. Baseline plus its
already-drained contiguous event suffix then publish in one MainActor turn. The fitted tail mounts immediately regardless of its display-bearing count; earlier-page reads begin only from the mounted presentation and cannot make the conversation unavailable. A stale or failed
attempt closes only its provisional token, so a stale close cannot unsubscribe a newer same-session mount. Protocol-v4
peers always provide explicit subscription ownership. If a reconnect installs a new runtime generation for the same canonical session,
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

## Covered presentation surfaces

Surface coverage pauses only disposable presentation work. Gateway intake,
sequence admission, canonical reduction, accepted mutations, drafts, receipts,
and notifications continue unchanged. Ancestors of the topmost surface continue only the bounded data publication needed so a visible descendant tool or command sheet receives live output and terminal status; their own loads, polls, automatic presentation effects, continuous animation, native scroll callbacks, and viewport observation remain paused. Tool payload-only revisions use the indexed projection fast path and the worker remains serial/latest-wins. The covered chat retains one pre-cover viewport baseline and rebases once against the newest complete installation when uncovered instead of processing every hidden update. Covered branches outside that active lineage
retain their last complete installation and do not replay intermediate events.
When uncovered, the owning presentation store derives one latest aggregate and
installs it through the existing generation and frame-admission rules. Chat
retires an in-flight disposable projection only when it leaves the active lineage, retains its last
complete installation, and suppresses accumulated row entrances on the first
replacement. If coverage interrupts initial chat opening, uncover waits for the
retiring opening lease and starts one new exact opening only when still needed.
Dashboard summaries continue updating their indexed authority but publish one
rows/activity cut only after the dashboard becomes active again. Disposable
view loads, media preparation, and polls cancel on cover and restart from their
latest source identity on uncover; accepted mutations and transport operations
do not move into that lifecycle. A genuine cursor gap still uses normal
authoritative synchronization.
