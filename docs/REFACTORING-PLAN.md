# Comprehensive Modular Refactoring Plan

## Overview

This document outlines the systematic refactoring of 5 major components following test-driven development principles. Each refactoring follows the same proven methodology used in the SessionContext/Orchestrator migration:

1. **Phase 0**: Analysis and planning
2. **Incremental extraction**: One module at a time with full test coverage
3. **Dual-write pattern**: Old and new code coexist during migration
4. **Gradual cutover**: Switch to new implementation with fallbacks
5. **Cleanup**: Remove legacy code paths

### Guiding Principles

- **TDD First**: Write tests before implementation
- **No Big Bang**: Never replace working code in one commit
- **Backwards Compatible**: Old interfaces continue working during migration
- **Independently Testable**: Each new module has isolated unit tests
- **Observable Migration**: Clear tracking of what's migrated vs legacy

---

## Project 1: RPC Handler Refactor

### Current State Analysis

**File**: `packages/core/src/rpc/handler.ts` (2002 lines)

**Problems Identified**:
- Monolithic switch statement with 40+ cases in `dispatch()`
- 185 response helper calls with repetitive patterns
- Parameter validation scattered across handlers
- Each handler follows identical boilerplate:
  ```typescript
  private async handleXxx(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as XxxParams | undefined;
    if (!params?.requiredField) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'field required');
    }
    const result = await this.context.xxxManager.method(params);
    return this.successResponse(request.id, result);
  }
  ```
- Adding new RPC methods requires changes in multiple places
- No request/response logging middleware
- Hard to test handlers in isolation

**Current Method Groups** (by namespace):
- `session.*` (6 methods): create, resume, list, delete, fork, switchModel
- `agent.*` (3 methods): prompt, abort, getState
- `model.*` (2 methods): switch, list
- `memory.*` (3 methods): search, addEntry, getHandoffs
- `filesystem.*` (3 methods): listDir, getHome, createDir
- `system.*` (2 methods): ping, getInfo
- `transcribe.*` (2 methods): audio, listModels
- `events.*` (3 methods): getHistory, getSince, append
- `tree.*` (4 methods): getVisualization, getBranches, getSubtree, getAncestors
- `search.*` (2 methods): content, events
- `worktree.*` (4 methods): getStatus, commit, merge, list
- `context.*` (7 methods): getSnapshot, getDetailedSnapshot, shouldCompact, previewCompaction, confirmCompaction, canAcceptTurn, clear
- `voiceNotes.*` (3 methods): save, list, delete
- `message.*` (1 method): delete
- `browser.*` (3 methods): startStream, stopStream, getStatus
- `skill.*` (4 methods): list, get, refresh, remove
- `file.*` (1 method): read
- `tool.*` (1 method): result

### Target Architecture

```
packages/core/src/rpc/
├── index.ts                    # Public exports
├── handler.ts                  # RpcHandler class (slim orchestrator)
├── types.ts                    # Type definitions (existing)
├── registry.ts                 # Method registration system
├── middleware/
│   ├── index.ts
│   ├── logging.ts              # Request/response logging
│   ├── validation.ts           # Schema-based param validation
│   └── error-boundary.ts       # Consistent error wrapping
├── handlers/
│   ├── index.ts                # Handler registry setup
│   ├── base.ts                 # BaseHandler with common utilities
│   ├── session.handler.ts      # session.* methods
│   ├── agent.handler.ts        # agent.* methods
│   ├── model.handler.ts        # model.* methods
│   ├── memory.handler.ts       # memory.* methods
│   ├── filesystem.handler.ts   # filesystem.* methods
│   ├── system.handler.ts       # system.* methods
│   ├── transcribe.handler.ts   # transcribe.* methods
│   ├── events.handler.ts       # events.* methods
│   ├── tree.handler.ts         # tree.* methods
│   ├── search.handler.ts       # search.* methods
│   ├── worktree.handler.ts     # worktree.* methods
│   ├── context.handler.ts      # context.* methods
│   ├── voice-notes.handler.ts  # voiceNotes.* methods
│   ├── message.handler.ts      # message.* methods
│   ├── browser.handler.ts      # browser.* methods
│   ├── skill.handler.ts        # skill.* methods
│   ├── file.handler.ts         # file.* methods
│   └── tool.handler.ts         # tool.* methods
└── validators/
    ├── index.ts
    ├── session.validators.ts   # Validation schemas per namespace
    └── ...
```

