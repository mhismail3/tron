# Agent Development

## Setup

```bash
# From monorepo root
bun install
bun run build
```

## Commands

```bash
# Build agent package
bun run --cwd packages/agent build

# Run tests
bun run --cwd packages/agent test

# Watch mode
bun run --cwd packages/agent test:watch

# Type check
bun run --cwd packages/agent typecheck
```

## Development Workflow

```bash
# Full monorepo build + test
bun run build && bun run test

# Start development server (beta)
tron dev
# WebSocket: localhost:8082
# Health: localhost:8083

# Start production server
tron start
# WebSocket: localhost:8080
# Health: localhost:8081
```

## Testing

### Running Tests

```bash
bun run test                    # All tests
bun run test src/tools/         # Specific directory
bun run test:watch              # Watch mode
```

### Test Structure

```
src/
├── tools/__tests__/            # Tool tests
├── events/__tests__/           # Event store tests
├── providers/__tests__/        # Provider tests
├── orchestrator/__tests__/     # Orchestrator tests
├── __integration__/            # Integration tests
│   ├── provider-switching/     # Provider switch scenarios
│   ├── forking/                # Fork operation tests
│   └── edge-cases/             # Combined edge cases
└── __fixtures__/               # Shared test utilities
    ├── mocks/                  # Type-safe mock factories
    └── events/                 # Event fixture factories
```

### Using Test Fixtures

The `__fixtures__/` directory provides type-safe mock factories to eliminate `as any` casts:

```typescript
import { describe, it, expect } from 'vitest';
import {
  // Mock factories
  createMockEventStore,
  createMockStats,
  createMockDirent,
  createFsError,

  // Event fixtures
  createSessionStartEvent,
  createUserMessageEvent,
  createToolUseChain,
} from '../__fixtures__/index.js';

describe('MyFeature', () => {
  it('uses typed mocks', async () => {
    // EventStore mock with event tracking
    const mockStore = createMockEventStore({ trackEvents: true });

    // Access tracked events for assertions
    await someOperation(mockStore);
    const event = mockStore.events.find(e => e.type === 'worktree.acquired');
    expect(event).toBeDefined();
  });

  it('uses fs mocks', () => {
    // Typed fs.Stats mock
    vi.mocked(fs.stat).mockResolvedValue(createMockStats({ size: 1024 }));

    // Typed fs.Dirent mock
    vi.mocked(fs.readdir).mockResolvedValue([
      createMockDirent('file.ts'),
      createMockDirent('src', { isDirectory: true }),
    ]);

    // Typed error mock
    vi.mocked(fs.access).mockRejectedValue(createFsError('ENOENT'));
  });

  it('uses event fixtures', () => {
    // Create a complete tool use conversation chain
    const events = createToolUseChain({
      userContent: 'Read a file',
      toolName: 'ReadFile',
      toolResult: 'File contents',
    });

    expect(events).toHaveLength(5);
  });
});
```

### Testing RPC Handlers

RPC handlers use the registry pattern. Test via `registry.dispatch()`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { registry } from '../registry.js';
import { createMockRpcContext } from '../../__fixtures__/index.js';

describe('session.create handler', () => {
  beforeEach(() => {
    registry.clear();
    // Register handlers
  });

  it('validates required params', async () => {
    const context = createMockRpcContext();
    const response = await registry.dispatch(
      { jsonrpc: '2.0', id: '1', method: 'session.create', params: {} },
      context
    );

    expect(response.error?.code).toBe(-32602); // Invalid params
  });

  it('validates required managers', async () => {
    const context = createMockRpcContext({ sessionManager: undefined });
    const response = await registry.dispatch(
      { jsonrpc: '2.0', id: '1', method: 'session.create', params: { workingDirectory: '/tmp' } },
      context
    );

    expect(response.error?.code).toBe(-32002); // Manager not available
  });
});
```

### Testing Hooks

Test hook registration and execution:

```typescript
import { describe, it, expect } from 'vitest';
import { HookEngine } from '../hooks/engine.js';

describe('HookEngine', () => {
  it('executes hooks in priority order', async () => {
    const engine = new HookEngine();
    const order: string[] = [];

    engine.register({
      name: 'low-priority',
      type: 'PreToolUse',
      priority: 0,
      handler: async () => { order.push('low'); return { proceed: true }; },
    });

    engine.register({
      name: 'high-priority',
      type: 'PreToolUse',
      priority: 100,
      handler: async () => { order.push('high'); return { proceed: true }; },
    });

    await engine.execute('PreToolUse', { /* context */ });
    expect(order).toEqual(['high', 'low']);
  });
});
```

### Writing Tests

```typescript
import { describe, it, expect, beforeEach } from 'vitest';

