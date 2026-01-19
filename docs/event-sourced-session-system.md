# Event-Sourced Session Tree System

## Overview

The Event-Sourced Session Tree System is a comprehensive, agent-first session management architecture that captures every action as an immutable event forming a tree structure. This enables:

- **Complete Auditability**: Every prompt, response, tool call, and state change is recorded
- **Reproducibility**: Any historical state can be reconstructed from events
- **Fork/Rewind**: Branch from any point in history, rewind to previous states
- **Unified Access**: All clients (TUI, Web, iOS) share the same event model
- **Offline Support**: Clients cache events locally for offline operation

## Architecture Overview

```
                     ┌─────────────────────────────────────┐
                     │    Global Event Store               │
                     │    (~/.tron/db/prod.db)              │
                     │                                     │
                     │  ┌─────────────────────────────┐    │
                     │  │         SQLite               │   │
                     │  │  ┌───────┐ ┌──────────┐     │   │
                     │  │  │events │ │ sessions │     │   │
                     │  │  └───────┘ └──────────┘     │   │
                     │  │  ┌───────┐ ┌──────────┐     │   │
                     │  │  │blobs  │ │workspaces│     │   │
                     │  │  └───────┘ └──────────┘     │   │
                     │  │  ┌───────┐ ┌──────────┐     │   │
                     │  │  │branches│ │events_fts│    │   │
                     │  │  └───────┘ └──────────┘     │   │
                     │  └─────────────────────────────┘    │
                     └─────────────────────────────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
    ┌─────▼─────┐              ┌──────▼──────┐             ┌─────▼─────┐
    │    TUI    │              │   Server    │             │    iOS    │
    │ (Direct)  │              │ (WebSocket) │             │  (Local)  │
    │           │              │             │             │           │
    │ EventStore│              │ EventStore  │             │EventDB.swift│
    │  (sync)   │              │ Orchestrator│             │  (SQLite)  │
    └───────────┘              └──────┬──────┘             └─────┬─────┘
                                      │                          │
                               ┌──────▼──────┐                   │
                               │   Web UI    │                   │
                               │  (Browser)  │                   │
                               │             │                   │
                               │ IndexedDB   │◄──── RPC Sync ────┤
                               │ (event-db)  │                   │
                               └─────────────┘                   │
                                      │                          │
                                      └──────── RPC Sync ────────┘
```

## Core Concepts

### 1. Events are Immutable

Events are **never modified** after creation. Every action appends a new event to the log:

```typescript
interface BaseEvent {
  id: EventId;           // UUID v7 (time-sortable)
  parentId: EventId | null;  // Points to previous event (null for root)
  sessionId: SessionId;  // Session this belongs to
  workspaceId: WorkspaceId;
  timestamp: string;     // ISO 8601
  type: EventType;       // Discriminator (35+ types)
  sequence: number;      // Monotonic within session
  payload: Record<string, unknown>;
}
```

### 2. Tree Structure via Parent Chains

Events form a **tree** through `parentId` references:

```
[session.start] ← root (parentId=null)
      │
[message.user] ← parentId points to previous
      │
[message.assistant]
      │
[message.user]
      │
[message.assistant] ← FORK POINT (multiple children)
      │         \
      │          \
[next_msg]    [session.fork] ← New branch starts here
      │              │
     ...        [message.user]
                     │
                    ...
```

### 3. Sessions are Pointers

Sessions don't store messages directly. They point to:
- `rootEventId`: The first event (session.start)
- `headEventId`: The current position (latest event in active branch)

### 4. State is Reconstructed

To get the current state, we **replay events** from root to head:

```typescript
// Get messages at head
const ancestors = await getAncestors(session.headEventId);
const messages = ancestors
  .filter(e => e.type === 'message.user' || e.type === 'message.assistant')
  .map(e => ({ role: e.type.split('.')[1], content: e.payload.content }));
```

---

## Event Types (35+ Types)