### Migration Phases

#### Phase 0: Foundation (1 commit)
- [ ] Create `rpc/registry.ts` with method registration types
- [ ] Create `rpc/handlers/base.ts` with shared handler utilities
- [ ] Create `rpc/middleware/index.ts` with middleware types
- [ ] Write comprehensive tests for registry
- [ ] Document architecture in code comments

#### Phase 1: Registry System (2-3 commits)
- [ ] Implement `MethodRegistry` class with:
  - `register(method, handler, options)`
  - `dispatch(method, request, context)`
  - Validation schema support
  - Middleware chain support
- [ ] Write tests for registry dispatch logic
- [ ] Write tests for validation integration

#### Phase 2: Extract First Handler Group - `system.*` (1 commit)
- [ ] Create `handlers/system.handler.ts`
- [ ] Write unit tests for system handlers in isolation
- [ ] Register system handlers in registry
- [ ] Dual-path: registry checks first, falls back to switch

#### Phase 3: Extract Handler Groups Incrementally (1 commit each)
Order by complexity (simplest first):
1. [ ] `filesystem.*` handlers
2. [ ] `model.*` handlers
3. [ ] `memory.*` handlers
4. [ ] `transcribe.*` handlers
5. [ ] `voiceNotes.*` handlers
6. [ ] `message.*` handlers
7. [ ] `file.*` handlers
8. [ ] `tool.*` handlers
9. [ ] `search.*` handlers
10. [ ] `worktree.*` handlers
11. [ ] `events.*` handlers
12. [ ] `tree.*` handlers
13. [ ] `skill.*` handlers
14. [ ] `browser.*` handlers
15. [ ] `context.*` handlers
16. [ ] `session.*` handlers
17. [ ] `agent.*` handlers (most complex, last)

Each extraction:
- Write handler tests first
- Extract handler class
- Register with registry
- Verify dual-path works
- Commit

#### Phase 4: Middleware Extraction (2 commits)
- [ ] Extract logging middleware
- [ ] Extract error boundary middleware
- [ ] Wire middleware into registry dispatch
- [ ] Test middleware chain

#### Phase 5: Validation Layer (2 commits)
- [ ] Add zod or similar for schema validation
- [ ] Create validation schemas for each namespace
- [ ] Integrate validation middleware
- [ ] Remove inline validation from handlers

#### Phase 6: Cleanup (1 commit)
- [ ] Remove legacy switch statement
- [ ] Remove dual-path fallbacks
- [ ] Update handler.ts to use registry exclusively
- [ ] Final test pass

### Test Strategy

```
packages/core/test/rpc/
├── handler.test.ts              # Integration tests (existing, expand)
├── registry.test.ts             # Registry unit tests
├── middleware/
│   ├── logging.test.ts
│   ├── validation.test.ts
│   └── error-boundary.test.ts
└── handlers/
    ├── session.handler.test.ts
    ├── agent.handler.test.ts
    └── ... (one per handler)
```

**Test Coverage Requirements**:
- Each handler: valid params, missing params, manager errors
- Registry: registration, dispatch, not-found
- Middleware: chain execution order, error propagation
- Integration: full request/response cycle

---

## Project 2: Server RPC Adapter Cleanup

### Current State Analysis

**File**: `packages/server/src/index.ts` (1153 lines)

**Problems Identified**:
- `createRpcContext()` is 800+ lines of repetitive adapter code
- Each manager adapter has similar boilerplate mapping
- Skill loader closure is 150+ lines inline
- Hard to find specific adapter code
- No separation between server lifecycle and RPC setup

