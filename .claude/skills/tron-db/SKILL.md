---
name: Tron Database Accessor
description: Query patterns and CLI for debugging Tron agent sessions, events, and logs
autoInject: false
version: "1.0.0"
tools:
  - Bash
tags:
  - debugging
  - tron
  - sqlite
  - introspection
---

Debug Tron agent behavior by querying the events database. Use this skill when investigating session issues, analyzing token usage, finding errors, or understanding agent behavior.

## Database Location

```bash
# Production database
DB="$HOME/.tron/db/prod.db"

# Beta database (if using beta channel)
DB="$HOME/.tron/db/beta.db"

# Check which exists
ls -la ~/.tron/db/*.db
```

## CLI Tool

A CLI tool is available for common queries:

```bash
~/.tron/skills/tron-db/scripts/tron-db.py --help
```

## Schema Overview

| Table | Purpose |
|-------|---------|
| `sessions` | Session metadata, token counts, costs |
| `events` | Immutable event log (messages, tools, config changes) |
| `logs` | Structured application logs |
| `blobs` | Content-addressable blob storage |
| `workspaces` | Project/directory associations |
| `branches` | Session branching support |

## Event Types Reference

### Message Events
- `message.user` - User input
- `message.assistant` - Assistant response
- `message.deleted` - Deletion marker

### Agent Lifecycle
- `agent_start` / `agent_end` / `agent_interrupted`
- `turn_start` / `turn_end`
- `session.start` / `session.fork`

### Tool Events
- `tool_use_batch` - Tool calls from model
- `tool_execution_start` / `tool_execution_end`

### Configuration Events
- `config.model_switch` - Model changed
- `config.reasoning_level` - Reasoning level changed
- `compact.summary` - Compaction occurred

### Error Events
- `error` - Error with stack trace
- `api_retry` - API retry attempt

---

## Common Query Patterns

### 1. List Recent Sessions

```sql
SELECT
  id,
  title,
  datetime(created_at) as started,
  datetime(last_activity_at) as last_active,
  event_count,
  turn_count,
  total_input_tokens + total_output_tokens as total_tokens,
  printf('$%.4f', total_cost) as cost
FROM sessions
ORDER BY last_activity_at DESC
LIMIT 20;
```

### 2. Get Session Details

```sql
SELECT
  s.*,
  w.path as workspace_path,
  w.name as workspace_name
FROM sessions s
LEFT JOIN workspaces w ON s.workspace_id = w.id
WHERE s.id = 'SESSION_ID';
```

### 3. Get All Events for a Session

```sql
SELECT
  id,
  sequence,
  type,
  datetime(timestamp) as time,
  turn,
  tool_name,
  substr(payload, 1, 200) as payload_preview
FROM events
WHERE session_id = 'SESSION_ID'
ORDER BY sequence;
```

### 4. Get Messages Only (User/Assistant)

```sql
SELECT
  sequence,
  type,
  datetime(timestamp) as time,
  turn,
  json_extract(payload, '$.content') as content
FROM events
WHERE session_id = 'SESSION_ID'
  AND type IN ('message.user', 'message.assistant')
ORDER BY sequence;
```

### 5. Get Tool Executions for a Session

```sql
SELECT
  e.sequence,
  datetime(e.timestamp) as time,
  e.tool_name,
  e.type,
  json_extract(e.payload, '$.status') as status,
  json_extract(e.payload, '$.error') as error
FROM events e
WHERE e.session_id = 'SESSION_ID'
  AND e.type LIKE 'tool_execution%'
ORDER BY e.sequence;
```

### 6. Find Errors in a Session

```sql
-- Event-level errors
SELECT
  sequence,
  datetime(timestamp) as time,
  type,
  json_extract(payload, '$.error.message') as error_msg,
  json_extract(payload, '$.error.code') as error_code
FROM events
WHERE session_id = 'SESSION_ID'
  AND (type = 'error' OR payload LIKE '%"error"%')
ORDER BY sequence;

-- Log-level errors
SELECT
  datetime(timestamp) as time,
  level,
  component,
  message,
  error_message,
  error_stack
FROM logs
WHERE session_id = 'SESSION_ID'
  AND level_num >= 50
ORDER BY timestamp;
```

### 7. Get Logs for a Session

```sql
SELECT
  datetime(timestamp) as time,
  level,
  component,
  message,
  data
FROM logs
WHERE session_id = 'SESSION_ID'
ORDER BY timestamp;
```

### 8. Get Logs by Level

```sql
-- Errors and fatals only
SELECT
  datetime(timestamp) as time,
  level,
  component,
  session_id,
  message,
  error_message
FROM logs
WHERE level_num >= 50
ORDER BY timestamp DESC
LIMIT 50;

-- Warnings and above
SELECT * FROM logs WHERE level_num >= 40 ORDER BY timestamp DESC LIMIT 100;
```

### 9. Get Logs by Component

```sql
SELECT
  datetime(timestamp) as time,
  level,
  message,
  data
FROM logs
WHERE component = 'EventStore'
ORDER BY timestamp DESC
LIMIT 50;
```

### 10. Events in Time Range

