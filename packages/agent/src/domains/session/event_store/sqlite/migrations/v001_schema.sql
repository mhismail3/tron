-- v001: Primitive fresh schema.
--
-- This branch is a clean break. Fresh databases contain only the stores needed
-- to boot the agent loop, reconstruct bare sessions, persist invocation
-- history, retain agent-owned blobs, and capture server/client logs.

CREATE TABLE IF NOT EXISTS schema_version (
  version     INTEGER PRIMARY KEY,
  applied_at  TEXT    NOT NULL,
  description TEXT
);

CREATE TABLE IF NOT EXISTS workspaces (
  id               TEXT PRIMARY KEY,
  path             TEXT NOT NULL UNIQUE,
  name             TEXT,
  created_at       TEXT NOT NULL,
  last_activity_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);

CREATE TABLE IF NOT EXISTS sessions (
  id                          TEXT PRIMARY KEY,
  workspace_id                TEXT NOT NULL REFERENCES workspaces(id),
  head_event_id               TEXT,
  root_event_id               TEXT,
  title                       TEXT,
  latest_model                TEXT NOT NULL,
  working_directory           TEXT NOT NULL,
  parent_session_id           TEXT REFERENCES sessions(id),
  fork_from_event_id          TEXT,
  created_at                  TEXT NOT NULL,
  last_activity_at            TEXT NOT NULL,
  ended_at                    TEXT,
  event_count                 INTEGER NOT NULL DEFAULT 0,
  message_count               INTEGER NOT NULL DEFAULT 0,
  turn_count                  INTEGER NOT NULL DEFAULT 0,
  total_input_tokens          INTEGER NOT NULL DEFAULT 0,
  total_output_tokens         INTEGER NOT NULL DEFAULT 0,
  last_turn_input_tokens      INTEGER NOT NULL DEFAULT 0,
  total_cost                  REAL    NOT NULL DEFAULT 0,
  total_cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
  tags                        TEXT    NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_activity  ON sessions(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent    ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_ended     ON sessions(ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_created   ON sessions(created_at DESC);

CREATE TABLE IF NOT EXISTS events (
  id                    TEXT    PRIMARY KEY,
  session_id            TEXT    NOT NULL REFERENCES sessions(id),
  parent_id             TEXT    REFERENCES events(id),
  sequence              INTEGER NOT NULL,
  depth                 INTEGER NOT NULL DEFAULT 0,
  type                  TEXT    NOT NULL,
  timestamp             TEXT    NOT NULL,
  payload               TEXT    NOT NULL,
  content_blob_id       TEXT    REFERENCES blobs(id),
  workspace_id          TEXT    NOT NULL,
  role                  TEXT,
  model_primitive_name  TEXT,
  invocation_id         TEXT,
  turn                  INTEGER,
  input_tokens          INTEGER,
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  checksum              TEXT,
  model                 TEXT,
  latency_ms            INTEGER,
  stop_reason           TEXT,
  has_thinking          INTEGER,
  provider_type         TEXT,
  cost                  REAL,
  CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique
  ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);

CREATE TABLE IF NOT EXISTS blobs (
  id              TEXT    PRIMARY KEY,
  hash            TEXT    NOT NULL UNIQUE,
  content         BLOB    NOT NULL,
  mime_type       TEXT    NOT NULL DEFAULT 'text/plain',
  uncompressed_size INTEGER NOT NULL,
  size_compressed INTEGER NOT NULL,
  compression     TEXT    NOT NULL DEFAULT 'none',
  created_at      TEXT    NOT NULL,
  ref_count       INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_blobs_hash      ON blobs(hash);
CREATE INDEX IF NOT EXISTS idx_blobs_ref_count ON blobs(ref_count) WHERE ref_count <= 0;

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
  depth           INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_logs_client_dedup
  ON logs(timestamp, component, message)
  WHERE component LIKE 'ios.%';

CREATE TABLE IF NOT EXISTS trace_records (
  id                         TEXT    PRIMARY KEY,
  trace_id                   TEXT    NOT NULL,
  invocation_id              TEXT    NOT NULL,
  parent_invocation_id       TEXT,
  provider_invocation_id     TEXT,
  session_id                 TEXT,
  workspace_id               TEXT,
  turn                       INTEGER,
  model_primitive_name       TEXT    NOT NULL,
  operation                  TEXT    NOT NULL,
  status                     TEXT    NOT NULL,
  timestamp                  TEXT    NOT NULL,
  completed_at               TEXT,
  duration_ms                INTEGER,
  record_json                TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trace_records_trace
  ON trace_records(trace_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_trace_records_session
  ON trace_records(session_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_trace_records_invocation
  ON trace_records(invocation_id);
