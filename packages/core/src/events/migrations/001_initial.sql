-- Event-Sourced Session Tree Schema
-- Migration 001: Initial schema
-- Version: 1.0.0

-- =============================================================================
-- WORKSPACES TABLE
-- Tracks project/directory contexts
-- =============================================================================
CREATE TABLE IF NOT EXISTS workspaces (
  id TEXT PRIMARY KEY,                    -- 'ws_' + UUID
  path TEXT NOT NULL UNIQUE,              -- Absolute path (canonical)
  name TEXT,                              -- Project name (derived or explicit)
  created_at TEXT NOT NULL,               -- ISO 8601 timestamp
  last_activity_at TEXT NOT NULL          -- ISO 8601 timestamp
);

CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);
CREATE INDEX IF NOT EXISTS idx_workspaces_activity ON workspaces(last_activity_at DESC);

-- =============================================================================
-- SESSIONS TABLE
-- Pointers to head nodes in the event tree
-- =============================================================================
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,                    -- 'sess_' + 12-char UUID
  workspace_id TEXT NOT NULL REFERENCES workspaces(id),
  head_event_id TEXT,                     -- Current position in tree
  root_event_id TEXT,                     -- First event in this session's tree

  -- Denormalized for fast queries
  title TEXT,
  status TEXT NOT NULL DEFAULT 'active',  -- 'active', 'ended', 'archived'
  model TEXT NOT NULL,
  provider TEXT NOT NULL,
  working_directory TEXT NOT NULL,

  -- Fork tracking
  parent_session_id TEXT REFERENCES sessions(id),
  fork_from_event_id TEXT,

  -- Timestamps
  created_at TEXT NOT NULL,
  last_activity_at TEXT NOT NULL,
  ended_at TEXT,

  -- Aggregates (updated on event insert)
  event_count INTEGER DEFAULT 0,
  message_count INTEGER DEFAULT 0,
  turn_count INTEGER DEFAULT 0,
  total_input_tokens INTEGER DEFAULT 0,
  total_output_tokens INTEGER DEFAULT 0,
  total_cost REAL DEFAULT 0,

  -- Tags (JSON array)
  tags TEXT DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_working_dir ON sessions(working_directory);

-- =============================================================================
-- EVENTS TABLE
-- Core immutable event log - the heart of event sourcing
-- =============================================================================
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,                    -- UUID v7 (time-sortable)
  session_id TEXT NOT NULL REFERENCES sessions(id),

  -- TREE STRUCTURE
  parent_id TEXT REFERENCES events(id),   -- NULL only for root events
  sequence INTEGER NOT NULL,              -- Monotonic within session
  depth INTEGER NOT NULL DEFAULT 0,       -- Tree depth (0 = root)

  -- EVENT DATA
  type TEXT NOT NULL,                     -- Event type discriminator
  timestamp TEXT NOT NULL,                -- ISO 8601 timestamp

  -- Payload (JSON)
  payload TEXT NOT NULL,                  -- Event-specific data

  -- Large content reference (for deduplication)
  content_blob_id TEXT REFERENCES blobs(id),

  -- Denormalized for queries
  workspace_id TEXT NOT NULL,             -- For workspace-scoped queries
  role TEXT,                              -- 'user', 'assistant', 'tool', 'system'
  tool_name TEXT,                         -- For tool events
  tool_call_id TEXT,                      -- Links tool_call to tool_result
  turn INTEGER,                           -- Turn number

  -- Token usage (stored per-event for accurate tracking)
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_creation_tokens INTEGER,

  -- Integrity
  checksum TEXT                           -- SHA256 of (parent_id + payload)
);

-- Primary traversal index
CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_tool_call ON events(tool_call_id);
CREATE INDEX IF NOT EXISTS idx_events_workspace ON events(workspace_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_session_type ON events(session_id, type, sequence);

-- =============================================================================
-- BLOBS TABLE
-- Deduplicated large content storage
-- =============================================================================
CREATE TABLE IF NOT EXISTS blobs (
  id TEXT PRIMARY KEY,                    -- 'blob_' + UUID
  hash TEXT NOT NULL UNIQUE,              -- SHA256 of content
  content BLOB NOT NULL,                  -- Compressed content
  mime_type TEXT DEFAULT 'text/plain',
  size_original INTEGER NOT NULL,         -- Original size in bytes
  size_compressed INTEGER NOT NULL,       -- Compressed size
  compression TEXT DEFAULT 'none',        -- 'none', 'gzip', 'zstd'
  created_at TEXT NOT NULL,
  ref_count INTEGER DEFAULT 1             -- For garbage collection
);

CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);

-- =============================================================================
-- BRANCHES TABLE
-- Named branches for tree navigation
-- =============================================================================
CREATE TABLE IF NOT EXISTS branches (
  id TEXT PRIMARY KEY,                    -- 'br_' + UUID
  session_id TEXT NOT NULL REFERENCES sessions(id),
  name TEXT NOT NULL,
  description TEXT,
  root_event_id TEXT NOT NULL REFERENCES events(id),
  head_event_id TEXT NOT NULL REFERENCES events(id),
  is_default INTEGER DEFAULT 0,           -- Boolean
  created_at TEXT NOT NULL,
  last_activity_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_branches_session ON branches(session_id);

-- =============================================================================
-- FTS5 INDEX FOR FULL-TEXT SEARCH
-- Standalone table with manual inserts (content extracted from event payloads)
-- =============================================================================
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
  id UNINDEXED,
  session_id UNINDEXED,
  type,
  content,                                -- Extracted text content from payload
  tool_name,
  tokenize='porter unicode61'
);

-- =============================================================================
-- SCHEMA VERSION TRACKING
-- =============================================================================
CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL,
  description TEXT
);

INSERT OR IGNORE INTO schema_version (version, applied_at, description)
VALUES (1, datetime('now'), 'Initial event-sourced session tree schema');
