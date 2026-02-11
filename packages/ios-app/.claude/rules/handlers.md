---
paths:
  - "**/ViewModels/Handlers/**"
---

# Coordinators and Contexts

Coordinators contain stateless logic extracted from ChatViewModel. Contexts define the interface coordinators need.

## Pattern

```swift
// Context protocol (what coordinator needs)
@MainActor
protocol FeatureContext: AnyObject {
    var someState: SomeType { get set }
    func updateUI()
}

// Coordinator (stateless logic)
@MainActor
final class FeatureCoordinator {
    func doSomething(context: FeatureContext) {
        // Pure logic, mutates context
    }
}

// ChatViewModel extension (provides context)
extension ChatViewModel: FeatureContext {
    // Delegate calls to coordinator
}
```

## Key Coordinators

- `EventDispatchCoordinator` - Delegates to self-dispatching plugin boxes via `EventRegistry`
- `ToolEventCoordinator` - Handles tool start/end events
- `TurnLifecycleCoordinator` - Manages turn state transitions
- `PaginationCoordinator` - Handles event loading and pagination
- `MessagingCoordinator` - Sends messages and handles responses

## Event Dispatch

`EventDispatchCoordinator` uses plugin box delegation instead of a switch statement. Each `DispatchableEventPlugin` carries its own dispatch logic. The coordinator looks up the plugin box from `EventRegistry` and calls `box.dispatch(result:context:)`.

Handler protocols are split by domain (see `EventDispatchContext.swift`):
- `StreamingEventHandler`, `ToolEventHandler`, `TurnLifecycleEventHandler`
- `ContextEventHandler`, `BrowserEventHandler`, `SubagentEventHandler`
- `UICanvasEventHandler`, `TaskEventHandler`, `EventDispatchLogger`

These compose into `EventDispatchTarget` which ChatViewModel conforms to.

## Rules

- Coordinators are `@MainActor` for safe UI updates
- Contexts are `AnyObject` protocols for reference semantics
- Keep coordinators stateless - all state flows through context
- One coordinator per feature domain

---

## Update Triggers

Update this rule when:
- Adding new coordinators
- Changing context protocol pattern
- Modifying coordinator responsibilities

Verification:
```bash
ls packages/ios-app/Sources/ViewModels/Handlers/*Coordinator.swift
```
