# Database Schema Reference

## Database

```bash
DB="$HOME/.tron/system/database/log.db"
sqlite3 "$DB" "PRAGMA query_only = ON;"  # safety: read-only
```

Sessions are distinguished by `origin` column: prod = `localhost:9847`, dev/beta = `localhost:9846`, iOS = `ios-client`.

## Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `sessions` | Session metadata, token aggregates, costs | id, origin, workspace_id, title, total_cost |
| `events` | Immutable append-only event log | session_id, type, sequence, turn, payload |
| `logs` | Structured logs (server + iOS client) | timestamp, level, component, origin, message |
| `blobs` | Content-addressable blob storage | hash, content, size_original, compression |
| `workspaces` | Project/directory associations | path, name |
| `branches` | Session branching support | session_id, root_event_id, head_event_id |
| `cron_jobs` | Scheduled job definitions | name, schedule_json, payload_json, enabled |
| `cron_runs` | Job execution records | job_id, status, duration_ms, error, session_id |
| `device_tokens` | iOS push notification tokens | device_token, platform, environment, is_active |
| `notification_read_state` | Read receipts for notifications | event_id, read_at |
| `schema_version` | Migration tracking | version, applied_at |

## sessions

Session metadata and token aggregates.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `workspace_id` | TEXT FK→workspaces | |
| `head_event_id` | TEXT | Latest event |
| `root_event_id` | TEXT | First event |
| `title` | TEXT | |
| `latest_model` | TEXT NOT NULL | Current LLM model |
| `working_directory` | TEXT NOT NULL | |
| `parent_session_id` | TEXT FK→sessions | Fork parent |
| `fork_from_event_id` | TEXT | Event branched from |
| `created_at` | TEXT NOT NULL | ISO8601 |
| `last_activity_at` | TEXT NOT NULL | ISO8601 |
| `ended_at` | TEXT | NULL if ongoing |
| `event_count` | INTEGER | Aggregate counter |
| `message_count` | INTEGER | Aggregate counter |
| `turn_count` | INTEGER | Aggregate counter |
| `total_input_tokens` | INTEGER | |
| `total_output_tokens` | INTEGER | |
| `last_turn_input_tokens` | INTEGER | |
| `total_cost` | REAL | USD |
| `total_cache_read_tokens` | INTEGER | Anthropic prompt cache |
| `total_cache_creation_tokens` | INTEGER | |
| `tags` | TEXT | JSON array |
| `spawning_session_id` | TEXT | Parent if spawned as subagent |
| `spawn_type` | TEXT | |
| `spawn_task` | TEXT | |
| `origin` | TEXT | `localhost:9847` (prod), `localhost:9846` (beta) |
| `source` | TEXT | Source identifier |

**Indexes**: workspace_id, last_activity_at DESC, parent_session_id, ended_at, created_at DESC, (spawning_session_id, ended_at), origin, source.

## events

Immutable append-only event log with denormalized indexed fields.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `session_id` | TEXT FK→sessions | |
| `parent_id` | TEXT FK→events | Event tree structure |
| `sequence` | INTEGER | Order within session (unique per session) |
| `depth` | INTEGER | Tree depth |
| `type` | TEXT NOT NULL | Event type (see Event Types below) |
| `timestamp` | TEXT NOT NULL | ISO8601 |
| `payload` | TEXT NOT NULL | JSON event payload |
| `content_blob_id` | TEXT FK→blobs | Large content in blob storage |
| `workspace_id` | TEXT NOT NULL | |
| `role` | TEXT | 'user' / 'assistant' / 'system' |
| `tool_name` | TEXT | Tool identifier |
| `tool_call_id` | TEXT | For tool call/result pairing |
| `turn` | INTEGER | Turn number within session |
| `input_tokens` | INTEGER | Per-event token count |
| `output_tokens` | INTEGER | |
| `cache_read_tokens` | INTEGER | Prompt cache hits |
| `cache_creation_tokens` | INTEGER | |
| `checksum` | TEXT | Payload hash |
| `model` | TEXT | LLM model for this event |
| `latency_ms` | INTEGER | Provider response latency |
| `stop_reason` | TEXT | Why model stopped |
| `has_thinking` | INTEGER | Extended thinking flag |
| `provider_type` | TEXT | 'anthropic', 'openai', etc. |
| `cost` | REAL | USD cost of this event |

**Indexes**: UNIQUE (session_id, sequence).

## blobs

