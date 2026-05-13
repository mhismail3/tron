# iOS App Architecture

> Last verified: 2026-05-13 (capability-native chat/dashboard/event rendering, engine thin-client boundary, Engine Console workers/policies/traces/primer/program-runs sections, server-owned storage/observability settings, live session and approval stream subscription before prompt send, Codex App Server dashboard/detail flow, new-session mode chooser, local diagnostics, MetricKit retention, feedback bundle, settings grid revamp, local paired servers, unreachable server settings, server-owned settings, provider status cards, Agent Control sheet entrance animation, onboarding handoff, and foreground connection recovery)

## Overview

The iOS app is a SwiftUI client that connects to the Tron agent server via WebSocket. It provides:
- Real-time chat interface with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input
- Capability-native invocation/result rendering for the live `search` / `inspect` / `execute` harness
- A staged input composer where pending skills and attachments share one wrapping chip row before send
- A mode-driven New Session sheet for quick Chat, Project workspace sessions, GitHub clone, and Claude Code import
- A separate Codex mode that connects directly to a Tron-managed `codex app-server` on the active paired machine without using Tron agent sessions
- A top-level Engine Console mode for live capability registry search, program runs, and operator readiness, with plugin, worker, binding, policy, index, trace, primer, and redacted audit details behind an explicit Advanced toggle

The server remains the source of truth for engine storage, observability, retention, and payload capture. iOS exposes those controls in Settings and sends sparse `settings::update` requests, but it does not own database cleanup, compression, trace reconstruction, or storage-policy decisions.

## Directory Structure

```
Sources/
├── App/                    # App entry point, delegates, configuration
├── Core/                   # Business logic extracted from other modules
│   ├── Concurrency/        # Async primitives (AsyncSemaphore)
│   ├── DI/                 # Dependency injection container
│   └── Events/             # Event handling infrastructure
│       ├── Plugins/        # Live event parsing (WebSocket -> UI)
│       ├── Transformer/    # History reconstruction
│       └── Payloads/       # Shared Decodable structs
├── Database/               # SQLite event database, queries
├── Models/                 # Data models, event transformers
│   ├── CodexApp/           # Direct Codex App Server protocol models
│   ├── Events/             # Event types and registry
│   ├── Features/           # Feature-specific models
│   ├── Messages/           # Message models
│   └── EngineProtocol/     # /engine frame, invocation, and stream codables
├── Services/               # Network, state management
│   ├── CodexApp/           # Codex endpoint store, token store, JSON-RPC transport/client
│   ├── Network/            # engine protocol, WebSocket (with Bearer auth), deep links
│   ├── Events/             # Event store, sync
│   ├── Audio/              # Recording, transcription
│   ├── Diagnostics/        # Local MetricKit store + redacted feedback bundle builder
│   ├── Feedback/           # Native Mail envelope for explicit diagnostics bundles
│   ├── Notifications/      # Push notifications
│   ├── Observability/      # DiagnosticsRedactor shared with Mac
│   ├── Onboarding/         # Pairing validator/probe/persistor
│   ├── PairingURLParser.swift  # tron://pair?host&port&token&label parser + builder
│   ├── Settings/           # PairedServerStore (local server list + active id)
│   └── Storage/            # KeychainItem, PairedServerTokenStore, EngineConsoleCache
├── ViewModels/             # View state management
│   ├── CodexApp/           # Codex mode state reducer and view model
│   ├── Chat/               # ChatViewModel and extensions
│   ├── Handlers/           # Event handling coordinators
│   ├── Managers/           # Specialized state managers
│   └── State/              # @Observable state objects, including EngineConsoleState
└── Views/                  # SwiftUI views
    ├── CodexApp/           # Codex dashboard, full-screen thread detail, setup/status, approvals
    ├── Chat/               # Core chat interface
    ├── EngineConsole/      # Capability registry/plugin/binding/audit console
    ├── Capabilities/       # Generic capability invocation chips, detail sheets, and result rendering
    ├── Tools/              # Shared support views still used by capability/source-control surfaces
    ├── Components/         # Reusable UI components
    └── ...                 # Feature-specific views
```

