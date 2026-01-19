# Orchestrator Migration Tracking

## Overview

Incremental migration from legacy `ActiveSession` fields to `SessionContext` module.

**Status: COMPLETE** - All legacy fields have been removed and sessionContext is now required.

## Migration Status

### Completed (Phase 6)

- [x] **Plan Mode** - `isInPlanMode()`, `getBlockedTools()`, `isToolBlocked()`, `enterPlanMode()`, `exitPlanMode()`
  - All operations use SessionContext directly

### Completed (Phase 7)

- [x] **Processing State** - `isProcessing`, `lastActivity`
  - `runAgent()` - check and set processing state
  - `cancelAgent()` - check and clear processing state
  - `cleanupInactiveSessions()` - check processing and activity time

### Completed (Phase 8 - Part 1)

- [x] **Event Persistence** - `pendingHeadEventId`, `appendPromiseChain`, `lastAppendError`
  - Migrated 40+ usages to SessionContext methods
  - Uses `sessionContext.appendEvent()`, `appendEventFireAndForget()`, `appendMultipleEvents()`
  - Uses `sessionContext.flushEvents()` to wait for pending events
  - Uses `sessionContext.runInChain()` for special operations (deleteMessage)
  - Event chaining handled entirely by SessionContext's EventPersister

- [x] **Message Event IDs**
  - Uses `sessionContext.addMessageEventId()` for user message tracking

### Completed (Phase 8 - Part 2)

- [x] **Turn Management** - `currentTurn`, `turnTracker`, content tracking fields
  - Migrated 30+ usages in streaming event handlers (`forwardAgentEvent`)
  - All calls go through SessionContext:
    - `sessionContext.startTurn()` for turn start
    - `sessionContext.endTurn()` for turn end (builds content blocks)
    - `sessionContext.addTextDelta()` for text streaming
    - `sessionContext.startToolCall()` / `endToolCall()` for tool tracking
    - `sessionContext.onAgentStart()` / `onAgentEnd()` for agent lifecycle
    - `sessionContext.getTurnStartTime()` for latency calculation
    - `sessionContext.getAccumulatedContent()` for client catch-up
    - `sessionContext.buildInterruptedContent()` for interrupted session persistence

### Completed (Phase 8 - Part 3: Cleanup)

- [x] **Remove Legacy Field Updates** - Removed all LEGACY: marked sections in streaming handlers
  - Turn start: Removed `active.currentTurn`, `currentTurnStartTime`, etc.
  - Message update: Removed `currentTurnAccumulatedText`, etc.
  - Tool start/end: Removed `currentTurnToolCalls`, etc.
  - Turn end: Removed `lastTurnTokenUsage`, etc.
  - Agent start/end: Removed accumulated content clearing

- [x] **Remove Legacy Field Initializations** - Removed from session create/resume
  - Removed all content tracking fields
  - Removed turnTracker initialization

- [x] **Make sessionContext Required**
  - Updated ActiveSession interface in types.ts
  - Removed optional chaining for sessionContext access
  - Removed fallback code paths

- [x] **Delete Legacy Event Linearizer**
  - Removed `event-linearizer.ts` (replaced by EventPersister in SessionContext)
  - Removed exports from orchestrator/index.ts

### Fields Remaining in ActiveSession

These fields stay in ActiveSession (not session state):

- **sessionId** - Session identifier
- **agent** - TronAgent instance
- **isProcessing** - Processing flag (synced with SessionContext)
- **lastActivity** - Activity timestamp (synced with SessionContext)
- **workingDirectory** - Path string
- **model** - Model name
- **workingDir** - WorkingDirectory abstraction
- **wasInterrupted** - Interrupt flag
- **reasoningLevel** - Reasoning level setting
- **messageEventIds** - Message tracking array
- **skillTracker** - Uses existing @tron/core tracker
- **rulesTracker** - Uses existing @tron/core tracker
- **sessionContext** - **REQUIRED** SessionContext instance

## Architecture After Migration

```
ActiveSession
├── sessionContext (required)
│   ├── EventPersister (event linearization)
│   ├── TurnManager (turn lifecycle, content tracking)
│   ├── PlanModeHandler (plan mode state)
│   └── SessionReconstructor (state restoration)
├── agent (TronAgent instance)
├── skillTracker (from @tron/core)
└── rulesTracker (from @tron/core)
```

All session state management now goes through SessionContext, providing:
- Encapsulated modules with single responsibilities
- Clean interfaces for orchestrator operations
- Testable components in isolation
- State restoration via event reconstruction
