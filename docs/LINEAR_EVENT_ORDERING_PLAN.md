# Linear Event Ordering Plan

## Problem Statement

When a forked session is resumed, message reconstruction fails because events are not in logical order:

**Current event order:**
```
tool.call → tool.result → message.assistant (contains tool_use)
```

**Required order for Anthropic API:**
```
message.assistant (contains tool_use) → tool.call → tool.result
```

This happens because:
1. Tools execute during the turn, creating `tool.call`/`tool.result` events immediately
2. `message.assistant` is only created at turn END (consolidating all accumulated content)

## Solution: Emit message.assistant BEFORE tool execution

When tool execution starts, flush the accumulated assistant content FIRST, then execute tools.

## Current Flow (Problematic)

```
1. turn_start event
   └─► turnManager.startTurn()

2. LLM streams response
   └─► text deltas → turnManager.addTextDelta()
   └─► tool_use blocks → turnManager.startToolCall() (tracking only)

3. tool_execution_start event (FIRST TOOL)
   └─► tool.call event created
   └─► Tool executes...

4. tool_execution_end event
   └─► tool.result event created
   └─► turnManager.endToolCall()

5. (Repeat 3-4 for each tool)

6. turn_end event
   └─► turnManager.endTurn() builds content blocks
   └─► message.assistant event created (contains tool_use!)
   └─► stream.turn_end event created
```

## New Flow (Correct)

```
1. turn_start event
   └─► turnManager.startTurn()

2. LLM streams response
   └─► text deltas → turnManager.addTextDelta()
   └─► tool_use blocks → turnManager.trackToolUse() (tracking only)

3. tool_execution_start event (FIRST TOOL)
   └─► **NEW: Flush accumulated content as message.assistant**
   └─► tool.call event created
   └─► Tool executes...

4. tool_execution_end event
   └─► tool.result event created
   └─► turnManager.endToolCall()

5. (Repeat 3-4 for each tool)

6. turn_end event
   └─► Check if more content accumulated AFTER tools
   └─► If yes, create another message.assistant
   └─► stream.turn_end event created
```

## Implementation Plan

### Phase 1: Add Tests (TDD)

**File: `packages/server/test/orchestrator/event-ordering.test.ts`**

Create tests that verify:
1. Single tool call: `message.assistant` comes before `tool.call`
2. Multiple tool calls: `message.assistant` (with all tool_use) comes before any `tool.call`
3. Agentic loop (multi-turn): Each turn has correct ordering
4. Forked session: Messages reconstruct correctly
5. No tools: `message.assistant` still created at turn_end (no change)
6. Resume session: Existing behavior preserved
7. Interrupted session: Partial content persisted correctly

### Phase 2: Modify TurnManager

**File: `packages/server/src/orchestrator/turn-manager.ts`**

Add method to flush content before tools:

```typescript
/**
 * Flush accumulated content as message.assistant BEFORE tool execution.
 * Called when first tool_execution_start is received.
 * Returns content blocks to persist, or null if nothing to flush.
 */
flushPreToolContent(): AssistantContentBlock[] | null {
  // Only flush if we have content and haven't already flushed
  if (this.hasPreToolContentFlushed) return null;

  const content = this.buildPreToolContentBlocks();
  if (content.length === 0) return null;

  this.hasPreToolContentFlushed = true;
  return content;
}

/**
 * Build content blocks for pre-tool flush.
 * Includes text and tool_use blocks accumulated so far.
 */
private buildPreToolContentBlocks(): AssistantContentBlock[] {
  const content: AssistantContentBlock[] = [];

  for (const item of this.tracker.getCurrentTurnSequence()) {
    if (item.type === 'text' && item.text) {
      content.push({ type: 'text', text: item.text });
    } else if (item.type === 'tool_ref') {
      const toolCall = this.tracker.getToolCall(item.toolCallId);
      if (toolCall) {
        content.push({
          type: 'tool_use',
          id: toolCall.toolCallId,
          name: toolCall.toolName,
          input: toolCall.arguments,
        });
      }
    }
  }

  return content;
}
```

### Phase 3: Modify Event Handler

**File: `packages/server/src/event-store-orchestrator.ts`**

Modify `tool_execution_start` handler:

