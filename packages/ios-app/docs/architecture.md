# iOS App Architecture

> Last verified: 2026-06-05 (worker-first Work dashboard and worker detail sheets over `agent::work_snapshot`, worker-first chat/action detail projection, plain Guardrails settings UX, worker-first autonomy settings parity, post-scorecard recent-gap campaign activated, HMH-F7 reconnect chaos proof, Agent Control local-first card summaries, Agent Control semantic card buttons, lightweight source-control diff summary loading, canonical content-aware iPad liquid-glass sheet sizing, iPad prompt Tab no-draft behavior, Agent protected-branch Tab no-submit behavior, dashboard session-card worktree metadata projection, iPhone relaunch preload, persisted processing state, capability-native chat/event rendering, server-owned approval resolving/read-only state and consequence metadata, disconnected approval decision fail-closed guard, engine thin-client boundary, Engine Console semantic section/suggestion chip controls, live substrate-derived Engine Console search suggestions, Engine Console Created by Agent projection over registry plus live catalog snapshots, Engine Console workers/policies/traces/primer/program-runs/substrate sections, module package/config/activation/trust/health/evidence/action projections, server-authored module package/activation generated surfaces, server-authored generated `ui_surface` inspection/refresh/action flow, session-generated capability generated UI submit-coordinate proof, strict restrained-motion generated UI renderer for `ui_surface` refs, Engine Console offline cache fail-closed mutation guards, server-owned storage/observability settings, fail-visible local EventDatabase temporary-cache mode, live session and approval stream subscription before prompt send, new-session mode chooser, local diagnostics, MetricKit retention, feedback bundle, settings grid revamp, local paired servers, unreachable server settings, server-owned settings/model projection, strict source-control git policy/event-origin projection, direct-branch Source Control affordances for passthrough git checkouts, provider status cards, Agent Control sheet entrance animation, deferred settings-to-onboarding handoff, explicit onboarding Back/Next controls, foreground connection recovery, simulator-safe audio capture, retired direct integration removal, and fixed Automations/Voice Notes dashboards removed)

## Overview

