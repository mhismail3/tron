# Event System

<!--
PURPOSE: Technical documentation of the event-sourced session architecture.
AUDIENCE: Developers working on session management, state reconstruction, or sync.

AGENT MAINTENANCE:
- Update event types when new ones are added to packages/core/src/events/types.ts
- Update diagrams when data flow changes
- Verify table schemas match actual SQLite schema
- Last verified: 2026-01-20
-->

## Overview

Tron uses event sourcing for session management. Every action is recorded as an immutable event forming a tree structure.

**Benefits:**
- Complete auditability
- Fork/rewind from any point
- State reconstruction
- Multi-client sync (TUI, Web, iOS)

## Core Concepts

### Events are Immutable

Events are never modified. Every action appends a new event:

```typescript
interface BaseEvent {
  id: string;              // UUID v7 (time-sortable)
  parentId: string | null; // Previous event (null for root)
  sessionId: string;
  sequence: number;        // Monotonic within session
  type: string;            // Discriminator (35+ types)
  timestamp: string;       // ISO 8601
  payload: Record<string, unknown>;
}
```

### Tree Structure

Events form a tree through `parentId` references:

```
[session.start] ← root (parentId=null)
      │
[message.user]
      │
[message.assistant]
      │
[message.user]  ← FORK POINT
      │         \
[message.a]    [session.fork] ← New branch
      │              │
     ...        [message.user]
```

### Sessions are Pointers

Sessions don't store messages. They point to:
- `rootEventId`: First event (session.start)
- `headEventId`: Current position (latest event)

### State is Reconstructed

Get current state by replaying events from root to head:

```typescript
const ancestors = await getAncestors(session.headEventId);
const messages = ancestors
  .filter(e => e.type.startsWith('message.'))
  .map(toMessage);
```

## Event Types

### Session Lifecycle

| Type | Description |
|------|-------------|
| `session.start` | Root event with workingDirectory, model, provider |
| `session.end` | Session ended with reason, summary |
| `session.fork` | Fork point with sourceSessionId |

### Messages

| Type | Description |
|------|-------------|
| `message.user` | User prompt with content, turn |
| `message.assistant` | AI response with content, tokenUsage |
| `message.system` | System message |

### Tools

| Type | Description |
|------|-------------|
| `tool.call` | Tool invocation with name, arguments |
| `tool.result` | Tool output with content, isError, duration |

### Streaming

| Type | Description |
|------|-------------|
| `stream.text_delta` | Text chunk |
| `stream.thinking_delta` | Thinking chunk |
| `stream.turn_start` | Turn begins |
| `stream.turn_end` | Turn ends with tokenUsage |

## Operations

### Fork

Creates a new session branching from any event:

```typescript
async fork(fromEventId: string): Promise<ForkResult> {
  // 1. Create new session
  // 2. Create session.fork event with parentId = fromEventId
  // 3. Set new session's root and head to fork event
}
```

### Rewind

Moves session head back to a previous event:

```typescript
async rewind(sessionId: string, toEventId: string): Promise<void> {
  // Simply update session.headEventId
  // Events after this point become orphaned (preserved in DB)
}
```

## Database Schema

### Events Table

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  parent_id TEXT,
  sequence INTEGER NOT NULL,
  depth INTEGER NOT NULL DEFAULT 0,
  type TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  payload TEXT NOT NULL,
  workspace_id TEXT NOT NULL
);

CREATE INDEX idx_events_session_seq ON events(session_id, sequence);
CREATE INDEX idx_events_parent ON events(parent_id);
```

### Sessions Table

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  head_event_id TEXT,
  root_event_id TEXT,
  status TEXT DEFAULT 'active',
  model TEXT NOT NULL,
  provider TEXT NOT NULL,
  working_directory TEXT NOT NULL
);
```

### Full-Text Search

```sql
CREATE VIRTUAL TABLE events_fts USING fts5(
  id UNINDEXED,
  session_id UNINDEXED,
  type,
  content,
  tokenize='porter unicode61'
);
```

## Client Implementations

| Platform | Storage | Location |
|----------|---------|----------|
| Server/TUI | SQLite | `~/.tron/db/prod.db` |
| Web | IndexedDB | Browser |
| iOS | SQLite | App Documents |

## Sync Protocol

Clients sync via RPC:

```
Client                           Server
   │                                │
   │ events.getSince(lastEventId)   │
   │ ─────────────────────────────▶ │
   │                                │
   │ [event1, event2, event3]       │
   │ ◀───────────────────────────── │
   │                                │
   │ Cache locally                  │
   │                                │
```
