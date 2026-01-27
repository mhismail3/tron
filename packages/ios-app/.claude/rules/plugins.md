---
paths:
  - "**/Events/Plugins/**"
  - "**/EventRegistry*"
  - "**/EventDispatch*"
---

# Event Plugins

Self-contained handlers that parse WebSocket JSON, extract sessionId, and transform to UI-ready Result.

## Adding a New Event

### 1. Create Plugin

```swift
// Core/Events/Plugins/<Category>/MyEventPlugin.swift
enum MyEventPlugin: EventPlugin {
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
}
```

### 2. Register Plugin

```swift
// Core/Events/EventRegistry.swift
func registerAll() {
    register(MyEventPlugin.self)
}
```

### 3. Add Dispatch Case

```swift
// Core/Events/EventDispatchCoordinator.swift
func dispatch(_ event: any EventResult, to context: EventDispatchContext) {
    switch event {
    case let e as MyEventPlugin.Result:
        context.handleMyEvent(e)
    // ...
    }
}
```

### 4. Add Handler Protocol

```swift
// ViewModels/Handlers/EventDispatchContext.swift
protocol EventDispatchContext: AnyObject {
    func handleMyEvent(_ event: MyEventPlugin.Result)
}
```

### 5. Implement Handler

```swift
// ViewModels/Chat/ChatViewModel+EventDispatchContext.swift
extension ChatViewModel: EventDispatchContext {
    func handleMyEvent(_ event: MyEventPlugin.Result) {
        myState.updateWith(event)
    }
}
```

### 6. Add State Object (if needed)

```swift
// ViewModels/State/MyEventState.swift
@Observable
final class MyEventState {
    var items: [MyItem] = []
}
```

## Plugin Categories

Streaming, Tool, Lifecycle, Session, Subagent, PlanMode, UICanvas, Browser, Todo

## Common Patterns

### Non-Standard JSON

Override `parse(from:)` for complex payloads:

```swift
static func parse(from data: Data) -> (any EventResult)? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == eventType else { return nil }
    let customField = json["nested"]?["field"] as? String ?? ""
    return Result(customField: customField)
}
```

### Events Affecting History

Also update `UnifiedEventTransformer` if event should appear in reconstructed history.

## Verification Checklist

- [ ] Plugin registered in `EventRegistry.registerAll()`
- [ ] Dispatch case in `EventDispatchCoordinator`
- [ ] Handler in `EventDispatchContext` protocol
- [ ] Handler implemented in ChatViewModel extension
- [ ] Event payload matches backend schema
- [ ] Live event triggers UI update

## Rules

- Conform EventData to `StandardEventData` for automatic sessionId extraction
- Keep Result flat and UI-ready; logic goes in handler
- Override `parse(from:)` only for non-standard JSON

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
