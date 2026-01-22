# Phase 0: Pre-Refactoring Analysis Findings

## Baseline Metrics (before refactoring)

| Metric | Value |
|--------|-------|
| Test count | 3031 passing, 15 skipped |
| Source files | 252 files |
| Total lines of code | 66,804 lines |
| Total directories | 143 |
| Top-level src/ directories | 33 |
| Overall code coverage | 55.96% statements, 70.73% functions |
| Circular dependencies | **64 found** |

## Coverage Analysis

### HIGH RISK Modules (<60% coverage)
- **transcription/**: 8.17% - VERY LOW, HIGH RISK for refactoring
- **utils/content-normalizer.ts**: 48.88% - Core module, needs caution
- **utils/retry.ts**: 8.52% - Very low coverage

### MEDIUM RISK Modules (60-80% coverage)
- **usage/**: 64.9%
- **utils/file-completion.ts**: 61.95%

### SAFE Modules (>80% coverage)
- **ui/**: 92.51%
- **utils/clipboard.ts**: 88.73%
- **utils/errors.ts**: 84.33%

**Recommendation**: Avoid refactoring transcription module without adding tests first. Content-normalizer changes must be done carefully with verification after each change.

## Single-File Directories (Phase 1 targets)

All 5 directories identified in plan exist:
1. **artifacts/** - canvas-store.ts + index.ts
2. **features/** - index.ts only
3. **memory/** - types.ts + index.ts
4. **tmux/** - manager.ts + index.ts
5. **subagents/** - subagent-tracker.ts + index.ts

## RPC Layer Analysis (Phase 4 preparation)

### Current Structure
- **Handlers**: 25 files in `rpc/handlers/`
- **Adapters**: 14 files in `gateway/rpc/adapters/`

### History
- Both layers introduced in commit `abb3f0c` (Merge @tron/core and @tron/server packages)
- Significant overlap - adapters appear to wrap orchestrator methods
- Handlers appear to call adapters

### Circular Dependencies in RPC
- All handlers create circular dependencies with `rpc/handler.ts`
- Gateway adapters create circular dependencies through `gateway/rpc/context-factory.ts`

**Decision Path Recommendation**: Investigate whether adapters are pure delegation or add business logic. If pure delegation, follow Path A (remove adapter layer).

## Event Store Analysis (Phase 5 preparation)

- **event-store.ts line count**: 1,065 lines (not 41K - plan was estimating entire events/ folder)
- Still significant and could benefit from modularization
- Good test coverage exists based on integration tests

## Critical Circular Dependencies

**Total**: 64 circular dependencies found

### Most Problematic Patterns

1. **types/messages.ts ↔ types/tools.ts** - Core type circular dependency
2. **index.ts → gateway → orchestrator** - Creates 30+ transitive cycles
3. **rpc/handler.ts → all handlers → rpc/registry.ts** - 26 RPC-related cycles
4. **utils/content-normalizer.ts ← orchestrator** - Mentioned in plan

### Circular Dependency Categories
- Types layer: 1 direct cycle
- Gateway/orchestrator: 30+ cycles
- RPC layer: 26 cycles
- Services: 4 cycles
- Others: 3 cycles

**Action Required**: Phase 2 must address more than just content-normalizer. Consider addressing the root index.ts → gateway → orchestrator cycle first as it cascades to many modules.

## iOS App Smoke Test Baseline

**Manual Testing Required**: Not performed yet. Should verify before proceeding with actual refactoring:
1. Server starts: `bun run dev`
2. iOS app connects
3. Can send message and receive response
4. Tool execution works

## Recommendations

### Phase Order Adjustments

Consider modifying phase order:
1. **Phase 1** - Proceed as planned (low risk)
2. **Phase 2** - Expand scope to address top circular dependencies:
   - Fix types/messages.ts ↔ types/tools.ts
   - Fix index.ts → gateway → orchestrator pattern
   - Fix utils/content-normalizer.ts
3. **Phase 3** - Proceed as planned
4. **Phase 4** - RPC consolidation will help eliminate 26 circular dependencies
5. **Phase 5-7** - Proceed as planned

### Safety Measures

1. **Each commit must pass**:
   - `bun run build`
   - `bun run test` (vitest, not bun test)
   - Verify 3031 tests still passing

2. **High-risk modules**:
   - Skip transcription/ module refactoring (8% coverage)
   - Be very careful with utils/ changes
   - Add tests before moving low-coverage modules

3. **Circular dependency tracking**:
   - Run `npx madge --circular packages/agent/src/index.ts` after each phase
   - Goal: Reduce from 64 to <10 by end of refactoring

## Phase 0 Status: COMPLETE ✅

All baseline metrics captured. Ready to proceed to Phase 1.
