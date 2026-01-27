---
paths:
  - "**/Events/Transformer/**"
---

# Event Transformer

Reconstructs chat history from stored events. Converts `SessionEvent` or `RawEvent` arrays into `ChatMessage` arrays for display.

## Key Components

- `EventTransformable` - Protocol unifying RawEvent and SessionEvent
- `Handlers/` - Type-specific transformation logic (MessageHandlers, ToolHandlers, etc.)
- `Reconstruction/` - State tracking during transformation
- `AskUserQuestion/` - Special handling for question detection

## Reconstruction Flow

```
[SessionEvent] -> EventSorter -> Handlers -> InterleavedContentProcessor -> [ChatMessage]
```

## Rules

- Use `EventTransformable` protocol for generic functions that work with both RawEvent and SessionEvent
- Handler functions are pure: input events, output ChatMessage components
- Tool events reconstruct from both `tool.call` and `tool.result` events
- Sequence numbers determine ordering, not timestamps
- Handle truncated tool arguments by looking up original from tool.call events

---

## Update Triggers

Update this rule when:
- Adding new handler types in Handlers/
- Changing EventTransformable protocol
- Modifying reconstruction flow

Verification:
```bash
ls packages/ios-app/Sources/Core/Events/Transformer/Handlers/
```
