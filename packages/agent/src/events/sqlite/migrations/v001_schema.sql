-- v001: Consolidated schema — single source of truth
--
-- Tables: workspaces, sessions, events, blobs, branches,
--         logs, device_tokens, notification_read_state, cron_jobs, cron_runs
-- Meta:   schema_version

-- ═══════════════════════════════════════════════════════════════════════════════
-- Schema Version Tracking
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS schema_version (
  version     INTEGER PRIMARY KEY,
  applied_at  TEXT    NOT NULL,
  description TEXT
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Core Event Sourcing
-- ═══════════════════════════════════════════════════════════════════════════════

-- Workspaces (project/directory contexts)
CREATE TABLE IF NOT EXISTS workspaces (
  id               TEXT PRIMARY KEY,
  path             TEXT NOT NULL UNIQUE,
  name             TEXT,
  created_at       TEXT NOT NULL,
  last_activity_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);

-- Sessions (pointers into event tree + aggregate counters)
CREATE TABLE IF NOT EXISTS sessions (
  id                         TEXT PRIMARY KEY,
  workspace_id               TEXT NOT NULL REFERENCES workspaces(id),
  head_event_id              TEXT,
  root_event_id              TEXT,
  title                      TEXT,
  latest_model               TEXT NOT NULL,
  working_directory          TEXT NOT NULL,
  parent_session_id          TEXT REFERENCES sessions(id),
  fork_from_event_id         TEXT,
  created_at                 TEXT NOT NULL,
  last_activity_at           TEXT NOT NULL,
  ended_at                   TEXT,
  event_count                INTEGER NOT NULL DEFAULT 0,
  message_count              INTEGER NOT NULL DEFAULT 0,
  turn_count                 INTEGER NOT NULL DEFAULT 0,
  total_input_tokens         INTEGER NOT NULL DEFAULT 0,
  total_output_tokens        INTEGER NOT NULL DEFAULT 0,
  last_turn_input_tokens     INTEGER NOT NULL DEFAULT 0,
  total_cost                 REAL    NOT NULL DEFAULT 0,
  total_cache_read_tokens    INTEGER NOT NULL DEFAULT 0,
  total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
  tags                       TEXT NOT NULL DEFAULT '[]',
  spawning_session_id        TEXT,
  spawn_type                 TEXT,
  spawn_task                 TEXT,
  origin                     TEXT,
  source                     TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_workspace   ON sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_activity    ON sessions(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent      ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_ended       ON sessions(ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_created     ON sessions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_spawning    ON sessions(spawning_session_id, ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_origin      ON sessions(origin);
CREATE INDEX IF NOT EXISTS idx_sessions_source      ON sessions(source);

-- Events (immutable append-only log — heart of event sourcing)
CREATE TABLE IF NOT EXISTS events (
  id                   TEXT    PRIMARY KEY,
  session_id           TEXT    NOT NULL REFERENCES sessions(id),
  parent_id            TEXT    REFERENCES events(id),
  sequence             INTEGER NOT NULL,
  depth                INTEGER NOT NULL DEFAULT 0,
  type                 TEXT    NOT NULL,
  timestamp            TEXT    NOT NULL,
  payload              TEXT    NOT NULL,
  content_blob_id      TEXT    REFERENCES blobs(id),
  workspace_id         TEXT    NOT NULL,
  -- Denormalized fields extracted from payload for indexed queries
  role                 TEXT,
  tool_name            TEXT,
  tool_call_id         TEXT,
  turn                 INTEGER,
  input_tokens         INTEGER,
  output_tokens        INTEGER,
  cache_read_tokens    INTEGER,
  cache_creation_tokens INTEGER,
  checksum             TEXT,
  -- Per-turn metadata (queryable indexed columns for fields in payload)
  model                TEXT,
  latency_ms           INTEGER,
  stop_reason          TEXT,
  has_thinking         INTEGER,
  provider_type        TEXT,
  cost                 REAL
);

-- Minimal indexes: only what's needed for correctness (unique constraint)
-- and the primary access pattern (session event ordering).
-- All other queries can scan/filter at our volumes.
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);

-- Blobs (content-addressable deduplicated storage)
CREATE TABLE IF NOT EXISTS blobs (
  id              TEXT    PRIMARY KEY,
  hash            TEXT    NOT NULL UNIQUE,
  content         BLOB    NOT NULL,
  mime_type       TEXT    NOT NULL DEFAULT 'text/plain',
  size_original   INTEGER NOT NULL,
  size_compressed INTEGER NOT NULL,
  compression     TEXT    NOT NULL DEFAULT 'none',
  created_at      TEXT    NOT NULL,
  ref_count       INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_blobs_hash      ON blobs(hash);
CREATE INDEX IF NOT EXISTS idx_blobs_ref_count ON blobs(ref_count) WHERE ref_count <= 0;

-- Branches (named positions in the event tree)
CREATE TABLE IF NOT EXISTS branches (
  id               TEXT    PRIMARY KEY,
  session_id       TEXT    NOT NULL REFERENCES sessions(id),
  name             TEXT    NOT NULL,
  description      TEXT,
  root_event_id    TEXT    NOT NULL REFERENCES events(id),
  head_event_id    TEXT    NOT NULL REFERENCES events(id),
  is_default       INTEGER NOT NULL DEFAULT 0,
  created_at       TEXT    NOT NULL,
  last_activity_at TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_branches_session ON branches(session_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Logging
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS logs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp       TEXT    NOT NULL,
  level           TEXT    NOT NULL,
  level_num       INTEGER NOT NULL,
  component       TEXT    NOT NULL,
  message         TEXT    NOT NULL,
  session_id      TEXT,
  workspace_id    TEXT,
  event_id        TEXT,
  turn            INTEGER,
  data            TEXT,
  error_message   TEXT,
  error_stack     TEXT,
  trace_id        TEXT,
  parent_trace_id TEXT,
  depth           INTEGER NOT NULL DEFAULT 0,
  origin          TEXT
);

-- No query indexes on logs — scan/filter is sufficient at our volumes.
-- Only the dedup constraint for iOS client log replay.
CREATE UNIQUE INDEX IF NOT EXISTS idx_logs_ios_client_dedup
  ON logs(timestamp, component, message)
  WHERE origin = 'ios-client';

-- ═══════════════════════════════════════════════════════════════════════════════
-- Device Tokens (push notifications)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS device_tokens (
  id           TEXT PRIMARY KEY,
  device_token TEXT NOT NULL,
  session_id   TEXT REFERENCES sessions(id),
  workspace_id TEXT REFERENCES workspaces(id),
  platform     TEXT NOT NULL DEFAULT 'ios',
  environment  TEXT NOT NULL DEFAULT 'production',
  created_at   TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  is_active    INTEGER NOT NULL DEFAULT 1,
  UNIQUE(device_token, platform)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_session   ON device_tokens(session_id)   WHERE is_active = 1;
CREATE INDEX IF NOT EXISTS idx_device_tokens_workspace ON device_tokens(workspace_id) WHERE is_active = 1;
CREATE INDEX IF NOT EXISTS idx_device_tokens_token     ON device_tokens(device_token);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Notification Read State
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS notification_read_state (
    event_id TEXT PRIMARY KEY,
    read_at  TEXT NOT NULL
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Cron Scheduling
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS cron_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    schedule_json TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    delivery_json TEXT NOT NULL DEFAULT '[]',
    overlap_policy TEXT NOT NULL DEFAULT 'skip'
        CHECK(overlap_policy IN ('skip', 'allow')),
    misfire_policy TEXT NOT NULL DEFAULT 'skip'
        CHECK(misfire_policy IN ('skip', 'run_once')),
    max_retries INTEGER NOT NULL DEFAULT 0,
    auto_disable_after INTEGER NOT NULL DEFAULT 0,
    stuck_timeout_secs INTEGER NOT NULL DEFAULT 7200,
    tags TEXT NOT NULL DEFAULT '[]',
    workspace_id TEXT,
    tool_restrictions_json TEXT,
    -- Runtime state (scheduler-managed, NOT from config file)
    next_run_at TEXT,
    last_run_at TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    running_since TEXT,
    -- Timestamps
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cron_jobs_enabled_next
    ON cron_jobs(enabled, next_run_at) WHERE enabled = 1;

CREATE TABLE IF NOT EXISTS cron_runs (
    id TEXT PRIMARY KEY,
    job_id TEXT REFERENCES cron_jobs(id) ON DELETE SET NULL,
    job_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK(status IN ('running', 'completed', 'failed', 'timed_out', 'skipped', 'cancelled')),
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    duration_ms INTEGER,
    output TEXT,
    output_truncated INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    exit_code INTEGER,
    attempt INTEGER NOT NULL DEFAULT 0,
    session_id TEXT,
    delivery_status TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cron_runs_job_started
    ON cron_runs(job_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_cron_runs_status
    ON cron_runs(status) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS idx_cron_runs_created
    ON cron_runs(created_at);

