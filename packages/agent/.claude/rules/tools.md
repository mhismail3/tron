---
paths:
  - "**/tools/**"
  - "**/*-tool*"
  - "**/tool-executor*"
---

# Tools

Agent tools for filesystem, browser, subagent, UI, and system operations.

## Tool Categories

| Category | Location | Examples |
|----------|----------|----------|
| Filesystem | `tools/fs/` | read, write, edit, glob, grep |
| Browser | `tools/browser/` | browser automation |
| Subagent | `tools/subagent/` | spawn, query, wait |
| UI | `tools/ui/` | ask-user, notify, todo |
| System | `tools/system/` | bash, thinking |

## Adding a New Tool

### 1. Create Tool File

```typescript
// src/tools/<category>/<tool-name>.ts
import type { Tool, ToolContext } from '../types.js';

export const myTool: Tool = {
  name: 'my_tool',
  description: 'What this tool does',
  parameters: {
    type: 'object',
    properties: {
      param1: { type: 'string', description: '...' },
    },
    required: ['param1'],
  },
  execute: async (args, context: ToolContext) => {
    return { success: true, data: result };
  },
};
```

### 2. Export and Register

```typescript
// src/tools/<category>/index.ts
export { myTool } from './my-tool.js';

// src/tools/index.ts
import { myTool } from './<category>/index.js';
export const allTools = [...existingTools, myTool];
```

### 3. Handle Large Inputs (if >5KB)

```typescript
// src/utils/content-normalizer.ts
// Ensure normalizeContentBlock handles your tool's input format
```

### 4. Write Tests

```typescript
// src/tools/<category>/__tests__/<tool-name>.test.ts
describe('myTool', () => {
  it('should execute correctly', async () => {
    const result = await myTool.execute({ param1: 'value' }, mockContext);
    expect(result.success).toBe(true);
  });
});
```

### 5. Test Session Resume

```bash
# Create session, use tool, exit, resume - verify history reconstructs
tron -c
```

## Files to Update

| File | Purpose |
|------|---------|
| `src/tools/<category>/<name>.ts` | Tool implementation |
| `src/tools/<category>/index.ts` | Category export |
| `src/tools/index.ts` | Main registration |
| `src/utils/content-normalizer.ts` | Large input handling |
| `src/events/message-reconstructor.ts` | If affects messages |

## Known Pitfalls

1. **Large inputs (>5KB)**: Truncated with `{_truncated: true}`. Restored from `tool.call` events.
2. **Result format**: Can be string or array - handle both.
3. **Recording order**: `tool.result` recorded BEFORE `message.assistant`.
4. **API alternation**: Tool results become synthetic user messages.
5. **Fork/Resume**: Must reconstruct correctly.

## Reconstruction Flow

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

## Hook Integration

```typescript
// PreToolUse - can block or modify
hooks.runPreToolUse({ name, arguments, sessionId })

// PostToolUse - can observe or log
hooks.runPostToolUse({ name, result, duration })
```

## Rules

- Return structured results (avoid plain text)
- Handle AbortSignal for long-running operations
- Don't leak sensitive paths in errors

---

## Update Triggers

Update this rule when:
- Adding new tool categories
- Changing hook integration pattern
- Modifying tool registration flow

Verification:
```bash
ls packages/agent/src/tools/*/index.ts
```
