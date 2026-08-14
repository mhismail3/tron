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
| `Sources/UI/Chat` | session shell, transcript, composer, context, forks |
| `Sources/UI/Onboarding` | pairing, workspace, provider, and default setup |
| `Sources/UI/Settings` | agent, trust, packages, devices, migration, diagnostics |
| `Sources/UI/Terminal` | SwiftTerm adapter |
| `Sources/UI/Theme` | historical Tron colors and descriptor-based bundled typography |
| `ShareExtension` | app-group share handoff |

## State flow

`GatewayClient` performs one authenticated WebSocket connection, protocol hello,
request correlation, deadlines, and event delivery. Its injectable transport ends
at WebSocket bytes, and its monotonic-clock and UUID inputs control only time and
identity generation. The production transport is an actor-confined ephemeral
`URLSession` owner and preserves the existing data frames, headers, deadlines, and
random UUID behavior. Scripted test sockets contain no protocol, session, receipt,
or event-admission policy; `GatewayClient` remains the only decoder and client
runtime. Gateway connection and disposable cache intervals use the shared typed
performance-signpost boundary. Signpost metadata is structurally limited to result
codes, item counts, and byte counts; identifiers, paths, methods, filenames, model
names, prompts, transcript content, and terminal output are never recorded. `AppModel`
is the MainActor state owner and shares the clock/UUID seams for Gateway reconnect,
synchronization, receipt, debounce, and command-ID work. Its visible-open interval
contains independently measured authoritative synchronization attempts; invalidated
attempts end as discarded rather than being mislabeled as successful. Receipt timing
begins only after an uncertain mutation response, never for an ordinary confirmed
mutation. Terminal open/attach uses one replay installer and closes its interval only
after reset or delta chunks are admitted.
It loads a bounded disposable cache first, connects, fetches
cursor-paginated sessions and model catalogs, and replaces local state with
authoritative snapshots. Session snapshots carry a byte-bounded current
transcript tail; `transcriptStart`/`transcriptTotal` expose earlier canonical Pi
entries, which the chat can request backward without risking an oversized
WebSocket frame. The synchronous transcript projection is measured at its pure
snapshot-to-timeline boundary and reports only aggregate projected row count. Opening
a new chat presentation always synchronizes a fresh authoritative bounded latest page; disposable cached or previously paged prefixes are never revealed as
its baseline. The transcript remains behind a nonblank opening surface until the
two-phase `session.open`/`session.sync` handshake installs its authoritative tail,
then the whole stage fades and rises in (opacity only under Reduce Motion). That
handshake immediately marks the stage ready; the first-ready performance interval
closes only after the next display-link frame proves that ready state was presented.
Native `ScrollPosition` starts at the
bottom and receives one same-turn best-effort positioning hint before interaction
is enabled, but physical layout callbacks are never a correctness gate because
SwiftUI may coalesce them. Test builds can admit one synthetic authoritative
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
and its final native geometry wins over the pre-load detached state.
A just-created empty session remains locally selected until Pi indexes it after
its first user message; absence from discovery alone does not discard the
newly returned authoritative snapshot.

Gateway restart uses a supervised drain contract. The request freezes new mutations,
waits for accepted agent runs to settle in canonical JSONL, then replaces the Gateway
process; active PTYs must be closed first because their process state is not restartable.
iOS keeps the chat mounted, follows `system.stopping` into its ordinary bounded reconnect
loop, and installs a fresh authoritative session baseline from the replacement runtime.
A restart response may be immediate or scheduled behind active runs. Unexpected process
death is different: a surviving run marker projects the session as interrupted and Tron
never replays the accepted prompt automatically.

