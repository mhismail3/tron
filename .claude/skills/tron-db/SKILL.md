---
name: Tron Database Accessor
description: Query patterns and CLI for debugging Tron agent sessions, events, and logs
autoInject: false
version: "2.0.0"
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
# Single unified database (prod and beta share one file)
DB="$HOME/.tron/database/tron.db"

# Sessions are distinguished by `origin` column:
#   localhost:9847 = prod
#   localhost:9846 = dev/beta
```

## CLI Tool

A CLI tool is available for common queries:

```bash
~/.tron/skills/tron-db/scripts/tron-db.py --help

# Filter by origin (prod vs beta)
~/.tron/skills/tron-db/scripts/tron-db.py sessions --origin prod
~/.tron/skills/tron-db/scripts/tron-db.py sessions --origin beta
```

## Schema Overview

| Table | Purpose |
|-------|---------|
| `sessions` | Session metadata, token counts, costs, origin |
| `events` | Immutable event log (messages, tools, config changes) |
| `logs` | Structured application logs with tracing |
| `blobs` | Content-addressable blob storage |
| `workspaces` | Project/directory associations |
| `branches` | Session branching support |
| `tasks` | Task management (project/area scoped) |
| `areas` | Task area groupings |
| `projects` | Task project groupings |
| `memory_vectors` | Semantic memory embeddings |

### Key Columns

**sessions.origin** — Server origin string identifying the instance:
- `localhost:9847` = production
- `localhost:9846` = dev/beta

**events** denormalized columns (indexed, extracted from payload):
- `model`, `provider_type` — which model/provider handled the turn
- `latency_ms` — provider response latency
- `stop_reason` — why the turn ended
- `has_thinking` — whether thinking blocks were present
- `cost` — per-event cost

**logs** tracing columns:
- `trace_id`, `parent_trace_id`, `depth` — distributed tracing support
- `origin` — same server origin as sessions

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
  origin,
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

### 2. List Sessions by Origin (Prod vs Beta)

```sql
-- Production sessions only
SELECT id, title, datetime(last_activity_at) as last_active, event_count
FROM sessions
WHERE origin = 'localhost:9847'
ORDER BY last_activity_at DESC
LIMIT 20;

-- Beta/dev sessions only
SELECT id, title, datetime(last_activity_at) as last_active, event_count
FROM sessions
WHERE origin = 'localhost:9846'
ORDER BY last_activity_at DESC
LIMIT 20;
```

### 3. Get Session Details

```sql
SELECT
  s.*,
  w.path as workspace_path,
  w.name as workspace_name
FROM sessions s
LEFT JOIN workspaces w ON s.workspace_id = w.id
WHERE s.id = 'SESSION_ID';
```

### 4. Get All Events for a Session

```sql
SELECT
  id,
  sequence,
  type,
  datetime(timestamp) as time,
  turn,
  tool_name,
  model,
  latency_ms,
  substr(payload, 1, 200) as payload_preview
FROM events
WHERE session_id = 'SESSION_ID'
ORDER BY sequence;
```

### 5. Get Messages Only (User/Assistant)

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

### 6. Get Tool Executions for a Session

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

### 7. Find Errors in a Session

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

### 8. Get Logs for a Session

```sql
SELECT
  datetime(timestamp) as time,
  level,
  component,
  message,
  trace_id,
  data
FROM logs
WHERE session_id = 'SESSION_ID'
ORDER BY timestamp;
```

### 9. Get Logs by Level

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

### 10. Get Logs by Component

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

### 11. Events in Time Range

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

### 12. Token Usage by Session

```sql
SELECT
  id,
  title,
  origin,
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

### 13. Token Usage by Turn

```sql
SELECT
  turn,
  type,
  model,
  input_tokens,
  output_tokens,
  cache_read_tokens,
  latency_ms,
  datetime(timestamp) as time
FROM events
WHERE session_id = 'SESSION_ID'
  AND (input_tokens > 0 OR output_tokens > 0)
ORDER BY sequence;
```

### 14. Find Sessions by Workspace

```sql
SELECT
  s.id,
  s.title,
  s.origin,
  datetime(s.created_at) as created,
  s.event_count,
  s.turn_count
FROM sessions s
JOIN workspaces w ON s.workspace_id = w.id
WHERE w.path LIKE '%/my-project%'
ORDER BY s.last_activity_at DESC;
```

### 15. Full-Text Search Events

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

### 16. Full-Text Search Logs

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

### 17. Get Specific Turn Events

```sql
SELECT
  sequence,
  type,
  datetime(timestamp) as time,
  tool_name,
  model,
  input_tokens,
  output_tokens,
  latency_ms
FROM events
WHERE session_id = 'SESSION_ID'
  AND turn = 3
ORDER BY sequence;
```

### 18. Compaction History

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

### 19. API Retries

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

### 20. Session Fork History

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

### 21. Subagent Sessions

```sql
SELECT
  s.id,
  s.title,
  s.spawning_session_id,
  s.spawn_type,
  s.spawn_task,
  s.origin,
  datetime(s.created_at) as created
FROM sessions s
WHERE s.spawning_session_id IS NOT NULL
ORDER BY s.created_at DESC;
```

### 22. Model Usage Across Sessions

```sql
SELECT
  model,
  COUNT(*) as turn_count,
  SUM(input_tokens) as total_input,
  SUM(output_tokens) as total_output,
  AVG(latency_ms) as avg_latency_ms,
  SUM(cost) as total_cost
FROM events
WHERE model IS NOT NULL
GROUP BY model
ORDER BY turn_count DESC;
```

### 23. Database Statistics

```sql
SELECT
  (SELECT COUNT(*) FROM sessions) as total_sessions,
  (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL) as active_sessions,
  (SELECT COUNT(*) FROM sessions WHERE origin = 'localhost:9847') as prod_sessions,
  (SELECT COUNT(*) FROM sessions WHERE origin = 'localhost:9846') as beta_sessions,
  (SELECT COUNT(*) FROM events) as total_events,
  (SELECT COUNT(*) FROM logs) as total_logs,
  (SELECT SUM(total_cost) FROM sessions) as total_cost_usd,
  (SELECT SUM(total_input_tokens + total_output_tokens) FROM sessions) as total_tokens;
```

---

## Quick Reference: sqlite3 Commands

```bash
# Open database
sqlite3 ~/.tron/database/tron.db

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

### Compare Prod vs Beta

```bash
# Show only prod sessions
~/.tron/skills/tron-db/scripts/tron-db.py sessions --origin prod

# Show only beta sessions
~/.tron/skills/tron-db/scripts/tron-db.py sessions --origin beta

# Stats for a specific origin
~/.tron/skills/tron-db/scripts/tron-db.py stats --origin prod
```