### Session Lifecycle
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `session.start` | Root event | `workingDirectory`, `model`, `provider` |
| `session.end` | Session ended | `reason`, `summary`, `totalTokenUsage` |
| `session.fork` | Fork point | `sourceSessionId`, `sourceEventId` |
| `session.branch` | Named branch | `branchId`, `name` |

### Messages
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `message.user` | User prompt | `content`, `turn`, `imageCount` |
| `message.assistant` | AI response | `content`, `turn`, `tokenUsage`, `stopReason` |
| `message.system` | System message | `content`, `source` |

### Tool Execution
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `tool.call` | Tool invocation | `toolCallId`, `name`, `arguments` |
| `tool.result` | Tool output | `toolCallId`, `content`, `isError`, `duration` |

### Streaming
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `stream.text_delta` | Text chunk | `delta`, `turn`, `blockIndex` |
| `stream.thinking_delta` | Thinking chunk | `delta`, `turn` |
| `stream.turn_start` | Turn begins | `turn` |
| `stream.turn_end` | Turn ends | `turn`, `tokenUsage` |

### Configuration
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `config.model_switch` | Model changed | `previousModel`, `newModel` |
| `config.prompt_update` | Prompt changed | `previousHash`, `newHash` |

### Ledger (Todo System)
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `ledger.update` | Ledger changed | `field`, `previousValue`, `newValue` |
| `ledger.goal` | Goal set | `goal` |
| `ledger.task` | Task action | `action`, `task`, `list` |

### Compaction
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `compact.boundary` | Compaction range | `range`, `originalTokens`, `compactedTokens` |
| `compact.summary` | Summary content | `summary`, `keyDecisions`, `boundaryEventId` |

### Files
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `file.read` | File read | `path`, `lines` |
| `file.write` | File created | `path`, `size`, `contentHash` |
| `file.edit` | File edited | `path`, `oldString`, `newString` |

### Errors
| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `error.agent` | Agent error | `error`, `code`, `recoverable` |
| `error.tool` | Tool error | `toolName`, `toolCallId`, `error` |
| `error.provider` | API error | `provider`, `error`, `retryable` |

---

## Implementation Details by Package

### packages/core/src/events/

The core event store implementation using better-sqlite3.

#### types.ts (803 lines)
Defines all event types with TypeScript interfaces and type guards:
- Branded ID types (`EventId`, `SessionId`, `WorkspaceId`, `BranchId`)
- 35+ event type interfaces
- State reconstruction types (`SessionState`, `Message`)
- Tree visualization types (`TreeNode`, `Branch`)

#### sqlite-backend.ts (1049 lines)
Low-level SQLite operations:
- Schema creation with migrations
- Event CRUD operations
- Ancestor/descendant traversal using recursive CTEs
- FTS5 full-text search indexing
- Blob storage with deduplication

#### event-store.ts (477 lines)
High-level API:
- `createSession()` - Create new session with root event
- `append()` - Add event to session
- `getStateAt()` - Reconstruct state at any event
- `getMessagesAt()` - Get message history
- `fork()` - Create branch from any event
- `rewind()` - Move session head backwards
- `search()` - Full-text search across events

---

### packages/server/src/event-store-orchestrator.ts

Server-side session management that bridges EventStore with TronAgent.

```typescript
class EventStoreOrchestrator {
  // Create session → creates session.start event
  async createSession(options: CreateSessionOptions): Promise<string>

  // Run agent → appends message.user, message.assistant, tool.* events
  async runAgent(options: AgentRunOptions): Promise<TurnResult>

  // Fork → creates new session with session.fork event
  async forkSession(sessionId: string, fromEventId?: string): Promise<ForkResult>

  // Rewind → updates session.headEventId
  async rewindSession(sessionId: string, toEventId: string): Promise<RewindResult>
}
```

---

### packages/chat-web/src/store/event-db.ts

IndexedDB-based local cache for the web client.

