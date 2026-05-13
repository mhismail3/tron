# SQL Query Patterns

```bash
DB="$HOME/.tron/internal/database/log.db"
# Always use read-only mode for safety:
sqlite3 "$DB" "PRAGMA query_only = ON;"
```

Origin values: `localhost:9847` = prod, `localhost:9846` = dev/beta, `ios-client` = iOS app.

## Session Queries

### Recent Sessions
```sql
SELECT id, title, origin,
  datetime(created_at) as started, datetime(last_activity_at) as last_active,
  event_count, turn_count,
  total_input_tokens + total_output_tokens as total_tokens,
  printf('$%.4f', total_cost) as cost
FROM sessions ORDER BY last_activity_at DESC LIMIT 20;
```

### Sessions by Origin
```sql
SELECT id, title, datetime(last_activity_at) as last_active, event_count
FROM sessions WHERE origin = 'localhost:9847'  -- prod
ORDER BY last_activity_at DESC LIMIT 20;
-- Use origin = 'localhost:9846' for beta/dev
```

### Session Details
```sql
SELECT s.*, w.path as workspace_path, w.name as workspace_name
FROM sessions s LEFT JOIN workspaces w ON s.workspace_id = w.id
WHERE s.id = 'SESSION_ID';
```

### Sessions by Workspace
```sql
SELECT s.id, s.title, s.origin,
  datetime(s.created_at) as created, s.event_count, s.turn_count
FROM sessions s JOIN workspaces w ON s.workspace_id = w.id
WHERE w.path LIKE '%/my-project%'
ORDER BY s.last_activity_at DESC;
```

### Subagent Sessions
```sql
SELECT s.id, s.title, s.spawning_session_id, s.spawn_type, s.spawn_task,
  datetime(s.created_at) as created
FROM sessions s WHERE s.spawning_session_id IS NOT NULL
ORDER BY s.created_at DESC;
```

### Session Fork History
```sql
SELECT s.id, s.title, s.parent_session_id,
  s.fork_from_event_id, datetime(s.created_at) as forked_at
FROM sessions s WHERE s.parent_session_id IS NOT NULL
ORDER BY s.created_at DESC;
```

## Event Queries

### All Events for a Session
```sql
SELECT id, sequence, type, datetime(timestamp) as time, turn,
  capability_name, model, latency_ms, substr(payload, 1, 200) as payload_preview
FROM events WHERE session_id = 'SESSION_ID' ORDER BY sequence;
```

### Messages Only
```sql
SELECT sequence, type, datetime(timestamp) as time, turn,
  json_extract(payload, '$.content') as content
FROM events WHERE session_id = 'SESSION_ID'
  AND type IN ('message.user', 'message.assistant')
ORDER BY sequence;
```

### Tool Executions
```sql
SELECT e.sequence, datetime(e.timestamp) as time, e.capability_name, e.type,
  json_extract(e.payload, '$.isError') as is_error,
  json_extract(e.payload, '$.duration') as duration_ms
FROM events e WHERE e.session_id = 'SESSION_ID'
  AND e.type IN ('capability.invocation.started', 'capability.invocation.completed')
ORDER BY e.sequence;
```

### Errors in a Session
```sql
-- Event-level errors
SELECT sequence, datetime(timestamp) as time, type,
  json_extract(payload, '$.error.message') as error_msg,
  json_extract(payload, '$.error.code') as error_code
FROM events WHERE session_id = 'SESSION_ID'
  AND (type LIKE 'error.%' OR type = 'turn.failed')
ORDER BY sequence;

-- Log-level errors
SELECT datetime(timestamp) as time, level, component,
  message, error_message
FROM logs WHERE session_id = 'SESSION_ID' AND level_num >= 50
ORDER BY timestamp;
```

### Specific Turn Events
```sql
SELECT sequence, type, datetime(timestamp) as time, capability_name,
  model, input_tokens, output_tokens, latency_ms
FROM events WHERE session_id = 'SESSION_ID' AND turn = 3
ORDER BY sequence;
```

### Events in Time Range
```sql
SELECT e.session_id, e.sequence, e.type,
  datetime(e.timestamp) as time, e.capability_name
FROM events e
WHERE e.timestamp BETWEEN '2026-01-15T00:00:00' AND '2026-01-15T23:59:59'
ORDER BY e.timestamp;
```

### Compaction History
```sql
SELECT datetime(timestamp) as time, type,
  json_extract(payload, '$.reason') as reason,
  json_extract(payload, '$.originalTokens') as original_tokens,
  json_extract(payload, '$.compactedTokens') as compacted_tokens,
  json_extract(payload, '$.compressionRatio') as ratio
FROM events WHERE session_id = 'SESSION_ID'
  AND type IN ('compact.summary', 'compact.boundary')
ORDER BY sequence;
```

### Provider Errors (Global)
```sql
SELECT datetime(timestamp) as time, type,
  json_extract(payload, '$.message') as error_msg,
  json_extract(payload, '$.provider') as provider,
  json_extract(payload, '$.model') as model
FROM events WHERE type IN ('error.provider', 'error.agent', 'error.capability', 'turn.failed')
ORDER BY timestamp DESC LIMIT 20;
```

## Token Queries

