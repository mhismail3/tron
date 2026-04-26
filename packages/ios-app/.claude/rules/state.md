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
| `ThinkingState` | Thinking text streaming and turn lifecycle |
| `ProcessState` | Background process tracking |
| `InputBarState` | Input field state |
| `ContextTrackingState` | Token counts, costs, context window |
| `DisplayStreamState` | Active display stream, frames, sheet |
| `WorktreeIsolationState` | Session-scoped view over `WorktreeStatusCache`; the chat toolbar reads through it |
| `WorktreeStatusCache` | Shared per-session worktree status; populated lazily by sidebar rows + kept live via global worktree events. Toolbar and sidebar row render from the same cache |
| `OnboardingState` | `@Observable` pairing-sheet state. Owns pairing form inputs and `complete()` which flips `@AppStorage("onboardingComplete")`. It deliberately has no route stack because iOS onboarding is a single pairing form. |
| `SettingsState` | Server settings mirror + cached `connectionPresets[]`. Exposes the active preset ID so `PresetTokenStore` can look up the bearer token for `WebSocketService`. Telemetry and feedback toggles are surfaced from here to the Privacy page. |

## Managers (`ViewModels/Managers/`)

| Manager | Purpose |
|---------|---------|
| `StreamingManager` | Batches streaming deltas (chat view, single session) |
| `DashboardStreamManager` | Live activity buffers for sidebar cards (all sessions) |
| `ScrollStateCoordinator` | Scroll position tracking |
| `AnimationCoordinator` | Animation timing |
| `MessageWindowManager` | Visible message range |

## Connection + read-only policy (`Services/Network/`)

`@Observable @MainActor` services composing the single source of truth for connection
interactivity:

- `ConnectionManager` wraps `RPCClient.connectionState` and adds a `runOnReconnect(label:_:)` hook registry.
- `InteractionPolicy` projects `ConnectionManager.state` into semantic predicates (`canSendMessage` / `canMutateSession` / `canRecordAudio` / etc.) with a 500ms debounce on reconnect. Installed at the app root via SwiftUI `\.interactionPolicy` environment key; views fail closed when the environment is absent.
- `EventStoreManager+RefreshCoordination` extension adds `requestSessionRefresh(reason:)`, routing every session-list refresh through `SessionRefreshService` for coalescing, debouncing, and reconnect queuing.

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