```typescript
class EventDB {
  // Stores
  events: IDBObjectStore     // Cached events
  sessions: IDBObjectStore   // Cached sessions
  syncState: IDBObjectStore  // Sync cursor tracking

  // Operations
  async putEvent(event: CachedEvent): Promise<void>
  async getAncestors(eventId: string): Promise<CachedEvent[]>
  async buildTreeVisualization(sessionId: string): Promise<EventTreeNode[]>
  async getMessagesAt(eventId: string): Promise<Message[]>
}
```

---

### packages/chat-web/src/hooks/useEventStore.ts

React hook for web client event store integration.

```typescript
function useEventStore(options: UseEventStoreOptions): UseEventStoreReturn {
  return {
    // State
    state: { isInitialized, isSyncing, syncError, pendingEventCount },

    // Session ops
    getSession, getSessions, cacheSession, removeSession,

    // Event ops
    getEvents, cacheEvents, getAncestors,

    // State reconstruction
    getMessagesAtHead, getStateAtHead, getMessagesAtEvent,

    // Tree ops
    getTree,

    // Fork/Rewind
    fork, rewind,

    // Sync
    sync, fullSync, clear
  };
}
```

---

### packages/ios-app/Sources/Database/EventDatabase.swift

Swift SQLite wrapper for iOS local caching.

```swift
@MainActor
class EventDatabase: ObservableObject {
    // Event operations
    func insertEvent(_ event: SessionEvent) throws
    func getAncestors(_ eventId: String) throws -> [SessionEvent]
    func getChildren(_ eventId: String) throws -> [SessionEvent]

    // Session operations
    func insertSession(_ session: CachedSession) throws
    func getSession(_ id: String) throws -> CachedSession?

    // State reconstruction
    func reconstructSessionState(_ sessionId: String) throws -> ReconstructedSessionState
    func buildTreeVisualization(_ sessionId: String) throws -> [EventTreeNode]
}
```

---

## Data Flow Diagrams

