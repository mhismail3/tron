# Event Store Enhancement Plan

## Executive Summary

The server event store is the **source of truth** for all session data. Currently, it stores basic message content but misses valuable metadata and granular tool/turn information. This plan enhances the event store to capture **all** available data comprehensively.

---

## Current State Analysis

### What IS Being Stored

| Event Type | Payload | Status |
|------------|---------|--------|
| `session.start` | workingDirectory, model, provider, title | ✅ Complete |
| `session.end` | reason, timestamp | ✅ Complete |
| `session.fork` | sourceSessionId, sourceEventId, name | ✅ Complete |
| `message.user` | content (text or tool_result blocks) | ✅ Complete |
| `message.assistant` | content (tool_use + text blocks), tokenUsage | ⚠️ Partial |
| `config.model_switch` | previousModel, newModel | ✅ Complete |

### What's MISSING from `message.assistant`

Per the type definition (`AssistantMessageEvent` in `types.ts`), these fields should be stored:

```typescript
payload: {
  content: ContentBlock[];       // ✅ Currently stored
  turn: number;                  // ❌ MISSING - Available from runResult.turns
  tokenUsage: TokenUsage;        // ✅ Currently stored
  stopReason: string;            // ❌ MISSING - Available from runResult.stoppedReason
  latency?: number;              // ❌ MISSING - Need to track timing
  model: string;                 // ❌ MISSING - Available from active.model
  hasThinking?: boolean;         // ❌ MISSING - Detectable from content blocks
}
```

### Event Types DEFINED But NOT STORED

| Event Type | Purpose | Data Source |
|------------|---------|-------------|
| `tool.call` | Discrete tool invocation | `tool_execution_start` agent event |
| `tool.result` | Discrete tool result with duration | `tool_execution_end` agent event |
| `stream.turn_start` | Turn boundary marker | `turn_start` agent event |
| `stream.turn_end` | Turn completion with timing | `turn_end` agent event |
| `error.agent` | Agent-level errors | `runAgent()` catch block |
| `error.tool` | Tool execution errors | `tool_execution_end` with isError |
| `error.provider` | API/provider errors | `api_retry` agent events |

---

## Data Availability Audit

### From TronAgent Events (Real-time)

The agent emits these events during execution that we can capture:

```typescript
// Turn lifecycle
{ type: 'turn_start', turn: number }
{ type: 'turn_end', turn: number, duration: number, tokenUsage: TokenUsage }

// Tool execution
{ type: 'tool_execution_start', toolName: string, toolCallId: string, arguments: object }
{ type: 'tool_execution_end', toolName: string, toolCallId: string, duration: number, isError: boolean, result: object }

// Errors and retries
{ type: 'api_retry', attempt: number, maxRetries: number, delayMs: number, errorCategory: string, errorMessage: string }

// Agent lifecycle
{ type: 'agent_start', sessionId: string }
{ type: 'agent_end', error?: string }
{ type: 'agent_interrupted', turn: number, partialContent?: string, activeTool?: string }
```

### From RunResult (Final)

```typescript
{
  success: boolean;
  messages: Message[];           // Full message array
  turns: number;                 // Total turns executed
  totalTokenUsage: TokenUsage;   // Aggregated tokens
  error?: string;                // Error if failed
  stoppedReason?: string;        // Why agent stopped
  interrupted?: boolean;         // Was it aborted
  partialContent?: string;       // Partial streaming content
}
```

---

## Implementation Plan

### Phase 1: Enrich `message.assistant` Payload (Low Risk)

**Goal**: Add all missing metadata fields to assistant message events.

**Changes to `event-store-orchestrator.ts`**:

```typescript
// Track timing around agent.run()
const runStartTime = Date.now();
const runResult = await active.agent.run(options.prompt);
const runLatency = Date.now() - runStartTime;

// Detect if content has thinking blocks
const hasThinking = currentTurnContent.some((b: any) => b.type === 'thinking');

// Store enriched payload
await this.eventStore.append({
  sessionId: active.sessionId,
  type: 'message.assistant',
  payload: {
    content: normalizedAssistantContent,
    tokenUsage: runResult.totalTokenUsage,
    turn: runResult.turns,                    // NEW
    model: active.model,                      // NEW
    stopReason: runResult.stoppedReason,      // NEW
    latency: runLatency,                      // NEW
    hasThinking,                              // NEW
  },
});
```

**Risk**: Very low - just adding more fields to existing event.

---

### Phase 2: Store Discrete Tool Events (Medium Risk)

**Goal**: Store `tool.call` and `tool.result` as separate events for granular tracking.

**Changes**: Modify `forwardAgentEvent()` to ALSO store events (not just emit):

```typescript
private forwardAgentEvent(sessionId: SessionId, event: TronEvent): void {
  // ... existing emit logic ...

  // ALSO store discrete tool events
  if (event.type === 'tool_execution_start') {
    this.eventStore.append({
      sessionId,
      type: 'tool.call',
      payload: {
        toolCallId: event.toolCallId,
        name: event.toolName,
        arguments: event.arguments,
        turn: this.activeSessions.get(sessionId)?.currentTurn ?? 0,
      },
    }).catch(err => logger.error('Failed to store tool.call event', { err }));
  }

  if (event.type === 'tool_execution_end') {
    this.eventStore.append({
      sessionId,
      type: 'tool.result',
      payload: {
        toolCallId: event.toolCallId,
        content: truncateString(String(event.result?.content ?? ''), MAX_TOOL_RESULT_SIZE),
        isError: event.isError ?? false,
        duration: event.duration,
        // affectedFiles could be extracted from result.details if tools report it
      },
    }).catch(err => logger.error('Failed to store tool.result event', { err }));
  }
}
```