Content-addressable storage with dedup via hash.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `hash` | TEXT UNIQUE | Content hash for dedup |
| `content` | BLOB NOT NULL | Actual data |
| `mime_type` | TEXT | Default 'text/plain' |
| `size_original` | INTEGER | Uncompressed bytes |
| `size_compressed` | INTEGER | Stored bytes |
| `compression` | TEXT | 'none', 'zlib', etc. |
| `created_at` | TEXT NOT NULL | |
| `ref_count` | INTEGER | Reference counting for GC |

## logs

Structured logs from server and iOS client.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK AUTO | |
| `timestamp` | TEXT NOT NULL | |
| `level` | TEXT NOT NULL | trace/debug/info/warn/error/fatal |
| `level_num` | INTEGER NOT NULL | 10/20/30/40/50/60 |
| `component` | TEXT NOT NULL | Module name; iOS prefixed `ios.*` |
| `message` | TEXT NOT NULL | |
| `session_id` | TEXT | Set for server logs, NULL for iOS |
| `workspace_id` | TEXT | |
| `event_id` | TEXT | Associated event |
| `turn` | INTEGER | |
| `data` | TEXT | JSON structured data |
| `error_message` | TEXT | |
| `error_stack` | TEXT | Stack trace |
| `trace_id` | TEXT | Distributed tracing |
| `parent_trace_id` | TEXT | |
| `depth` | INTEGER | |
| `origin` | TEXT | `localhost:9847` / `localhost:9846` / `ios-client` |

**iOS components**: `ios.WebSocket`, `ios.RPC`, `ios.Session`, `ios.Chat`, `ios.UI`, `ios.Network`, `ios.Events`, `ios.Notification`, `ios.General`, `ios.Database`, `ios.Audio`

## cron_jobs

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `name` | TEXT NOT NULL | |
| `description` | TEXT | |
| `enabled` | INTEGER | 0/1 |
| `schedule_json` | TEXT NOT NULL | Cron schedule definition |
| `payload_json` | TEXT NOT NULL | What to execute |
| `delivery_json` | TEXT | Delivery config (push, etc.) |
| `overlap_policy` | TEXT | 'skip' or 'allow' |
| `misfire_policy` | TEXT | 'skip' or 'run_once' |
| `max_retries` | INTEGER | |
| `auto_disable_after` | INTEGER | Failed attempts before auto-disable |
| `stuck_timeout_secs` | INTEGER | Deadman switch (default 7200) |
| `tags` | TEXT | JSON array |
| `workspace_id` | TEXT | |
| `tool_restrictions_json` | TEXT | Tool allowlist |
| `next_run_at` | TEXT | Scheduler runtime state |
| `last_run_at` | TEXT | Scheduler runtime state |
| `consecutive_failures` | INTEGER | Scheduler runtime state |
| `running_since` | TEXT | Scheduler runtime state |
| `created_at` | TEXT | |
| `updated_at` | TEXT | |

## cron_runs

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `job_id` | TEXT FK→cron_jobs | SET NULL on delete |
| `job_name` | TEXT NOT NULL | |
| `status` | TEXT | running/completed/failed/timed_out/skipped/cancelled |
| `started_at` | TEXT | |
| `completed_at` | TEXT | |
| `duration_ms` | INTEGER | |
| `output` | TEXT | |
| `output_truncated` | INTEGER | |
| `error` | TEXT | |
| `exit_code` | INTEGER | |
| `attempt` | INTEGER | |
| `session_id` | TEXT | Agent session spawned for this run |
| `delivery_status` | TEXT | Push notification delivery result |
| `created_at` | TEXT | |

## Other Tables

**branches**: `id`, `session_id` FK, `name`, `description`, `root_event_id` FK, `head_event_id` FK, `is_default`, `created_at`, `last_activity_at`

**workspaces**: `id`, `path` (UNIQUE), `name`, `created_at`, `last_activity_at`

**device_tokens**: `id`, `device_token`, `session_id` FK, `workspace_id` FK, `platform` (default 'ios'), `environment` (default 'production'), `created_at`, `last_used_at`, `is_active`. UNIQUE(device_token, platform).

**notification_read_state**: `event_id` PK, `read_at`

---

## Event Types (50 variants)

Stored in `events.type`. Each has a typed JSON payload.