**Current Structure**:
```typescript
function createRpcContext(orchestrator: EventStoreOrchestrator): RpcContext {
  return {
    sessionManager: { /* 120 lines */ },
    agentManager: { /* 200 lines */ },
    memoryStore: { /* 30 lines */ },
    eventStore: { /* 80 lines */ },
    worktreeManager: { /* 40 lines */ },
    transcriptionManager: { /* 20 lines */ },
    contextManager: { /* 50 lines */ },
    browserManager: { /* 30 lines */ },
    skillManager: { /* 150 lines */ },
    toolCallTracker: { /* 20 lines */ },
  };
}
```

### Target Architecture

```
packages/server/src/
├── index.ts                        # Slim entry: TronServer export
├── server.ts                       # TronServer class (lifecycle)
├── websocket.ts                    # WebSocket server (existing)
├── health.ts                       # Health server (existing)
├── rpc/
│   ├── index.ts                    # createRpcContext facade
│   ├── context-factory.ts          # Assembles RpcContext
│   └── adapters/
│       ├── session.adapter.ts      # sessionManager adapter
│       ├── agent.adapter.ts        # agentManager adapter
│       ├── memory.adapter.ts       # memoryStore adapter
│       ├── event-store.adapter.ts  # eventStore adapter
│       ├── worktree.adapter.ts     # worktreeManager adapter
│       ├── transcription.adapter.ts
│       ├── context.adapter.ts      # contextManager adapter
│       ├── browser.adapter.ts      # browserManager adapter
│       ├── skill.adapter.ts        # skillManager adapter
│       └── tool-call.adapter.ts    # toolCallTracker adapter
├── orchestrator/                   # (existing modules)
└── browser/                        # (existing)
```

### Migration Phases

#### Phase 0: Setup (1 commit)
- [ ] Create `server/src/rpc/` directory structure
- [ ] Create adapter interface types
- [ ] Write tests for adapter contracts

#### Phase 1: Extract Adapters Incrementally (1 commit each)
Order by size (smallest first):
1. [ ] `tool-call.adapter.ts` (~20 lines)
2. [ ] `transcription.adapter.ts` (~20 lines)
3. [ ] `memory.adapter.ts` (~30 lines)
4. [ ] `browser.adapter.ts` (~30 lines)
5. [ ] `worktree.adapter.ts` (~40 lines)
6. [ ] `context.adapter.ts` (~50 lines)
7. [ ] `event-store.adapter.ts` (~80 lines)
8. [ ] `session.adapter.ts` (~120 lines)
9. [ ] `skill.adapter.ts` (~150 lines)
10. [ ] `agent.adapter.ts` (~200 lines)

Each extraction:
- Write adapter tests
- Extract to file
- Import in createRpcContext
- Verify server still works
- Commit

#### Phase 2: Context Factory (1 commit)
- [ ] Create `context-factory.ts`
- [ ] Move assembly logic from index.ts
- [ ] Clean up index.ts to just re-export

#### Phase 3: Server Lifecycle Cleanup (1 commit)
- [ ] Extract TronServer to `server.ts` if not already
- [ ] Clean up initialization flow
- [ ] Document server lifecycle

### Test Strategy

```
packages/server/test/rpc/
├── context-factory.test.ts
└── adapters/
    ├── session.adapter.test.ts
    ├── agent.adapter.test.ts
    └── ... (one per adapter)
```

**Test Coverage Requirements**:
- Each adapter: method delegation, error handling
- Context factory: assembly, missing orchestrator handling
- Integration: full RPC flow through adapters

---

## Project 3: Provider Base Class

### Current State Analysis

**Files**:
- `anthropic.ts` (991 lines) - Has retry logic, OAuth refresh
- `openai.ts` (609 lines) - No retry logic
- `openai-codex.ts` (806 lines) - No retry logic, reasoning support
- `google.ts` (528 lines) - No retry logic

