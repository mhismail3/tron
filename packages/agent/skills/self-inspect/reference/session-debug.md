# Debug Current Session

> **MANDATORY OUTPUT RULE**: Every session debug or investigation MUST produce a written report file at `~/.tron/memory/reports/YYYY-MM-DD-session-debug.md`. Writing findings only in chat is not acceptable. Write the file first, then give the verbal summary. No exceptions.

**What this does**: Debugs the session you are currently operating in — the literal conversation happening right now between you and the user. "This session" means YOUR active session: the one with `ended_at IS NULL` and the most recent `last_activity_at` in the database. That is always the session you are running inside of, because your own queries update its `last_activity_at` timestamp.

Produces a structured diagnostic report written to `~/.tron/memory/reports/`.

```bash
DB="$HOME/.tron/system/db/log.db"
```

## Step 1: Identify the Active Session

```sql
SELECT id, title, latest_model, origin, working_directory,
  datetime(created_at) as started, datetime(last_activity_at) as last_active,
  event_count, turn_count, message_count,
  total_input_tokens, total_output_tokens,
  total_cache_read_tokens, total_cache_creation_tokens,
  printf('$%.4f', total_cost) as cost
FROM sessions
WHERE ended_at IS NULL
ORDER BY last_activity_at DESC LIMIT 1;
```

Save the session `id` as `SESSION_ID` for all subsequent queries.

Get workspace info:

```sql
SELECT w.path, w.name FROM workspaces w
JOIN sessions s ON s.workspace_id = w.id
WHERE s.id = 'SESSION_ID';
```

## Step 2: Get the Latest Turn Number

```sql
SELECT MAX(turn) as latest_turn FROM events WHERE session_id = 'SESSION_ID';
```

Use this to define the "recent window": the last 5 turns, i.e. `turn > (latest_turn - 5)`.

## Step 3: Recent Turn Timeline

```sql
SELECT turn, sequence, type, datetime(timestamp) as time,
  tool_name, model, role, input_tokens, output_tokens, latency_ms,
  substr(payload, 1, 300) as payload_preview
FROM events
WHERE session_id = 'SESSION_ID'
  AND turn > (SELECT MAX(turn) - 5 FROM events WHERE session_id = 'SESSION_ID')
ORDER BY sequence;
```

## Step 4: Find All Errors

### Event-level errors

```sql
SELECT sequence, turn, datetime(timestamp) as time, type,
  json_extract(payload, '$.error.message') as error_msg,
  json_extract(payload, '$.error.code') as error_code,
  json_extract(payload, '$.error.type') as error_type,
  tool_name,
  substr(payload, 1, 500) as full_payload
FROM events
WHERE session_id = 'SESSION_ID'
  AND (type LIKE 'error.%' OR type = 'turn.failed')
ORDER BY sequence;
```

### Log-level errors and warnings

```sql
SELECT datetime(timestamp) as time, level, component,
  message, error_message, error_stack, turn
FROM logs
WHERE session_id = 'SESSION_ID' AND level_num >= 40
ORDER BY timestamp;
```

Using `level_num >= 40` captures both warnings and errors — warnings are often the early signal.

## Step 5: Tool Call Analysis

```sql
SELECT e1.sequence as call_seq, e1.turn, e1.tool_name,
  datetime(e1.timestamp) as called_at,
  substr(e1.payload, 1, 200) as call_preview,
  e2.sequence as result_seq,
  json_extract(e2.payload, '$.isError') as is_error,
  json_extract(e2.payload, '$.duration') as duration_ms,
  substr(e2.payload, 1, 300) as result_preview
FROM events e1
LEFT JOIN events e2 ON e2.session_id = e1.session_id
  AND e2.tool_call_id = e1.tool_call_id
  AND e2.type = 'tool.result'
WHERE e1.session_id = 'SESSION_ID'
  AND e1.type = 'tool.call'
  AND e1.turn > (SELECT MAX(turn) - 5 FROM events WHERE session_id = 'SESSION_ID')
ORDER BY e1.sequence;
```

