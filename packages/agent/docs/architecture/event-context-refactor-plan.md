# Event Context Refactor Plan

## Problem Statement

When adding `runId` correlation, we had to modify **13 emit calls** across **6 handler files** and **24+ appendEventLinearized calls**. Every handler:

1. Manually calls `getActiveSession(sessionId)` to get the active session
2. Manually extracts `active?.currentRunId`
3. Manually constructs the event envelope with `{ type, sessionId, timestamp, runId, data }`
4. Manually includes `runId` in persistence payloads

This is a textbook **Shotgun Surgery** anti-pattern. Adding any new cross-cutting concern (tracing, metrics, audit fields) requires touching every handler.

### Current Flow (Anti-Pattern)

```
AgentEventHandler.forwardEvent(sessionId, event)
    │
    ├─► const timestamp = new Date().toISOString()
    ├─► const active = getActiveSession(sessionId)  // Each handler does this
    │
    └─► TurnEventHandler.handleTurnStart(sessionId, event, timestamp)
            │
            ├─► const active = this.deps.getActiveSession(sessionId)  // AGAIN!
            ├─► const runId = active?.currentRunId                    // Manual extraction
            │
            ├─► this.deps.emit('agent_event', {
            │       type: 'agent.turn_start',
            │       sessionId,           // Manual
            │       timestamp,           // Manual
            │       runId,               // Manual
            │       data: { turn }
            │   })
            │
            └─► this.deps.appendEventLinearized(sessionId, 'stream.turn_start', {
                    turn, runId          // Manual runId inclusion
                })
```

**Problems:**
- `getActiveSession` called multiple times per event (once in coordinator, once in handler)
- Every handler manually constructs the same envelope structure
- No compile-time guarantee that runId is included
- Easy to forget fields when adding new handlers

---

## Proposed Solution: EventContext Pattern

### Core Idea

Create a **scoped EventContext** at the start of each event dispatch that:
1. Resolves the active session ONCE
2. Captures timestamp ONCE
3. Provides typed methods for emitting/persisting events
4. Automatically includes sessionId, timestamp, runId in all events

### New Flow (Proposed)

```
AgentEventHandler.forwardEvent(sessionId, event)
    │
    ├─► const ctx = EventContext.create(sessionId, deps)
    │       // Resolves session, captures timestamp, extracts runId ONCE
    │
    └─► TurnEventHandler.handleTurnStart(ctx, event)
            │
            ├─► ctx.emit('agent.turn_start', { turn })
            │       // Automatically includes sessionId, timestamp, runId
            │
            └─► ctx.persist('stream.turn_start', { turn })
                    // Automatically includes runId in payload
```

---

## Design

### 1. EventContext Interface

```typescript
// src/orchestrator/turn/event-context.ts

/**
 * Scoped context for a single event dispatch.
 * Created at the start of forwardEvent(), passed to all handlers.
 * Provides typed methods that automatically include session metadata.
 */
export interface EventContext {
  /** Session ID this context is scoped to */
  readonly sessionId: SessionId;

  /** Timestamp captured at context creation (consistent across all events) */
  readonly timestamp: string;

  /** Current run ID (undefined if no active run) */
  readonly runId: string | undefined;

  /** Active session (may be undefined for some event types) */
  readonly active: ActiveSession | undefined;

  /**
   * Emit a real-time event to WebSocket clients.
   * Automatically includes sessionId, timestamp, runId.
   */
  emit(type: AgentEventType, data?: Record<string, unknown>): void;

  /**
   * Persist an event to the event store (linearized).
   * Automatically includes runId in payload.
   */
  persist(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void;
}
```

### 2. EventContext Implementation

```typescript
// src/orchestrator/turn/event-context.ts

export class EventContextImpl implements EventContext {
  readonly sessionId: SessionId;
  readonly timestamp: string;
  readonly runId: string | undefined;
  readonly active: ActiveSession | undefined;

  private readonly deps: EventContextDeps;

  private constructor(
    sessionId: SessionId,
    deps: EventContextDeps
  ) {
    this.sessionId = sessionId;
    this.timestamp = new Date().toISOString();
    this.deps = deps;
    this.active = deps.getActiveSession(sessionId);
    this.runId = this.active?.currentRunId;
  }

  static create(sessionId: SessionId, deps: EventContextDeps): EventContext {
    return new EventContextImpl(sessionId, deps);
  }

  emit(type: AgentEventType, data?: Record<string, unknown>): void {
    this.deps.emit('agent_event', {
      type,
      sessionId: this.sessionId,
      timestamp: this.timestamp,
      runId: this.runId,
      data,
    });
  }

  persist(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void {
    this.deps.appendEventLinearized(
      this.sessionId,
      type,
      { ...payload, runId: this.runId },
      onCreated
    );
  }
}

interface EventContextDeps {
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  appendEventLinearized: (...) => void;
  emit: (event: string, data: unknown) => void;
}
```