**Problems Identified**:
- Retry logic only in Anthropic provider
- Each provider has similar streaming patterns
- Error handling inconsistent across providers
- Token counting duplicated
- No shared base for common functionality

**Common Patterns Across Providers**:
```typescript
// All providers have:
- stream(context, options): AsyncGenerator<StreamEvent>
- convertMessages(messages): ProviderFormat
- convertTools(tools): ProviderFormat
- handleStreamChunk(chunk): StreamEvent[]
- calculateUsage(response): TokenUsage
```

### Target Architecture

```
packages/core/src/providers/
├── index.ts                    # Public exports
├── factory.ts                  # Provider factory (existing)
├── models.ts                   # Model definitions (existing)
├── base/
│   ├── index.ts
│   ├── provider.ts             # Abstract BaseProvider class
│   ├── stream-processor.ts     # Shared stream utilities
│   ├── retry-handler.ts        # Retry with backoff
│   └── error-normalizer.ts     # Consistent error format
├── anthropic/
│   ├── index.ts
│   ├── provider.ts             # AnthropicProvider extends BaseProvider
│   ├── message-converter.ts    # Anthropic-specific conversion
│   └── stream-handler.ts       # Anthropic stream processing
├── openai/
│   ├── index.ts
│   ├── provider.ts             # OpenAIProvider extends BaseProvider
│   ├── message-converter.ts
│   └── stream-handler.ts
├── openai-codex/
│   ├── index.ts
│   ├── provider.ts             # OpenAICodexProvider extends BaseProvider
│   ├── message-converter.ts
│   └── stream-handler.ts
├── google/
│   ├── index.ts
│   ├── provider.ts             # GoogleProvider extends BaseProvider
│   ├── message-converter.ts
│   └── stream-handler.ts
└── prompts/                    # (existing)
```

### Migration Phases

#### Phase 0: Base Infrastructure (2 commits)
- [ ] Create `base/provider.ts` with abstract BaseProvider
- [ ] Create `base/retry-handler.ts` extracting from anthropic.ts
- [ ] Create `base/error-normalizer.ts` with unified error types
- [ ] Write comprehensive tests for base utilities

#### Phase 1: Stream Processor (1 commit)
- [ ] Create `base/stream-processor.ts`
- [ ] Extract common stream handling patterns
- [ ] Write tests for stream processing

#### Phase 2: Migrate Anthropic Provider (2 commits)
- [ ] Refactor anthropic.ts to extend BaseProvider
- [ ] Extract message converter
- [ ] Extract stream handler
- [ ] Ensure all existing tests pass
- [ ] Add new unit tests for extracted modules

#### Phase 3: Migrate OpenAI Provider (2 commits)
- [ ] Refactor openai.ts to extend BaseProvider
- [ ] Add retry logic via BaseProvider
- [ ] Extract message converter and stream handler
- [ ] Write/update tests

#### Phase 4: Migrate OpenAI Codex Provider (2 commits)
- [ ] Refactor openai-codex.ts to extend BaseProvider
- [ ] Handle reasoning-specific logic
- [ ] Extract modules
- [ ] Write/update tests

#### Phase 5: Migrate Google Provider (2 commits)
- [ ] Refactor google.ts to extend BaseProvider
- [ ] Extract modules
- [ ] Write/update tests

#### Phase 6: Cleanup and Documentation (1 commit)
- [ ] Remove any remaining duplication
- [ ] Update factory.ts for new structure
- [ ] Document provider extension pattern

### Test Strategy

```
packages/core/test/providers/
├── base/
│   ├── provider.test.ts
│   ├── retry-handler.test.ts
│   ├── error-normalizer.test.ts
│   └── stream-processor.test.ts
├── anthropic/
│   ├── provider.test.ts
│   ├── message-converter.test.ts
│   └── stream-handler.test.ts
├── openai/
│   └── ... (same structure)
├── openai-codex/
│   └── ...
└── google/
    └── ...
```