```typescript
case 'tool_execution_start':
  if (active) {
    // BEFORE executing tool, flush accumulated assistant content
    // This ensures message.assistant (with tool_use) comes BEFORE tool.call
    const preToolContent = active.sessionContext!.flushPreToolContent();
    if (preToolContent && preToolContent.length > 0) {
      const normalizedContent = normalizeContentBlocks(preToolContent);
      this.appendEventLinearized(sessionId, 'message.assistant', {
        content: normalizedContent,
        turn: active.sessionContext!.getCurrentTurn(),
        model: active.model,
        stopReason: 'tool_use', // Indicates tools are being called
      });
    }

    // Now track the tool call (existing code)
    active.sessionContext!.startToolCall(...);
  }

  // Create tool.call event (existing code)
  this.appendEventLinearized(sessionId, 'tool.call', {...});
  break;
```

### Phase 4: Modify turn_end Handler

**File: `packages/server/src/event-store-orchestrator.ts`**

Modify `turn_end` handler to only create `message.assistant` if there's NEW content after tools:

```typescript
case 'turn_end':
  if (active) {
    const turnResult = active.sessionContext!.endTurn(event.tokenUsage);

    // Only create message.assistant if:
    // 1. Content exists AND
    // 2. We haven't already flushed (no tools) OR there's post-tool content
    const hasUnflushedContent = !active.sessionContext!.hasPreToolContentFlushed();
    const hasPostToolContent = turnResult.hasPostToolContent; // New flag

    if (turnResult.content.length > 0 && (hasUnflushedContent || hasPostToolContent)) {
      this.appendEventLinearized(sessionId, 'message.assistant', {
        content: turnResult.content,
        tokenUsage: turnResult.tokenUsage,
        turn: turnResult.turn,
        model: active.model,
        stopReason: 'end_turn',
      });
    }
  }
  break;
```

### Phase 5: Simplify Message Reconstruction

**File: `packages/core/src/events/event-store.ts`**

With linear event ordering, simplify `getMessagesAt()`:

```typescript
async getMessagesAt(eventId: EventId): Promise<Message[]> {
  const ancestors = await this.backend.getAncestors(eventId);

  // Collect deleted event IDs
  const deletedEventIds = new Set<EventId>();
  for (const event of ancestors) {
    if (event.type === 'message.deleted') {
      deletedEventIds.add((event.payload as any).targetEventId);
    }
  }

  const messages: Message[] = [];

  for (const event of ancestors) {
    if (deletedEventIds.has(event.id)) continue;

    // Handle compaction/context cleared (existing)
    if (event.type === 'compact.summary') { /* ... */ }
    if (event.type === 'context.cleared') { /* ... */ }

    // User messages
    if (event.type === 'message.user') {
      // Merge consecutive user messages
      const payload = event.payload as { content: Message['content'] };
      const lastMessage = messages[messages.length - 1];
      if (lastMessage?.role === 'user') {
        lastMessage.content = mergeMessageContent(lastMessage.content, payload.content, 'user');
      } else {
        messages.push({ role: 'user', content: payload.content });
      }
    }

    // Assistant messages
    if (event.type === 'message.assistant') {
      const payload = event.payload as { content: Message['content'] };
      const lastMessage = messages[messages.length - 1];
      // Merge consecutive assistant messages (from multi-tool turns)
      if (lastMessage?.role === 'assistant') {
        lastMessage.content = mergeMessageContent(lastMessage.content, payload.content, 'assistant');
      } else {
        messages.push({ role: 'assistant', content: payload.content });
      }
    }

    // Tool results - create user message with tool_result content
    if (event.type === 'tool.result') {
      const payload = event.payload as { toolCallId: string; content: string; isError?: boolean };
      const lastMessage = messages[messages.length - 1];

      const toolResultBlock = {
        type: 'tool_result' as const,
        tool_use_id: payload.toolCallId,
        content: payload.content,
        is_error: payload.isError ?? false,
      };

      // Merge into existing user message if last was user with tool_results
      if (lastMessage?.role === 'user' && isToolResultContent(lastMessage.content)) {
        (lastMessage.content as any[]).push(toolResultBlock);
      } else {
        messages.push({ role: 'user', content: [toolResultBlock] as any });
      }
    }
  }

  return messages;
}

function isToolResultContent(content: Message['content']): boolean {
  if (!Array.isArray(content)) return false;
  return content.every(c => c.type === 'tool_result');
}
```

### Phase 6: Update TurnContentTracker

**File: `packages/server/src/orchestrator/turn-content-tracker.ts`**

Add methods to support pre-tool flush:

```typescript
/**
 * Check if pre-tool content has been flushed.
 */
hasPreToolContentFlushed(): boolean {
  return this.preToolFlushed;
}

/**
 * Mark pre-tool content as flushed.
 */
markPreToolFlushed(): void {
  this.preToolFlushed = true;
}

/**
 * Get sequence of items for current turn (for building content blocks).
 */
getCurrentTurnSequence(): SequenceItem[] {
  return [...this.currentTurnSequence];
}

/**
 * Check if there's content added after tools.
 * Used to determine if turn_end should create message.assistant.
 */
hasPostToolContent(): boolean {
  if (!this.preToolFlushed) return false;
  // Check if any content was added after the last tool_ref
  // ... implementation
}
```

