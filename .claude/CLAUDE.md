# Tron Project Guidelines

**Documentation:** See `docs/` for architecture, development workflow, and customization.

## ⚠️ CRITICAL RULES - ALWAYS FOLLOW

### Root Cause Analysis
**NEVER apply bandaid fixes.** When you find a bug, ALWAYS:
1. Analyze the code and trace call paths to identify the TRUE root cause
2. Understand WHY the bug exists, not just WHERE it manifests
3. Fix the underlying issue robustly, even if it requires more effort

### Debugging with Database Logs
**Source of truth for all agent sessions is `$HOME/.tron/db/`**. The databases contain:
- `events` table: All session events (messages, tool calls, results)
- `logs` table: All application logs with timestamps and context

**ALWAYS use the `@tron-db` skill** (`.claude/skills/tron-db/`) when the user asks to investigate an issue. Query the database directly—don't guess.

### Build & Test Verification
**ALWAYS run before completing any task:**
```bash
bun run build && bun run test
```
Do not mark work as complete until both succeed. If tests fail, fix them.

### Test-Driven Development
**Prioritize zero regressions.** When making changes:
1. Write or update tests FIRST when adding features
2. Run existing tests BEFORE and AFTER changes
3. If refactoring, ensure test coverage exists before touching code
4. Never commit code that introduces test failures

---

## Adding New Tools - CRITICAL CHECKLIST

When adding a new tool, you MUST handle all of the following to prevent breaking session resume, forks, and API compatibility.

### The Tool Lifecycle

1. **Tool Definition** (`packages/core/src/tools/`)
2. **Tool Call Event** (`tool.call`) - recorded when agent invokes tool
3. **Tool Result Event** (`tool.result`) - recorded when execution completes
4. **Message Content** (`message.assistant`) - contains `tool_use` blocks
5. **Content Normalization** (`packages/server/src/utils/content-normalizer.ts`)
6. **State Reconstruction** (`packages/core/src/events/event-store.ts`)

### Files to Update

| File | Check |
|------|-------|
| `packages/core/src/events/event-store.ts` | `getMessagesAt()` reconstructs tool_use/tool_result |
| `packages/server/src/utils/content-normalizer.ts` | `normalizeContentBlock()` handles tool input format |
| `packages/server/src/orchestrator/agent-event-handler.ts` | Events properly recorded |
| `packages/core/src/types/events.ts` | Event payload types if new fields needed |

### Known Pitfalls

1. **Large Tool Inputs (>5KB)**: Truncated with `{_truncated: true}`. MUST restore from `tool.call` events during reconstruction.

2. **Tool Result Content**: Can be string or array. Both formats must be handled.

3. **Event Recording Order**: `tool.result` recorded BEFORE `message.assistant`. Reconstruction relies on this.

4. **Message Alternation**: Anthropic API requires user/assistant alternation. Tool results become synthetic user messages.

5. **Fork/Resume**: All tool data must reconstruct correctly when resuming or forking.

### Reconstruction Flow

```
Events:
  message.assistant with tool_use (seq 2)  <-- may be truncated
  tool.call (seq 3)                        <-- has FULL arguments
  tool.result (seq 4)

Reconstruction:
  1. Collect tool.call arguments into map
  2. Build messages, restore truncated inputs from map
  3. Inject tool_result as synthetic user message
```

---

## Key Sub-Agent Files

| File | Purpose |
|------|---------|
| `packages/core/src/subagents/subagent-tracker.ts` | Tracks sub-agents, manages pending results |
| `packages/core/src/tools/spawn-subsession.ts` | In-process spawning |
| `packages/core/src/tools/spawn-tmux-agent.ts` | Out-of-process spawning |
| `packages/core/src/tools/query-subagent.ts` | Query sub-agent state |
| `packages/server/src/event-store-orchestrator.ts` | Orchestrates lifecycle |