### Token Usage by Session
```sql
SELECT id, title, origin,
  total_input_tokens, total_output_tokens,
  total_cache_read_tokens, total_cache_creation_tokens,
  total_input_tokens + total_output_tokens as total_tokens,
  printf('$%.4f', total_cost) as cost
FROM sessions WHERE total_cost > 0
ORDER BY total_cost DESC LIMIT 20;
```

### Token Usage by Turn
```sql
SELECT turn, type, model, input_tokens, output_tokens,
  cache_read_tokens, cache_creation_tokens, latency_ms,
  datetime(timestamp) as time
FROM events WHERE session_id = 'SESSION_ID'
  AND (input_tokens > 0 OR output_tokens > 0)
ORDER BY sequence;
```

### Model Usage Across Sessions
```sql
SELECT model, COUNT(*) as turn_count,
  SUM(input_tokens) as total_input, SUM(output_tokens) as total_output,
  AVG(latency_ms) as avg_latency_ms, SUM(cost) as total_cost
FROM events WHERE model IS NOT NULL
GROUP BY model ORDER BY turn_count DESC;
```

## Log Queries

### Session Logs
```sql
SELECT datetime(timestamp) as time, level, component,
  message, trace_id, data
FROM logs WHERE session_id = 'SESSION_ID' ORDER BY timestamp;
```

### Logs by Level
```sql
SELECT datetime(timestamp) as time, level, component,
  session_id, message, error_message
FROM logs WHERE level_num >= 50
ORDER BY timestamp DESC LIMIT 50;
```

### Logs by Component
```sql
SELECT datetime(timestamp) as time, level, message, data
FROM logs WHERE component = 'EventStore'
ORDER BY timestamp DESC LIMIT 50;
```

### iOS Client Logs
```sql
-- Recent iOS client logs
SELECT datetime(timestamp) as time, level, component, message
FROM logs WHERE origin = 'ios-client'
ORDER BY timestamp DESC LIMIT 50;

-- iOS client errors only
SELECT datetime(timestamp) as time, component, message
FROM logs WHERE origin = 'ios-client' AND level_num >= 50
ORDER BY timestamp DESC LIMIT 50;

-- iOS logs by component (ios.WebSocket, ios.RPC, ios.Session, ios.Chat,
-- ios.UI, ios.Network, ios.Events, ios.Notification, ios.General, ios.Database, ios.Audio)
SELECT datetime(timestamp) as time, level, message
FROM logs WHERE origin = 'ios-client' AND component = 'ios.WebSocket'
ORDER BY timestamp DESC LIMIT 50;
```

## Cron Queries

### Job Listing
```sql
SELECT id, name, enabled, overlap_policy,
  datetime(next_run_at) as next_run, datetime(last_run_at) as last_run,
  consecutive_failures, schedule_json
FROM cron_jobs ORDER BY enabled DESC, name;
```

### Run History
```sql
SELECT r.id, r.job_name, r.status,
  datetime(r.started_at) as started, r.duration_ms, r.error, r.session_id
FROM cron_runs r ORDER BY r.started_at DESC LIMIT 20;
```

### Failed Runs
```sql
SELECT r.id, r.job_name, r.status,
  datetime(r.started_at) as started, r.error
FROM cron_runs r WHERE r.status IN ('failed', 'timed_out')
ORDER BY r.started_at DESC LIMIT 20;
```

## Storage & Stats

### Blob Storage Statistics
```sql
SELECT COUNT(*) as total_blobs,
  SUM(size_original) as total_original_bytes,
  SUM(size_compressed) as total_compressed_bytes,
  CASE WHEN SUM(size_original) > 0
    THEN printf('%.1f%%', 100.0 * SUM(size_compressed) / SUM(size_original))
    ELSE 'N/A' END as compression_ratio,
  SUM(CASE WHEN ref_count <= 0 THEN 1 ELSE 0 END) as orphaned_blobs
FROM blobs;
```

### Database Statistics
```sql
SELECT
  (SELECT COUNT(*) FROM sessions) as total_sessions,
  (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL) as active_sessions,
  (SELECT COUNT(*) FROM sessions WHERE origin = 'localhost:9847') as prod_sessions,
  (SELECT COUNT(*) FROM sessions WHERE origin = 'localhost:9846') as beta_sessions,
  (SELECT COUNT(*) FROM events) as total_events,
  (SELECT COUNT(*) FROM logs) as total_logs,
  (SELECT printf('$%.2f', COALESCE(SUM(total_cost), 0)) FROM sessions) as total_cost,
  (SELECT SUM(total_input_tokens + total_output_tokens) FROM sessions) as total_tokens;
```

### Workspace Listing
```sql
SELECT w.id, w.path, w.name,
  datetime(w.last_activity_at) as last_activity,
  COUNT(s.id) as session_count
FROM workspaces w LEFT JOIN sessions s ON s.workspace_id = w.id
GROUP BY w.id ORDER BY w.last_activity_at DESC;
```

### Device Tokens
```sql
SELECT id, platform, environment, is_active,
  datetime(created_at) as created, datetime(last_used_at) as last_used
FROM device_tokens ORDER BY last_used_at DESC;
```

## sqlite3 Quick Reference

```bash
sqlite3 "$HOME/.tron/internal/database/log.db"

.mode column
.headers on
.tables
.schema events

-- Export to CSV
.mode csv
.output results.csv
SELECT * FROM sessions;
.output stdout

.quit
```
