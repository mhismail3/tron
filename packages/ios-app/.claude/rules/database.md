---
paths:
  - "**/Database/**"
---

# Event Database

Local SQLite storage for events. Provides offline support and fast history loading.

## Schema

```
sessions: id, workspace_id, title, created_at, updated_at, ...
events: id, session_id, type, payload (JSON), sequence, timestamp, ...
thinking_blocks: id, event_id, block_index, content (separate for size)
sync_state: session_id, last_synced_sequence
```

## Repositories

- `SessionRepository` - CRUD for sessions table
- `EventRepository` - Event storage and querying
- `ThinkingRepository` - Thinking block storage
- `TreeRepository` - Event parent/child relationships
- `SyncRepository` - Sync state tracking

## Usage

```swift
// All DB access through EventDatabase
let events = try await eventDatabase.events.fetch(sessionId: id, limit: 50)
```

## Rules

- Access only through repository methods, never raw SQL
- Payload is JSON blob - use `AnyCodable` for type-safe access
- Sequence numbers are per-session, used for sync and ordering
- Thinking blocks stored separately due to size (can be 100KB+)

---

## Update Triggers

Update this rule when:
- Adding tables or columns to schema
- Adding new repository classes
- Changing sync state tracking

Verification:
```bash
grep -l "Repository" packages/ios-app/Sources/Database/*.swift
```