The iOS app is a SwiftUI client that connects to the Tron agent server via WebSocket. It provides:
- Real-time chat interface with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input
- Worker-first invocation/result rendering for the single model-facing `execute` harness and server-owned generated UI actions
- A staged input composer where pending skills and attachments share one wrapping chip row before send; staged skill chips expose separate detail and remove accessibility actions while sent message skill chips stay compact
- On iPad, hardware Tab in the prompt composer and Agent protected-branch field resigns input focus instead of inserting hidden draft text or submitting a setting; broader control-to-control keyboard traversal remains a separate visual QA concern
- A mode-driven New Session sheet for quick Chat, Project workspace sessions, GitHub clone, and Claude Code import
- A top-level Work mode that reads the server-owned `agent::work_snapshot` projection and shows autonomy, active work, workers, recent results, guardrails, and one Audit Details entry point. Worker detail sheets show server-supplied health, trust, generated controls, selected-worker guardrails, abilities, recent work, and audit refs. Technical capability registry, catalog, plugin, binding, policy, trace, primer, and generated-surface inspection remains available only behind Audit Details.
- No fixed Automations or Voice Notes dashboards; reusable cron and voice-note protocol pieces remain capability modules until generated/control surfaces replace them

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
│   ├── Events/             # Event types and registry
│   ├── Features/           # Feature-specific models
│   ├── Messages/           # Message models
│   └── EngineProtocol/     # /engine frame, invocation, stream, catalog, control, and generated UI codables
├── Services/               # Network, state management
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
│   ├── Chat/               # ChatViewModel and extensions
│   ├── Handlers/           # Event handling coordinators
│   ├── Managers/           # Specialized state managers
│   └── State/              # @Observable state objects, including WorkDashboardState and audit console state
└── Views/                  # SwiftUI views
    ├── Chat/               # Core chat interface
    ├── Work/               # Worker-first Work dashboard and worker details
    ├── EngineConsole/      # Capability registry/plugin/binding/audit console
    ├── Capabilities/       # Generic capability invocation chips, detail sheets, and result rendering
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
Work:   /engine read(agent::work_snapshot) → AgentClient → WorkDashboardState → WorkDashboardView
Audit:  /engine invoke(capability::*) → CapabilityClient → EngineConsoleState → EngineConsoleView
```

Live/stored `capability.invocation.started`, `capability.invocation.progress`,
and `capability.invocation.completed` names are immutable server lifecycle
labels. Active chat, dashboard, action details, and history reconstruction
render those events as Work: the default projection shows a high-signal chip and
detail rows for what happened, why it ran, the worker, status, result, and
compact inputs. The projection is still built from server-owned
`CapabilityIdentity` and `presentationHints`; iOS does not infer policy,
lineage, approval, or routing truth from display strings. Raw request/result,
schema digest, trace, binding, policy, and approval-state payloads remain behind
Audit Details. Clean-slate local storage means unsupported or malformed events
are treated as diagnostics rather than normalized through retired names.
Assistant message metadata renders server `tokenRecord` truth directly: the
up-arrow value is provider-reported raw input, the down-arrow value is raw
output, and server cost is locally printed once as a dollar amount. The
computed new-input delta remains server-owned context-accounting state rather
than a visible substitute for provider input.
Action detail sheets lead with a Work summary and a horizontal
Choose/Prepare/Run/Finish progression. Execution path, selection policy, schema
digests, raw requests, raw results, and approval state are available behind
Audit Details so the default sheet explains the work before showing audit
metadata.
The progression is a clipped horizontal viewport inside the Progress section;
cards may scroll, but must not paint outside the section container.
Live `agent.compaction_started` events render a single transient progress pill.
Successful `agent.compaction` events become visible compaction summaries, while
server terminal no-op events only retire the spinner because no
`compact.boundary` was committed.

### @Observable State Objects

Complex state extracted into dedicated objects:

```swift
@Observable
final class SubagentState {
    var activeSubagents: [String: SubagentInfo] = [:]
    var events: [String: [SubagentEvent]] = [:]  // Capped at 100 per subagent
}
```

Subagent chips are fed by server-owned lifecycle payloads. Live events and
history reconstruction decode optional `taskProfile` and `modelRouting`
presentations, store them on `SubagentInvocationData`, and render compact
task/model/result lineage. The app never chooses hosted routes or infers route
policy from raw model ids.

## Key Files

| File | Purpose |
|------|---------|
| `Core/DI/DependencyContainer.swift` | Service initialization and injection |
| `Core/Events/EventRegistry.swift` | Plugin registration |
| `Core/Events/EventDispatchCoordinator.swift` | Routes events to handlers |
| `Models/UnifiedEventTransformer.swift` | History reconstruction |
| `ViewModels/Chat/ChatViewModel.swift` | Main chat state |
| `Services/Network/EngineClient.swift` | /engine client protocol, canonical invoke, and stream subscriptions |
| `Services/Network/EngineConnection.swift` | WebSocket transport state machine, heartbeat, reconnect, request/response routing |
| `Services/Network/EngineConnectionTypes.swift` | Connection state, connection errors, bearer-token resolver, one-shot continuation box |
| `Services/Network/EngineConnectionProtocolFrames.swift` | `/engine` wire frames and WebSocket URLSession delegate |
| `Services/Network/Clients/AgentClient.swift` | Agent prompt, queue, subagent, and server-owned Work snapshot client |
| `Services/Network/Clients/CapabilityClient.swift` | Capability admin, catalog watch, control, and generated UI primitive client for Audit Details |
| `Models/EngineProtocol/EngineProtocolTypes+Catalog.swift` | Catalog watch snapshot DTOs for live worker/function/trigger projections |
| `Services/Storage/EngineConsoleCache.swift` | Read-only disconnected Engine Console summary cache, including redacted generated UI refs |
| `Services/Network/Clients/ApprovalClient.swift` | Thin client for canonical `approval::resolve` decisions |
| `Services/Events/EventStoreManager.swift` | Local event persistence |
| `ViewModels/State/WorkDashboardState.swift` | Thin state object for `agent::work_snapshot`, refresh, blocked-work status, and worker detail filtering |
| `ViewModels/State/EngineConsoleState.swift` | Live capability status/snapshot/search/audit state behind Audit Details |
| `ViewModels/State/EngineConsoleCreatedByAgentProjection.swift` | Read-only Created by Agent shelf projection over session-created capability lineage from registry/catalog snapshots, generated surfaces, audit, and program runs |
| `ViewModels/State/EngineConsoleModuleProjection.swift` | Typed read-only projection over server-authored local pack/config/activation/trust/health/action rows and pack/activation generated-surface targets |
| `Views/Work/WorkDashboardView.swift` | Top-level Work surface for autonomy, active work, workers, results, guardrails, and Audit Details |
| `Views/EngineConsole/EngineConsoleView.swift` | Audit Details capability operator console |
| `Views/EngineConsole/EngineConsoleSection.swift` | Engine Console section identity |
| `Views/EngineConsole/EngineConsoleComponents.swift` | Console-specific section chips, metrics, cards, rows, and inspection sheet components |
| `Views/EngineConsole/EngineConsoleCreatedByAgentView.swift` | Native Created by Agent shelf for session-created capability history, provenance, tests, surfaces, promotion, cleanup, and trace evidence |
| `Views/EngineConsole/EngineConsoleModuleProjectionView.swift` | Native local pack projection card for pack/config/activation/trust/health/evidence/action rows and server-authored surface-open controls |
| `Views/EngineConsole/GeneratedUISurfaceView.swift` | Strict SwiftUI renderer for fixed-catalog server-authored generated UI resources, including session-generated capability surfaces; uses Tron typography/color tokens, restrained native row expansion, and submits only stored action coordinates |
| `Models/Messages/CapabilityInvocationTypes.swift` | Capability invocation lifecycle DTOs, artifacts, results, and errors |
| `Models/Messages/CapabilityInvocationDisplayModel.swift` | Server-authored invocation display projection and audit metadata |
| `Models/Messages/CapabilityInvocationWorkRows.swift` | What happened / Why / Worker / Status / Result rows for Work action details |
| `Models/Messages/CapabilityInvocationProgressModel.swift` | Choose/Prepare/Run/Finish progress projection for action detail sheets |
| `Models/Messages/CapabilityPresentation.swift` | Capability status color, icon, and label presentation helpers |
| `Views/Capabilities/CapabilityInvocationViews.swift` | Work chip, action detail, result, and Audit Details shell |
| `Views/Capabilities/CapabilityInvocationDetailComponents.swift` | Detail sheet header, execution groups, readable rows, and raw disclosure components |
| `Views/Capabilities/CapabilityResultRenderers.swift` | Capability result summary/rendering components |

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
Workspace self-extension approvals are keyed to
`self_extension::grant_workspace_autonomy`, so chat copy can say "Allow local
capability work in this workspace" while grant ids, traces, and target metadata
stay in Inspect.
Approval records carry server-snapshotted `targetMetadata` for the requested
function's effect class, risk level, required authority, idempotency contract,
resource lease requirement, and compensation contract; the sheet renders those
sections from the record along with the original grant/scopes/idempotency key.
User decisions invoke canonical `approval::resolve`; iOS never accepts or denies
approval locally. After the user submits a decision, the chip may render a
transient read-only `resolving` state while the engine request is in flight, but
the final approved, denied, executed, or failed state must come from the
`approval::resolve` response or the approval stream. Non-pending approval sheets
hide decision controls, and matching terminal approval events dismiss any open
sheet so stale local UI cannot remain actionable after server truth advances.
ACKs are coalesced to the latest cursor per subscription so bursts do not turn
into one engine request per event.
Large client files are split by client-owned concern only: transport state
types and wire frames stay beside `EngineConnection`, Engine Console components
stay beside the console view, and capability invocation display/presentation
helpers stay beside the message models and invocation views. Those splits must
not introduce capability policy, routing, approval truth, generated-UI
semantics, or server-owned product state into Swift.
The local `EventDatabase` is a projection/cache. If Documents storage is
unavailable at launch, the app uses `temporaryCache` mode rather than
crashing, logs that mode, includes it in diagnostics bundles, and shows it in
Engine Console. The temporary cache is never server truth: it cannot construct
grants, generated UI action targets/templates, resource lineage, or capability
policy.
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
APNs remains the background device-delivery transport. Read-state mutations are
also connection-gated and never optimistic: `NotificationStore` mutates local
rows only after `notifications::mark_read` or `notifications::mark_all_read`
returns, uses the server's global `unreadCount` for badge truth, and surfaces a
toast if the action fails. Detail mark-read calls carry the row's `sessionId`
when available; global Read All stays unscoped, while session-open auto-read
uses `notifications::mark_all_read(sessionId:)` so one session cannot clear
another session's unread rows. On iPad, notification inbox and notification
detail presentations use compact liquid-glass form sizing so the split-view
dashboard remains visible behind them; iPhone keeps the standard sheet detents.

### Work Dashboard And Audit Boundary

`NavigationMode.work` is the native product surface for autonomous work. It
calls `agent::work_snapshot` through `AgentClient`, then renders the returned
server-owned projection without joining registry, catalog, approval, policy,
or audit internals in Swift. The default dashboard is intentionally small:
Autonomy, Active Work, Workers, Guardrails, Recent Results, and one Audit
Details row. Worker cards and detail sheets use labels, health, trust,
generated controls, selected-worker guardrails, abilities, milestones, and
audit refs supplied by the server snapshot. iOS may filter the snapshot for
presentation, such as recent milestones and guardrails for a selected worker,
but it does not infer approval policy, worker routing, capability binding,
generated action targets, source trust, or guardrail truth.

Audit Details opens `EngineConsoleView`, which remains the native operator
surface for the live capability architecture. It calls `capability::status`,
`capability::registry_snapshot`, `catalog::watch_snapshot`,
`capability::audit_query`, binding functions, plugin functions, conformance,
and policy functions through `CapabilityClient`; it never reads a hardcoded
tool descriptor catalog. The audit console exposes plugin, worker, binding,
policy, index, trace, primer, generated UI, local pack, activation, trust,
health, evidence, and action refs for inspection. `EngineConsoleState` owns
refresh, search, inspect, local mutation state, mutation gating, and
disconnected read-only cache snapshots. The server remains the source of truth
for policy, authority, approval, audit redaction, plugin lifecycle, local
pack/config/activation/trust/health/action resources, and binding selection.
Module operator rows decode `control::snapshot` fields such as `moduleHealth`,
`moduleSourceTrust`, and server-advertised `module::` action summaries; Swift
uses server labels, server-owned `trustPresentation` strings, and pack display
names for display and does not keep a package-policy allowlist, reconstruct
module action targets, or map raw trust codes into UX truth.

The audit console uses sheet-native Tron components: section chips, compact
metric grids, capability cards, status banners, generated action rows, and
inspection sheets. Optional runtime features such as Program Runs surface their
unavailable state inside their own section so a connected audit surface does
not appear globally broken. Capability search has its own
loading/error/empty/results state, so a failed search does not replace cached
registry state. Capability search suggestions are projected from live status,
registry documents, catalog functions, control-advertised actions, module
package resources, generated UI refs, audit traces, program runs, and primer
state instead of a hardcoded tool list.
Created by Agent rows project session-created capability lineage from the same
server-owned registry, catalog, control, audit, and program-run DTOs. The row
title/subtitle stays product-facing, the history strip names created, updated,
auto-repaired, tested, failed, promoted, revoked, discarded, and reused states,
and deeper evidence remains provenance, generated UI, promotion scope, cleanup,
trace, and child-invocation metadata for Inspect-oriented review.
Generated capability and module operator surfaces render server-authored native
controls from the stored `ui_surface`; submit sends only surface/version/action
coordinates, user input, and idempotency key through
`CapabilityClient.submitUiAction`. Package and activation module rows can open
generated `ui_surface` resources through the generic server-advertised surface
authoring action, so configure, activate, disable, upgrade, rollback, and
quarantine remain stored server actions rather than Swift-owned payload policy.
Source-control generated surfaces can add preview, plain diff preview, allowed
actions, validation/Inspect cues, and review controls without adding a
target-specific Swift surface because the content is expressed as fixed-catalog
components.
Capability cards avoid duplicate titles when a contract id and function id are
identical, and inspection sheets reuse the same capability color, sheet title,
and hidden drag-handle conventions as the rest of the app. Capability mutations
also have local action state, so conformance, plugin, binding, and
implementation updates report success/failure without collapsing the whole console into a failed load
state. Operator search sends explicit runtime metadata requesting degraded
lexical search only when vectors are unavailable; that policy is visible in the
search result status and is not applied to model turns.

The console cache is intentionally read-only. On disconnect, the UI shows stale
catalog/registry/index/module summaries and disables mutations; direct
`EngineConsoleState` mutation calls for generated surface authoring, refresh,
action submission, program execution, implementation/plugin state,
conformance, promotion, and binding updates also fail closed with a read-only
error before reaching `CapabilityClient`. Cached generated UI views return
before submitting even if a stale control fires. Reconnect refreshes the live
snapshot and replaces cached summaries when the server reports a newer catalog
or registry revision. The cache stores redacted audit rows and generated UI
refs only; full payload reveal and module lifecycle actions are
server-authorized flows and must not be reconstructed locally. Approval
decisions use the same read-only rule: while disconnected, the sheet stays open,
the chip stays pending, and no pending `approval::resolve` submission is
queued.

## Data Flow

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
SessionClient.reconstruct(sessionId, limit, beforeEventId)
    ↓  (calls session::reconstruct engine protocol)
SessionReconstructResult (events, isRunning, hasMoreEvents, oldestEventId)
    ↓
UnifiedEventTransformer.reconstructSessionState(from: events)
    ↓
ReconstructedState (messages, activeTools, pendingQuestion, ...)
    ↓
Merge separately returned approvalItems by approval createdAt
    ↓
ChatViewModel.messages (batched for pagination)
    ↓
ChatView renders
```

