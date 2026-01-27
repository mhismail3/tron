# Event Handling

The iOS app handles events through two systems: **plugins** for live WebSocket events and **transformer** for reconstructing history.

## Architecture Overview

```
Live:   WebSocket → EventRegistry → Plugin → EventDispatchCoordinator → ChatViewModel
Stored: EventDatabase → Transformer → ChatMessage array
```

## Event Plugin System

Plugins are self-contained handlers that parse WebSocket JSON and transform to UI-ready results.

### Plugin Structure

```swift
enum MyEventPlugin: EventPlugin {
    static let eventType = "agent.my_event"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        // Event-specific fields
    }

    struct Result: EventResult {
        // UI-ready fields only
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(/* map fields */)
    }
}
```

### Plugin Categories

| Category | Location | Events |
|----------|----------|--------|
| Streaming | `Plugins/Streaming/` | text_delta, turn_complete |
| Tool | `Plugins/Tool/` | tool_start, tool_end |
| Lifecycle | `Plugins/Lifecycle/` | session_start, session_end |
| Session | `Plugins/Session/` | fork, status |
| Subagent | `Plugins/Subagent/` | spawn, progress, complete |
| PlanMode | `Plugins/PlanMode/` | plan events |
| UICanvas | `Plugins/UICanvas/` | render_app_ui |
| Browser | `Plugins/Browser/` | browser events |
| Todo | `Plugins/Todo/` | todo_write |

### Registration

All plugins registered at app startup:

```swift
// EventRegistry.swift
func registerAll() {
    register(TextDeltaPlugin.self)
    register(ToolStartPlugin.self)
    register(ToolEndPlugin.self)
    // ... all plugins
}
```

## Event Dispatch

`EventDispatchCoordinator` routes parsed events to handlers:

```swift
func dispatch(_ event: any EventResult, to context: EventDispatchContext) {
    switch event {
    case let e as TextDeltaPlugin.Result:
        context.handleTextDelta(e)
    case let e as ToolStartPlugin.Result:
        context.handleToolStart(e)
    // ... all cases
    }
}
```

### Handler Protocol

```swift
@MainActor
protocol EventDispatchContext: AnyObject {
    func handleTextDelta(_ event: TextDeltaPlugin.Result)
    func handleToolStart(_ event: ToolStartPlugin.Result)
    func handleToolEnd(_ event: ToolEndPlugin.Result)
    // ... all handlers
}
```

### Implementation

ChatViewModel extensions implement handlers:

```swift
// ChatViewModel+EventDispatchContext.swift
extension ChatViewModel: EventDispatchContext {
    func handleTextDelta(_ event: TextDeltaPlugin.Result) {
        streamingManager.appendDelta(event.delta)
    }

    func handleToolStart(_ event: ToolStartPlugin.Result) {
        activeTools[event.toolId] = ToolState(name: event.toolName)
    }
}
```

## Event Transformer

Reconstructs chat history from stored events.

### Key Components

| File | Purpose |
|------|---------|
| `UnifiedEventTransformer.swift` | Main transformation logic |
| `Handlers/MessageHandlers.swift` | Message event handling |
| `Handlers/ToolHandlers.swift` | Tool event handling |
| `Reconstruction/` | State tracking during transform |

### Transformation Flow

```swift
// Input: [SessionEvent] or [RawEvent]
// Output: [ChatMessage]

let messages = UnifiedEventTransformer.transform(events: events)
```

### EventTransformable Protocol

Unifies different event types:

```swift
protocol EventTransformable {
    var id: String { get }
    var type: String { get }
    var sessionId: String? { get }
    var timestamp: String? { get }
    var sequence: Int? { get }
    func payload<T: Decodable>(as type: T.Type) -> T?
}
```

## Adding a New Event

### 1. Create Plugin

```swift
// Core/Events/Plugins/<Category>/MyEventPlugin.swift
enum MyEventPlugin: EventPlugin {
    static let eventType = "agent.my_event"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let customField: String
    }

    struct Result: EventResult {
        let customField: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(customField: event.customField)
    }
}
```

### 2. Register Plugin

```swift
// EventRegistry.swift
func registerAll() {
    // ... existing
    register(MyEventPlugin.self)
}
```

### 3. Add Dispatch Case

```swift
// EventDispatchCoordinator.swift
func dispatch(_ event: any EventResult, to context: EventDispatchContext) {
    switch event {
    // ... existing
    case let e as MyEventPlugin.Result:
        context.handleMyEvent(e)
    }
}
```

### 4. Add Handler Protocol

```swift
// EventDispatchContext.swift
protocol EventDispatchContext {
    // ... existing
    func handleMyEvent(_ event: MyEventPlugin.Result)
}
```

### 5. Implement Handler

```swift
// ChatViewModel+EventDispatchContext.swift
func handleMyEvent(_ event: MyEventPlugin.Result) {
    // Update state based on event
}
```

## Rules

- Plugins handle live WebSocket events only
- Transformer handles history reconstruction only
- All live events flow through `eventPublisherV2`
- Payloads are shared between systems - changes affect both
- Use `StandardEventData` for automatic sessionId extraction
- Keep Result structs flat and UI-ready
