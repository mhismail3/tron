-- Current event-store schema.
--
-- Databases contain only the stores needed
-- to boot the agent loop, reconstruct bare sessions, persist invocation
-- history, retain agent-owned blobs, and capture server/client logs.

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

-- Agent deliveries are durable reference context addressed to either one
-- session or one logical mailbox. They deliberately live beside session truth:
-- the EventStore can create a visible session and seed its first delivery in
-- one transaction, and session deletion can revoke every associated grant.
CREATE TABLE IF NOT EXISTS agent_deliveries (
  delivery_id                TEXT    PRIMARY KEY,
  idempotency_key            TEXT    NOT NULL UNIQUE,
  source_kind                TEXT    NOT NULL
    CHECK (source_kind IN ('worker_result','agent_message','continuity')),
  intent                     TEXT
    CHECK (intent IS NULL OR intent IN ('information','request')),
  source_session_id          TEXT    REFERENCES sessions(id) ON DELETE SET NULL,
  source_workspace_id        TEXT    NOT NULL,
  source_invocation_id       TEXT,
  source_trace_id            TEXT,
  source_root_invocation_id  TEXT,
  causal_depth               INTEGER NOT NULL DEFAULT 0 CHECK (causal_depth >= 0),
  target_kind                TEXT    NOT NULL CHECK (target_kind IN ('session','mailbox')),
  target_session_id          TEXT    REFERENCES sessions(id) ON DELETE CASCADE,
  mailbox_scope              TEXT
    CHECK (mailbox_scope IS NULL OR mailbox_scope IN ('workspace','profile')),
  mailbox_workspace_id       TEXT    REFERENCES workspaces(id) ON DELETE CASCADE,
  mailbox_name               TEXT,
  wake_policy                TEXT    NOT NULL CHECK (wake_policy IN ('passive','wake')),
  boundary                   TEXT    NOT NULL CHECK (boundary IN ('next_turn','next_run')),
  originating_run_id         TEXT,
  arrived_during_run_id      TEXT,
  defer_until_run_id         TEXT,
  result_invocation_id       TEXT,
  content                    TEXT    NOT NULL,
  not_before                 TEXT,
  expires_at                 TEXT,
  disposition                TEXT    NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','observed','cancelled','stale')),
  leased_run_id              TEXT,
  leased_turn                INTEGER,
  lease_count                INTEGER NOT NULL DEFAULT 0 CHECK (lease_count >= 0),
  wake_attempts              INTEGER NOT NULL DEFAULT 0 CHECK (wake_attempts >= 0),
  next_wake_at               TEXT,
  last_error                 TEXT,
  created_at                 TEXT    NOT NULL,
  claimed_at                 TEXT,
  observed_at                TEXT,
  cancelled_at               TEXT,
  CHECK (
    (target_kind='session' AND target_session_id IS NOT NULL
      AND mailbox_scope IS NULL AND mailbox_workspace_id IS NULL
      AND mailbox_name IS NULL)
    OR
    (target_kind='mailbox' AND target_session_id IS NULL
      AND mailbox_scope IS NOT NULL AND mailbox_name IS NOT NULL)
  ),
  CHECK (
    (mailbox_scope='workspace' AND mailbox_workspace_id IS NOT NULL)
    OR (mailbox_scope='profile' AND mailbox_workspace_id IS NULL)
    OR mailbox_scope IS NULL
  ),
  CHECK (target_kind!='mailbox' OR wake_policy='passive'),
  CHECK (
    (leased_run_id IS NULL AND leased_turn IS NULL)
    OR (leased_run_id IS NOT NULL AND leased_turn IS NOT NULL
      AND disposition='pending')
  ),
  CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 40000)
);

CREATE INDEX IF NOT EXISTS idx_agent_deliveries_session_pending
  ON agent_deliveries(target_session_id, disposition, not_before, created_at, delivery_id);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_wake_due
  ON agent_deliveries(wake_policy, disposition, next_wake_at, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_mailbox
  ON agent_deliveries(
    mailbox_scope,
    mailbox_workspace_id,
    mailbox_name,
    disposition,
    created_at
  );
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_result_grant
  ON agent_deliveries(result_invocation_id, target_session_id, disposition);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_lease
  ON agent_deliveries(leased_run_id, disposition);

CREATE TABLE IF NOT EXISTS agent_waits (
  wait_id          TEXT PRIMARY KEY,
  idempotency_key  TEXT NOT NULL UNIQUE,
  session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_invocation_id TEXT NOT NULL,
  source_trace_id  TEXT NOT NULL,
  source_root_invocation_id TEXT,
  causal_depth     INTEGER NOT NULL CHECK (causal_depth >= 0 AND causal_depth <= 4294967295),
  mode             TEXT NOT NULL CHECK (mode IN ('all','any')),
  disposition      TEXT NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','satisfied','cancelled')),
  delivery_id      TEXT REFERENCES agent_deliveries(delivery_id) ON DELETE SET NULL,
  created_at       TEXT NOT NULL,
  resolved_at      TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_waits_pending
  ON agent_waits(disposition, session_id, created_at);

CREATE TABLE IF NOT EXISTS agent_wait_members (
  wait_id              TEXT NOT NULL REFERENCES agent_waits(wait_id) ON DELETE CASCADE,
  invocation_id        TEXT NOT NULL,
  ordinal              INTEGER NOT NULL,
  disposition          TEXT NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','satisfied','ignored')),
  terminal_status      TEXT,
  terminal_evidence    TEXT,
  resolved_at          TEXT,
  PRIMARY KEY(wait_id, invocation_id),
  UNIQUE(wait_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_agent_wait_members_invocation
  ON agent_wait_members(invocation_id, disposition, wait_id);

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
  tool_name  TEXT,
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