Pagination: older history is loaded on demand via `beforeEventId`, passing the
`oldestEventId` from the previous page. `hasMoreEvents` controls whether the
"load more" UI is shown. Forked session reconstruction is server-ordered from
the ancestor chain ending at the child head, so inherited history and child
events arrive as one timeline.

Session deep links can target the session itself or a `capability` / `event`
query item. The app resolves target IDs against the current reconstructed
window, then pages older history through `beforeEventId` until the target is
visible or the server reports no older page. While target resolution is loading
older windows, `ScrollStateCoordinator` suppresses bottom auto-scroll and the
new-content pill so the target scroll is not overridden by history prepends.
Notification URLs use the same pending-deep-link route and carry the target
session into the chat view after the notification detail is opened.

`session::reconstruct` returns approval records separately from the persisted
session event rows because the approval primitive owns approval lifecycle. The
client merges those approval chips into the reconstructed message timeline by
approval creation timestamp before selecting the visible page; it must not append
historical approvals after the visible slice, because that misorders approved
capability runs after their final assistant result when a session is resumed.

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
On iPhone the sheet opens at the large detent because the primary setup cards
and toolbar action must remain visually reachable without relying on a hidden
sheet resize gesture. Decorative card icons are hidden from accessibility so
VoiceOver lands on the actionable controls rather than glyphs.
The dashboard empty-state captions use the secondary text token rather than
the subtle/decorative token so the copy remains readable in dark appearance.

