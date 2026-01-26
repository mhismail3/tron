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

**ALWAYS use the `@tron-db` skill** (`.claude/skills/tron-db/`) when the user asks to investigate an issue. Query the database directly — do not guess.

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

### Documentation Maintenance
**Keep docs in sync with code.** After making significant changes, update the relevant docs in `docs/`:

| Doc File | Update When |
|----------|-------------|
| `docs/architecture.md` | Package structure, event types, database schema, tool organization changes |
| `docs/development.md` | Test commands, build process, deployment, troubleshooting changes |
| `docs/customization.md` | Settings, skills, system prompt, file location changes |
| `docs/user-guide.md` | CLI options, slash commands, keyboard shortcuts, feature changes |

Each doc has an `AGENT MAINTENANCE` comment at the top listing what to verify. Update the `Last verified` date when you review or modify a doc.

---

## Adding New Tools

When adding a new tool, you MUST handle all of the following to prevent breaking session resume, forks, and API compatibility.

### The Tool Lifecycle

1. **Tool Definition** (`packages/agent/src/tools/`)
2. **Tool Call Event** (`tool.call`) - recorded when agent invokes tool
3. **Tool Result Event** (`tool.result`) - recorded when execution completes
4. **Message Content** (`message.assistant`) - contains `tool_use` blocks
5. **Content Normalization** (`packages/agent/src/utils/content-normalizer.ts`)
6. **State Reconstruction** (`packages/agent/src/events/event-store.ts`)

### Files to Update

| File | Check |
|------|-------|
| `packages/agent/src/events/event-store.ts` | `getMessagesAt()` reconstructs tool_use/tool_result |
| `packages/agent/src/utils/content-normalizer.ts` | `normalizeContentBlock()` handles tool input format |
| `packages/agent/src/orchestrator/agent-event-handler.ts` | Events properly recorded |
| `packages/agent/src/types/events.ts` | Event payload types if new fields needed |

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
| `packages/agent/src/tools/subagent/subagent-tracker.ts` | Tracks sub-agents, manages pending results |
| `packages/agent/src/tools/subagent/spawn-subagent.ts` | In-process spawning |
| `packages/agent/src/tools/subagent/spawn-tmux-agent.ts` | Out-of-process spawning |
| `packages/agent/src/tools/subagent/query-subagent.ts` | Query sub-agent state |
| `packages/agent/src/tools/subagent/wait-for-subagent.ts` | Wait for sub-agent completion |
| `packages/agent/src/orchestrator/event-store-orchestrator.ts` | Orchestrates session lifecycle |

---

## iOS App Event Plugin System

The iOS app uses an Event Plugin System for handling WebSocket events. Each event type is self-contained in a single plugin file.

### Adding a New Event

1. **Create plugin file** in `packages/ios-app/Sources/Core/Events/Plugins/<Category>/`:
```swift
enum MyNewEventPlugin: EventPlugin {
    static let eventType = "agent.my_new_event"

    struct EventData: Decodable {
        let type: String
        let sessionId: String?
        // ... fields matching server JSON
    }

    struct Result: EventResult {
        // ... UI-ready fields
    }

    static func sessionId(from event: EventData) -> String? { event.sessionId }
    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(/* map fields */)
    }
}
```

2. **Register** in `EventRegistry.swift`:
```swift
register(MyNewEventPlugin.self)
```

3. **Handle** in `ChatViewModel.swift` `handlePluginEvent()`:
```swift
case MyNewEventPlugin.eventType:
    if let r = transform() as? MyNewEventPlugin.Result {
        handleMyNewEventResult(r)
    }
```

4. **Add handler** in `ChatViewModel+Events.swift` if needed.

### Key Files

| File | Purpose |
|------|---------|
| `Sources/Core/Events/Plugins/EventPlugin.swift` | Protocol definition |
| `Sources/Core/Events/Plugins/EventRegistry.swift` | Central registration |
| `Sources/Core/Events/Plugins/ParsedEventV2.swift` | Event wrapper enum |
| `Sources/ViewModels/Chat/ChatViewModel.swift` | Event dispatch (`handlePluginEvent`) |
| `Sources/ViewModels/Chat/ChatViewModel+Events.swift` | Handler implementations |

### Guidelines

- **DO NOT** modify `Events.swift` for new WebSocket events — use the plugin system
- **DO NOT** create parallel event handling paths — all events flow through `eventPublisherV2`
- **Plugin categories**: Streaming, Tool, Lifecycle, Session, Subagent, PlanMode, UICanvas, Browser, Todo
- **Custom Decodable**: Override `parse(from:)` only when JSON structure requires special handling (e.g., `ToolEndPlugin` handles output as String OR ContentBlock array)
- **Result structs**: Keep flat and UI-ready; complex transformations belong in the handler, not the plugin
- **Deleting plugins**: Remove from registry, remove handler case, delete file — grep for the event type string to ensure no stale references
