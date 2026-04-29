# iOS App Architecture

> Last verified: 2026-04-29 (local diagnostics, MetricKit retention, feedback bundle, settings revamp, local paired servers, server-owned settings, provider status cards, and onboarding handoff)

## Overview

The iOS app is a SwiftUI client that connects to the Tron agent server via WebSocket. It provides:
- Real-time chat interface with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input
- A staged input composer where pending skills and attachments share one wrapping chip row before send

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
│   └── RPC/                # RPC types and codables
├── Services/               # Network, state management
│   ├── Network/            # RPC, WebSocket (with Bearer auth), deep links
│   ├── Events/             # Event store, sync
│   ├── Audio/              # Recording, transcription
│   ├── Diagnostics/        # Local MetricKit store + redacted feedback bundle builder
│   ├── Feedback/           # Mail/share envelope for explicit diagnostics bundles
│   ├── Notifications/      # Push notifications
│   ├── Observability/      # DiagnosticsRedactor shared with Mac
│   ├── Onboarding/         # Pairing validator/probe/persistor
│   ├── PairingURLParser.swift  # tron://pair?host&port&token&label parser + builder
│   ├── Parsing/            # Tool result parsers (delegated by ToolResultParser)
│   ├── Settings/           # PairedServerStore (local server list + active id)
│   └── Storage/            # KeychainItem + PairedServerTokenStore
├── ViewModels/             # View state management
│   ├── Chat/               # ChatViewModel and extensions
│   ├── Handlers/           # Event handling coordinators
│   ├── Managers/           # Specialized state managers
│   └── State/              # @Observable state objects
└── Views/                  # SwiftUI views
    ├── Chat/               # Core chat interface
    ├── Tools/              # Tool chips + detail sheets
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
protocol ToolEventContext: AnyObject {
    var activeTools: [String: ToolState] { get set }
    func updateToolState(_ id: String, state: ToolState)
}

// Coordinator (stateless logic)
@MainActor
final class ToolEventCoordinator {
    func handleToolStart(context: ToolEventContext, event: ToolStartEvent) {
        context.activeTools[event.toolId] = .running
    }
}

// ViewModel extension (provides context)
extension ChatViewModel: ToolEventContext { ... }
```

### Event Plugin System

Two systems handle events:

1. **Plugins** - Parse live WebSocket events → UI-ready Result
2. **Transformer** - Reconstruct history from stored events → ChatMessage

```
Live:   WebSocket → EventRegistry → Plugin → EventDispatchCoordinator → ChatViewModel
Stored: EventDatabase → Transformer → ChatMessage array
```

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
| `Services/Network/RPCClient.swift` | WebSocket RPC |
| `Services/Events/EventStoreManager.swift` | Local event persistence |

## Data Flow

### Live Events

```
WebSocket message
    ↓
RPCClient.eventPublisherV2
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
    ↓  (calls session.reconstruct RPC)
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

## Dependency Injection

All services injected via SwiftUI environment:

```swift
// App startup
@State private var container = DependencyContainer()

// In views
@Environment(\.dependencies) var dependencies
dependencies.rpcClient
dependencies.eventStoreManager
```

### Service Lifecycle

| Type | Recreated On |
|------|--------------|
| Persistent | Never (eventDatabase, pushNotificationService) |
| Connection-based | Server change (rpcClient, skillStore) |

## File Placement Guidelines

| Type | Location |
|------|----------|
| Event plugin | `Core/Events/Plugins/<Category>/` |
| RPC client | `Services/Network/` |
| State object | `ViewModels/State/` |
| Coordinator | `ViewModels/Handlers/` |
| Tool chip+sheet | `Views/Tools/<ToolName>/` |
| Reusable component | `Views/Components/` |

Settings pages live under `Views/Settings/Pages/` and are launched from the
main `SettingsView` by `ServerSettingsCategory`. Server-backed settings are
grouped by behavior owner: Servers covers pairing/security/transcription/updates,
Providers covers auth credentials, Agent covers execution lifecycle including
hooks, prompt-history capture/retention, queued-message delivery, and protected
branches, Context covers compaction/memory/skills/rules, and MCP covers external
tools. Low-level hook `add_context` budgeting stays an internal server fuse,
not an end-user Agent setting. Source-control action sheets expose merge, push,
branch, and upstream choices at the moment of action rather than through a
separate source-control settings destination. Destructive cross-cutting actions
such as clearing prompt history stay in the main Settings Danger Zone. Sheets
that summarize server-backed behavior start with `SettingsInfoCard` and derive the
mostly-static title plus dynamic description through small helpers in
`SettingsSupport.swift` so copy and grouping rules are covered by focused tests.
Main-sheet icon strings live in the same support file, and server-backed
destination summary cards reuse their `ServerSettingsCategory` icons so the
launcher row and destination stay visually aligned.
Static status rows such as the user hook directory keep their path/value in the
trailing position and show a small empty-state placeholder when the server has
no listable detail to return.

## Build Configuration

Uses XcodeGen with `project.yml`:

- **Configs**: Beta (debug), Prod (release)
- **Minimum iOS**: 18.0
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