### 3. Typed Event Types (Optional Enhancement)

For compile-time safety, we can define discriminated union types:

```typescript
// src/orchestrator/turn/event-types.ts

export type AgentEventType =
  | 'agent.turn_start'
  | 'agent.turn_end'
  | 'agent.text_delta'
  | 'agent.thinking_start'
  | 'agent.thinking_delta'
  | 'agent.thinking_end'
  | 'agent.tool_start'
  | 'agent.tool_end'
  | 'agent.compaction'
  | 'agent.complete'
  | 'agent.subagent_event'
  | 'agent.subagent_status';

// For even stronger typing (Phase 2):
export type AgentEvent =
  | { type: 'agent.turn_start'; data: { turn: number } }
  | { type: 'agent.turn_end'; data: TurnEndData }
  | { type: 'agent.text_delta'; data: { delta: string } }
  // ... etc
```

### 4. Handler Interface Changes

**Before:**
```typescript
export interface TurnEventHandlerDeps {
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  appendEventLinearized: (...) => void;
  emit: (event: string, data: unknown) => void;
}

class TurnEventHandler {
  handleTurnStart(sessionId: SessionId, event: TronEvent, timestamp: string): void {
    const active = this.deps.getActiveSession(sessionId);
    const runId = active?.currentRunId;
    // ... manual emit with all fields
  }
}
```

**After:**
```typescript
// No more deps needed! Context provides everything
class TurnEventHandler {
  handleTurnStart(ctx: EventContext, event: TronEvent): void {
    ctx.active?.sessionContext?.startTurn(event.turn);
    ctx.emit('agent.turn_start', { turn: event.turn });
    ctx.persist('stream.turn_start', { turn: event.turn });
  }
}
```

### 5. Coordinator Changes

**Before (AgentEventHandler):**
```typescript
forwardEvent(sessionId: SessionId, event: TronEvent): void {
  const timestamp = new Date().toISOString();
  const active = this.config.getActiveSession(sessionId);

  switch (event.type) {
    case 'turn_start':
      this.turnHandler.handleTurnStart(sessionId, event, timestamp);
      break;
    // ... 15 more cases
  }
}
```

**After:**
```typescript
forwardEvent(sessionId: SessionId, event: TronEvent): void {
  const ctx = EventContext.create(sessionId, this.config);

  // Forward subagent events first (if applicable)
  if (ctx.active?.parentSessionId) {
    this.subagentForwarder.forwardToParent(ctx, event);
  }

  switch (event.type) {
    case 'turn_start':
      this.turnHandler.handleTurnStart(ctx, event);
      break;
    // ... same routing, but cleaner handler signatures
  }
}
```

---

## Migration Strategy

### Phase 1: Create EventContext (Non-Breaking)

1. Create `EventContext` interface and implementation
2. Add `EventContext.create()` to AgentEventHandler
3. Keep existing handler interfaces working
4. Add deprecation warnings to old pattern

**Files to create:**
- `src/orchestrator/turn/event-context.ts`

### Phase 2: Migrate Handlers One-by-One

Migrate each handler to use EventContext:

1. **StreamingEventHandler** (simplest - no persistence)
2. **CompactionEventHandler** (simple - one method)
3. **HookEventHandler** (simple - two methods)
4. **LifecycleEventHandler** (medium complexity)
5. **TurnEventHandler** (most complex)
6. **ToolEventHandler** (complex - UIRenderHandler integration)
7. **SubagentForwarder** (special - creates child contexts)

For each handler:
1. Change method signatures to accept `EventContext`
2. Replace manual `getActiveSession` with `ctx.active`
3. Replace manual `emit` with `ctx.emit`
4. Replace manual `appendEventLinearized` with `ctx.persist`
5. Update tests