**Test Coverage Requirements**:
- Base provider: abstract contract, retry behavior, error normalization
- Each provider: message conversion, stream handling, tool formatting
- Integration: end-to-end streaming with mocked API

---

## Project 4: SQLite Backend Modularization

### Current State Analysis

**File**: `packages/core/src/events/sqlite-backend.ts` (1385 lines)

**Problems Identified**:
- Mixes 6+ distinct concerns in one file
- 400+ lines of inline SQL in migration strings
- Hard to test individual operations in isolation
- Database initialization coupled with business logic
- No clear separation of read vs write operations

**Current Responsibilities**:
1. **Database Lifecycle** (~100 lines): initialize, close, migrations
2. **Workspace Operations** (~80 lines): create, get, list workspaces
3. **Session Operations** (~250 lines): CRUD, counters, message previews
4. **Event Operations** (~200 lines): insert, get, query, ancestors, children
5. **Blob Operations** (~80 lines): store, get, ref counting
6. **Search Operations** (~100 lines): FTS indexing, search
7. **Branch Operations** (~80 lines): create, get, update branches
8. **Utility** (~50 lines): ID generation, row conversion

### Target Architecture

```
packages/core/src/events/
├── index.ts                        # Public exports
├── event-store.ts                  # EventStore class (existing)
├── types.ts                        # Type definitions (existing)
├── sqlite/
│   ├── index.ts                    # SQLiteBackend facade
│   ├── database.ts                 # Database connection & lifecycle
│   ├── migrations/
│   │   ├── index.ts                # Migration runner
│   │   ├── types.ts                # Migration types
│   │   └── versions/
│   │       ├── v001-initial.ts
│   │       ├── v002-search.ts
│   │       ├── v003-branches.ts
│   │       └── ...
│   ├── repositories/
│   │   ├── index.ts                # Repository exports
│   │   ├── base.ts                 # BaseRepository with common utilities
│   │   ├── workspace.repo.ts       # Workspace operations
│   │   ├── session.repo.ts         # Session operations
│   │   ├── event.repo.ts           # Event operations
│   │   ├── blob.repo.ts            # Blob storage operations
│   │   ├── search.repo.ts          # FTS operations
│   │   └── branch.repo.ts          # Branch operations
│   └── utils/
│       ├── id-generator.ts         # ID generation
│       └── row-converters.ts       # Row to entity conversion
```

### Migration Phases

#### Phase 0: Foundation (2 commits)
- [ ] Create directory structure
- [ ] Create `sqlite/database.ts` with connection management
- [ ] Create `repositories/base.ts` with shared utilities
- [ ] Write tests for database lifecycle

#### Phase 1: Migration System (2 commits)
- [ ] Create `migrations/types.ts` with migration interface
- [ ] Create `migrations/index.ts` with runner
- [ ] Extract existing migrations to version files
- [ ] Write tests for migration runner
- [ ] Verify migrations run correctly

#### Phase 2: Extract Repositories Incrementally (1 commit each)
Order by dependency (least dependent first):
1. [ ] `blob.repo.ts` - No dependencies on other repos
2. [ ] `workspace.repo.ts` - Minimal dependencies
3. [ ] `branch.repo.ts` - Minimal dependencies
4. [ ] `search.repo.ts` - Depends on events
5. [ ] `event.repo.ts` - Core event operations
6. [ ] `session.repo.ts` - Depends on events, workspace

Each extraction:
- Write repository tests (CRUD, edge cases)
- Extract repository class
- Wire into SQLiteBackend facade
- Verify integration tests pass
- Commit

#### Phase 3: Utilities Extraction (1 commit)
- [ ] Extract `id-generator.ts`
- [ ] Extract `row-converters.ts`
- [ ] Update repositories to use utilities
- [ ] Write utility tests