### Web UI Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WEB BROWSER                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐    ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │   App.tsx   │───▶│  useEventStore  │───▶│      IndexedDB (event-db)   │ │
│  │             │    │     Hook        │    │                             │ │
│  │ - Sessions  │    │                 │    │  ┌─────────┐ ┌──────────┐  │ │
│  │ - Messages  │    │ - cacheSession  │    │  │ events  │ │ sessions │  │ │
│  │ - Events    │    │ - getAncestors  │    │  └─────────┘ └──────────┘  │ │
│  └─────┬───────┘    │ - sync()        │    │  ┌─────────┐               │ │
│        │            │ - fork()        │    │  │syncState│               │ │
│        │            │ - rewind()      │    │  └─────────┘               │ │
│        │            └────────┬────────┘    └─────────────────────────────┘ │
│        │                     │                                              │
│        │                     │ RPC Calls                                    │
│        ▼                     ▼                                              │
│  ┌─────────────┐    ┌─────────────────┐                                    │
│  │   useRpc    │───▶│   WebSocket     │                                    │
│  │   Hook      │    │   Connection    │                                    │
│  └─────────────┘    └────────┬────────┘                                    │
│                              │                                              │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               ▼ WebSocket (ws://localhost:8080/ws)
┌──────────────────────────────┼──────────────────────────────────────────────┐
│                              │              SERVER                          │
├──────────────────────────────┼──────────────────────────────────────────────┤
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    EventStoreOrchestrator                            │   │
│  │                                                                      │   │
│  │   RPC Handlers:                                                      │   │
│  │   ├── session.create  → createSession() → session.start event       │   │
│  │   ├── session.resume  → loadSession() → getStateAtHead()            │   │
│  │   ├── session.fork    → fork() → session.fork event                 │   │
│  │   ├── session.rewind  → rewind() → update headEventId               │   │
│  │   ├── agent.prompt    → runAgent() → message.* events               │   │
│  │   └── events.getSince → getEventsSince() → return new events        │   │
│  │                                                                      │   │
│  └────────────────────────────┬────────────────────────────────────────┘   │
│                               │                                             │
│                               ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         EventStore                                   │   │
│  │                                                                      │   │
│  │   ├── append() ────────────────────┐                                │   │
│  │   ├── getStateAt() ◀───────────────┤                                │   │
│  │   ├── fork()                       │                                │   │
│  │   └── rewind()                     ▼                                │   │
│  │                        ┌─────────────────────┐                       │   │
│  │                        │   SQLiteBackend     │                       │   │
│  │                        │  (better-sqlite3)   │                       │   │
│  │                        └──────────┬──────────┘                       │   │
│  └───────────────────────────────────┼─────────────────────────────────┘   │
│                                      │                                      │
│                                      ▼                                      │
│                          ┌─────────────────────┐                            │
│                          │  ~/.tron/db/prod.db  │                            │
│                          │      (SQLite)       │                            │
│                          └─────────────────────┘                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Web UI: Message Send Flow

```
User types message and hits Enter
         │
         ▼
┌─────────────────────────────────────────┐
│ App.tsx: handleSendPrompt()             │
│   1. dispatch('ADD_MESSAGE', userMsg)   │  ◀── Optimistic UI update
│   2. rpc.sendPrompt(prompt)             │
└─────────────────┬───────────────────────┘
                  │
                  ▼ WebSocket RPC
┌─────────────────────────────────────────┐
│ Server: agent.prompt handler            │
│   1. eventStore.append('message.user')  │  ◀── Persist user message
│   2. agent.run(prompt)                  │
│   3. Stream events back to client       │
└─────────────────┬───────────────────────┘
                  │
                  │ Events streamed back:
                  │  • stream.turn_start
                  │  • stream.text_delta (many)
                  │  • tool.call (if tools used)
                  │  • tool.result
                  │  • stream.turn_end
                  │  • message.assistant (final)
                  ▼
┌─────────────────────────────────────────┐
│ App.tsx: onEvent callback               │
│   1. dispatch('UPDATE_STREAMING', delta)│  ◀── Real-time UI updates
│   2. dispatch('SET_ASSISTANT_MSG', msg) │
│   3. eventStore.cacheEvents(events)     │  ◀── Cache locally
└─────────────────────────────────────────┘
```

#### Web UI: Sync Flow

```
┌─────────────────────────────────────────┐
│ useEventStore: Auto-sync (30s interval) │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│ sync(sessionId)                         │
│   1. Get syncState from IndexedDB       │
│   2. RPC: events.getSince(lastEventId)  │
│   3. Cache new events in IndexedDB      │
│   4. Update syncState cursor            │
└─────────────────────────────────────────┘
```

---

### TUI Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                TUI PROCESS                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     EventStoreTuiSession                             │   │
│  │                                                                      │   │
│  │   Direct EventStore Access (no network):                            │   │
│  │                                                                      │   │
│  │   ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │   │
│  │   │ TuiSession   │───▶│  EventStore  │───▶│  SQLiteBackend       │  │   │
│  │   │              │    │              │    │                      │  │   │
│  │   │ - sendPrompt │    │ - append()   │    │ ~/.tron/db/prod.db    │  │   │
│  │   │ - fork()     │    │ - fork()     │    │                      │  │   │
│  │   │ - rewind()   │    │ - rewind()   │    └──────────────────────┘  │   │
│  │   └──────────────┘    └──────────────┘                              │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Message Flow:                                                              │
│                                                                             │
│  User Input ──▶ TuiSession.sendPrompt()                                    │
│                       │                                                     │
│                       ▼                                                     │
│               eventStore.append({                                          │
│                 type: 'message.user',                                      │
│                 parentId: currentHeadEventId,                              │
│                 payload: { content: prompt }                               │
│               })                                                           │
│                       │                                                     │
│                       ▼                                                     │
│               agent.run(prompt)                                            │
│                       │                                                     │
│                       ▼                                                     │
│               eventStore.append({                                          │
│                 type: 'message.assistant',                                 │
│                 parentId: userMessageEventId,                              │
│                 payload: { content: response, tokenUsage: {...} }          │
│               })                                                           │
│                       │                                                     │
│                       ▼                                                     │
│               Update session.headEventId                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### iOS Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               iOS APP                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐                                                        │
│  │  TronMobileApp  │                                                        │
│  │                 │                                                        │
│  │ @StateObject    │                                                        │
│  │ eventDatabase   │──────────────────────────────────────┐                │
│  └────────┬────────┘                                      │                │
│           │                                               │                │
│           ▼                                               ▼                │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │  ChatViewModel  │───▶│  EventDatabase  │───▶│  SQLite (local)         │ │
│  │                 │    │    (Swift)      │    │                         │ │
│  │ - sendPrompt()  │    │                 │    │  ~/Documents/.tron/     │ │
│  │ - loadSession() │    │ - insertEvent() │    │      events.db          │ │
│  └─────────┬───────┘    │ - getAncestors()│    │                         │ │
│            │            │ - buildTree()   │    └─────────────────────────┘ │
│            │            └─────────────────┘                                │
│            │                                                               │
│            │ RPC Calls                                                     │
│            ▼                                                               │
│  ┌─────────────────┐                                                       │
│  │  WebSocketService│                                                      │
│  │                 │                                                       │
│  │ - connect()     │                                                       │
│  │ - call()        │                                                       │
│  └────────┬────────┘                                                       │
│           │                                                                │
└───────────┼────────────────────────────────────────────────────────────────┘
            │
            ▼ WebSocket
┌───────────┴────────────────────────────────────────────────────────────────┐
│                                SERVER                                       │
│                                                                             │
│   Same as Web UI flow - events synced via RPC                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### iOS: Session Creation Flow

```swift
// NewSessionFlow.swift
private func createSession() async {
    // 1. Create session via RPC
    let result = await websocketService.call("session.create", params)

    // 2. Cache session in local EventDatabase
    let cachedSession = CachedSession(
        id: result.sessionId,
        workspaceId: workingDirectory,
        rootEventId: nil,
        headEventId: nil,
        status: .active,
        // ...
    )
    try? eventDatabase.insertSession(cachedSession)

    // 3. Navigate to chat view
    onSessionCreated(session)
}
```

---

## Fork and Rewind Operations

### Fork Operation

Creates a new session branching from any point in history.

```
Before Fork:
                [session.start A]
                      │
                [message.user]
                      │
                [message.assistant]
                      │
                [message.user]  ◀── Fork from here
                      │
                [message.assistant]
                      │
                [message.user]
                      │
                [message.assistant] ◀── Current head

After Fork:
                [session.start A]
                      │
                [message.user]
                      │
                [message.assistant]
                      │
                [message.user]
                      │
        ┌─────────────┴─────────────┐
        │                           │
[message.assistant]          [session.fork B]  ◀── New session B
        │                           │                starts here
[message.user]              [message.user]
        │                           │
[message.assistant]         [message.assistant]
        │                           │
   Session A                   Session B
   (original)                  (forked)
```

```typescript
// Fork implementation
async fork(fromEventId: EventId): Promise<ForkResult> {
  // 1. Create new session
  const newSession = await createSession({
    parentSessionId: sourceSession.id,
    forkFromEventId: fromEventId
  });

  // 2. Create session.fork event pointing to fork point
  const forkEvent = {
    type: 'session.fork',
    parentId: fromEventId,  // Points to where we forked from
    sessionId: newSession.id,
    payload: {
      sourceSessionId: sourceSession.id,
      sourceEventId: fromEventId
    }
  };
  await backend.insertEvent(forkEvent);

  // 3. Set new session's root and head to fork event
  await backend.updateSessionRoot(newSession.id, forkEvent.id);
  await backend.updateSessionHead(newSession.id, forkEvent.id);

  return { session: newSession, rootEvent: forkEvent };
}
```

### Rewind Operation

Moves the session head back to a previous event.

```
Before Rewind:
                [session.start]
                      │
                [message.user]
                      │
                [message.assistant] ◀── Rewind to here
                      │
                [message.user]
                      │
                [message.assistant] ◀── Current head

After Rewind:
                [session.start]
                      │
                [message.user]
                      │
                [message.assistant] ◀── New head (events after are orphaned)
                      │
                [message.user]        (orphaned - still in DB)
                      │
                [message.assistant]   (orphaned - still in DB)
```

```typescript
// Rewind implementation
async rewind(sessionId: SessionId, toEventId: EventId): Promise<void> {
  // Simply update the session head pointer
  // Events after this point become "orphaned" but are preserved
  await backend.updateSessionHead(sessionId, toEventId);
}
```

---

## State Reconstruction

State is never stored directly - it's always computed by replaying events.

### Algorithm

```typescript
async getStateAt(eventId: EventId): Promise<SessionState> {
  // 1. Get all ancestors from root to this event
  const ancestors = await backend.getAncestors(eventId);  // Uses recursive CTE

  // 2. Replay events to build state
  const messages: Message[] = [];
  let inputTokens = 0;
  let outputTokens = 0;
  let turnCount = 0;
  const ledger = { goal: '', next: [], done: [] };

  for (const event of ancestors) {
    switch (event.type) {
      case 'message.user':
        messages.push({ role: 'user', content: event.payload.content });
        break;

      case 'message.assistant':
        messages.push({ role: 'assistant', content: event.payload.content });
        inputTokens += event.payload.tokenUsage.inputTokens;
        outputTokens += event.payload.tokenUsage.outputTokens;
        turnCount = Math.max(turnCount, event.payload.turn);
        break;

      case 'ledger.update':
        Object.assign(ledger, event.payload.updates);
        break;
    }
  }

  return { messages, tokenUsage: { inputTokens, outputTokens }, turnCount, ledger };
}
```

### Recursive CTE for Ancestor Traversal

```sql
WITH RECURSIVE ancestors AS (
  -- Start from target event
  SELECT * FROM events WHERE id = ?

  UNION ALL

  -- Walk up parent chain
  SELECT e.* FROM events e
  INNER JOIN ancestors a ON e.id = a.parent_id
)
SELECT * FROM ancestors ORDER BY depth DESC;  -- Root first
```

---

## Database Schema

### Events Table

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,              -- UUID v7
  session_id TEXT NOT NULL,
  parent_id TEXT,                   -- NULL for root events
  sequence INTEGER NOT NULL,        -- Monotonic within session
  depth INTEGER NOT NULL DEFAULT 0, -- Tree depth
  type TEXT NOT NULL,               -- Event type discriminator
  timestamp TEXT NOT NULL,          -- ISO 8601
  payload TEXT NOT NULL,            -- JSON
  workspace_id TEXT NOT NULL,
  role TEXT,                        -- Extracted: user/assistant/tool
  tool_name TEXT,                   -- Extracted from tool events
  input_tokens INTEGER,             -- Extracted from payload
  output_tokens INTEGER,
  checksum TEXT                     -- Integrity verification
);