Events are invalidation or live-presentation hints. They do not form a durable
event journal and are never replayed into a local database. `session.open` uses
a two-phase subscription barrier: the authoritative snapshot and ephemeral sync
token are returned first; the same opaque token remains the subscription ownership
credential after synchronization. iOS installs that baseline and acknowledges the
token before the gateway releases later events, and `session.close` only releases a
subscription whose current token matches. Older protocol-v2 gateways omit the
explicit ownership field; iOS safely treats their per-open `syncToken` as the same
identity during rolling upgrades, avoiding interruption of Gateway-owned runs.
While a resync is in
flight, iOS quarantines that session's events, discards those covered by the new
baseline, and replays the contiguous remainder. Gaps, runtime-generation changes,
buffer overflow, oversized frames, reconnect, and foreground activation all
converge through another authoritative open. Unknown sequenced session events
still advance the cursor so a newer app can add hints without forcing false gaps.
Dashboard phase/name/count updates use a separate bounded global `session.summary`
projection: every connected client sees active/settled rows without subscribing to
every transcript, while an opened chat receives the full sequenced snapshot and
stream/tool events. Structure, context, and resource invalidations refresh any
already-presented History, Fork, Manage Session, or Project Resources surface.
Chat uses one presentation timeline rather than separate canonical, streaming,
and live-tool tails. Tool calls, progress, and results join by `toolCallId`; the
Gateway supplies a monotonic per-run ordinal for parallel calls, and the grouped
row keeps the first call's identity as it moves from invocation to completion.
Consolidation applies only to consecutive tool calls: every canonical thinking,
text, attachment, or notification boundary flushes the current group, preserving
the exact Pi content order without hiding or moving thinking traces.
The immutable navigation session ID owns one opening task and one typed
`ScrollPosition`; duplicate dashboard opens and competing proxy scroll commands are
forbidden. The complete composer is the sole structural owner of the ScrollView's bottom
safe-area inset, including wrapped text, staged attachments, and supported extension widgets.
The retired `pi-subagents` async and fleet editor widgets are not mounted; unrelated extension
widgets retain their declared placement. Native safe-area layout therefore pushes the transcript
exactly once and reverses naturally when the
keyboard or composer contracts; no parallel `ScrollPosition` correction or focus-triggered
jump competes with it. Interactive transcripts use bottom initial positioning but top alignment
for undersized or lazily materializing content, preventing keyboard frames from repeatedly
re-anchoring a partial stack. Once a bottom command or manual catch-up settles inside the
practical tail boundary, its persistent `ScrollPosition` target is cleared without moving the viewport so later safe-area
changes cannot replay stale edge ownership. Viewport resize owns mixed resize/streaming frames:
a pinned reader receives only a bottom-edge command, while a detached reader receives no app
position write. Native ownership arriving after geometry consumes preserved directional evidence
instead of losing an upward gesture. Direct interactive scrolling always wins. A compact scroll coordinator is the sole owner of following intent: it
combines native `ScrollPosition` ownership, phase-final geometry, inset-aware bottom
distance, prepend ownership, and durable user scroll-away. A separate lightweight
performance tracker owns only interval generations: a replacement command discards
its predecessor, practical-tail observation settles the active command even when
SwiftUI already cleared its binding, and stale paging defer work cannot close a newer
prepend or paging owner. Upward user geometry is
the only ordinary transition from pinned to detached; native ownership alone cannot
detach a reader when streamed growth moves the physical bottom. A gesture commits
detachment only after its settled geometry has moved toward older content, so bottom-edge
rubber-banding cannot flash the catch-up control. While detached, a fixed action-sized circular
glass down-arrow morphs from the composer's trailing edge; multiline editor height can never
resize it. Reaching the practical tail boundary (with a small inset-rounding tolerance) or
tapping that control immediately re-pins the transcript. Long-distance
catch-up jumps without animation to a small reveal distance and smoothly animates only the
final approach, avoiding a jittery traversal through lazy history. Every later measured
height increase reissues a coalescible bottom command until another upward gesture.
Progress-only tool mutations cannot request a tail position. Keyboard and composer layout may
restore a logically pinned tail but cannot change the durable pinned/detached mode. Async editor
height measurements carry a latest-revision guard, so an older wrap measurement cannot overwrite
a newer line count. Every stable row owns its horizontal inset instead of relying on
transient ScrollView content margins, so prompt insertion cannot expose a flush-left frame.
Existing rows never participate in stack-wide insertion or scale animations. Thinking,
Markdown, tool, and working rows therefore remain stable above the composer while the user
follows the tail. Terminal output has its own monotonic sequence and reconnect replay cursor.
Secondary live-runtime reads require that exact session to be opened first, so a
stale selection cannot read or render another session's context, tree, resources,
export, or terminal inventory.
Backward transcript pages carry an entry anchor and are rejected if branch
navigation changed the requested boundary. Mutations whose response is lost wait
for reconnect and poll the bounded command receipt: completed results are reused,
only confirmed-missing commands are retried with the same ID, and pending outcomes
are never replayed automatically.

## Sessions

A snapshot contains phase, model, thinking level, queue state, transcript,
streaming projection, context usage, pending extension interactions, and runtime
diagnostics. Model identity is always `(provider,id)`; model IDs alone are not
assumed globally unique.