### Agent Control Sheet

The chat input-bar pill opens `AgentControlView`, a medium/large detent sheet
that summarizes context, model, analytics, history, and source control when the
server reports either an isolated session worktree or a direct git checkout for
the session. Its card containers use the shared
`CardEntranceModifier` from `Views/Components/` for a
short opacity/vertical-offset reveal. The modifier owns that entrance animation
directly and clears inherited sheet transactions before applying it, so iOS 26
Liquid Glass container bounds do not inherit presentation springs or stretch
during the sheet's own open animation. Tappable Agent Control cards wrap the
same glass chrome in plain semantic buttons with hover highlighting, so pointer,
hardware-keyboard, and assistive navigation see Context, Model, Source Control,
Analytics, and History as controls rather than text-only rows.
The Source Control card uses the branch glyph as its primary icon and remains a
thin projection of server truth: `WorktreeStatusCache`/`worktree::get_status`
hydrates branch and dirty state immediately, and `worktree::get_diff_summary`
adds aggregate file/addition/deletion counts without loading unified patch text.
Full `worktree::get_diff` data is deferred to the Source Control drill-down
sheet; when the drill-down refreshes full status/diff data, it notifies the
presenting Agent Control sheet and shared `WorktreeStatusCache` so the compact
card cannot keep a stale clean/direct-branch label. Analytics and History cards
seed from local `CachedSession` counters and local EventDatabase rows before
background session/event refreshes reconcile them, so valid zero values render
as values rather than loading placeholders.
The Context card is also server-first: detailed context snapshots or the
server-provided model context window supply the denominator. Until one is known,
the card renders the limit as unknown rather than manufacturing a `1`-token
window.
Live `session.updated` events carry server-owned event and turn counts; the app
persists those updates and Agent Control merges the in-memory row with the local
DB snapshot so a same-run sheet open cannot regress to stale dashboard counts.
A passthrough repo status (`hasWorktree=true` with `worktree.isolated=false`)
renders as a direct-branch checkout: the Source Control card, diff list, commit
sheet, repo metadata, and safe direct-branch push controls stay available. Merge,
rebase, finalize, sibling-session branch coordination, and conflict automation
remain disabled unless `worktree.get_status` reports an isolated session
worktree.

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