## Key Architectural Patterns

### MVVM with Extensions

Large view models split across extension files:

```
ViewModels/Chat/
├── ChatViewModel.swift              # Core state (~300 LOC)
├── ChatViewModel+Connection.swift   # WebSocket management
├── ChatViewModel+Events.swift       # Event subscription
├── ChatViewModel+Messaging.swift    # Message sending
├── ChatViewModel+Pagination.swift   # History loading
├── ChatViewModel+Reconstruction.swift # Session reconstruction + pagination
└── ChatViewModel+EventDispatchContext.swift  # Event handlers
```

### Coordinator Pattern

Coordinators contain stateless logic. Context protocols define the interface:

```swift
// Protocol (what coordinator needs)
@MainActor
protocol CapabilityEventContext: AnyObject {
    var activeInvocations: [String: CapabilityInvocationState] { get set }
    func updateInvocationState(_ id: String, state: CapabilityInvocationState)
}

// Coordinator (stateless logic)
@MainActor
final class CapabilityEventCoordinator {
    func handleCapabilityStart(context: CapabilityEventContext, event: CapabilityStartEvent) {
        context.activeInvocations[event.invocationId] = .running
    }
}

// ViewModel extension (provides context)
extension ChatViewModel: CapabilityEventContext { ... }
```

### Event Plugin System

Two systems handle events:

1. **Plugins** - Parse live WebSocket events → UI-ready Result
2. **Transformer** - Reconstruct history from stored events → ChatMessage

```
Live:   WebSocket → EventRegistry → Plugin → EventDispatchCoordinator → ChatViewModel
Stored: EventDatabase → Transformer → ChatMessage array
Console: /engine invoke(capability::*) → CapabilityClient → EngineConsoleState → EngineConsoleView
```

Live/stored `capability.invocation.started`, `capability.invocation.progress`,
and `capability.invocation.completed` names are capability lifecycle labels.
Active chat, dashboard, detail sheets, and history reconstruction render
capability invocations from `CapabilityIdentity`
metadata (`contractId`, `implementationId`, `pluginId`, schema digest, catalog
revision, trust/risk/effect, trace, and binding decision). Clean-slate local
storage means unsupported or malformed events are treated as diagnostics rather
than normalized through retired names.

### @Observable State Objects

Complex state extracted into dedicated objects:

```swift
@Observable
final class SubagentState {
    var activeSubagents: [String: SubagentInfo] = [:]
    var events: [String: [SubagentEvent]] = [:]  // Capped at 100 per subagent
}
```

## Key Files

| File | Purpose |
|------|---------|
| `Core/DI/DependencyContainer.swift` | Service initialization and injection |
| `Core/Events/EventRegistry.swift` | Plugin registration |
| `Core/Events/EventDispatchCoordinator.swift` | Routes events to handlers |
| `Models/UnifiedEventTransformer.swift` | History reconstruction |
| `ViewModels/Chat/ChatViewModel.swift` | Main chat state |
| `Services/Network/EngineClient.swift` | /engine client protocol, canonical invoke, and stream subscriptions |
| `Services/Network/Clients/CapabilityClient.swift` | Capability admin and primitive client for Engine Console |
| `Services/Storage/EngineConsoleCache.swift` | Read-only disconnected Engine Console summary cache |
| `Services/Network/Clients/ApprovalClient.swift` | Thin client for canonical `approval::resolve` decisions |
| `Services/Events/EventStoreManager.swift` | Local event persistence |
| `Services/CodexApp/CodexJSONRPCTransport.swift` | Direct Codex App Server JSON-RPC transport |
| `ViewModels/CodexApp/CodexAppViewModel.swift` | Codex mode setup, connection, thread, turn, and approval state |
| `ViewModels/State/EngineConsoleState.swift` | Live capability status/snapshot/search/audit state |
| `Views/EngineConsole/EngineConsoleView.swift` | Top-level capability operator console |

## Engine Client Boundary