#### Phase 4: Facade Cleanup (1 commit)
- [ ] Simplify SQLiteBackend to delegate to repositories
- [ ] Ensure backwards compatibility
- [ ] Update exports

#### Phase 5: Final Cleanup (1 commit)
- [ ] Remove duplicate code
- [ ] Update documentation
- [ ] Final test pass

### Test Strategy

```
packages/core/test/events/
├── event-store.test.ts             # (existing, keep)
├── sqlite-backend.test.ts          # (existing, keep for integration)
├── sqlite/
│   ├── database.test.ts
│   ├── migrations/
│   │   └── runner.test.ts
│   └── repositories/
│       ├── workspace.repo.test.ts
│       ├── session.repo.test.ts
│       ├── event.repo.test.ts
│       ├── blob.repo.test.ts
│       ├── search.repo.test.ts
│       └── branch.repo.test.ts
```

**Test Coverage Requirements**:
- Database: connection, close, transaction handling
- Migrations: version ordering, idempotency, rollback
- Each repository: CRUD operations, constraints, edge cases
- Integration: full event store operations through facade

---

## Project 5: TronAgent Decomposition

### Current State Analysis

**File**: `packages/core/src/agent/tron-agent.ts` (1100 lines)

**Problems Identified**:
- Mixes multiple concerns: provider management, tool execution, hooks, streaming
- `run()` method is 80+ lines of complex flow control
- `turn()` method is 450+ lines handling many cases
- Tool execution logic interleaved with turn logic
- Hard to test turn logic without full agent setup
- Streaming state management mixed with business logic

**Current Responsibilities**:
1. **Configuration** (~100 lines): constructor, config, provider setup
2. **Lifecycle** (~50 lines): abort, state getters
3. **Context Management** (~80 lines): message handling, context manager delegation
4. **Tool Execution** (~200 lines): tool lookup, execution, result handling
5. **Turn Logic** (~450 lines): LLM call, response processing, tool calls
6. **Run Loop** (~80 lines): multi-turn orchestration
7. **Event Emission** (~50 lines): event creation and dispatch
8. **Streaming State** (~50 lines): partial content tracking

### Target Architecture

```
packages/core/src/agent/
├── index.ts                        # Public exports
├── tron-agent.ts                   # TronAgent class (orchestrator)
├── types.ts                        # Type definitions (existing)
├── config.ts                       # Configuration handling
├── turn/
│   ├── index.ts
│   ├── turn-runner.ts              # Single turn execution
│   ├── response-processor.ts       # LLM response handling
│   └── stream-accumulator.ts       # Stream state management
├── tools/
│   ├── index.ts
│   ├── tool-executor.ts            # Tool execution orchestration
│   ├── tool-registry.ts            # Tool lookup and validation
│   └── result-processor.ts         # Tool result handling
├── hooks/
│   ├── index.ts
│   ├── hook-runner.ts              # Hook execution (wraps HookEngine)
│   └── hook-context.ts             # Hook context building
└── events/
    ├── index.ts
    ├── event-emitter.ts            # Event creation and dispatch
    └── event-types.ts              # Agent-specific event types
```

### Migration Phases

#### Phase 0: Analysis and Interface Design (1 commit)
- [ ] Document current method dependencies
- [ ] Define interfaces for extracted modules
- [ ] Create type definitions
- [ ] Write interface tests

#### Phase 1: Event Emission Extraction (1 commit)
- [ ] Create `events/event-emitter.ts`
- [ ] Extract event creation logic
- [ ] Write tests for event emitter
- [ ] Wire into TronAgent

#### Phase 2: Tool Execution Extraction (2 commits)
- [ ] Create `tools/tool-registry.ts`
- [ ] Create `tools/tool-executor.ts`
- [ ] Create `tools/result-processor.ts`
- [ ] Write comprehensive tool execution tests
- [ ] Wire into TronAgent with dual-path

#### Phase 3: Stream Accumulator (1 commit)
- [ ] Create `turn/stream-accumulator.ts`
- [ ] Extract streaming state management
- [ ] Write tests for stream accumulation
- [ ] Wire into TronAgent