Foreground/background handling for the primary Tron engine connection is owned by
`TronMobileApp` and the network services rather than by session views. SwiftUI
`scenePhase` changes call `DependencyContainer.setBackgroundState(_:)`, which
pauses WebSocket heartbeats while inactive and resets paused reconnect attempts
to `.disconnected` so the next foreground transition can kick a fresh retry. On
foreground return, the app verifies any apparently connected socket with a
bounded URLSession WebSocket ping before issuing notification or session-list
engine refreshes, and manually retries through the same path as the status pill when
the connection state machine says retrying is appropriate. Normal automatic recovery uses
short foreground WebSocket-open probes at a bounded cadence until the server returns,
the app backgrounds, or authentication fails, so dashboard and chat controls recover
after dev rebuilds without per-view retry logic. Deploy-aware reconnect remains more
patient because `server.restarting` is an explicit signal that the Mac is expected to
come back. New engine WebSocket tasks also stay in
`.connecting` until URLSession reports that the WebSocket upgrade opened, so a
sleeping Mac cannot be reported as connected just because a task was resumed.
Foreground ping failures and ping timeouts transition the stale socket out of
`.connected` so the status pill and settings sheets immediately render the
reconnecting or unavailable state instead of waiting on server-backed engine protocol
timeouts. While foregrounded, the WebSocket heartbeat pings every five seconds
with a ten-second verification timeout so local engine cold starts, capability
index warm-up, and embedding initialization do not cause false disconnects.
Disconnected, connecting, reconnecting, deploy-restarting, and failed states
remain read-only until the shared interaction policy observes a real connected
edge after its debounce; reconnect countdown ticks do not make writes
optimistically available.
URLSession's WebSocket close
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
divergence or sibling-session data when the server reports a git checkout with
a repo root. Passthrough sessions can call the same repo metadata path; the
server resolves the session's selected checkout and returns empty/inapplicable
branch-baseline data instead of forcing the client to guess.
Source-control action defaults are also server-owned. Merge strategy, session
branch policy, auto-upstream behavior, and protected branches are decoded from
`settings::get`; Source Control disables merge and push affordances until those
fields arrive. Worktree and repo event plugins treat required payload fields as
required, including conflict/pending-merge `origin`, and bump one
`sourceControlRefreshTick` so status, diff, and repo-divergence projections
reload together after commit, push, pull, merge, rebase, or conflict events.
Those refresh paths surface worktree/repo/settings load failures through the
shared git error presentation instead of keeping stale values as usable state.
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

