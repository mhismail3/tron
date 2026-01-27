---
paths:
  - "**/events/**"
  - "**/event-store*"
  - "**/*-event-*"
  - "**/message-reconstructor*"
---

# Event Store

Append-only event log with tree structure. All session state is reconstructed from events.

## Key Patterns

- Events linked via `parentId` forming a tree (forks create branches)
- Sessions hold `rootEventId` and `headEventId` pointers
- State reconstruction walks ancestors from head to root
- Large tool inputs (>5KB) truncated with `{_truncated: true}`

## Reconstruction Flow

```
Events:
  message.assistant with tool_use (seq 2)  <-- may be truncated
  tool.call (seq 3)                        <-- has FULL arguments
  tool.result (seq 4)

Reconstruction:
  1. Collect tool.call arguments into map
  2. Build messages, restore truncated inputs from map
  3. Inject tool_result as synthetic user message
```

## Adding Event Types

1. Define in `events/types.ts` (EventType union, payload interface)
2. Emit via `appendEvent()` in appropriate handler
3. Handle in `message-reconstructor.ts` if affects message reconstruction
4. Update iOS plugin if client needs real-time handling

## Rules

- Recording order: `tool.result` BEFORE `message.assistant` - reconstruction relies on this
- Anthropic API requires user/assistant alternation - tool results become synthetic user messages
- Tool result content can be string or array - handle both formats
- Fork/resume must reconstruct correctly - test all new event types

---

## Update Triggers

Update this rule when:
- Adding/changing event types in `types.ts`
- Modifying reconstruction logic in `message-reconstructor.ts`
- Changing truncation thresholds or behavior

Verification:
```bash
grep -l "EventType" packages/agent/src/events/types.ts
grep -l "reconstructFromEvents" packages/agent/src/events/message-reconstructor.ts
```
