/**
 * @fileoverview Task Management Migration
 *
 * Creates the projects, tasks, task_dependencies, and task_activity tables
 * for the persistent task management system. Also creates FTS index on tasks
 * and migrates existing task_backlog data.
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 7,
  description: 'Add persistent task management system (projects, tasks, dependencies, activity)',
  up: (db) => {
    db.exec(`
      -- =======================================================================
      -- Projects
      -- =======================================================================
      CREATE TABLE IF NOT EXISTS projects (
        id            TEXT PRIMARY KEY,
        workspace_id  TEXT,
        title         TEXT NOT NULL,
        description   TEXT,
        status        TEXT NOT NULL DEFAULT 'active',
        tags          TEXT NOT NULL DEFAULT '[]',
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        completed_at  TEXT,
        metadata      TEXT,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE SET NULL
      );

      CREATE INDEX IF NOT EXISTS idx_projects_workspace ON projects(workspace_id, status);
      CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status, updated_at DESC);

      -- =======================================================================
      -- Tasks
      -- =======================================================================
      CREATE TABLE IF NOT EXISTS tasks (
        id                    TEXT PRIMARY KEY,
        project_id            TEXT,
        parent_task_id        TEXT,
        workspace_id          TEXT,

        title                 TEXT NOT NULL,
        description           TEXT,
        active_form           TEXT,
        notes                 TEXT,

        status                TEXT NOT NULL DEFAULT 'pending',
        priority              TEXT NOT NULL DEFAULT 'medium',
        source                TEXT NOT NULL DEFAULT 'agent',
        tags                  TEXT NOT NULL DEFAULT '[]',

        due_date              TEXT,
        deferred_until        TEXT,
        started_at            TEXT,
        completed_at          TEXT,
        created_at            TEXT NOT NULL,
        updated_at            TEXT NOT NULL,

        estimated_minutes     INTEGER,
        actual_minutes        INTEGER NOT NULL DEFAULT 0,

        created_by_session_id TEXT,
        last_session_id       TEXT,
        last_session_at       TEXT,

        sort_order            INTEGER NOT NULL DEFAULT 0,
        metadata              TEXT,

        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE SET NULL,
        FOREIGN KEY (parent_task_id) REFERENCES tasks(id) ON DELETE CASCADE,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE SET NULL
      );

      CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, status, sort_order);
      CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id, sort_order);
      CREATE INDEX IF NOT EXISTS idx_tasks_workspace ON tasks(workspace_id, status, updated_at DESC);
      CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status, priority DESC, updated_at DESC);
      CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due_date, status);
      CREATE INDEX IF NOT EXISTS idx_tasks_deferred ON tasks(deferred_until);
      CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(created_by_session_id);
      CREATE INDEX IF NOT EXISTS idx_tasks_last_session ON tasks(last_session_id);

      -- =======================================================================
      -- Task Dependencies
      -- =======================================================================
      CREATE TABLE IF NOT EXISTS task_dependencies (
        blocker_task_id TEXT NOT NULL,
        blocked_task_id TEXT NOT NULL,
        relationship    TEXT NOT NULL DEFAULT 'blocks',
        created_at      TEXT NOT NULL,
        PRIMARY KEY (blocker_task_id, blocked_task_id),
        FOREIGN KEY (blocker_task_id) REFERENCES tasks(id) ON DELETE CASCADE,
        FOREIGN KEY (blocked_task_id) REFERENCES tasks(id) ON DELETE CASCADE,
        CHECK (blocker_task_id != blocked_task_id)
      );

      CREATE INDEX IF NOT EXISTS idx_deps_blocked ON task_dependencies(blocked_task_id);

      -- =======================================================================
      -- Task Activity (append-only audit trail)
      -- =======================================================================
      CREATE TABLE IF NOT EXISTS task_activity (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id         TEXT NOT NULL,
        session_id      TEXT,
        event_id        TEXT,
        action          TEXT NOT NULL,
        old_value       TEXT,
        new_value       TEXT,
        detail          TEXT,
        minutes_logged  INTEGER,
        timestamp       TEXT NOT NULL,
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
      );

      CREATE INDEX IF NOT EXISTS idx_activity_task ON task_activity(task_id, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_activity_session ON task_activity(session_id, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_activity_timestamp ON task_activity(timestamp DESC);

      -- =======================================================================
      -- Full-Text Search on Tasks
      -- =======================================================================
      CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
        task_id UNINDEXED, title, description, notes, tags,
        tokenize='porter unicode61'
      );

      -- FTS sync triggers
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
    `);

    // =======================================================================
    // Migrate existing task_backlog data
    // =======================================================================
    const hasBacklog = db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='task_backlog'"
    ).get();

    if (hasBacklog) {
      const unrestoredRows = db.prepare(`
        SELECT id, workspace_id, source_session_id, content, active_form, status, source,
               created_at, completed_at, metadata
        FROM task_backlog
        WHERE restored_to_session_id IS NULL
          AND status != 'completed'
      `).all() as Array<{
        id: string;
        workspace_id: string;
        source_session_id: string;
        content: string;
        active_form: string;
        status: string;
        source: string;
        created_at: string;
        completed_at: string | null;
        metadata: string | null;
      }>;

      if (unrestoredRows.length > 0) {
        const now = new Date().toISOString();
        const insertTask = db.prepare(`
          INSERT OR IGNORE INTO tasks (
            id, workspace_id, title, active_form, status, priority, source, tags,
            created_at, updated_at, created_by_session_id, sort_order
          ) VALUES (?, ?, ?, ?, 'pending', 'medium', ?, '["#migrated-from-backlog"]', ?, ?, ?, ?)
        `);

        for (let i = 0; i < unrestoredRows.length; i++) {
          const row = unrestoredRows[i]!;
          insertTask.run(
            row.id,
            row.workspace_id,
            row.content,
            row.active_form,
            row.source,
            row.created_at,
            now,
            row.source_session_id,
            i
          );
        }
      }
    }
  },
};
