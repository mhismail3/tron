-- v001: Complete schema — fresh from first principles
--
-- Tables: workspaces, sessions, events, blobs, branches,
--         logs, device_tokens, projects, tasks, task_dependencies,
--         task_activity, task_backlog, areas
-- FTS:    events_fts, logs_fts, tasks_fts, areas_fts
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
  origin                     TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_workspace   ON sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_activity    ON sessions(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent      ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_ended       ON sessions(ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_created     ON sessions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_spawning    ON sessions(spawning_session_id, ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_origin      ON sessions(origin);

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

CREATE INDEX IF NOT EXISTS idx_events_session_seq       ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_parent            ON events(parent_id);
CREATE INDEX IF NOT EXISTS idx_events_type              ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_timestamp         ON events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_workspace         ON events(workspace_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_tool_call_id      ON events(tool_call_id) WHERE tool_call_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_message_preview   ON events(session_id, type, sequence DESC)
  WHERE type IN ('message.user', 'message.assistant');
CREATE INDEX IF NOT EXISTS idx_events_session_covering  ON events(session_id, sequence, type, timestamp, parent_id);
CREATE INDEX IF NOT EXISTS idx_events_model             ON events(session_id, model) WHERE model IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_latency           ON events(session_id, latency_ms) WHERE latency_ms IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique ON events(session_id, sequence);

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

CREATE INDEX IF NOT EXISTS idx_logs_timestamp      ON logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_session_time   ON logs(session_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_level_time     ON logs(level_num, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_component_time ON logs(component, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_event          ON logs(event_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_logs_workspace_time ON logs(workspace_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_trace_id       ON logs(trace_id);
CREATE INDEX IF NOT EXISTS idx_logs_parent_trace   ON logs(parent_trace_id);
CREATE INDEX IF NOT EXISTS idx_logs_origin         ON logs(origin);

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
-- Task Management (PARA: Projects, Areas, Tasks)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Areas (ongoing responsibilities)
CREATE TABLE IF NOT EXISTS areas (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL DEFAULT 'default',
  title        TEXT NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'active',
  tags         TEXT NOT NULL DEFAULT '[]',
  sort_order   REAL NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  metadata     TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_areas_workspace ON areas(workspace_id);
CREATE INDEX IF NOT EXISTS idx_areas_status    ON areas(status);

-- Projects (time-bound initiatives under areas)
CREATE TABLE IF NOT EXISTS projects (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
  area_id      TEXT REFERENCES areas(id)      ON DELETE SET NULL,
  title        TEXT NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'active',
  tags         TEXT NOT NULL DEFAULT '[]',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  completed_at TEXT,
  metadata     TEXT
);

CREATE INDEX IF NOT EXISTS idx_projects_workspace ON projects(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_projects_status    ON projects(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_projects_area      ON projects(area_id);

-- Tasks (actionable items)
CREATE TABLE IF NOT EXISTS tasks (
  id                    TEXT    PRIMARY KEY,
  project_id            TEXT    REFERENCES projects(id) ON DELETE SET NULL,
  parent_task_id        TEXT    REFERENCES tasks(id)    ON DELETE CASCADE,
  workspace_id          TEXT    REFERENCES workspaces(id) ON DELETE SET NULL,
  area_id               TEXT    REFERENCES areas(id)    ON DELETE SET NULL,
  title                 TEXT    NOT NULL,
  description           TEXT,
  active_form           TEXT,
  notes                 TEXT,
  status                TEXT    NOT NULL DEFAULT 'pending',
  priority              TEXT    NOT NULL DEFAULT 'medium',
  source                TEXT    NOT NULL DEFAULT 'agent',
  tags                  TEXT    NOT NULL DEFAULT '[]',
  due_date              TEXT,
  deferred_until        TEXT,
  started_at            TEXT,
  completed_at          TEXT,
  created_at            TEXT    NOT NULL,
  updated_at            TEXT    NOT NULL,
  estimated_minutes     INTEGER,
  actual_minutes        INTEGER NOT NULL DEFAULT 0,
  created_by_session_id TEXT,
  last_session_id       TEXT,
  last_session_at       TEXT,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  metadata              TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_project      ON tasks(project_id, status, sort_order);
CREATE INDEX IF NOT EXISTS idx_tasks_parent       ON tasks(parent_task_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_tasks_workspace    ON tasks(workspace_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_status       ON tasks(status, priority DESC, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_due          ON tasks(due_date, status);
CREATE INDEX IF NOT EXISTS idx_tasks_deferred     ON tasks(deferred_until);
CREATE INDEX IF NOT EXISTS idx_tasks_session      ON tasks(created_by_session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_last_session ON tasks(last_session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_area         ON tasks(area_id);

-- Task dependencies (blocking relationships)
CREATE TABLE IF NOT EXISTS task_dependencies (
  blocker_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  blocked_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  relationship    TEXT NOT NULL DEFAULT 'blocks',
  created_at      TEXT NOT NULL,
  PRIMARY KEY (blocker_task_id, blocked_task_id),
  CHECK (blocker_task_id != blocked_task_id)
);

CREATE INDEX IF NOT EXISTS idx_deps_blocked ON task_dependencies(blocked_task_id);

-- Task activity (append-only audit trail)
CREATE TABLE IF NOT EXISTS task_activity (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id        TEXT    NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  session_id     TEXT,
  event_id       TEXT,
  action         TEXT    NOT NULL,
  old_value      TEXT,
  new_value      TEXT,
  detail         TEXT,
  minutes_logged INTEGER,
  timestamp      TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_task      ON task_activity(task_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_activity_session   ON task_activity(session_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_activity_timestamp ON task_activity(timestamp DESC);

-- Task backlog (persisted incomplete tasks across sessions)
CREATE TABLE IF NOT EXISTS task_backlog (
  id                     TEXT PRIMARY KEY,
  workspace_id           TEXT NOT NULL REFERENCES workspaces(id),
  source_session_id      TEXT NOT NULL REFERENCES sessions(id),
  content                TEXT NOT NULL,
  active_form            TEXT NOT NULL,
  status                 TEXT NOT NULL,
  source                 TEXT NOT NULL,
  created_at             TEXT NOT NULL,
  completed_at           TEXT,
  backlogged_at          TEXT NOT NULL,
  backlog_reason         TEXT NOT NULL,
  metadata               TEXT,
  restored_to_session_id TEXT,
  restored_at            TEXT
);

CREATE INDEX IF NOT EXISTS idx_backlog_workspace ON task_backlog(workspace_id, backlogged_at DESC);
CREATE INDEX IF NOT EXISTS idx_backlog_status    ON task_backlog(status, restored_to_session_id);
CREATE INDEX IF NOT EXISTS idx_backlog_session   ON task_backlog(source_session_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Full-Text Search
-- ═══════════════════════════════════════════════════════════════════════════════

-- Events FTS
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
  id UNINDEXED, session_id UNINDEXED, type, content, tool_name,
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS events_fts_insert
AFTER INSERT ON events
BEGIN
  INSERT INTO events_fts (id, session_id, type, content, tool_name)
  VALUES (
    NEW.id,
    NEW.session_id,
    NEW.type,
    CASE WHEN json_valid(NEW.payload)
      THEN COALESCE(json_extract(NEW.payload, '$.content'), '')
      ELSE ''
    END,
    COALESCE(
      NEW.tool_name,
      CASE WHEN json_valid(NEW.payload)
        THEN COALESCE(
          json_extract(NEW.payload, '$.toolName'),
          json_extract(NEW.payload, '$.name')
        )
        ELSE NULL
      END,
      ''
    )
  );
END;

CREATE TRIGGER IF NOT EXISTS events_fts_delete
AFTER DELETE ON events
BEGIN
  DELETE FROM events_fts WHERE id = OLD.id;
END;

-- Logs FTS
CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
  log_id UNINDEXED, session_id UNINDEXED, component, message, error_message,
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS logs_fts_insert
AFTER INSERT ON logs
BEGIN
  INSERT INTO logs_fts (log_id, session_id, component, message, error_message)
  VALUES (
    NEW.id,
    NEW.session_id,
    NEW.component,
    NEW.message,
    COALESCE(NEW.error_message, '')
  );
END;

CREATE TRIGGER IF NOT EXISTS logs_fts_delete
AFTER DELETE ON logs
BEGIN
  DELETE FROM logs_fts WHERE log_id = OLD.id;
END;

-- Tasks FTS
CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
  task_id UNINDEXED, title, description, notes, tags,
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS tasks_fts_insert
AFTER INSERT ON tasks
BEGIN
  INSERT INTO tasks_fts (task_id, title, description, notes, tags)
  VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.notes, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_update
AFTER UPDATE ON tasks
BEGIN
  DELETE FROM tasks_fts WHERE task_id = OLD.id;
  INSERT INTO tasks_fts (task_id, title, description, notes, tags)
  VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.notes, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_delete
AFTER DELETE ON tasks
BEGIN
  DELETE FROM tasks_fts WHERE task_id = OLD.id;
END;

-- Areas FTS
CREATE VIRTUAL TABLE IF NOT EXISTS areas_fts USING fts5(
  area_id UNINDEXED, title, description, tags,
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS areas_fts_insert
AFTER INSERT ON areas
BEGIN
  INSERT INTO areas_fts (area_id, title, description, tags)
  VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.tags, '[]'));
END;

CREATE TRIGGER IF NOT EXISTS areas_fts_update
AFTER UPDATE ON areas
BEGIN
  DELETE FROM areas_fts WHERE area_id = OLD.id;
  INSERT INTO areas_fts (area_id, title, description, tags)
  VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.tags, '[]'));
END;

CREATE TRIGGER IF NOT EXISTS areas_fts_delete
AFTER DELETE ON areas
BEGIN
  DELETE FROM areas_fts WHERE area_id = OLD.id;
END;
