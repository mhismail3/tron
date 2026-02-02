# Architectural Patterns

This document describes the key patterns used throughout the agent codebase. Follow these patterns when adding new features.

## Registry Pattern

Use when you need centralized dispatch with automatic validation.

### When to Use

- Multiple handlers for different method/event types
- Repeated validation logic across handlers
- Need for middleware/cross-cutting concerns
- Namespace-based organization

### Implementation

```typescript
// registry.ts
interface MethodOptions {
  requiredParams?: string[];
  requiredManagers?: string[];
  description?: string;
}

class MethodRegistry {
  private registrations = new Map<string, Registration>();
  private middlewares: Middleware[] = [];

  register(method: string, handler: Handler, options?: MethodOptions) {
    this.registrations.set(method, { handler, options });
  }

  use(middleware: Middleware) {
    this.middlewares.push(middleware);
  }

  async dispatch(request: Request, context: Context): Promise<Response> {
    // 1. Find registration
    const registration = this.registrations.get(request.method);
    if (!registration) return errorResponse('Method not found');

    // 2. Validate params
    for (const param of registration.options?.requiredParams ?? []) {
      if (!(param in request.params)) {
        return errorResponse(`Missing param: ${param}`);
      }
    }

    // 3. Validate managers
    for (const manager of registration.options?.requiredManagers ?? []) {
      if (!context[manager]) {
        return errorResponse(`Manager unavailable: ${manager}`);
      }
    }

    // 4. Run middleware chain
    const chain = this.buildMiddlewareChain(registration.handler);
    return chain(request, context);
  }
}
```

### Example: RPC Handlers

```typescript
// Handler returns result directly - no wrapping
const createSessionHandler: MethodHandler = async (request, context) => {
  return context.sessionManager.create(request.params);
};

// Register with validation rules
registry.register('session.create', createSessionHandler, {
  requiredParams: ['workingDirectory'],
  requiredManagers: ['sessionManager'],
});

// Dispatch handles all validation and error mapping
const response = await registry.dispatch(request, context);
```

**Files:** `interface/rpc/registry.ts`, `interface/rpc/handlers/`

## Factory Pattern

Use when you need consistent object construction with automatic field generation.

### When to Use

- Objects need auto-generated IDs
- Timestamps should be automatic
- Scoped context (session, workspace) shared across creations
- Reduce boilerplate in object construction

### Implementation

```typescript
// event-factory.ts
interface EventFactoryOptions {
  sessionId: string;
  workspaceId: string;
  idGenerator?: () => string;
}

function createEventFactory(options: EventFactoryOptions): EventFactory {
  const generateId = options.idGenerator ?? (() => `evt_${randomId()}`);

  return {
    createSessionStart(params) {
      return {
        id: generateId(),
        sessionId: options.sessionId,
        workspaceId: options.workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        ...params,
      };
    },

    createEvent(params) {
      return {
        id: generateId(),
        sessionId: options.sessionId,
        workspaceId: options.workspaceId,
        timestamp: new Date().toISOString(),
        ...params,
      };
    },
  };
}
```

### Example: Hook Context Factory

```typescript
const factory = createHookContextFactory({ sessionId: 'sess_abc' });

// All contexts get sessionId and timestamp automatically
const preToolContext = factory.createPreToolContext({
  toolName: 'bash',
  toolInput: { command: 'ls' },
});
// Result: { hookType: 'PreToolUse', sessionId: 'sess_abc', timestamp: '...', toolName: 'bash', ... }
```

**Files:** `infrastructure/events/event-factory.ts`, `capabilities/extensions/hooks/context-factory.ts`

## Component Extraction

Use when a class grows beyond 300 lines or has multiple responsibilities.

### When to Use

- Class has multiple distinct responsibilities
- Testing requires mocking internal state
- Logic is reusable in other contexts
- Code organization could be improved by separation

### Implementation

```typescript
// Before: Monolithic class
class HookEngine {
  private registrations = new Map();
  private pending = new Map();

  register() { /* 50 lines */ }
  unregister() { /* 20 lines */ }
  getByType() { /* 30 lines */ }
  execute() { /* 100 lines */ }
  trackPending() { /* 40 lines */ }
  waitForPending() { /* 30 lines */ }
  // 500+ lines total
}

// After: Focused components
class HookRegistry {
  register() { /* ... */ }
  unregister() { /* ... */ }
  getByType() { /* ... */ }
}

class BackgroundTracker {
  track() { /* ... */ }
  waitForAll() { /* ... */ }
}

class HookEngine {
  private registry = new HookRegistry();
  private tracker = new BackgroundTracker();

  execute() {
    const hooks = this.registry.getByType(type);
    // Orchestration logic only
  }
}
```

### Key Principles

