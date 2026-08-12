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
WebSocket frame.
A just-created empty session remains locally selected until Pi indexes it after
its first user message; absence from discovery alone does not discard the
newly returned authoritative snapshot.

Events are invalidation or live-presentation hints. They do not form a durable
event journal and are never replayed into a local database. Reopening a session
always converges through `session.open`.

## Sessions

A snapshot contains phase, model, thinking level, queue state, transcript,
streaming projection, context usage, pending extension interactions, and runtime
diagnostics. Model identity is always `(provider,id)`; model IDs alone are not
assumed globally unique.

The composer supports text, native speech transcription, images, and bounded
file uploads. Images become native image input. Other files are represented by a
deterministic uploaded path envelope. Its historical context ring projects the
canonical context percentage and opens Manage Session immediately beside the
microphone; model and thinking configuration live in that sheet rather than as
bootstrap transcript rows. Disconnecting never implies aborting an accepted run.

## Security

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
retain a selected tint. Canonical session selection is
kept separate from dashboard navigation intent, so opening Settings or search
cannot reveal a previously selected session. Dashboard search autofocuses in a
floating bottom safe-area bar immediately above the keyboard. Modal detail flows dismiss
with the native top-right check action; top-left dismissal controls are reserved
for navigation, not app-owned sheets. Settings containers and their nested font
or model choices disclose as progressively stacked sub-sheets rather than
horizontal navigation pushes; connected-provider logout lives in the provider
row's compact action menu. The chat composer
floats over the transcript without an opaque footer; transcript content scrolls
behind it, a dynamic trailing clearance keeps the last response reachable, and
the scroll-edge policy is attached to each concrete ScrollView/List inside its
NavigationStack, matching the working non-gateway presentation boundary. Every
edge is explicitly soft because iOS 27's automatic top style can resolve to the
hard cutoff; Tron instead keeps the prominent graduated blur/fade.
System navigation-bar backgrounds remain hidden at that same boundary so
scrolling content reaches the toolbar and newer iOS releases can render their
native top blur/fade instead of having it masked by an app-owned material or
lost across a sheet-host boundary. Sheets never use pull-to-refresh;
session history, packages, and providers expose reload as an explicit toolbar
action while non-sheet dashboard refresh remains available. Every tool chip owns a tappable, top-anchored detail sheet, including
read/write/edit and filesystem search tools. The immersive camera retains the
pre-gateway flashlight, morphing shutter/confirmation, and flip/retake controls
over a full-sheet preview. A tool call and its canonical result are presented as
one progressively updated chip when both are in the bounded transcript page; an
unmatched result remains visible when its call is outside that page. Consecutive
tool-only entries collapse into a single compact run chip whose sub-sheet keeps
every tool and its individual detail available. Tool chips use a thin rounded
rectangle rather than a tall capsule. Transcript configuration changes, errors,
bookmarks, and extension statuses share one readable notification-pill language,
and thinking text and workspace shortcuts stay above the compact-caption scale.
The hidden custom back button is paired with a UIKit navigation bridge so the
native left-edge interactive-pop gesture remains available. Transcript rows enter with the historical soft
opacity/scale transition, and tool status/result changes use spring and opacity
content transitions. User turns are trailing-aligned while assistant and tool
content remain leading-aligned. Initial model/thinking entries describe
bootstrap configuration and are omitted from chat; later canonical changes are
shown as compact notification pills. Structured result data expands recursively, with raw
JSON only as the arbitrary-data fallback. Gateway connection state is driven by
the current authenticated socket, ignores stale cancellation from replaced
receivers, and uses gateway WebSocket heartbeats to keep Tailscale/iOS idle paths
alive. Canonical settings determine the default model; catalog order is never a
default-selection policy. Package and resource settings project Pi's canonical
global configuration even when a current project is untrusted. Deep session
history is projected iteratively with a bounded node count so large canonical
sessions cannot overflow the gateway stack. Terminal presentation retains the
historical connection indicator, options menu, native keyboard integration,
floating shortcut bar, command-key keyboard, soft edges, and selected bundled
code font over the gateway's retained PTY. System alerts, confirmation dialogs,
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
