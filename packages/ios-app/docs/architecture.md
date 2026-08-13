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
| `Sources/Support` | bounded cache, share intake, native speech |
| `Sources/UI/Chat` | session shell, transcript, composer, context, forks |
| `Sources/UI/Onboarding` | pairing, workspace, provider, and default setup |
| `Sources/UI/Settings` | agent, trust, packages, devices, migration, diagnostics |
| `Sources/UI/Terminal` | SwiftTerm adapter |
| `Sources/UI/Theme` | historical Tron colors and descriptor-based bundled typography |
| `ShareExtension` | app-group share handoff |

## State flow

`GatewayClient` performs one authenticated WebSocket connection, protocol hello,
request correlation, deadlines, and event delivery. `AppModel` is the MainActor
state owner. It loads a bounded disposable cache first, connects, fetches
cursor-paginated sessions and model catalogs, and replaces local state with
authoritative snapshots. Session snapshots carry a byte-bounded current
transcript tail; `transcriptStart`/`transcriptTotal` expose earlier canonical Pi
entries, which the chat can request backward without risking an oversized
WebSocket frame. Opening or resuming a long session starts at that bounded latest
page and offers a compact Liquid Glass earlier-history pill. Once the chat is
open, later authoritative snapshots merge their overlapping canonical tail with
all history already loaded in that viewport; live tool bursts and resynchronization
can never replace the visible branch with a shorter page. Explicit earlier-page
loads prepend rows and restore the former first-visible anchor so the viewport
does not jump.
A just-created empty session remains locally selected until Pi indexes it after
its first user message; absence from discovery alone does not discard the
newly returned authoritative snapshot.

Events are invalidation or live-presentation hints. They do not form a durable
event journal and are never replayed into a local database. `session.open` uses
a two-phase subscription barrier: the authoritative snapshot and ephemeral sync
token are returned first; iOS installs that baseline and acknowledges the token
before the gateway releases later events. While a resync is in
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
Tail-follow includes measured floating-composer clearance and reacts to both
response-state changes and later content-height settlement. Thinking, Markdown,
tool, and working rows therefore remain above the composer while the user follows
the tail; explicit user scroll-away always wins. Structural row insertions animate,
while stable long-history rows use equatable inputs and avoid stack-wide animation
for streaming progress. Terminal output has its own monotonic sequence and reconnect replay cursor.
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

The composer supports text, native speech transcription, images, and bounded
file uploads. Images become native image input. Other files remain agent-readable
through a deterministic canonical path envelope, while the mobile projection
removes that path and exposes only display-safe name/type/size metadata. Sent
images and files share one attachment strip above the prompt text: images use the
same square previews as pending photos and files use named chips. One gateway runtime is the sole mutable
owner of a canonical session; terminal and mobile chat clients must attach to
that owner rather than opening the same JSONL in separate Pi processes. Its
historical context ring projects the
canonical context percentage and opens Manage Session immediately beside the
microphone; model and thinking configuration live in that sheet rather than as
bootstrap transcript rows. Disconnecting never implies aborting an accepted run.

## Security

Current Tron builds do not register for local or remote notifications and do not
compute an icon badge from session state. On launch and foreground activation,
the app writes a zero badge only to clear SpringBoard state left by the retired
APNs implementation under the unchanged production bundle identifier. This
one-way cleanup does not request notification permission or restore push delivery.

Pairing accepts only `tron://pair` invitations containing a host, port, and
8–32-character one-time code. The permanent returned device token goes directly
to Keychain. Gateway profiles persist non-secret connection metadata only.
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
app Settings; Manage Session is owned by the composer's context ring. App-owned workspace
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
floating bottom safe-area bar immediately above the keyboard. Modal detail flows dismiss
with the native top-right check action; top-left dismissal controls are reserved
for navigation, not app-owned sheets. Settings containers and their nested font
or model choices disclose as progressively stacked sub-sheets rather than
horizontal navigation pushes; connected-provider logout lives in the provider
row's compact action menu. The chat composer
floats over the transcript without an opaque footer. Its UIKit text view is the
sole first-responder owner; SwiftUI mirrors delegate focus only for presentation,
so transcript relayout and programmatic tail-follow cannot dismiss a direct tap.
Transcript content scrolls
behind it, a dynamic trailing clearance keeps the last response reachable, and
the scroll-edge policy is attached to each concrete ScrollView/List inside its
NavigationStack, matching the working non-gateway presentation boundary. Every
edge is explicitly soft because the hard top style renders as an opaque cutoff
on physical iOS 27 hardware instead of Tron's graduated translucent blur.
System navigation-bar backgrounds remain hidden at that same boundary so
scrolling content reaches the toolbar and newer iOS releases can render their
native top blur/fade instead of having it masked by an app-owned material or
lost across a sheet-host boundary. Provider authentication is presented only by
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
setting before editing it.
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
scrolling while the outer SwiftUI layout measures only actual height changes.
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
streaming state, and rewrites active phases to `interrupted`. It is disposable
presentation state, not session truth.

## Removed architecture

The app has no Engine transport, SQLite event store, reconstruction plugins,
Activity feed, workers, reusable-agent management, coordination dashboard, or
worker speech service. Generic runtime tools and extension interactions are
rendered directly from snapshot contracts.
