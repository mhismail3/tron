---
paths:
  - "**/Events/Transformer/**"
---

# Event Transformer

Reconstructs chat history from stored events. Converts `SessionEvent` or `RawEvent` arrays into `ChatMessage` arrays for display.

## Key Components

- `EventTransformable` - Protocol unifying RawEvent and SessionEvent (all fields non-optional: sessionId, timestamp, sequence)
- `buildToolMaps(from:)` - Shared first-pass helper building tool call/result lookups and consumed subagent IDs
- `Handlers/` - Type-specific transformation logic (MessageHandlers, ToolHandlers, etc.)
- `Reconstruction/` - State tracking during transformation (produces `ReconstructedState`)
- `AskUserQuestion/` - Special handling for question detection

## Reconstruction Flow

The server provides events via the `session.reconstruct` RPC (with pagination via `beforeSequence`/`hasMoreEvents`). The transformer then processes them:

```
server events (from session.reconstruct RPC)
    ↓
buildToolMaps (first pass — tool call/result lookups)
    ↓
reconstructSessionState (second pass — handlers per event type)
    ↓
ReconstructedState (messages, activeTools, pendingQuestion, ...)
    ↓
ChatViewModel.messages
```

## Rules

- Use `EventTransformable` protocol for generic functions that work with both RawEvent and SessionEvent
- Handler functions are pure: input events, output ChatMessage components
- Tool events reconstruct from both `tool.call` and `tool.result` events
- Sequence numbers determine ordering, not timestamps
- Handle truncated tool arguments by looking up original from tool.call events
- `buildToolMaps` is shared between `transformPersistedEvents` and `reconstructSessionState` — keep it in sync

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