## Test Cases

### Test 1: Single Tool Call Ordering
```typescript
it('should create message.assistant before tool.call for single tool', async () => {
  // Setup session
  // Trigger agent with prompt that causes one tool call
  // Verify event order: message.assistant → tool.call → tool.result
});
```

### Test 2: Multiple Tool Calls Ordering
```typescript
it('should create one message.assistant before all tool.calls', async () => {
  // Setup session
  // Trigger agent with prompt that causes multiple tool calls
  // Verify: message.assistant (with all tool_use) → tool.call → tool.result → tool.call → tool.result
});
```

### Test 3: Forked Session Reconstruction
```typescript
it('should reconstruct messages correctly for forked session with tools', async () => {
  // Create session with tool calls
  // Archive session
  // Fork session
  // Verify messages reconstruct correctly
  // Verify can send new message without API error
});
```

### Test 4: No Tools (No Regression)
```typescript
it('should create message.assistant at turn_end when no tools', async () => {
  // Setup session
  // Send prompt with no tool calls
  // Verify: message.assistant created at turn_end
  // Verify: No change from current behavior
});
```

### Test 5: Resume Session (No Regression)
```typescript
it('should resume session with tool history correctly', async () => {
  // Create session with tool calls
  // Close session
  // Resume session
  // Verify messages load correctly
  // Verify can continue conversation
});
```

### Test 6: Agentic Multi-Turn Loop
```typescript
it('should maintain correct ordering across agentic turns', async () => {
  // Setup session
  // Trigger multi-turn agentic loop (tool → continue → tool → continue)
  // Verify each turn has correct ordering
});
```

## Migration Considerations

1. **Existing sessions**: Old sessions have old event ordering. The simplified reconstruction should still handle them via the consecutive message merging logic.

2. **Backwards compatibility**: The new `message.assistant` events will have `stopReason: 'tool_use'` to distinguish from turn-end messages.

3. **No schema changes**: Using existing event types, just changing when they're created.

## Rollback Plan

If issues arise:
1. Revert the `tool_execution_start` handler changes
2. Revert the `turn_end` handler changes
3. Keep the simplified reconstruction (it handles both old and new ordering)

## Success Criteria

1. ✅ Fork session with tools → can send messages
2. ✅ Resume session with tools → can continue
3. ✅ New session with tools → correct ordering
4. ✅ Multi-tool in one turn → one message.assistant before all tool.calls
5. ✅ Agentic loop → each turn has correct ordering
6. ✅ No tools → same behavior as before
7. ✅ All existing tests pass

## Implementation Status: COMPLETE (January 2026)

The linear event ordering has been implemented with the following changes:

### Files Modified

1. **`packages/core/src/events/event-store.ts`**
   - Fixed `getMessagesAt()` to flush pending tool results at end when last message is assistant with tool_use
   - Uses snake_case field names (`tool_use_id`, `is_error`) to match Anthropic API format

2. **`packages/server/src/orchestrator/turn-content-tracker.ts`**
   - Added `preToolContentFlushed` flag to track if content was flushed
   - Added `hasPreToolContentFlushed()` method
   - Added `flushPreToolContent()` method to get and flush pre-tool content
   - Reset flag in `onTurnStart()` and `onAgentStart()`

3. **`packages/server/src/orchestrator/turn-manager.ts`**
   - Added wrapper methods for `hasPreToolContentFlushed()` and `flushPreToolContent()`

4. **`packages/server/src/orchestrator/session-context.ts`**
   - Exposed `hasPreToolContentFlushed()` and `flushPreToolContent()` methods

5. **`packages/server/src/event-store-orchestrator.ts`**
   - Modified `tool_execution_start` handler to flush pre-tool content as `message.assistant` BEFORE creating `tool.call` event
   - Modified `turn_end` handler to skip `message.assistant` creation if content was already flushed for tools

### Test Files

1. **`packages/server/test/orchestrator/event-ordering.test.ts`** (NEW)
   - Comprehensive tests for linear event ordering
   - Tests for single tool, multiple tools, agentic loops, forks, no tools, resume, errors

2. **`packages/server/test/agentic-loop-reconstruction.test.ts`** (UPDATED)
   - Updated field name expectations to use snake_case (`tool_use_id`, `is_error`)