1. **Single Responsibility** - Each component does one thing well
2. **Delegation** - Parent orchestrates, components do the work
3. **Testability** - Components can be tested in isolation
4. **Backward Compatibility** - Public API unchanged

**Files:** `capabilities/extensions/hooks/engine.ts`, `registry.ts`, `background-tracker.ts`

## Type-Safe Enums

Use when string constants are repeated and typos cause bugs.

### When to Use

- Event types, status codes, error codes
- String values used in switch statements
- Cross-module communication
- Compile-time validation needed

### Implementation

```typescript
// event-envelope.ts
export const BroadcastEventType = {
  SESSION_CREATED: 'session.created',
  SESSION_ENDED: 'session.ended',
  AGENT_TURN: 'agent.turn',
  // ...
} as const;

export type BroadcastEventTypeValue =
  (typeof BroadcastEventType)[keyof typeof BroadcastEventType];

// Usage - compile-time checked
function broadcast(type: BroadcastEventTypeValue, data: unknown) {
  // ...
}

// This compiles
broadcast(BroadcastEventType.SESSION_CREATED, { sessionId });

// This fails at compile time
broadcast('sesssion.created', { sessionId }); // typo caught!
```

**Files:** `infrastructure/events/event-envelope.ts`, `interface/rpc/rpc-errors.ts`

## Typed Error Hierarchy

Use when errors need to carry semantic information for handling.

### When to Use

- Different error types need different handling
- Error codes mapped to responses
- Categorization for logging/monitoring
- Retryability determination

### Implementation

```typescript
// rpc-errors.ts
abstract class RpcError extends Error {
  abstract readonly code: number;
  abstract readonly category: 'client_error' | 'server_error' | 'transient_error';
  abstract readonly retryable: boolean;
}

class SessionNotFoundError extends RpcError {
  readonly code = -32000;
  readonly category = 'client_error' as const;
  readonly retryable = false;

  constructor(public readonly sessionId: string) {
    super(`Session not found: ${sessionId}`);
  }
}

// Usage in handlers
throw new SessionNotFoundError(sessionId);

// Registry detects type and maps correctly
if (error instanceof RpcError) {
  return {
    error: {
      code: error.code,
      message: error.message,
      data: { category: error.category, retryable: error.retryable },
    },
  };
}
```

**Files:** `interface/rpc/rpc-errors.ts`

## Fail-Open Error Handling

Use for non-critical paths where failures shouldn't crash the system.

### When to Use

- Extension/plugin systems
- Observability (logging, metrics)
- Background tasks
- Optional features

### Implementation

```typescript
// hooks/engine.ts
async executeBackgroundHook(hook: Hook, context: Context) {
  try {
    await hook.handler(context);
  } catch (error) {
    // Log with context for debugging
    logger.error('Background hook failed', {
      hookName: hook.name,
      sessionId: context.sessionId,
      error: error.message,
    });
    // Don't re-throw - operation continues
  }
}
```

### Key Principles

1. **Log with context** - Include enough info to debug later
2. **Continue operation** - Don't let extensions break core functionality
3. **Track failures** - Metrics/alerts for monitoring
4. **Blocking hooks may fail** - Sometimes blocking hooks should fail if they throw

**Files:** `capabilities/extensions/hooks/engine.ts`

## Unified Sync/Async API

Use when both sync and async versions of an operation are needed.

### When to Use

- Startup code (needs sync)
- Runtime code (can use async)
- Shared validation/transformation logic
- File I/O with both patterns

### Implementation

```typescript
// auth/unified.ts

// Shared logic parameterized by sync flag
function validateAuthStorage(
  data: unknown,
  path: string,
  sync: boolean
): AuthStorage | null {
  // Same validation logic for both paths
}

// Public async API
export async function loadAuthStorage(): Promise<AuthStorage | null> {
  const data = await fs.readFile(path, 'utf-8');
  return validateAuthStorage(JSON.parse(data), path, false);
}

// Public sync API
export function loadAuthStorageSync(): AuthStorage | null {
  const data = fs.readFileSync(path, 'utf-8');
  return validateAuthStorage(JSON.parse(data), path, true);
}
```

### Key Principles

1. **Extract shared logic** - Don't duplicate validation/transformation
2. **Parameterize differences** - Pass `sync` boolean where behavior differs
3. **Consistent error handling** - Same errors from both paths
4. **Test both paths** - Sync and async may have subtle differences

**Files:** `infrastructure/auth/unified.ts`

## Pattern Selection Guide

| Situation | Pattern |
|-----------|---------|
| Multiple handlers with shared validation | Registry |
| Consistent object construction | Factory |
| Class over 300 lines | Component Extraction |
| String constants with typo risk | Type-Safe Enums |
| Errors need semantic handling | Typed Error Hierarchy |
| Non-critical operations | Fail-Open |
| Need sync + async versions | Unified Sync/Async |