The iOS app is a thin `/engine` client. It never owns Tron capability routing,
implementation execution, session mutation policy, or stream delivery rules. Write calls
carry an explicit `EngineInvocationContext` when the capability is scoped to a
session or workspace, and live session subscriptions send explicit stream
filters (`sessionId` and, when known, `workspaceId`) so the server can enforce
visibility with its engine stream primitives. Session history is reconstructed
with `session::reconstruct`; `events.session` subscriptions are live-tail only
and never replay a stored cursor into the view state machine. The client records
delivered cursors for ACK coalescing and diagnostics, not as the source of
session catch-up. The same session-scoped subscription setup also subscribes to
the engine `approvals` topic so high-risk capability gates surface from the
approval primitive worker instead of through a separate UI-only approval path.
User decisions invoke canonical `approval::resolve`; iOS does not mutate approval
state locally. ACKs are coalesced to the latest cursor per subscription so
bursts do not turn into one engine request per event.
Each visible `ChatView` starts and stops only its own `ChatViewModel` live-event
task. SwiftUI can create short-lived chat models during navigation and
reconstruction, so live-stream lifecycle is local to the view model that owns
the task. Duplicate server rows are handled by session sequence and cursor
dedupe; context snapshot refreshes are similarly coalesced inside each chat
view model so multiple UI triggers after one turn issue one
`context::get_snapshot` read and apply that server-owned snapshot to the local
projection.
Active subscription ids are per WebSocket, so they are cleared whenever the
transport leaves `.connected` and recreated at the engine topic tail after
reconnect. Catalog, ledger, idempotency, approval, lease, stream visibility, and
worker ownership stay server-side. Before sending prompt-producing agent writes,
the client awaits the `events.session` subscription; if that cannot be
established, it does not start server work that the UI cannot observe.
Foreground notification inbox updates follow the same thin-client rule:
notification capability completions delivered over `/engine` refresh the inbox, while
APNs remains the background device-delivery transport.

### Capability Console Boundary

`NavigationMode.engine` is the native operator surface for the live capability
architecture. It calls `capability::status`, `capability::registry_snapshot`,
`capability::audit_query`, binding functions, plugin functions, conformance, and
policy functions through `CapabilityClient`; it never reads a hardcoded tool
descriptor catalog. The default console surface is intentionally small:
Overview, Capabilities, and Program Runs. Advanced sections expose plugins,
workers, bindings, policies, audit, traces, and primer internals only after the
user opts in. `EngineConsoleState` owns refresh, search, inspect, local mutation
state, mutation gating, and disconnected read-only cache snapshots. The server
remains the source of truth for policy, authority, approval, audit redaction,
plugin lifecycle, and binding selection.

The Engine Console uses sheet-native Tron components: section chips, compact
metric grids, capability cards, status banners, generated action rows, and
inspection sheets. Capability search has its own loading/error/empty/results
state, so a failed search does not replace the overview or cached registry
state. Capability mutations also have local action state, so conformance,
plugin, binding, and implementation updates report success/failure without
collapsing the whole console into a failed load state. Operator search sends
explicit runtime metadata requesting degraded lexical search only when vectors
are unavailable; that policy is visible in the search result status and is not
applied to model turns.

The console cache is intentionally read-only. On disconnect, the UI shows stale
catalog/registry/index summaries and disables mutations. Reconnect refreshes the
live snapshot and replaces cached summaries when the server reports a newer
catalog or registry revision. The cache stores redacted audit rows only; full
payload reveal is a future server-authorized flow and must not be reconstructed
locally.

## Data Flow

### Codex App Server Mode

```
Codex mode UI
    ↓
CodexAppViewModel + CodexAppReducer
    ↓
CodexAppClient
    ↓
CodexJSONRPCTransport
    ↓
Tron-managed codex app-server on the active paired machine
```

Codex mode does not use Tron sessions, the Tron agent turn pipeline, or
`EventRegistry`/`EventStoreManager`. It does use authenticated Tron engine protocol for
discovery: `CodexAppModeView` asks `engineClient.codexAppServer.status()` for the
server-owned endpoint, bearer token, lifecycle state, and thread defaults. The
iOS view model keeps that data in memory only; Codex endpoint configuration and
the WebSocket bearer token are owned by Tron Server.