Generated management surfaces use the same `ToastCenter` path for transient
success feedback. Prompt Library generated actions, for example, show bounded
success toasts after `ui::submit_action` completes and keep raw child
invocation ids in server logs and Audit Details instead of rendering them
inline as product content. Sheets that sit above the app root may attach the same
central toast banner modifier locally; they still share `ToastCenter.shared`
and do not introduce a second notification mechanism.

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
Dashboard session rows are projections over two server-owned sources:
`session::list` supplies title, activity lines, token/cost/model metadata,
turn count, archive state, and `isRunning`; live `session.updated` events keep
those same counters fresh during an active run; `worktree::get_status` supplies
fork/branch and dirty metadata. The local sessions table persists
`is_processing` and `turn_count` so a relaunch cannot lose an active processing
bar or server-known Agent Control History count between live events, server list
refreshes, and local cache reload. The sidebar preloads filtered session ids only
after the engine is connected; row labels and title icons both read through
`SessionTitleIcons`, so visual fork/branch/dirty affordances and accessibility
descriptors stay aligned with the same `WorktreeInfo` snapshot. Recent activity
labels clamp near-now or slightly future timestamps to `now` before localized
relative formatting so fresh sidebar rows do not briefly announce future time.

Token, cache, cost, provider, and model metadata are also server-owned display
data. iOS may render provisional live totals during a streaming turn, but
persisted message metadata, Agent Control Analytics, context views, dashboard
rows, and import previews consume the server `tokenRecord` or session-list
projection. The app does not maintain local pricing tables or recompute
persisted cost, and missing required turn/token fields are omitted or decoded as
invalid instead of defaulting to a misleading turn number or guessed price.