### Failed tool calls specifically

```sql
SELECT e1.turn, e1.tool_name, datetime(e1.timestamp) as time,
  e2.payload as error_payload
FROM events e1
JOIN events e2 ON e2.session_id = e1.session_id
  AND e2.tool_call_id = e1.tool_call_id
  AND e2.type = 'tool.result'
WHERE e1.session_id = 'SESSION_ID'
  AND e1.type = 'tool.call'
  AND json_extract(e2.payload, '$.isError') = 1
ORDER BY e1.sequence;
```

## Step 6: Token Usage Pattern

```sql
SELECT turn, model, input_tokens, output_tokens,
  cache_read_tokens, cache_creation_tokens,
  latency_ms, datetime(timestamp) as time
FROM events
WHERE session_id = 'SESSION_ID'
  AND (input_tokens > 0 OR output_tokens > 0)
ORDER BY sequence;
```

Look for: sudden spikes in input_tokens (context blowup), high latency turns, cache miss patterns.

## Step 7: Check for Compaction Events

```sql
SELECT datetime(timestamp) as time, type,
  json_extract(payload, '$.reason') as reason,
  json_extract(payload, '$.originalTokens') as original_tokens,
  json_extract(payload, '$.compactedTokens') as compacted_tokens
FROM events
WHERE session_id = 'SESSION_ID'
  AND type IN ('compact.boundary', 'compact.summary')
ORDER BY sequence;
```

## Step 8: Write the Diagnostic Report (MANDATORY — do not skip)

```bash
mkdir -p ~/.tron/memory/reports
```

Write a markdown report to `~/.tron/memory/reports/YYYY-MM-DD-session-debug.md` using the current date. Use `date -u +%Y-%m-%d` for the date prefix. If multiple debug reports are needed on the same day, append a short disambiguator (e.g. `2026-03-31-session-debug-auth-failure.md`). **This step is not optional. Do not summarize findings only in chat. Write the file, then tell the user the path.**

### Report Template

```markdown
# Session Debug Report

**Generated**: {timestamp}
**Session ID**: {session_id}
**Title**: {title}
**Model**: {latest_model}
**Origin**: {origin}
**Workspace**: {workspace_path}
**Started**: {created_at}
**Last Activity**: {last_activity_at}
**Turns**: {turn_count} | **Events**: {event_count}
**Tokens**: {total_input_tokens} in / {total_output_tokens} out (cache read: {cache_read_tokens})
**Cost**: {total_cost}

---

## Recent Turn Timeline

| Turn | Type | Tool | Time | Tokens (in/out) | Latency |
|------|------|------|------|-----------------|---------|
{rows from step 3}

## Errors Found

### Event-Level Errors
{from step 4, or "None found"}

### Log-Level Warnings/Errors
{from step 4, or "None found"}

## Tool Call Analysis

**Total tool calls (last 5 turns)**: {count}
**Failed tool calls**: {count}

### Failed Tools
{table of failed tool calls with name, turn, error message — or "None"}

### All Tool Calls (Last 5 Turns)
| Turn | Tool | Duration | Error? |
|------|------|----------|--------|
{rows from step 5}

## Token Usage Pattern

| Turn | Model | Input | Output | Cache Read | Latency |
|------|-------|-------|--------|------------|---------|
{rows from step 6}

**Anomalies**: {note any spikes, unusual patterns, or "None detected"}

## Compaction Events

{from step 7, or "No compaction occurred"}

## Root Cause Hypothesis

{Your analysis based on all the data above — what likely went wrong and why}

## Suggested Next Steps

{Actionable recommendations based on your findings}
```

## Notes

- Always use `PRAGMA query_only = ON;` before queries for safety.
- The "Root Cause Hypothesis" and "Suggested Next Steps" sections are YOUR analysis after reviewing the query results — not SQL-derived.
- If no errors are found, still write the report but note the session appears healthy and suggest what else to check.
- **Write the report file first. Then tell the user the file path. Then give the verbal summary. In that order. Every time.**