### Phase 3: Remove Old Pattern

1. Remove `getActiveSession` from handler deps
2. Remove `emit` from handler deps
3. Remove `appendEventLinearized` from handler deps
4. Handlers receive only `EventContext` + any handler-specific deps (like `uiRenderHandler`)

---

## Benefits

### 1. Eliminates Shotgun Surgery
Adding a new field (like `traceId`) requires changing ONE place:

```typescript
// EventContext.emit() automatically includes traceId
emit(type: AgentEventType, data?: Record<string, unknown>): void {
  this.deps.emit('agent_event', {
    type,
    sessionId: this.sessionId,
    timestamp: this.timestamp,
    runId: this.runId,
    traceId: this.traceId,  // NEW - added in ONE place
    data,
  });
}
```

### 2. Consistent Timestamps
All events in a single `forwardEvent()` call share the same timestamp:

```typescript
const ctx = EventContext.create(sessionId, deps);
// ctx.timestamp is captured ONCE
// All handlers use the same timestamp
```

### 3. Single Session Lookup
Session is resolved ONCE per event dispatch:

```typescript
// Before: 2+ lookups per event
const active = this.deps.getActiveSession(sessionId);  // Coordinator
const active = this.deps.getActiveSession(sessionId);  // Handler

// After: 1 lookup
const ctx = EventContext.create(sessionId, deps);  // Contains active
```

### 4. Type Safety (Optional)
With typed event types, we get compile-time guarantees:

```typescript
// Compiler error: 'agent.turn_strat' is not a valid event type
ctx.emit('agent.turn_strat', { turn: 1 });
```

### 5. Easier Testing
Tests create a mock context instead of mocking multiple deps:

```typescript
// Before: Mock 3 deps
const deps = {
  getActiveSession: vi.fn(),
  appendEventLinearized: vi.fn(),
  emit: vi.fn(),
};

// After: Create test context
const ctx = createTestEventContext({
  sessionId: 'test-session',
  runId: 'run-123',
});
```

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Large migration | Migrate one handler at a time, keep old interface working |
| Test rewrites | Provide `createTestEventContext()` helper |
| UIRenderHandler coupling | Keep uiRenderHandler as separate dep, pass ctx.runId |
| Subagent forwarding | SubagentForwarder creates child context for parent session |

---

## Implementation Checklist

### Phase 1: Foundation
- [ ] Create `EventContext` interface
- [ ] Create `EventContextImpl` class
- [ ] Create `createTestEventContext()` test helper
- [ ] Add `EventContext.create()` to AgentEventHandler
- [ ] Write unit tests for EventContext

### Phase 2: Handler Migration
- [ ] Migrate StreamingEventHandler + tests
- [ ] Migrate CompactionEventHandler + tests
- [ ] Migrate HookEventHandler + tests
- [ ] Migrate LifecycleEventHandler + tests
- [ ] Migrate TurnEventHandler + tests
- [ ] Migrate ToolEventHandler + tests
- [ ] Migrate SubagentForwarder + tests

### Phase 3: Cleanup
- [ ] Remove deprecated deps from handlers
- [ ] Remove old method signatures
- [ ] Update documentation
- [ ] Final test pass

---

## Example: Before and After

### StreamingEventHandler - Before

```typescript
handleMessageUpdate(
  sessionId: SessionId,
  event: TronEvent,
  timestamp: string,
  active: ActiveSession | undefined
): void {
  const msgEvent = event as { content?: string };
  const runId = active?.currentRunId;

  if (active && typeof msgEvent.content === 'string') {
    active.sessionContext!.addTextDelta(msgEvent.content);
  }

  this.deps.emit('agent_event', {
    type: 'agent.text_delta',
    sessionId,
    timestamp,
    runId,
    data: { delta: msgEvent.content },
  });
}
```

### StreamingEventHandler - After

```typescript
handleMessageUpdate(ctx: EventContext, event: TronEvent): void {
  const msgEvent = event as { content?: string };

  if (ctx.active && typeof msgEvent.content === 'string') {
    ctx.active.sessionContext!.addTextDelta(msgEvent.content);
  }

  ctx.emit('agent.text_delta', { delta: msgEvent.content });
}
```

**Lines reduced:** 15 → 7 (53% reduction)
**Manual field handling:** 4 → 0
