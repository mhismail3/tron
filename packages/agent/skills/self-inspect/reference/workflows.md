# Investigation Workflows

All workflows use direct sqlite3 queries and system commands. Set `DB` first:

```bash
DB="$HOME/.tron/system/db/log.db"
```

## Workflow 1: Installation Health Check

1. `curl -s http://localhost:9847/health/deep | jq .` — full server health with subsystem checks
2. `sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM sessions) as sessions, (SELECT COUNT(*) FROM events) as events, (SELECT COUNT(*) FROM logs) as logs;"` — database stats
3. `cat ~/.tron/system/settings.json | jq .` — verify settings
4. `du -sh ~/.tron/system/ ~/.tron/memory/ ~/.tron/skills/` — disk usage

## Workflow 2: Investigate a Failed Session

1. Find the session:
   ```sql
   SELECT id, title, origin, datetime(last_activity_at) as last_active, event_count
   FROM sessions ORDER BY last_activity_at DESC LIMIT 10;
   ```
2. Session overview:
   ```sql
   SELECT s.*, w.path as workspace_path FROM sessions s
   LEFT JOIN workspaces w ON s.workspace_id = w.id WHERE s.id = 'SESSION_ID';
   ```
3. Find errors:
   ```sql
   SELECT sequence, type, datetime(timestamp), json_extract(payload, '$.error.message')
   FROM events WHERE session_id = 'SESSION_ID'
     AND (type LIKE 'error.%' OR type = 'turn.failed') ORDER BY sequence;
   ```
4. Detailed error logs:
   ```sql
   SELECT datetime(timestamp), level, component, message, error_message
   FROM logs WHERE session_id = 'SESSION_ID' AND level_num >= 50 ORDER BY timestamp;
   ```
5. Examine specific turn:
   ```sql
   SELECT sequence, type, tool_name, model, input_tokens, output_tokens, latency_ms
   FROM events WHERE session_id = 'SESSION_ID' AND turn = 3 ORDER BY sequence;
   ```

## Workflow 3: Token Usage Spike

1. High-cost sessions:
   ```sql
   SELECT id, title, origin, total_input_tokens + total_output_tokens as tokens,
     printf('$%.4f', total_cost) as cost
   FROM sessions WHERE total_cost > 0 ORDER BY total_cost DESC LIMIT 20;
   ```
2. Per-turn breakdown for a session:
   ```sql
   SELECT turn, model, input_tokens, output_tokens, cache_read_tokens, latency_ms
   FROM events WHERE session_id = 'SESSION_ID' AND (input_tokens > 0 OR output_tokens > 0)
   ORDER BY sequence;
   ```
3. Check compaction events (see queries.md: Compaction History)

## Workflow 4: iOS Client Issues

1. Recent iOS logs:
   ```sql
   SELECT datetime(timestamp), level, component, message
   FROM logs WHERE origin = 'ios-client' ORDER BY timestamp DESC LIMIT 50;
   ```
2. iOS errors:
   ```sql
   SELECT datetime(timestamp), component, message
   FROM logs WHERE origin = 'ios-client' AND level_num >= 50
   ORDER BY timestamp DESC LIMIT 50;
   ```
3. By component (e.g. WebSocket):
   ```sql
   SELECT datetime(timestamp), level, message
   FROM logs WHERE origin = 'ios-client' AND component = 'ios.WebSocket'
   ORDER BY timestamp DESC LIMIT 50;
   ```
4. Search for specific issues:
   ```sql
   SELECT datetime(timestamp), component, message
   FROM logs WHERE origin = 'ios-client' AND message LIKE '%timeout%'
   ORDER BY timestamp DESC LIMIT 20;
   ```

## Workflow 5: Automation/Cron Debugging

1. List jobs:
   ```sql
   SELECT name, enabled, datetime(next_run_at), datetime(last_run_at), consecutive_failures
   FROM cron_jobs ORDER BY enabled DESC, name;
   ```
2. Recent runs:
   ```sql
   SELECT job_name, status, datetime(started_at), duration_ms, error
   FROM cron_runs ORDER BY started_at DESC LIMIT 20;
   ```
3. Failed runs:
   ```sql
   SELECT job_name, status, datetime(started_at), error
   FROM cron_runs WHERE status IN ('failed', 'timed_out')
   ORDER BY started_at DESC LIMIT 20;
   ```

## Workflow 6: Auth & Provider Issues

1. Check configured providers (redacted):
   ```bash
   cat ~/.tron/system/auth.json | jq 'del(.. | .accessToken?, .refreshToken?, .apiKey?, .clientSecret?)'
   ```
2. Check default provider/model:
   ```bash
   cat ~/.tron/system/settings.json | jq '.server | {defaultModel, defaultProvider}'
   ```
3. Search logs for auth errors:
   ```sql
   SELECT datetime(timestamp), component, message
   FROM logs WHERE message LIKE '%401%' OR message LIKE '%unauthorized%' OR message LIKE '%auth%'
   ORDER BY timestamp DESC LIMIT 20;
   ```

## Workflow 7: Compare Prod vs Beta

```sql
-- Prod sessions
SELECT id, title, datetime(last_activity_at), event_count
FROM sessions WHERE origin = 'localhost:9847' ORDER BY last_activity_at DESC LIMIT 10;

-- Beta sessions
SELECT id, title, datetime(last_activity_at), event_count
FROM sessions WHERE origin = 'localhost:9846' ORDER BY last_activity_at DESC LIMIT 10;

-- Stats by origin
SELECT origin, COUNT(*) as sessions, SUM(event_count) as events,
  printf('$%.2f', SUM(total_cost)) as cost
FROM sessions GROUP BY origin;
```

## Workflow 8: Verify Installation Files

1. `curl -s http://localhost:9847/health/deep | jq .` — deep health endpoint
2. Check deployment state:
   ```bash
   cat ~/.tron/system/deployment/last-deployment.json | jq .
   cat ~/.tron/system/deployment/deployed-commit
   cat ~/.tron/system/deployment/restart-sentinel.json | jq .
   ```
3. Verify key files exist:
   ```bash
   ls -la ~/.tron/system/bin/tron
   ls -la ~/.tron/system/db/log.db
   ls -la ~/.tron/system/settings.json
   ls -la ~/.tron/system/auth.json
   ```