```sql
SELECT
  e.session_id,
  e.sequence,
  e.type,
  datetime(e.timestamp) as time,
  e.tool_name
FROM events e
WHERE e.timestamp BETWEEN '2024-01-15T00:00:00' AND '2024-01-15T23:59:59'
ORDER BY e.timestamp;
```

### 11. Token Usage by Session

```sql
SELECT
  id,
  title,
  total_input_tokens,
  total_output_tokens,
  total_cache_read_tokens,
  total_cache_creation_tokens,
  total_input_tokens + total_output_tokens as total_tokens,
  printf('$%.4f', total_cost) as cost
FROM sessions
WHERE total_cost > 0
ORDER BY total_cost DESC
LIMIT 20;
```

### 12. Token Usage by Turn

```sql
SELECT
  turn,
  type,
  input_tokens,
  output_tokens,
  cache_read_tokens,
  datetime(timestamp) as time
FROM events
WHERE session_id = 'SESSION_ID'
  AND (input_tokens > 0 OR output_tokens > 0)
ORDER BY sequence;
```

### 13. Find Sessions by Workspace

```sql
SELECT
  s.id,
  s.title,
  datetime(s.created_at) as created,
  s.event_count,
  s.turn_count
FROM sessions s
JOIN workspaces w ON s.workspace_id = w.id
WHERE w.path LIKE '%/my-project%'
ORDER BY s.last_activity_at DESC;
```

### 14. Full-Text Search Events

```sql
SELECT
  e.id,
  e.session_id,
  e.type,
  datetime(e.timestamp) as time,
  snippet(events_fts, 0, '>>>', '<<<', '...', 30) as match
FROM events_fts
JOIN events e ON events_fts.rowid = e.rowid
WHERE events_fts MATCH 'error OR exception'
ORDER BY e.timestamp DESC
LIMIT 20;
```

### 15. Full-Text Search Logs

```sql
SELECT
  l.id,
  l.session_id,
  datetime(l.timestamp) as time,
  l.level,
  snippet(logs_fts, 0, '>>>', '<<<', '...', 30) as match
FROM logs_fts
JOIN logs l ON logs_fts.rowid = l.id
WHERE logs_fts MATCH 'timeout OR failed'
ORDER BY l.timestamp DESC
LIMIT 20;
```

### 16. Get Specific Turn Events

```sql
SELECT
  sequence,
  type,
  datetime(timestamp) as time,
  tool_name,
  input_tokens,
  output_tokens
FROM events
WHERE session_id = 'SESSION_ID'
  AND turn = 3
ORDER BY sequence;
```

### 17. Compaction History

```sql
SELECT
  datetime(timestamp) as time,
  type,
  json_extract(payload, '$.reason') as reason,
  json_extract(payload, '$.tokensBefore') as tokens_before,
  json_extract(payload, '$.tokensAfter') as tokens_after,
  json_extract(payload, '$.compressionRatio') as ratio
FROM events
WHERE session_id = 'SESSION_ID'
  AND type IN ('compaction_start', 'compaction_complete')
ORDER BY sequence;
```

### 18. API Retries

```sql
SELECT
  datetime(timestamp) as time,
  json_extract(payload, '$.attempt') as attempt,
  json_extract(payload, '$.maxRetries') as max_retries,
  json_extract(payload, '$.delayMs') as delay_ms,
  json_extract(payload, '$.error.message') as error
FROM events
WHERE type = 'api_retry'
ORDER BY timestamp DESC
LIMIT 20;
```

### 19. Session Fork History

```sql
SELECT
  s.id,
  s.title,
  s.parent_session_id,
  s.fork_from_event_id,
  datetime(s.created_at) as forked_at
FROM sessions s
WHERE s.parent_session_id IS NOT NULL
ORDER BY s.created_at DESC;
```

### 20. Database Statistics

```sql
SELECT
  (SELECT COUNT(*) FROM sessions) as total_sessions,
  (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL) as active_sessions,
  (SELECT COUNT(*) FROM events) as total_events,
  (SELECT COUNT(*) FROM logs) as total_logs,
  (SELECT SUM(total_cost) FROM sessions) as total_cost_usd,
  (SELECT SUM(total_input_tokens + total_output_tokens) FROM sessions) as total_tokens;
```

---

## Quick Reference: sqlite3 Commands

```bash
# Open database (use prod.db or beta.db as appropriate)
sqlite3 ~/.tron/db/prod.db

# Pretty output
.mode column
.headers on

# Show tables
.tables

# Describe table
.schema events

# Export to CSV
.mode csv
.output results.csv
SELECT * FROM sessions;
.output stdout

# Exit
.quit
```

## Debugging Workflow

### Investigate a Failed Session

1. **Find the session**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py sessions --limit 10
   ```

2. **Get session overview**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py session SESSION_ID
   ```

3. **Find errors**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py errors SESSION_ID
   ```

4. **Get detailed logs**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py logs SESSION_ID --level error
   ```

5. **Examine specific turn**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py turn SESSION_ID 3
   ```

### Find Why Token Usage Spiked

1. **List high-cost sessions**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py tokens --sort cost
   ```

2. **Get token breakdown by turn**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py tokens SESSION_ID
   ```

3. **Check for compaction events**
   ```bash
   ~/.tron/skills/tron-db/scripts/tron-db.py events SESSION_ID --type compaction
   ```