describe('MyFeature', () => {
  beforeEach(() => {
    // Setup
  });

  it('should do something', () => {
    expect(result).toBe(expected);
  });
});
```

## File Locations

| Location | Purpose |
|----------|---------|
| `~/.tron/db/` | SQLite databases |
| `~/.tron/skills/` | Global skills |
| `~/.tron/settings.json` | User settings |
| `~/.tron/auth.json` | API keys and OAuth tokens |

## Debugging

### Log Levels

```bash
TRON_LOG_LEVEL=debug bun run dev
```

### Database Queries

```bash
# Query events
sqlite3 ~/.tron/db/prod.db "SELECT type, json_extract(payload, '$.name') FROM events WHERE type LIKE 'tool.%' LIMIT 10"

# Query sessions
sqlite3 ~/.tron/db/prod.db "SELECT id, status, model FROM sessions ORDER BY rowid DESC LIMIT 5"
```

### Event Inspection

```bash
# View recent events for a session
sqlite3 ~/.tron/db/prod.db "SELECT sequence, type, substr(payload, 1, 100) FROM events WHERE session_id='sess_xxx' ORDER BY sequence"
```

## Troubleshooting

### Port in Use

```bash
kill $(lsof -t -i :8082)
```

### Native Module Errors (better-sqlite3)

```bash
cd node_modules/.bun/better-sqlite3@*/node_modules/better-sqlite3
rm -rf build
PYTHON=/opt/homebrew/bin/python3 npx node-gyp rebuild --release
```

### Memory Issues

Vitest may occasionally fail with heap memory errors. This is a known Vitest issue, not a test failure.

## Code Organization

### Adding a New Tool

See `adding-tools.md` for the complete checklist.

### Adding Event Types

1. Define in `src/events/types/union.ts`
2. Add payload interface in `src/events/types/`
3. Handle in `src/events/message-reconstructor.ts` if affects messages
4. Emit via `eventStore.appendEvent()`

### Adding an RPC Handler

1. Create handler in `src/interface/rpc/handlers/<domain>/`:
   ```typescript
   export const myHandler: MethodHandler = async (request, context) => {
     // Handler returns result directly - no wrapping needed
     return context.manager.doSomething(request.params);
   };
   ```

2. Register in domain index file:
   ```typescript
   registry.register('domain.method', myHandler, {
     requiredParams: ['param1', 'param2'],
     requiredManagers: ['myManager'],
   });
   ```

3. Write tests using `registry.dispatch()` (not direct handler calls)

### Adding a Hook Type

1. Add type to `HookType` union in `hooks/types.ts`
2. Add context interface in same file
3. Add factory method in `hooks/context-factory.ts`
4. If blocking, add to `FORCED_BLOCKING_TYPES` in registry
5. Call `engine.execute()` at appropriate point in code

### Adding a Provider

For complex providers, use the modular directory structure:

1. Create `src/providers/<name>/` directory:
   ```
   providers/<name>/
   ├── index.ts           # Public exports
   ├── <name>-provider.ts # Core provider class
   ├── message-converter.ts # Message format conversion
   └── types.ts           # Provider-specific types
   ```
2. Implement the `Provider` interface in `<name>-provider.ts`
3. Export via `index.ts` with factory function
4. Add to `src/providers/factory.ts` switch
5. Add model IDs to `src/providers/models.ts`
6. Add token normalization in `src/providers/token-normalizer.ts`

For simpler providers, a single file may suffice (see `openai.ts`).

## Architectural Patterns

### Registry Pattern

Use for centralized dispatch with validation:

```typescript
// Registration
registry.register('method.name', handler, {
  requiredParams: ['param1'],
  requiredManagers: ['manager1'],
});

// Dispatch (handles validation automatically)
const response = await registry.dispatch(request, context);
```

### Factory Pattern

Use for consistent object construction:

```typescript
// Session-scoped factory
const factory = createEventFactory({ sessionId, workspaceId });

// Consistent event creation
const event = factory.createSessionStart({ parentId, sequence, payload });
```

### Component Extraction

When a class exceeds ~300 lines, extract focused components:

```typescript
// Before: monolithic class
class BigEngine {
  private registrations = new Map();
  private pending = new Map();
  // 500+ lines of mixed concerns
}

// After: focused components
class Engine {
  private registry = new Registry();  // Registration/lookup
  private tracker = new Tracker();    // Background tracking
  // Orchestration only
}
```
