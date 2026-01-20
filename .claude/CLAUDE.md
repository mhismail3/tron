# Tron Project Guidelines

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

## Project Structure

```
packages/
├── core/       # Event system, SQLite storage, types, sub-agent tools
├── server/     # EventStoreOrchestrator, tools, agent orchestration
├── tui/        # Terminal UI and CLI
├── chat-web/   # Web chat interface
└── ios-app/    # iOS application
```

## Commands

```bash
tron dev        # Build, test, start beta server (ports 8082/8083)
tron deploy     # Build, test, deploy to production
tron status     # Show service status
tron logs       # Query database logs
bun run test    # Run tests (uses Vitest)
bun run build   # Build all packages
```

## Testing

```bash
bun run test        # Run all tests
bun run test:watch  # Watch mode
```

**Known Issue**: Vitest may fail 1 test file with "Worker terminated due to reaching memory limit: JS heap out of memory". This is a pre-existing Vitest issue, not related to code changes.

## Database Migrations

Schema migrations are in `packages/core/src/events/sqlite/migrations/versions/`. When adding new columns:
1. Add to the base schema in `v001-initial.ts` for fresh databases
2. Create incremental migration for existing databases if needed

---

## Adding New Tools - CRITICAL CHECKLIST

When adding a new tool to Tron, you MUST ensure all the following are handled correctly to prevent breaking session resume, forks, and API compatibility.

### The Tool Lifecycle

1. **Tool Definition** (`packages/core/src/tools/`) - The tool implementation
2. **Tool Call Event** (`tool.call`) - Recorded when agent invokes a tool
3. **Tool Result Event** (`tool.result`) - Recorded when tool execution completes
4. **Message Content** (`message.assistant`) - Contains `tool_use` blocks with the tool invocation
5. **Content Normalization** (`packages/server/src/utils/content-normalizer.ts`) - Sanitizes/truncates content for storage
6. **State Reconstruction** (`packages/core/src/events/event-store.ts`) - Rebuilds messages from events

### Files That MUST Be Updated/Verified

| File | What to Check |
|------|---------------|
| `packages/core/src/events/event-store.ts` | `getMessagesAt()` and `getStateAt()` properly reconstruct tool_use/tool_result |
| `packages/server/src/utils/content-normalizer.ts` | `normalizeContentBlock()` handles the tool's input format without data loss |
| `packages/server/src/orchestrator/agent-event-handler.ts` | Tool calls and results are properly recorded as events |
| `packages/core/src/agent/tool-executor.ts` | Tool execution and result handling |
| `packages/core/src/types/events.ts` | Event payload types if new fields are needed |

### Known Pitfalls

1. **Large Tool Inputs (>5KB)**: `content-normalizer.ts` truncates large `tool_use` inputs with `{_truncated: true, _originalSize, _preview}`. These MUST be restored from `tool.call` events during reconstruction or the API will reject them.

2. **Tool Result Content**: Can be string or array of content parts. Both formats must be handled in normalization and reconstruction.

3. **Event Recording Order**: `tool.result` events are recorded BEFORE `message.assistant` events. State reconstruction relies on this order.

4. **Message Alternation**: Anthropic API requires strict user/assistant alternation. Tool results become synthetic user messages. Ensure reconstruction maintains this pattern.

5. **Fork/Resume Scenarios**: All tool data must reconstruct correctly when:
   - Resuming a session (`getStateAt()` / `getStateAtHead()`)
   - Forking from a mid-conversation point
   - Replaying events after compaction

### Testing New Tools

1. Create a session using the new tool with various input sizes (small, >5KB)
2. End the session and resume it - verify no API errors
3. Fork from a point after tool use - verify fork works
4. Check that tool results display correctly in all UIs (TUI, iOS, web)

### The Reconstruction Flow

```
Events in DB:
  message.user (seq 1)
  message.assistant with tool_use blocks (seq 2)  <-- may have truncated inputs
  tool.call (seq 3)                               <-- has FULL arguments
  tool.result (seq 4)                             <-- has result content
  message.assistant continuation (seq 5)

Reconstruction (getStateAt/getMessagesAt):
  1. First pass: collect tool.call arguments into toolCallArgsMap
  2. Second pass: build messages, restoring truncated tool_use inputs from map
  3. Inject tool_result as synthetic user message after assistant with tool_use
```

---

## Key Sub-Agent Files

- `packages/core/src/subagents/subagent-tracker.ts` - Tracks sub-agents and manages pending results
- `packages/core/src/tools/spawn-subsession.ts` - In-process spawning
- `packages/core/src/tools/spawn-tmux-agent.ts` - Out-of-process spawning
- `packages/core/src/tools/query-subagent.ts` - Querying sub-agent state
- `packages/core/src/tools/wait-for-subagent.ts` - Blocking wait for completion
- `packages/server/src/event-store-orchestrator.ts` - Orchestrates sub-agent lifecycle

---

## Native Module Issues (better-sqlite3)

This project uses `better-sqlite3` which requires native compilation. There's a known issue where bun's node-gyp may pick up the wrong Node.js version.

### Symptoms
- Tests fail with: `NODE_MODULE_VERSION X. This version of Node.js requires NODE_MODULE_VERSION Y`
- The mismatch happens when Homebrew's Node.js is used for compilation but nvm's Node.js runs the tests

### Fix
The `tron dev` and `tron deploy` commands automatically detect and rebuild native modules when needed. For manual rebuild:

```bash
cd node_modules/.bun/better-sqlite3@11.10.0/node_modules/better-sqlite3
rm -rf build
PYTHON=/opt/homebrew/bin/python3 npx node-gyp rebuild --release
```