The composer supports text, system-keyboard dictation, images, and bounded file
uploads. It does not expose an app-owned microphone control until a proper voice mode exists.
Drafting remains available while authoritative opening finishes and throughout
an active turn; only submission waits for readiness. Active visible working state remains a
compact runtime row after the canonical transcript, including provider retry attempts, and
never changes the composer's structure. A non-empty active draft replaces the trailing Stop
action with Send and is admitted as a steering message, while an empty active
composer retains Stop. The keyboard remains focused after steering so multiple messages can
be queued without waiting for the current turn to settle. Camera, photo, and file actions
also remain enabled during an active turn: uploads stage locally and the eventual prompt
carries the same steering behavior as text. The native attachment menu derives enablement
from the immutable viewed session and an explicit authoritative phase; a missing phase remains
unavailable. Its identity changes only when the session or effective availability changes.
Menu selections enter one cancellation-aware queue and become
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
images and files share one attachment strip above the prompt text: images use the
same square previews as pending photos and files use named chips. One gateway runtime is the sole mutable
owner of a canonical session; terminal and mobile chat clients must attach to
that owner rather than opening the same JSONL in separate Pi processes. Its
historical context ring projects the
canonical context percentage and opens Manage Session at the composer's trailing
edge whenever no Send or Stop action is needed. When a draft adds Send, the action
scales and fades in at its final in-bar position while the context ring springs left;
Reduce Motion uses a short fade.
Model and thinking configuration live in that sheet rather than as bootstrap
transcript rows. Disconnecting never
implies aborting an accepted run.

## Security

Current Tron builds do not register for local or remote notifications and do not
compute an icon badge from session state. On launch and foreground activation,
the app writes a zero badge only to clear SpringBoard state left by the retired
APNs implementation under the unchanged production bundle identifier. This
one-way cleanup does not request notification permission or restore push delivery.

Pairing accepts only `tron://pair` invitations containing a host, port, and
8–32-character one-time code. `GatewayPairer` alone owns the narrow HTTP-data
boundary for `POST /v1/pair`; it builds the request and deterministically maps
HTTP status and response bytes while the transport owns no pairing policy. The
permanent returned device token goes directly to Keychain. Gateway profiles
persist non-secret connection metadata only.