The UI mirrors the core session flow: a dashboard lists Codex threads, `+` opens
a draft full-screen thread view, tapping an existing thread routes to a full
detail view on iPhone, and iPad uses the same dashboard/detail split. The
dashboard auto-connects, auto-loads `thread/list`, and keeps polling managed
server status while disconnected so a restarted Codex child recovers without
manual refresh. Foreground transitions in Codex mode also recover the dedicated
Codex WebSocket: the view model disconnects the stale direct socket, refreshes
managed status through Tron engine protocol, reconnects, reloads `thread/list`, and resumes
the selected thread without replaying any turn. Detail views render text
messages and Codex tool items as one chronological transcript, show the newest
resumed history window first, keep older decoded entries outside the SwiftUI
list until Load Earlier Entries is tapped, and re-anchor after prepending older
batches. Failed/disabled server lifecycle states stay inside the dashboard as
retryable connection states; manual server configuration lives in the main
Settings sheet instead of an in-dashboard settings subpage.

### Live Events

```
WebSocket message
    ↓
engineClient.eventPublisherV2
    ↓
EventRegistry.parse() → EventPlugin → EventResult
    ↓
EventDispatchCoordinator.dispatch()
    ↓
ChatViewModel handler method
    ↓
UI updates via @Observable
```

### History Loading (Session Reconstruction)

```
SessionClient.reconstruct(sessionId, limit, beforeSequence)
    ↓  (calls session::reconstruct engine protocol)
SessionReconstructResult (events, isRunning, hasMoreEvents, oldestSequence)
    ↓
UnifiedEventTransformer.reconstructSessionState(from: events)
    ↓
ReconstructedState (messages, activeTools, pendingQuestion, ...)
    ↓
ChatViewModel.messages (batched for pagination)
    ↓
ChatView renders
```

Pagination: older history is loaded on demand via `beforeSequence`, passing the
`oldestSequence` from the previous page. `hasMoreEvents` controls whether the
"load more" UI is shown.

### Session Creation

The New Session sheet keeps shortcut paths separate from the standard workspace
setup. Quick Chat and Claude Code import sit in a compact shortcut row at the
top. Quick Chat applies a sheet preset instead of immediately creating a
session: it resolves the quick-session workspace, selects the chat profile mode,
and restores the default cloud model.
The main setup section is separated by a thin divider and contains recent
workspace pills, a profile-mode card (`Normal`, `Quick Chat`, `Local`), the
workspace picker, model picker, git worktree isolation for repo-backed default
sessions, and optional GitHub cloning. Selecting a local provider model forces
Local mode, and selecting Normal or Quick Chat from Local restores the default
cloud model. The toolbar Create button starts the currently configured profile
mode; Clone GitHub clones into the selected workspace and starts in the cloned
repository when not in Quick Chat mode. Imports preserve
the imported model and do not force the sheet's selected model. While switching
workspaces, the worktree card keeps its previous visibility until the new
git-repo probe resolves, then animates any actual appear/disappear change.

### Agent Control Sheet

The chat input-bar pill opens `AgentControlView`, a medium/large detent sheet
that summarizes context, model, source control, analytics, and history. Its card
containers use the shared `CardEntranceModifier` from `Views/Components/` for a
short opacity/vertical-offset reveal. The modifier owns that entrance animation
directly and clears inherited sheet transactions before applying it, so iOS 26
Liquid Glass container bounds do not inherit presentation springs or stretch
during the sheet's own open animation.

## Dependency Injection

All services injected via SwiftUI environment:

```swift
// App startup
@State private var container = DependencyContainer()

// In views
@Environment(\.dependencies) var dependencies
dependencies.engineClient
dependencies.eventStoreManager
```

### Service Lifecycle

| Type | Recreated On |
|------|--------------|
| Persistent | Never (eventDatabase, pushNotificationService) |
| Connection-based | Server change (engineClient, skillStore) |
| Codex mode | Active paired server change; foreground recovery resets the direct Codex WebSocket only |