#### Phase 4: Response Processor (1 commit)
- [ ] Create `turn/response-processor.ts`
- [ ] Extract LLM response handling
- [ ] Write tests for response processing
- [ ] Wire into TronAgent

#### Phase 5: Turn Runner (2 commits)
- [ ] Create `turn/turn-runner.ts`
- [ ] Extract single turn logic
- [ ] This is the most complex extraction
- [ ] Write comprehensive turn tests
- [ ] Wire into TronAgent

#### Phase 6: Hook Runner (1 commit)
- [ ] Create `hooks/hook-runner.ts`
- [ ] Extract hook execution logic
- [ ] Write hook runner tests
- [ ] Wire into TronAgent

#### Phase 7: Cleanup (1 commit)
- [ ] Simplify TronAgent to orchestration only
- [ ] Remove legacy code paths
- [ ] Update documentation
- [ ] Final test pass

### Test Strategy

```
packages/core/test/agent/
├── tron-agent.test.ts              # (existing, keep for integration)
├── turn/
│   ├── turn-runner.test.ts
│   ├── response-processor.test.ts
│   └── stream-accumulator.test.ts
├── tools/
│   ├── tool-executor.test.ts
│   ├── tool-registry.test.ts
│   └── result-processor.test.ts
├── hooks/
│   └── hook-runner.test.ts
└── events/
    └── event-emitter.test.ts
```

**Test Coverage Requirements**:
- Turn runner: successful turn, tool calls, abort, errors
- Tool executor: execution, timeout, errors, result formatting
- Stream accumulator: text accumulation, tool tracking, reset
- Response processor: all content types, stop reasons
- Hook runner: pre/post hooks, blocking, errors
- Integration: full multi-turn agent runs

---

## Execution Order

Based on dependencies and risk assessment:

### Week 1-2: Project 2 (Server RPC Adapters)
- Lowest risk, mostly file reorganization
- No logic changes, just extraction
- Good warm-up for larger refactors

### Week 2-3: Project 1 (RPC Handler)
- Medium complexity
- Well-bounded scope
- Enables better testing of RPC layer

### Week 3-4: Project 3 (Provider Base Class)
- Medium complexity
- Improves reliability across all providers
- Adds retry logic to providers missing it

### Week 4-6: Project 4 (SQLite Backend)
- Higher complexity due to data layer
- Requires careful migration testing
- Critical path for persistence

### Week 6-8: Project 5 (TronAgent)
- Highest complexity
- Core business logic
- Should be done last when other layers are stable

---

## Migration Tracking Template

For each project, maintain a tracking file similar to `orchestrator/MIGRATION.md`:

```markdown
# [Component] Migration Tracking

## Overview
[Brief description of migration goal]

**Status: IN_PROGRESS**

## Migration Status

### Completed
- [x] Phase 0: Foundation

### In Progress
- [ ] Phase 1: [Description]
  - [x] Step 1
  - [ ] Step 2

### Pending
- [ ] Phase 2: [Description]

## Architecture After Migration
[Diagram or description]

## Test Coverage
- Unit tests: X/Y passing
- Integration tests: X/Y passing
```

---

## Success Criteria

Each project is complete when:

1. **All tests pass**: Existing + new tests
2. **No legacy code**: Old implementations removed
3. **Documentation updated**: Architecture docs, code comments
4. **Independent testability**: Each module testable in isolation
5. **Backwards compatible**: Public API unchanged
6. **Performance maintained**: No regressions in benchmarks
7. **Code review approved**: PR reviewed and merged

---

## Risk Mitigation

1. **Feature flags**: Use environment variables to toggle new vs old paths
2. **Incremental rollout**: Deploy each phase separately
3. **Monitoring**: Add logging to track which code path is used
4. **Rollback plan**: Each commit is revertible
5. **Integration tests**: Run full test suite after each phase
