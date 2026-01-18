# EventStoreOrchestrator Refactoring Plan

## Status: COMPLETE ✅

**Final Results:**
- Original size: 3,541 lines
- Final size: 1,566 lines
- Total reduction: 1,975 lines (55.8%)
- All 2,866 tests pass

## Overview

**Goal**: Break down the 3,541-line `event-store-orchestrator.ts` into composable, testable modules while maintaining zero regressions.

**Approach**: Test-Driven Development (TDD)
1. Write/verify tests for functionality being extracted
2. Extract to new module with clear interface
3. Update orchestrator to delegate to new module
4. Verify all tests pass
5. Repeat for next extraction

## Current State Analysis

### File: `event-store-orchestrator.ts` (3,541 lines → 2,496 lines)

| Section | Lines | Start | End | Dependencies |
|---------|-------|-------|-----|--------------|
| Imports & Types | ~165 | 1 | 165 | - |
| Constructor & Lifecycle | ~50 | 166 | 216 | EventStore, BrowserService |
| EventStore Access | ~50 | 217 | 266 | EventStore (delegate) |
| Session Management | ~480 | 267 | 750 | EventStore, Agent, SessionContext |
| Fork Operations | ~65 | 751 | 815 | EventStore, Session ops |
| Event Operations | ~120 | 816 | 937 | EventStore, SessionContext |
| **Agent Operations** | ~400 | 938 | 1336 | Agent, SessionContext, Skills |
| Model Switching | ~70 | 1337 | 1408 | Session, Agent |
| Context/Compaction | ~270 | 1409 | 1680 | SessionContext, handlers |
| Search | ~12 | 1681 | 1693 | EventStore |
| Health & Stats | ~20 | 1694 | 1714 | activeSessions |
| Worktree Operations | ~60 | 1715 | 1776 | WorktreeCoordinator |
| Private Methods | ~420 | 1777 | 2199 | Mixed |
| Linearized Appending | ~46 | 2200 | 2246 | SessionContext |
| **Sub-Agent Operations** | ~615 | 2247 | 2862 | Session, Agent, EventStore |
| **Agent Event Handling** | ~470 | 2863 | 3333 | SessionContext, EventEmitter |
| Browser Service | ~57 | 3334 | 3391 | BrowserService |
| Plan Mode | ~149 | 3392 | 3541 | SessionContext |

### Extracted Modules

```
orchestrator/
├── subagent-ops.ts         # Phase 1: Sub-agent operations (~250 lines)
├── agent-event-handler.ts  # Phase 2: Agent event handling (~380 lines)
├── skill-loader.ts         # Phase 3: Skill loading & content transform (~310 lines)
├── session-manager.ts      # Phase 5: Session lifecycle management (~730 lines)
├── context-ops.ts          # Phase 6: Context management (~344 lines)
├── agent-factory.ts        # Phase 7: Agent creation (~200 lines)
├── auth-provider.ts        # Phase 8: Authentication (~117 lines)
├── session-context.ts      # Session state wrapper
├── turn-manager.ts         # Turn lifecycle
├── turn-content-tracker.ts # Content accumulation
├── event-persister.ts      # Event linearization
├── session-reconstructor.ts # State restoration
├── worktree-ops.ts         # Worktree utilities
├── types.ts                # Shared types
└── handlers/
    ├── plan-mode.ts        # Plan mode state
    ├── compaction.ts       # Context compaction
    ├── context-clear.ts    # Context clearing
    └── interrupt.ts        # Interrupt handling
```

## Completed Phases

### Phase 1: Sub-Agent Operations ✅
**Files**: `orchestrator/subagent-ops.ts`
**Lines**: ~250
**Risk**: LOW

**Extracted Methods:**
- `spawnSubsession(parentSessionId, params)` → Creates in-process sub-agent
- `spawnTmuxAgent(parentSessionId, params)` → Creates out-of-process sub-agent
- `querySubagent(sessionId, queryType, limit)` → Queries sub-agent state
- `buildSubagentResultsContext(active)` → Formats pending results for injection

**Note**: `waitForSubagents` remained in orchestrator because it needs to iterate the activeSessions map.

### Phase 2: Agent Event Handling ✅
**Files**: `orchestrator/agent-event-handler.ts`
**Lines**: ~380
**Risk**: MEDIUM