`AppModel` admits one pairing attempt at a time. Supersession, forget, and switch
synchronously invalidate and cancel that exact task. Attempt identity is checked
immediately after HTTP returns, immediately before profile/Keychain save, before
connect, and after the connect-owned suspension boundaries. Therefore a stale
pre-commit HTTP result cannot persist or connect. This admission boundary is not
a Gateway connection epoch: a connection already suspended inside
`GatewayClient` still requires the Phase 2 generation hardening.

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
instead of adding a new toolbar destination. Tron preserves its bundled font
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
chips and details, structured-data disclosures, Manage Session content, and
settings groups use Tron's tinted Liquid Glass surfaces. The dashboard keeps
search as an explicit toolbar action, aligns workspace headers to the session
status column, uses compact separated session cards, and keeps relative activity
time at each row's trailing edge. Workspace headers and session cards share the
same 28-point status-icon anchor: 16 points of outer row inset plus 12 points of
card content padding. Selectable app-owned cards have one full-card
hit region and no decorative disclosure chevron. Dashboard session rows never
retain a selected tint; their trailing swipe actions rename or delete the exact
swiped canonical session without changing navigation selection. Canonical session selection is
kept separate from dashboard navigation intent, so opening Settings or search
cannot reveal a previously selected session. Dashboard search autofocuses in a
floating bottom safe-area bar immediately above the keyboard. The dashboard shows only
user sessions, including ordinary user forks; classified subagent backing sessions remain hidden.
Disposable caches from before session-kind classification are invalidated rather than briefly
presenting backing-process sessions as user sessions. Modal detail flows dismiss
with the native top-right check action; top-left dismissal controls are reserved
for navigation, not app-owned sheets. Settings containers and their nested font
or model choices disclose as progressively stacked sub-sheets rather than
horizontal navigation pushes; connected-provider logout lives in the provider
row's compact action menu. The chat composer remains visually floating without an
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
action while non-sheet dashboard refresh remains available. Every tool chip owns a tappable, top-anchored detail sheet, including
read/write/edit and filesystem search tools. The immersive camera retains the
pre-gateway flashlight, morphing shutter/confirmation, and flip/retake controls
over a full-sheet preview. A tool call and its canonical result are presented as
one progressively updated chip when both are in the bounded transcript page; an
unmatched result remains visible when its call is outside that page. Consecutive
tool-only entries collapse into a single compact run chip whose sub-sheet keeps
every tool and its individual detail available. Tool detail separates canonical
request arguments from response data, explicitly top-anchors short scroll content,
and begins immediately below native toolbar chrome. Tool chips use compact row spacing
and minimal visual insets while their semantic buttons retain a 44-point interaction
region. Thinking traces are noninteractive and never hide canonical text behind a
disclosure: adjacent thinking parts and their nonempty lines form one compact inline
paragraph, each presentation segment ends in an ellipsis, and newly appended segments
fade in unless Reduce Motion is enabled. Tool chips use a thin rounded rectangle rather
than a tall capsule. Compaction and branch-summary events use
content-sized transcript pills whose sheets contain the complete canonical summary;
compaction token counts use compact `K` shorthand.
Transcript configuration changes, errors,
bookmarks, and extension statuses share one readable notification-pill language,
and thinking text and workspace shortcuts stay above the compact-caption scale.
The hidden custom back button is paired with a UIKit navigation bridge so the
native left-edge interactive-pop gesture remains available. Transcript rows enter with the historical soft
opacity/scale transition, newly appended thinking segments fade independently within
their stable paragraph, and tool status/result changes use spring and opacity content
transitions. User turns are trailing-aligned while assistant and tool
content remain leading-aligned. Initial model/thinking entries describe
bootstrap configuration and are omitted from chat; later canonical changes are
shown as compact notification pills. Structured result data expands recursively, with raw
JSON only as the arbitrary-data fallback. Gateway connection state is driven by
the current authenticated socket, ignores stale cancellation from replaced
receivers, and uses gateway WebSocket heartbeats to keep Tailscale/iOS idle paths
alive. Canonical settings determine the default model; catalog order is never a
default-selection policy. Dashboard Settings explicitly exposes only global configuration; project scope,
trust, and project package actions appear only when Settings is opened from a
project session. Manage Session presents resolved extensions, prompts, skills,
context files, and tools as named, summarized resource rows over the canonical
projection; arbitrary arrays derive labels from stable name/path/source fields
instead of exposing positional “Item” labels. Resource Locations separates
optional discovery paths from advanced Mac runtime overrides and explains each
setting before editing it. Session storage is gateway-owned and is not exposed as
a backing-runtime location override.
Deep session history is projected as a bounded flat outline with depth, branch,
and current-path metadata so large canonical sessions neither overflow the
gateway stack nor exceed the mobile frame while history/fork sheets remain
usable. Manage Session displays the runtime-projected latest cache-hit rate—the
same canonical formula used by the terminal footer—and never derives a ratio
from cumulative iOS fields. Terminal presentation retains the
historical connection indicator, options menu, native keyboard integration,
floating shortcut bar, command-key keyboard, soft edges, and selected bundled
code font over the gateway's retained PTY. Pending and transcript images use
square previews with dedicated image sheets. A pending photo is a stable,
non-morphing preview target; its separate remove control owns a 44-point hit
region. Pending and sent photo chips share the historical medium-detent,
concentrically rounded preview with native pinch and double-tap zoom. Earlier-history loading, context summaries, and unread-response navigation share one
content-sized compact pill treatment while preserving 44-point semantic targets and the
exact visible transcript offset when rows prepend. The multiline composer
gives its capped UIKit text view sole ownership of caret visibility and internal
scrolling. The composer itself is the transcript ScrollView's bottom safe-area inset;
no height preference or synthetic transcript spacer mirrors its geometry.
Diagnostics parses the bounded
Gateway log records into level-filtered rows and copyable details rather than
showing raw JSON. Custom models have a guided provider/model editor while the
complete JSON remains an explicit advanced path and is validated before mutation.
System alerts, confirmation dialogs,
menus, document/photo pickers, and terminal emulation remain platform-owned, as
they did before the gateway migration. New features must compose these
primitives instead of introducing `.body`, `.caption`, stock bordered controls,
rounded UIKit fields, or system search and segmented styles.

## Offline cache

`SnapshotCache` admits snapshots only for the bounded session summary set,
limits transcript size and session count, strips transient interactions and
streaming state, and rewrites active phases to `interrupted`. Load/save signposts
report only admitted aggregate item and encoded-byte counts. It is disposable
presentation state, not session truth.

## Removed architecture

The app has no Engine transport, SQLite event store, reconstruction plugins,
Activity feed, workers, reusable-agent management, coordination dashboard, or
worker speech service. Generic runtime tools and extension interactions are
rendered directly from snapshot contracts.
