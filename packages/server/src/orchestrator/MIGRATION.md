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

### Deferred (Complex, High Risk)

- [ ] **Event Persistence** - `pendingHeadEventId`, `appendPromiseChain`, `lastAppendError`
  - 40+ usages throughout orchestrator
  - Tightly coupled with streaming event handlers
  - Risk: Breaking event linearization could cause orphaned branches
  - Target: Use `sessionContext.appendEvent()`, `sessionContext.flushEvents()`

- [ ] **Turn Management** - `currentTurn`, `turnTracker`, content tracking fields
  - 30+ usages in streaming event handlers
  - Direct field access for accumulated content
  - Risk: Breaking turn tracking affects session resume
  - Target: Use `sessionContext.startTurn()`, `endTurn()`, `addTextDelta()`, etc.

- [ ] **Message Event IDs** - `messageEventIds`
  - Used for context audit
  - Lower risk but depends on event persistence
  - Target: Use `sessionContext.getMessageEventIds()`, `addMessageEventId()`

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