### Audio Capture

`AudioCaptureEngine` is the single capture backend for chat transcription and
voice-note recording. Device builds use `AVAudioEngine` with a prewarm path so
the sheet can start recording immediately and keep pre-roll audio. iOS Simulator
builds use a compile-time simulator backend that never touches CoreAudio input;
it preserves the same `prepare -> start -> stop/cancel` state machine and writes
a bounded silent WAV for downstream transcription/voice-note flows. This keeps
simulator UI tests on the real app workflow while avoiding simulator-only
CoreAudio aborts. Transcription and voice-note persistence remain server-owned
through `transcription::audio` and voice-note media capabilities; Swift only
captures the local file and projects the returned result or no-speech/error
state. Chat transcription start failures caused by microphone permission denial
surface an explicit local error and do not append a generic transcription-failed
message to the session transcript.

## File Placement Guidelines

| Type | Location |
|------|----------|
| Event plugin | `Core/Events/Plugins/<Category>/` |
| engine client | `Services/Network/` |
| State object | `ViewModels/State/` |
| Coordinator | `ViewModels/Handlers/` |
| Work surface | `Views/Work/` |
| Audit Details surface | `Views/EngineConsole/` |
| Capability chip+sheet | `Views/Capabilities/` |
| Reusable component | `Views/Components/` |