Foreground/background handling for the primary Tron engine connection is owned by
`TronMobileApp` and the network services rather than by session views. SwiftUI
`scenePhase` changes call `DependencyContainer.setBackgroundState(_:)`, which
pauses WebSocket heartbeats while inactive and resets paused reconnect attempts
to `.disconnected` so the next foreground transition can kick a fresh retry. On
foreground return, the app verifies any apparently connected socket with a
bounded URLSession WebSocket ping before issuing notification or session-list
engine refreshes, and manually retries through the same path as the status pill when
the connection state machine says retrying is appropriate. Codex mode owns a
small mode-scoped foreground hook because its Codex WebSocket bypasses
`EngineConnection`; that hook refreshes only the direct Codex transport and does
not mutate Tron session state. Normal automatic recovery uses one short
two-second WebSocket-open probe; if that probe cannot connect, the transport
parks in the user-retryable failed/not-connected state instead of cycling
through repeated reconnect windows. Deploy-aware reconnect remains more patient
because `server.restarting` is an explicit signal that the Mac is expected to
come back. New engine WebSocket tasks also stay in
`.connecting` until URLSession reports that the WebSocket upgrade opened, so a
sleeping Mac cannot be reported as connected just because a task was resumed.
Foreground ping failures and ping timeouts transition the stale socket out of
`.connected` so the status pill and settings sheets immediately render the
reconnecting or unavailable state instead of waiting on server-backed engine protocol
timeouts. While foregrounded, the WebSocket heartbeat pings every five seconds
with the same bounded verification timeout, and URLSession's WebSocket close
delegate feeds remote closes into the reconnect state machine. Failed WebSocket
upgrade completions also resume the open wait immediately, leaving the 10-second
open timeout as a secondary guard instead of the primary failure signal. If a failed
open leaves an `engineClient` wrapper with a disconnected transport, the next
`connect()` discards that stale transport instead of treating it as an active
connection.

Session-scoped writes are intentionally thin-client calls: iOS includes the
active `sessionId` in both the request payload and the engine invocation context,
then the server owns idempotency, authorization, leases, ledger attempts, and
stream publication. Source-control repo metadata follows the same shape: iOS
first reads `worktree::get_status` and only asks repo capabilities for
divergence or sibling-session data when the server reports an active worktree
with a repo root.
`ConnectionToastPolicy` maps app-level connection state into the global
toast banner stack: when an active paired server becomes disconnected,
reconnecting, failed, or unauthorized, a deduplicated compact pill appears near
the top safe area with the appropriate repair affordance and hugs its content
up to a fixed maximum width. Disconnected/failed banners say `Not Connected`;
reconnecting banners say `Reconnecting`. Disconnected and reconnecting banners
are warning-yellow, failed banners are error-red, and all retryable connection
banners auto-dismiss after four seconds. Unauthorized re-pair banners remain
sticky because the stored credential must be repaired.
All connection banners clear as soon as the active server reconnects or no
active server remains, and reconnecting countdown ticks keep the same semantic
banner so they do not reset the auto-dismiss timer.

`SessionRefreshService` is the gatekeeper for `session::list` refreshes. It
debounces foreground refreshes, re-checks connectivity after the debounce, and
registers a single reconnect hook through `ConnectionManager` when refresh work
finds the socket offline or reconnecting. Native URLSession/POSIX transport
errors such as `NSURLErrorNetworkConnectionLost` or `ECONNABORTED` are
classified by `ConnectionErrorClassifier` and deferred to the reconnect flow
instead of being shown as session-refresh error banners. Non-transport
application errors still flow through `ErrorHandler` so real failures remain
visible. The server owns the dashboard query contract: iOS may pass
`workingDirectory`, `limit`, `offset`, and `includeArchived`, then caches only
the returned server-authoritative metadata for the active paired origin.

## File Placement Guidelines

| Type | Location |
|------|----------|
| Event plugin | `Core/Events/Plugins/<Category>/` |
| engine client | `Services/Network/` |
| State object | `ViewModels/State/` |
| Coordinator | `ViewModels/Handlers/` |
| Engine Console surface | `Views/EngineConsole/` |
| Capability chip+sheet | `Views/Capabilities/` |
| Reusable component | `Views/Components/` |

