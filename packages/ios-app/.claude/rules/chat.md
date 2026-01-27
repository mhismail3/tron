---
paths:
  - "**/ViewModels/Chat/**"
---

# ChatViewModel

Split across extension files. Extensions conform to context protocols, which delegate to coordinators for stateless logic.

## Extension Pattern

| Extension File | Context Protocol | Coordinator |
|----------------|------------------|-------------|
| +ToolEventContext | ToolEventContext | ToolEventCoordinator |
| +TurnLifecycleContext | TurnLifecycleContext | TurnLifecycleCoordinator |
| +EventDispatchContext | EventDispatchContext | EventDispatchCoordinator |
| +Pagination | PaginationContext | PaginationCoordinator |
| +UICanvasContext | UICanvasContext | UICanvasCoordinator |

## Adding Features

1. Create extension file `ChatViewModel+Feature.swift`
2. Define context protocol in `Handlers/FeatureContext.swift`
3. Create coordinator in `Handlers/FeatureCoordinator.swift`
4. Conform ChatViewModel extension to context protocol

## Rules

- Don't add >100 LOC directly to ChatViewModel.swift
- Extensions provide state access; coordinators contain logic
- State objects live in `ViewModels/State/` for complex observable state
- Context protocols enable testing coordinators without full ChatViewModel

---

## Update Triggers

Update this rule when:
- Adding new ChatViewModel extensions
- Changing coordinator/context pattern
- Adding new context protocols

Verification:
```bash
ls packages/ios-app/Sources/ViewModels/Chat/ChatViewModel+*.swift
```