Settings pages live under `Views/Settings/Pages/` and are launched from the
main `SettingsView` grid. The root sheet supports medium and large detents and
starts at medium on iPhone. On iPad, adaptive sheets use balanced liquid-glass
floating forms so the underlying app context remains visible without the sheet
reading as a full-width panel. Detented app sheets route through
`adaptivePresentationDetents`; source-level tests forbid raw
`.presentationDetents(...)` in app sources outside that helper and require every
adaptive sheet call site to declare its `ipadSizing` preset explicitly.
Reusable app sheet views with app-owned modal chrome own their adaptive helper
call rather than relying on each presenter to patch sizing around them.
Detail-sheet containers such as `CapabilityDetailSheetContainer` and
`GitSubSheetContainer` are reusable sheet owners too, so presenters that route
content through those containers do not add a second adaptive sizing helper
around the same content. Reusable system sheets such as `LogViewer` follow the
same rule. Raw
`.presentationBackground(...)` calls are centralized too: detented sheets use
the adaptive helper and glass popovers use `glassPopoverPresentationBackground`.
The same helper owns the app sheet drag-indicator policy, so app sources do not
repeat raw `.presentationDragIndicator(...)` styling.
Compact-width popover adaptation is centralized through
`popoverCompactAdaptation` so action and option popovers do not fall back to
raw sheet-style adaptation call sites.
Large iPad forms target `0.46w` capped at `540` wide and `0.88h` capped at
`900` high with a `540` floor, while compact iPad forms target `0.40w` capped
at `470` wide and `0.78h` capped at `760` high with a `420` floor. Both variants
can shrink short detail content within their floor/cap so resolved approval,
provider-error, notification, and user-interaction sheets do not become empty
tall columns. The iPhone/non-iPad branch keeps its existing detents,
selected-detent bindings, and background behavior, including raw-detent callers
converted to the helper with phone sizing/background marked unchanged. The iPad
branch does not attach phone detents, so forms remain centered floating
containers instead of falling back to bottom-detent sheets. The iPad branch also
prioritizes scrolling sheet content so long settings pages remain reachable in
landscape.
Its first grid row launches the surface-oriented settings: App, Server, and
Providers. Its second row launches agent-behavior settings: Agent, Context, and
Plugin Sources. The Agent page switches to an iPad-only two-column landscape
layout so protected-branch controls stay visible near the top of the floating
form. The protected-branch add field has an iPad-only hardware Tab handler that
resigns input focus without invoking Add, so keyboard traversal cannot mutate
the server settings snapshot. Server and Providers use the same shared
iPad-landscape detector:
Servers balances paired-server/transcription/diagnostics controls against the
updates column, and Providers splits model providers and services into two
columns so configured rows stay visible without deep scrolling. Server controls
use an explicit status projection so no active server hides server-backed
controls, an offline active server shows unavailable copy, and connected
not-yet-loaded settings still show a loading state. The third row
holds the destructive actions without a separate Danger Zone header, while
keeping those tiles error-red. All
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
covers autonomy prompt mode, execution lifecycle including hooks,
prompt-history capture/retention, queued-message delivery, and protected branches, Context covers
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
Settings is a projection of the active server snapshot. `SettingsState` stores
the loaded `defaultModel` and `agent.autonomy.approvalPromptMode` alongside the
rest of `settings::get`; Agent model and autonomy selections send sparse
`settings::update` requests, reload `settings::get`, and only then update the
app-wide active-server snapshot. A failed write rolls visible settings back to
the last loaded server response. Model picker reasoning
controls are opt-in: chat/session flows pass a reasoning binding, while Settings
model pickers hide the control because they do not own reasoning-level writes.
Automation and subagent model presets are also server-owned: iOS renders the
returned `modelRouting` presentation but does not select local/hosted route.
When Settings launches server onboarding, `ContentView` records the requested
prefill, dismisses Settings, and posts the onboarding launch from the sheet's
dismiss callback so SwiftUI never drops the second modal presentation.
First-run onboarding also exposes explicit Back/Next controls backed by
`OnboardingState`, with setup pages still locked until the pairing probe and
setup hydration succeed. The page gesture remains available, but forward
progress never depends on a hidden swipe affordance.
The settings toolbar exposes Logs in every build configuration. Production and
TestFlight builds can still inspect and copy redacted in-memory client logs
while the production logger keeps its lower-volume `.info` default. During
normal connected app execution, `ClientLogIngestionService` automatically
mirrors bounded client logs into the server `logs` table through `logs::ingest`
with send-boundary redaction, endpoint-scoped entry fingerprints, deterministic
batch idempotency, and cancellation of stale scheduled uploads after server
changes. Successful `logs::ingest` transport/debug plumbing is omitted from
automatic upload to avoid a self-feeding diagnostics loop, while ingestion
failures and reconnect warnings remain eligible for server-side inspection.
The server remains the durable, deduplicated log truth. Broader system
diagnostics stay debug/beta-only.
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

- **Configs**: Beta (debug, beta bundle ID), ProdDebug (debug, production
  bundle ID), Prod (release, production bundle ID)
- **Schemes**: Tron (optimized production), Tron Fast (debug-speed production),
  Tron Beta (debug beta)
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