**Extracted Methods:**
- `forwardAgentEvent(sessionId, event)` → Handles all agent event types
  - turn_start, turn_end
  - message_update
  - tool_use_batch
  - tool_execution_start/end
  - api_retry
  - agent_start/end
  - agent_interrupted
  - compaction_complete

### Phase 3: Skill Loading ✅
**Files**: `orchestrator/skill-loader.ts`
**Lines**: ~310
**Risk**: LOW

**Extracted Methods:**
- `loadSkillContextForPrompt(context, options)` → Loads and builds skill context
- `trackSkillsForPrompt(context, options)` → Tracks skill events
- `transformContentForLLM(content)` → Converts text documents for LLM

**Note**: Pass-through methods kept in orchestrator for backward compatibility with tests.

### Phase 4: Cleanup & Consolidation ✅
- Removed unused imports from orchestrator
- Added pass-through methods for testing compatibility
- Updated index.ts exports
- Documented extraction in this plan

### Phase 5: Session Manager ✅
**Files**: `orchestrator/session-manager.ts`
**Lines**: ~730
**Risk**: MEDIUM

**Extracted Methods:**
- `createSession(options)` → Creates new session with agent, rules, worktree
- `resumeSession(sessionId)` → Resumes existing session with full state reconstruction
- `endSession(sessionId, options)` → Terminates session with cleanup
- `getSession(sessionId)` → Gets session info
- `listSessions(options)` → Lists sessions with filtering
- `getActiveSession(sessionId)` → Gets active session
- `wasSessionInterrupted(sessionId)` → Checks if last turn was interrupted
- `forkSession(sessionId, fromEventId)` → Forks session at event point
- `cleanupInactiveSessions(threshold)` → Cleans up stale sessions

**Removed from orchestrator:**
- `sessionRowToInfo()` helper
- `reconstructPlanModeFromEvents()` helper
- `cleanupInactiveSessions()` (now delegated)
- Unused `this.config` field

**Lines reduced**: ~568 lines (2,496 → 1,928)

### Phase 6: Context Operations ✅
**Files**: `orchestrator/context-ops.ts`
**Lines**: ~344
**Risk**: LOW

**Extracted Methods:**
- `getContextSnapshot(sessionId)` → Returns context token snapshot
- `getDetailedContextSnapshot(sessionId)` → Returns per-message token breakdown
- `shouldCompact(sessionId)` → Checks if compaction needed
- `previewCompaction(sessionId)` → Preview without executing
- `confirmCompaction(sessionId, opts)` → Execute compaction
- `canAcceptTurn(sessionId, opts)` → Pre-turn validation
- `clearContext(sessionId)` → Clear all messages

### Phase 7: Agent Factory ✅
**Files**: `orchestrator/agent-factory.ts`
**Lines**: ~200
**Risk**: MEDIUM

**Extracted Methods:**
- `createAgentForSession(sessionId, workingDir, model, systemPrompt)` → Full agent setup
  - Tool instantiation (Read, Write, Edit, Bash, Grep, etc.)
  - Browser delegate setup
  - Sub-agent tool wiring (SpawnSubsession, SpawnTmuxAgent, QuerySubagent, WaitForSubagent)
  - Agent event forwarding

### Phase 8: Auth Provider ✅
**Files**: `orchestrator/auth-provider.ts`
**Lines**: ~117
**Risk**: LOW

**Extracted Methods:**
- `getAuthForProvider(model)` → Model-specific auth resolution
- `loadCodexTokens()` → Load Codex OAuth tokens
- `setCachedAuth(auth)` / `getCachedAuth()` → Auth cache management

## Success Criteria

- [x] All 2866 tests pass
- [x] `event-store-orchestrator.ts` reduced by ~1,975 lines (55.8%)
- [x] Operations fully encapsulated in new modules
- [x] No changes to public API of EventStoreOrchestrator
- [x] TypeScript compiles without errors

## Final State

Final `event-store-orchestrator.ts` size: 1,566 lines (from 3,541 original)

The orchestrator is now a thin coordination layer that:
- Initializes delegated modules
- Routes public API calls to appropriate delegates
- Manages shared state (activeSessions map)
- Handles event emission

**Total reduction**: 1,975 lines (55.8%)