-- Indexes for common queries
CREATE INDEX idx_events_session_seq ON events(session_id, sequence);
CREATE INDEX idx_events_parent ON events(parent_id);
CREATE INDEX idx_events_type ON events(type);
CREATE INDEX idx_events_workspace ON events(workspace_id, timestamp DESC);
```

### Sessions Table

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  head_event_id TEXT,               -- Current position
  root_event_id TEXT,               -- First event
  title TEXT,
  status TEXT DEFAULT 'active',     -- active/ended/archived
  model TEXT NOT NULL,
  provider TEXT NOT NULL,
  working_directory TEXT NOT NULL,
  parent_session_id TEXT,           -- If forked
  fork_from_event_id TEXT,          -- Fork point
  created_at TEXT NOT NULL,
  last_activity_at TEXT NOT NULL,
  event_count INTEGER DEFAULT 0,
  message_count INTEGER DEFAULT 0,
  total_input_tokens INTEGER DEFAULT 0,
  total_output_tokens INTEGER DEFAULT 0
);
```

### Full-Text Search

```sql
CREATE VIRTUAL TABLE events_fts USING fts5(
  id UNINDEXED,
  session_id UNINDEXED,
  type,
  content,
  tool_name,
  tokenize='porter unicode61'
);

-- Search query
SELECT id, snippet(events_fts, 3, '<mark>', '</mark>', '...', 64) as snippet
FROM events_fts
WHERE events_fts MATCH 'search query'
ORDER BY bm25(events_fts);
```

