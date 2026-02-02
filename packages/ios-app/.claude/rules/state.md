---
paths:
  - "**/ViewModels/State/**"
  - "**/ViewModels/Managers/**"
  - "**/*State.swift"
  - "**/*Coordinator.swift"
---

# State Management

@Observable state objects and managers.

## State Objects (`ViewModels/State/`)

| State | Purpose |
|-------|---------|
| `SubagentState` | Tracks active sub-agents, events |
| `ThinkingState` | Thinking/extended thinking |
| `TodoState` | Todo list state |
| `UICanvasState` | Dynamic UI rendering |
| `InputBarState` | Input field state |
| `SheetState` | Active sheet management |

## Managers (`ViewModels/Managers/`)

| Manager | Purpose |
|---------|---------|
| `StreamingManager` | Batches streaming deltas |
| `ScrollStateCoordinator` | Scroll position tracking |
| `AnimationCoordinator` | Animation timing |
| `MessageWindowManager` | Visible message range |

## @Observable Usage

```swift
@Observable
final class MyState {
    var items: [Item] = []

    // Computed properties are automatically tracked
    var isEmpty: Bool { items.isEmpty }
}
```

## Memory Management

- Cap event arrays (SubagentState limits to 100 events/subagent)
- Clear old state when switching sessions
- Managers are lightweight; state objects hold data

## State vs Coordinator

- **State**: Holds data, publishes changes
- **Coordinator**: Stateless logic, uses state for data

---

## Update Triggers

Update this rule when:
- Adding new state objects
- Changing @Observable patterns
- Modifying memory management strategies

Verification:
```bash
ls packages/ios-app/Sources/ViewModels/State/
grep -l "@Observable" packages/ios-app/Sources/ViewModels/State/*.swift | head -3
```