Settings pages live under `Views/Settings/Pages/` and are launched from the
main `SettingsView` grid. The root sheet supports medium and large detents and
starts at medium on iPhone. Its first grid row launches the surface-oriented
settings: App, Server, and Providers. Its second row launches agent-behavior
settings: Agent, Context, and Plugin Sources. The third row holds the destructive actions
without a separate Danger Zone header, while keeping those tiles error-red. All
main-grid icons use the shared settings tile size. A thin muted divider separates
the green destination rows from the destructive actions. The surface and behavior
tiles use taller containers with left-aligned emerald titles, top-right icons,
and smaller softer descriptive copy below, while the destructive row sizes to its
two-line red labels and top-right icons. When paired server settings are not
available, the main grid hides the server-backed destination tiles, stretches App
and Server across a two-column row, and places the persistent unavailable card
where the second green row normally sits.
Server-backed settings are grouped by behavior owner: Servers covers
pairing/security/transcription/updates, Providers covers auth credentials, Agent
covers execution lifecycle including hooks, prompt-history capture/retention,
queued-message delivery, and protected branches, Context covers
compaction/memory/skills/rules, and Plugin Sources covers external capability sources. Low-level hook
`add_context` budgeting stays an internal server fuse, not an end-user Agent
setting. Source-control action sheets expose merge, push, branch, and upstream
choices at the moment of action rather than through a separate source-control
settings destination. The main settings sheet keeps its container, sheet
presenters, lifecycle hooks, and alert presenters in separate computed view
sections so SwiftUI's type checker remains stable under Xcode 26 while the UI
stays declarative. Sheets that summarize server-backed behavior start with
`SettingsInfoCard` and derive the mostly-static title plus dynamic description
through small helpers in `SettingsSupport.swift` so copy and grouping rules are
covered by focused tests. Main-sheet icon strings live in the same support file,
and server-backed destination summary cards reuse their `ServerSettingsCategory`
icons so the launcher tile and destination stay visually aligned. The main
settings feedback footer is pinned with a bottom safe-area inset rather than
placed inside the scroll content, so app/version copy and the diagnostics action
remain reachable while the cards scroll independently. The feedback button lets
native interactive glass own the pressed border, matching chips and avoiding a
nested manual stroke. Send Feedback is mail-only: it builds the redacted
diagnostics JSON, opens the native Mail composer with the tracked support
recipient and attachment, and shows an alert when Mail is unavailable because
iOS does not reliably attach files through a default-mail-app handoff.
When the active paired server cannot be reached, Settings keeps local paired
server management visible but hides server-backed controls until the connection
returns and settings reload. The main sheet keeps App and Server visible,
removes Providers, Agent, Context, and Plugin Sources from the launcher grid, moves the
warning card above the destructive row, and disables destructive server-coupled
actions such as clearing prompt history and archiving all sessions. The Servers
sheet turns its top summary card
warning-yellow, reports `<server name> not available`, overrides stale row
metadata with an `Unavailable` status for the selected server, and limits that
row's menu to Retry and Forget. Settings verifies the live socket before loading
server-backed controls, so a half-open connection is demoted before the sheet can
get stuck on loading copy. The main dashboard owns the global unreachable-server
banner; Settings owns the persistent in-sheet warning surfaces.
Static status rows such as the user hook directory keep their path/value in the
trailing position and show a small empty-state placeholder when the server has
no listable detail to return.

## Build Configuration

Uses XcodeGen with `project.yml`:

- **Configs**: Beta (debug), Prod (release)
- **Minimum iOS**: 26.0
- **Swift**: 6.0
- **Versioning**: `VERSION.env` is the only hand-edited release identity file.
  `scripts/tron version sync` mirrors `TRON_VERSION` into the app and share
  extension as `TRON_CANONICAL_VERSION`, while Apple receives numeric
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` values. UI surfaces format
  canonical versions through `VersionDisplay`, so `0.1.0-beta.1` renders as
  `v0.1 (Beta 1)` without leaking Apple/Cargo constraints into user copy.

```bash
xcodegen generate
```
