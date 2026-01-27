# iOS App Architecture

> Last verified: 2026-01-27

## Overview

The iOS app is a SwiftUI client that connects to the Tron agent server via WebSocket. It provides:
- Real-time chat interface with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input

## Directory Structure

```
Sources/
├── App/                    # App entry point, delegates, configuration
├── Core/                   # Business logic extracted from other modules
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
│   ├── Network/            # RPC, WebSocket, deep links
│   ├── Events/             # Event store, sync
│   ├── Audio/              # Recording, transcription
│   └── Notifications/      # Push notifications
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

### History Loading

```
EventStoreManager.fetchEvents()
    ↓
UnifiedEventTransformer.transform()
    ↓
[ChatMessage] array
    ↓
ChatViewModel.messages
    ↓
ChatView renders
```

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

## Build Configuration

Uses XcodeGen with `project.yml`:

- **Configs**: Debug-Beta, Release-Beta, Debug-Prod, Release-Prod
- **Minimum iOS**: 18.0
- **Swift**: 6.0

```bash
xcodegen generate
```
