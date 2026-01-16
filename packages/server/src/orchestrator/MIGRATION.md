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

### Completed (Phase 8 - Part 2)

- [x] **Turn Management** - `currentTurn`, `turnTracker`, content tracking fields
  - Migrated 30+ usages in streaming event handlers (`forwardAgentEvent`)
  - All calls now go through SessionContext:
    - `sessionContext.startTurn()` for turn start (replaces `turnTracker.onTurnStart()`)
    - `sessionContext.endTurn()` for turn end (builds content blocks)
    - `sessionContext.addTextDelta()` for text streaming
    - `sessionContext.startToolCall()` / `endToolCall()` for tool tracking
    - `sessionContext.onAgentStart()` / `onAgentEnd()` for agent lifecycle
    - `sessionContext.getTurnStartTime()` for latency calculation
    - `sessionContext.getAccumulatedContent()` for client catch-up
    - `sessionContext.buildInterruptedContent()` for interrupted session persistence
  - RPC getState() uses SessionContext with fallback to legacy
  - Legacy fields still updated (dual-write) for backward compatibility
  - Next: Remove legacy field updates to complete cleanup

### Pending (Phase 8 - Part 3: Cleanup)

- [ ] **Remove Legacy Field Updates** - Remove LEGACY: marked sections in streaming handlers
  - Turn start: Remove `active.currentTurn`, `currentTurnStartTime`, `thisTurnContent`, `thisTurnToolCalls` updates
  - Message update: Remove `currentTurnAccumulatedText`, `currentTurnContentSequence`, `thisTurnContent` updates
  - Tool start/end: Remove `currentTurnToolCalls`, `currentTurnContentSequence`, `thisTurnToolCalls` updates
  - Turn end: Remove `lastTurnTokenUsage`, `thisTurnContent`, `thisTurnToolCalls` updates
  - Agent start/end: Remove accumulated content clearing
  - **Risk**: May break clients that read legacy fields directly

- [ ] **Remove Legacy Field Initializations** - Remove from session create/resume
  - Remove `currentTurnAccumulatedText`, `currentTurnToolCalls`, `currentTurnContentSequence`
  - Remove `thisTurnContent`, `thisTurnToolCalls`
  - Remove `currentTurn`, `currentTurnStartTime`, `lastTurnTokenUsage`
  - Remove `turnTracker` initialization (use sessionContext.startTurn() etc.)

- [ ] **Make sessionContext Required** - Change type from `sessionContext?: SessionContext`
  - Update ActiveSession interface
  - Remove all `?.` and `!.` optional chaining for sessionContext access
  - Remove fallback code paths in getState() and other methods

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
