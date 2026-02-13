/**
 * @fileoverview Initial Schema Migration
 *
 * Creates the core database tables:
 * - workspaces: Project/directory contexts
 * - sessions: Conversation sessions
 * - events: Event-sourced message history
 * - blobs: Content-addressable blob storage
 * - branches: Session branching support
 * - events_fts: Full-text search for events
 * - logs: Structured logging
 * - logs_fts: Full-text search for logs
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 1,
  description: 'Initial schema with core tables',
  up: (db) => {
    db.exec(`
      -- Workspaces
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        name TEXT,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);

      -- Sessions
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id),
        head_event_id TEXT,
        root_event_id TEXT,
        title TEXT,
        latest_model TEXT NOT NULL,
        working_directory TEXT NOT NULL,
        parent_session_id TEXT REFERENCES sessions(id),
        fork_from_event_id TEXT,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL,
        archived_at TEXT,
        event_count INTEGER DEFAULT 0,
        message_count INTEGER DEFAULT 0,
        turn_count INTEGER DEFAULT 0,
        total_input_tokens INTEGER DEFAULT 0,
        total_output_tokens INTEGER DEFAULT 0,
        last_turn_input_tokens INTEGER DEFAULT 0,
        total_cost REAL DEFAULT 0,
        total_cache_read_tokens INTEGER DEFAULT 0,
        total_cache_creation_tokens INTEGER DEFAULT 0,
        tags TEXT DEFAULT '[]',
        spawning_session_id TEXT,
        spawn_type TEXT,
        spawn_task TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived_at);
      CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at DESC);
      CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_working_dir ON sessions(working_directory);
      CREATE INDEX IF NOT EXISTS idx_sessions_spawning ON sessions(spawning_session_id);

      -- Events
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        parent_id TEXT REFERENCES events(id),
        sequence INTEGER NOT NULL,
        depth INTEGER NOT NULL DEFAULT 0,
        type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        payload TEXT NOT NULL,
        content_blob_id TEXT REFERENCES blobs(id),
        workspace_id TEXT NOT NULL,
        role TEXT,
        tool_name TEXT,
        tool_call_id TEXT,
        turn INTEGER,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_creation_tokens INTEGER,
        checksum TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);
      CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id);
      CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
      CREATE INDEX IF NOT EXISTS idx_events_workspace ON events(workspace_id, timestamp DESC);

      -- Blobs
      CREATE TABLE IF NOT EXISTS blobs (
        id TEXT PRIMARY KEY,
        hash TEXT NOT NULL UNIQUE,
        content BLOB NOT NULL,
        mime_type TEXT DEFAULT 'text/plain',
        size_original INTEGER NOT NULL,
        size_compressed INTEGER NOT NULL,
        compression TEXT DEFAULT 'none',
        created_at TEXT NOT NULL,
        ref_count INTEGER DEFAULT 1
      );
      CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);

      -- Branches
      CREATE TABLE IF NOT EXISTS branches (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        name TEXT NOT NULL,
        description TEXT,
        root_event_id TEXT NOT NULL REFERENCES events(id),
        head_event_id TEXT NOT NULL REFERENCES events(id),
        is_default INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_branches_session ON branches(session_id);

      -- FTS5 for event content search
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        id UNINDEXED,
        session_id UNINDEXED,
        type,
        content,
        tool_name,
        tokenize='porter unicode61'
      );

      -- Logs table for structured logging
      CREATE TABLE IF NOT EXISTS logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        level_num INTEGER NOT NULL,
        component TEXT NOT NULL,
        message TEXT NOT NULL,
        session_id TEXT,
        workspace_id TEXT,
        event_id TEXT,
        turn INTEGER,
        data TEXT,
        error_message TEXT,
        error_stack TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_session_time ON logs(session_id, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_level_time ON logs(level_num, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_component_time ON logs(component, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_event ON logs(event_id, timestamp);
      CREATE INDEX IF NOT EXISTS idx_logs_workspace_time ON logs(workspace_id, timestamp DESC);

      -- FTS5 for log message search
      CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
        log_id UNINDEXED,
        session_id UNINDEXED,
        component,
        message,
        error_message,
        tokenize='porter unicode61'
      );
    `);
  },
};