| Category | Types |
|----------|-------|
| Session | `session.start`, `session.end`, `session.fork` |
| Messages | `message.user`, `message.assistant`, `message.system`, `message.deleted` |
| Tools | `tool.call`, `tool.result` |
| Streaming | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| Config | `config.model_switch`, `config.prompt_update`, `config.reasoning_level` |
| Notifications | `notification.interrupted`, `notification.subagent_result`, `subagent.results_consumed` |
| Compaction | `compact.boundary`, `compact.summary` |
| Context | `context.cleared` |
| Skills | `skill.activated`, `skill.deactivated`, `skills.cleared` |
| Rules | `rules.loaded`, `rules.indexed`, `rules.activated` |
| Metadata | `metadata.update`, `metadata.tag` |
| Files | `file.read`, `file.write`, `file.edit` |
| Worktree | `worktree.acquired`, `worktree.commit`, `worktree.released`, `worktree.merged` |
| Errors | `error.agent`, `error.tool`, `error.provider` |
| Subagent | `subagent.spawned`, `subagent.status_update`, `subagent.completed`, `subagent.failed` |
| Todo | `todo.write` |
| Turn | `turn.failed` |
| Hooks | `hook.triggered`, `hook.completed`, `hook.background_started`, `hook.background_completed` |
| Memory | `memory.retained` |

---

## Settings Schema

Settings live at `~/.tron/system/settings.json`. All keys are camelCase. Missing fields get defaults.

### Root Sections

| Section | Purpose |
|---------|---------|
| `server` | Network, model, workspace, connection presets |
| `context` | Compaction settings, rules discovery |
| `agent` | Max turns, subagent depth/model |
| `tools` | Per-tool settings (bash, read, find, search, web, browser, computerUse) |
| `logging` | DB log level, module overrides |
| `hooks` | Timeout, discovery, project/user dirs |
| `session` | Worktree isolation, chat settings, cache TTL |
| `api` | Provider auth config (Anthropic, OpenAI, Google, MiniMax, Kimi) |
| `ui` | Theme, palette, icons, input, animation |
| `mcp` | MCP server configuration (array of servers) |
| `retry` | API retry config (max retries, delays, jitter) |
| `tmux` | Tmux integration (command timeout, polling interval) |
| `guardrails` | Optional safety rules, custom rules, audit |

### server

| Key | Default | Description |
|-----|---------|-------------|
| `defaultModel` | `"claude-sonnet-4-6"` | Default LLM model |
| `defaultProvider` | `"anthropic"` | Default LLM provider |
| `defaultWorkspace` | null | Default workspace path |
| `heartbeatIntervalMs` | 30000 | WebSocket heartbeat interval |
| `sessionsDir` | `"sessions"` | Session data directory |
| `memoryDbPath` | `"memory.db"` | Memory database path |
| `transcription.enabled` | true | Audio transcription |
| `connectionPresets` | [] | Array of {id, label, host, port} |

### agent

| Key | Default | Description |
|-----|---------|-------------|
| `maxTurns` | 250 | Max agentic turns per prompt |
| `subagentMaxDepth` | 3 | Max subagent nesting |
| `subagentModel` | `"claude-haiku-4-5-20251001"` | Default subagent model |

### context.compactor

| Key | Default | Description |
|-----|---------|-------------|
| `maxTokens` | 25000 | Max token budget for summarized context |
| `compactionThreshold` | 0.85 | Context window usage ratio that triggers compaction |
| `targetTokens` | 10000 | Target token count after compaction |
| `charsPerToken` | 4 | Approximate characters per token for estimation |
| `bufferTokens` | 4000 | Token buffer reserved for responses |
| `triggerTokenThreshold` | 0.70 | Context usage ratio trigger; also used as preserved-turn budget |
| `preserveRecentCount` | 5 | Recent messages to preserve during compaction |

### logging

| Key | Default | Description |
|-----|---------|-------------|
| `dbLogLevel` | `"info"` | Minimum log level for DB |
| `moduleOverrides` | `{"ort": "error"}` | Per-module level overrides |

---

## Runtime Files

| Path | Purpose |
|------|---------|
| `~/.tron/system/run/auth.lock` | Auth serialization lock |
| `~/.tron/system/run/.mac-wrapper.lock` | Mac wrapper single-instance lock |
| `~/.tron/system/run/.onboarded` | First-run sentinel |
| `~/.tron/system/run/updater-state.json` | Update-check scheduler state |
| `~/.tron/system/database/log.db.lock` | SQLite process lock beside `log.db` |

## Health Endpoints

```bash
# Basic health
curl -s http://localhost:9847/health | jq .
# Response: { status, uptime_secs, connections, active_sessions }

# Deep health (all subsystem checks)
curl -s http://localhost:9847/health/deep | jq .
# Response: { status, uptimeSecs, connections, activeSessions, checks: [{name, status, detail}] }

```