---

## Sync Protocol

### Web Client Sync

```
┌─────────────────────┐                    ┌─────────────────────┐
│    Web Client       │                    │       Server        │
│   (IndexedDB)       │                    │    (SQLite)         │
└──────────┬──────────┘                    └──────────┬──────────┘
           │                                          │
           │  1. Get last synced event ID             │
           │  ────────────────────────────▶           │
           │     events.getSince(lastEventId)         │
           │                                          │
           │  2. Return new events                    │
           │  ◀────────────────────────────           │
           │     [event1, event2, event3]             │
           │                                          │
           │  3. Cache events in IndexedDB            │
           │  ┌──────────────────────┐               │
           │  │ putEvents(newEvents) │               │
           │  └──────────────────────┘               │
           │                                          │
           │  4. Update sync cursor                   │
           │  ┌───────────────────────────┐          │
           │  │ putSyncState({            │          │
           │  │   lastSyncedEventId: last │          │
           │  │ })                        │          │
           │  └───────────────────────────┘          │
           │                                          │
```

---

## Test Coverage

### Core Package Tests
- `packages/core/test/events/event-store.test.ts` - EventStore API tests
- `packages/core/test/events/sqlite-backend.test.ts` - Database layer tests

### Web Package Tests
- `packages/chat-web/test/store/event-db.test.ts` - IndexedDB tests (22 tests)
- `packages/chat-web/test/hooks/useEventStore.test.ts` - Hook tests (16 tests)

