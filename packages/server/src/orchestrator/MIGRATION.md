# Orchestrator Migration Tracking

## Overview

Incremental migration from legacy `ActiveSession` fields to `SessionContext` module.

**Key Principle**: Legacy fields remain alongside SessionContext until ALL operations
are migrated. Phase 8 cleanup will remove legacy fields.

## Migration Status

### Completed (Phase 6)

- [x] **Plan Mode** - `isInPlanMode()`, `getBlockedTools()`, `isToolBlocked()`, `enterPlanMode()`, `exitPlanMode()`
  - Reads use SessionContext with fallback to legacy
  - Writes update both legacy and SessionContext

### Completed (Phase 7)

- [x] **Processing State** - `isProcessing`, `lastActivity`
  - `runAgent()` - check and set processing state
  - `cancelAgent()` - check and clear processing state
  - `cleanupInactiveSessions()` - check processing and activity time
  - All operations sync both legacy and SessionContext

### Completed (Phase 8 - Part 1)

- [x] **Event Persistence** - `pendingHeadEventId`, `appendPromiseChain`, `lastAppendError`
  - Migrated 40+ usages to SessionContext methods
  - Uses `sessionContext.appendEvent()`, `appendEventFireAndForget()`, `appendMultipleEvents()`
  - Uses `sessionContext.flushEvents()` to wait for pending events
  - Uses `sessionContext.runInChain()` for special operations (deleteMessage)
  - Legacy fields still initialized but NOT used for active event linearization
  - Event chaining now handled entirely by SessionContext's EventPersister

- [x] **Message Event IDs** (partial)
  - Uses `sessionContext.addMessageEventId()` for user message tracking
  - Legacy `messageEventIds` array still used in some places

### Deferred (Phase 8 - Part 2: Complex, Streaming-Critical)

- [ ] **Turn Management** - `currentTurn`, `turnTracker`, content tracking fields
  - 30+ usages in streaming event handlers
  - Both `turnTracker` and individual fields are updated (dual-write pattern)
  - Risk: Breaking turn tracking affects session resume and client catch-up
  - Current state: SessionContext's TurnManager receives updates alongside legacy fields
  - Target: Remove legacy field updates, use only SessionContext methods

### Not Migrated (Stay in ActiveSession)

- **agent** - TronAgent instance (not session state)
- **skillTracker** - Uses existing @tron/core tracker
- **rulesTracker** - Uses existing @tron/core tracker
- **workingDir** - WorkingDirectory abstraction

## Phase 8: Cleanup

After ALL operations are migrated:
1. Remove legacy fields from `ActiveSession` interface
2. Make `sessionContext` required (not optional)
3. Remove fallback code paths
4. **CRITICAL: Verify full iOS app compatibility**
   - Test session create/resume/fork
   - Test agent prompt/abort
   - Test event synchronization
   - Test plan mode UI
   - Test all RPC methods used by iOS app

## Migration Pattern

```typescript
// 1. Read operations - use SessionContext with fallback
getSomething(): T {
  const active = this.activeSessions.get(sessionId);
  if (active?.sessionContext) {
    return active.sessionContext.getSomething();
  }
  return active?.legacyField ?? defaultValue;
}

// 2. Write operations - update BOTH during migration
setSomething(value: T): void {
  // Update legacy field
  active.legacyField = value;

  // Also update SessionContext
  if (active.sessionContext) {
    active.sessionContext.setSomething(value);
  }
}
```