**Benefits**:
- Queryable tool execution history
- Per-tool duration tracking
- Tool error tracking separate from message content

**Risk**: Medium - adds more events, increases DB writes. Use fire-and-forget with error logging.

---

### Phase 3: Store Error Events (Low Risk)

**Goal**: Persist errors as discrete events for debugging and analytics.

**Changes to `runAgent()` catch block**:

```typescript
} catch (error) {
  logger.error('Agent run error', { sessionId: options.sessionId, error });

  // Store error event
  await this.eventStore.append({
    sessionId: active.sessionId,
    type: 'error.agent',
    payload: {
      error: error instanceof Error ? error.message : String(error),
      code: error instanceof Error ? error.name : undefined,
      recoverable: false,
    },
  }).catch(err => logger.error('Failed to store error event', { err }));

  // ... rest of error handling ...
}
```

**Also add to `forwardAgentEvent()` for API retries**:

```typescript
if (event.type === 'api_retry') {
  this.eventStore.append({
    sessionId,
    type: 'error.provider',
    payload: {
      provider: this.config.defaultProvider,
      error: event.errorMessage,
      code: event.errorCategory,
      retryable: true,
      retryAfter: event.delayMs,
    },
  }).catch(err => logger.error('Failed to store provider error event', { err }));
}
```

**Risk**: Low - errors are infrequent, adds valuable debugging data.

---

### Phase 4: Store Turn Boundary Events (Medium Risk)

**Goal**: Store `stream.turn_start` and `stream.turn_end` for turn-level analytics.

**Changes to `forwardAgentEvent()`**:

```typescript
if (event.type === 'turn_start') {
  this.eventStore.append({
    sessionId,
    type: 'stream.turn_start',
    payload: { turn: event.turn },
  }).catch(err => logger.error('Failed to store turn_start event', { err }));
}

if (event.type === 'turn_end') {
  this.eventStore.append({
    sessionId,
    type: 'stream.turn_end',
    payload: {
      turn: event.turn,
      tokenUsage: event.tokenUsage,
    },
  }).catch(err => logger.error('Failed to store turn_end event', { err }));
}
```

**Benefits**:
- Understand multi-turn structure
- Per-turn token usage
- Turn duration tracking

**Risk**: Medium - adds 2 events per turn. Consider making configurable.

---

### Phase 5: File Operation Events (Future/Optional)

**Goal**: Track file reads/writes for change history.

**Approach**: Tools would need to report affected files in their result details:

```typescript
// In tool execution, if result.details.affectedFiles exists:
if (event.type === 'tool_execution_end' && event.result?.details?.affectedFiles) {
  const files = event.result.details.affectedFiles as string[];
  for (const filePath of files) {
    await this.eventStore.append({
      sessionId,
      type: 'file.write', // or file.read/file.edit based on tool
      payload: {
        path: filePath,
        // size, contentHash would need tool to report
      },
    });
  }
}
```

**Risk**: Higher - requires tool modifications to report file operations.
**Recommendation**: Defer to Phase 2 of development.

---

## Implementation Order

| Phase | Priority | Risk | Effort | Dependencies |
|-------|----------|------|--------|--------------|
| 1. Enrich message.assistant | HIGH | Low | Small | None |
| 2. Discrete tool events | HIGH | Medium | Medium | Phase 1 |
| 3. Error events | MEDIUM | Low | Small | None |
| 4. Turn boundary events | LOW | Medium | Small | None |
| 5. File operation events | LOW | High | Large | Tool changes |

---

## Testing Checklist

After implementation:

- [ ] Create new session, send message with tool use
- [ ] Verify `message.assistant` has: turn, model, stopReason, latency
- [ ] Verify `tool.call` events created with arguments
- [ ] Verify `tool.result` events created with duration
- [ ] Trigger an error, verify `error.agent` event stored
- [ ] Verify iOS app still displays correctly (backward compatible)
- [ ] Query events by type to verify searchability
- [ ] Check DB size growth is reasonable

---

## Backward Compatibility

All changes are **additive**:
- Existing events continue to work
- New fields in `message.assistant` are optional for consumers
- New event types are separate from existing ones
- iOS app can ignore events it doesn't understand

---

## Configuration Options (Future)

Consider adding flags to control verbosity:

```typescript
interface EventStoreOrchestratorConfig {
  // ... existing ...

  // Event storage options
  storeToolEvents?: boolean;      // Default: true
  storeTurnEvents?: boolean;      // Default: false (high volume)
  storeStreamDeltas?: boolean;    // Default: false (very high volume)
}
```

---

## Summary

This plan transforms the event store from basic message storage to a **comprehensive audit log** that captures:

1. **Rich message metadata** (turn, model, timing, stop reason)
2. **Granular tool execution** (individual calls with duration/errors)
3. **Error history** (agent, tool, and provider errors)
4. **Turn structure** (boundaries for multi-turn analysis)

All data sources have been verified as available from TronAgent. Implementation is low-to-medium risk with high value for debugging, analytics, and future features.