### iOS Tests
- `packages/ios-app/Tests/EventDatabaseTests.swift` - Swift SQLite tests

---

## What's NOT Yet Implemented

### Phase 6: Tree Visualization UI

The tree visualization components are not yet created:

- `packages/chat-web/src/components/tree/SessionTree.tsx`
- `packages/chat-web/src/components/tree/TreeNode.tsx`
- `packages/ios-app/Sources/Views/SessionTreeView.swift`

These would provide:
- Visual tree rendering of session history
- Click to fork from any node
- Click to rewind to any node
- Branch comparison view

---

## Configuration

### Environment Variables

```bash
# Server
TRON_EVENT_STORE_PATH=~/.tron/db/prod.db  # Default event store location
TRON_MEMORY_DB_PATH=~/.tron/memory.db    # Memory store location

# Web
VITE_WS_URL=ws://localhost:8080/ws       # WebSocket server URL
```

### Storage Locations

| Platform | Event Store Location |
|----------|---------------------|
| Server/TUI | `~/.tron/db/prod.db` |
| iOS | `~/Documents/.tron/db/prod.db` |
| Web | IndexedDB: `tron_events` |

---

## Summary

The Event-Sourced Session Tree System provides:

1. **Immutable History**: Every action is recorded as an append-only event
2. **Tree Structure**: Parent chains enable branching and forking
3. **State Reconstruction**: Current state computed by replaying events
4. **Multi-Client Support**: TUI, Web, iOS all use the same event model
5. **Offline Support**: Clients cache events locally
6. **Sync Protocol**: RPC-based incremental sync with server
7. **Full-Text Search**: FTS5 indexing for content search

The system is ~85% complete. The main remaining work is the tree visualization UI for Web and iOS.
