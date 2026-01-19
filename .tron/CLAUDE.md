# Tron Agent Instructions

## Adding New Tools - CRITICAL CHECKLIST

When adding a new tool to Tron, you MUST ensure all the following are handled correctly to prevent breaking session resume, forks, and API compatibility. **Tool use/result formatting bugs have occurred repeatedly** when new tools are added without updating all touchpoints.

### The Tool Lifecycle

1. **Tool Definition** (`packages/core/src/tools/`) - The tool implementation
2. **Tool Call Event** (`tool.call`) - Recorded when agent invokes a tool
3. **Tool Result Event** (`tool.result`) - Recorded when tool execution completes
4. **Message Content** (`message.assistant`) - Contains `tool_use` blocks with the tool invocation
5. **Content Normalization** (`packages/server/src/utils/content-normalizer.ts`) - Sanitizes/truncates content for storage
6. **State Reconstruction** (`packages/core/src/events/event-store.ts`) - Rebuilds messages from events

### Files That MUST Be Updated/Verified

| File | What to Check |
|------|---------------|
| `packages/core/src/events/event-store.ts` | `getMessagesAt()` and `getStateAt()` properly reconstruct tool_use/tool_result |
| `packages/server/src/utils/content-normalizer.ts` | `normalizeContentBlock()` handles the tool's input format without data loss |
| `packages/server/src/orchestrator/agent-event-handler.ts` | Tool calls and results are properly recorded as events |
| `packages/core/src/agent/tool-executor.ts` | Tool execution and result handling |
| `packages/core/src/types/events.ts` | Event payload types if new fields are needed |

### Known Pitfalls

1. **Large Tool Inputs (>5KB)**: `content-normalizer.ts` truncates large `tool_use` inputs with `{_truncated: true, _originalSize, _preview}`. These MUST be restored from `tool.call` events during reconstruction or the API will reject them.

2. **Tool Result Content**: Can be string or array of content parts. Both formats must be handled in normalization and reconstruction.

3. **Event Recording Order**: `tool.result` events are recorded BEFORE `message.assistant` events. State reconstruction relies on this order.

4. **Message Alternation**: Anthropic API requires strict user/assistant alternation. Tool results become synthetic user messages. Ensure reconstruction maintains this pattern.

5. **Fork/Resume Scenarios**: All tool data must reconstruct correctly when:
   - Resuming a session (`getStateAt()` / `getStateAtHead()`)
   - Forking from a mid-conversation point
   - Replaying events after compaction

### Testing New Tools

1. Create a session using the new tool with various input sizes (small, >5KB)
2. End the session and resume it - verify no API errors
3. Fork from a point after tool use - verify fork works
4. Check that tool results display correctly in all UIs (TUI, iOS, web)

### The Reconstruction Flow

```
Events in DB:
  message.user (seq 1)
  message.assistant with tool_use blocks (seq 2)  <-- may have truncated inputs
  tool.call (seq 3)                               <-- has FULL arguments
  tool.result (seq 4)                             <-- has result content
  message.assistant continuation (seq 5)

Reconstruction (getStateAt/getMessagesAt):
  1. First pass: collect tool.call arguments into toolCallArgsMap
  2. Second pass: build messages, restoring truncated tool_use inputs from map
  3. Inject tool_result as synthetic user message after assistant with tool_use
```

### Quick Verification Command

After adding a new tool, run:
```bash
bun run test
```

Pay special attention to tests in:
- `packages/server/test/eventstore-integration.test.ts`
- `packages/core/test/events/` (if exists)
