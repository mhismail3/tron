/**
 * @fileoverview Task Backlog Migration
 *
 * Creates the task_backlog table for persisting incomplete tasks
 * when sessions are cleared or ended.
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 2,
  description: 'Add task backlog table for todo persistence',
  up: (db) => {
    db.exec(`
      -- Task backlog for persisting incomplete todos across sessions
      CREATE TABLE IF NOT EXISTS task_backlog (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        source_session_id TEXT NOT NULL,
        content TEXT NOT NULL,
        active_form TEXT NOT NULL,
        status TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        completed_at TEXT,
        backlogged_at TEXT NOT NULL,
        backlog_reason TEXT NOT NULL,
        metadata TEXT,
        restored_to_session_id TEXT,
        restored_at TEXT,

        FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
        FOREIGN KEY (source_session_id) REFERENCES sessions(id)
      );

      -- Index for efficient workspace-scoped queries
      CREATE INDEX IF NOT EXISTS idx_backlog_workspace ON task_backlog(workspace_id, backlogged_at DESC);

      -- Index for finding unrestored tasks by status
      CREATE INDEX IF NOT EXISTS idx_backlog_status ON task_backlog(status, restored_to_session_id);

      -- Index for finding tasks from a specific session
      CREATE INDEX IF NOT EXISTS idx_backlog_session ON task_backlog(source_session_id);
    `);
  },
};
