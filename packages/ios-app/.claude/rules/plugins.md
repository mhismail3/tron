---
paths:
  - "**/Events/Plugins/**"
  - "**/EventRegistry*"
  - "**/EventDispatch*"
---

# Event Plugins

Self-contained handlers that parse WebSocket JSON, extract sessionId, transform to UI-ready Result, and dispatch to the appropriate handler.

## Adding a New Event

### 1. Create Self-Dispatching Plugin

```swift
// Core/Events/Plugins/<Category>/MyEventPlugin.swift
enum MyEventPlugin: DispatchableEventPlugin {
    static let eventType = "agent.my_event"  // Must match backend

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let customField: String
        let optionalField: Int?
    }

    struct Result: EventResult {
        let customField: String
        let optionalField: Int
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            customField: event.customField,
            optionalField: event.optionalField ?? 0
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMyEvent(r)
    }
}
```

### 2. Register Plugin

```swift
// Core/Events/EventRegistry.swift — registerAll()
register(MyEventPlugin.self)
```

### 3. Add Handler to Domain Protocol

```swift
// ViewModels/Handlers/EventDispatchContext.swift
// Add to the appropriate domain protocol (e.g., ContextEventHandler)
@MainActor protocol ContextEventHandler: AnyObject {
    func handleMyEvent(_ result: MyEventPlugin.Result)
    // ... existing methods
}
```

### 4. Implement Handler

```swift
// ViewModels/Chat/ChatViewModel+EventDispatchContext.swift
extension ChatViewModel: EventDispatchTarget {
    func handleMyEvent(_ result: MyEventPlugin.Result) {
        myState.updateWith(result)
    }
}
```

That's it — no coordinator switch case needed. The plugin dispatches itself.

## Domain Handler Protocols

| Protocol | Domain |
|----------|--------|
| `StreamingEventHandler` | Text/thinking deltas |
| `ToolEventHandler` | Tool start/end |
| `TurnLifecycleEventHandler` | Turn start/end, complete, error |
| `ContextEventHandler` | Compaction, memory, context cleared |
| `BrowserEventHandler` | Browser frames, closed |
| `SubagentEventHandler` | Subagent lifecycle |
| `UICanvasEventHandler` | UI render lifecycle |
| `TodoEventHandler` | Todo updates |
| `EventDispatchLogger` | Logging |

All compose into `EventDispatchTarget` which ChatViewModel conforms to.

## Plugin Categories

Streaming, Tool, Lifecycle, Session, Subagent, UICanvas, Browser, Todo

## Common Patterns

### Non-Standard JSON

Override `parse(from:)` for complex payloads:

```swift
static func parse(from data: Data) throws -> EventData {
    // Custom decoding logic
}
```

### Events Affecting History

Also update `UnifiedEventTransformer` if event should appear in reconstructed history.

## Verification Checklist

- [ ] Plugin conforms to `DispatchableEventPlugin`
- [ ] Plugin registered in `EventRegistry.registerAll()`
- [ ] Handler added to appropriate domain protocol
- [ ] Handler implemented in ChatViewModel extension
- [ ] Event payload matches backend schema
- [ ] Live event triggers UI update

## Rules

- Conform EventData to `StandardEventData` for automatic sessionId extraction
- Keep Result flat and UI-ready; logic goes in handler
- Override `parse(from:)` only for non-standard JSON
- Use `DispatchableEventPlugin` for all new plugins (self-dispatch pattern)

---

## Update Triggers

Update this rule when:
- Adding new plugin categories
- Changing EventPlugin protocol
- Modifying dispatch flow

Verification:
```bash
ls packages/ios-app/Sources/Core/Events/Plugins/*/
```
