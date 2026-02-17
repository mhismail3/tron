//! SQL DDL for the task management tables.
//!
//! Creates the `projects`, `tasks`, `task_dependencies`, `task_activity`,
//! `areas`, and FTS virtual tables. Mirrors migrations v007 and v008 from
//! the TypeScript codebase.
//!
//! These tables share the same database as `tron-events` — the runtime
//! calls [`run_migrations`] after the event store migrations complete.

use rusqlite::Connection;

use super::errors::TaskError;

/// Run all task-related migrations.
///
/// Idempotent — safe to call multiple times (uses `IF NOT EXISTS`).
pub fn run_migrations(conn: &Connection) -> Result<(), TaskError> {
    conn.execute_batch(TASKS_SCHEMA)?;
    Ok(())
}

/// Combined DDL for all task management tables.
const TASKS_SCHEMA: &str = r"
-- Projects table
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    workspace_id TEXT,
    area_id TEXT,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'paused', 'completed', 'archived')),
    tags TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    metadata TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_projects_workspace_status
    ON projects(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_projects_status_updated
    ON projects(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_projects_area
    ON projects(area_id);

-- Tasks table
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
    parent_task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
    workspace_id TEXT,
    area_id TEXT,
    title TEXT NOT NULL,
    description TEXT,
    active_form TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('backlog', 'pending', 'in_progress', 'completed', 'cancelled')),
    priority TEXT NOT NULL DEFAULT 'medium'
        CHECK(priority IN ('low', 'medium', 'high', 'critical')),
    source TEXT NOT NULL DEFAULT 'agent'
        CHECK(source IN ('agent', 'user', 'skill', 'system')),
    tags TEXT NOT NULL DEFAULT '[]',
    due_date TEXT,
    deferred_until TEXT,
    started_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    estimated_minutes INTEGER,
    actual_minutes INTEGER NOT NULL DEFAULT 0,
    created_by_session_id TEXT,
    last_session_id TEXT,
    last_session_at TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_project_status_sort
    ON tasks(project_id, status, sort_order);
CREATE INDEX IF NOT EXISTS idx_tasks_parent_sort
    ON tasks(parent_task_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_tasks_workspace_status
    ON tasks(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority
    ON tasks(status, priority);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date
    ON tasks(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_deferred
    ON tasks(deferred_until) WHERE deferred_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_session
    ON tasks(created_by_session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_last_session
    ON tasks(last_session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_area
    ON tasks(area_id);

-- Task dependencies
CREATE TABLE IF NOT EXISTS task_dependencies (
    blocker_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    blocked_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    relationship TEXT NOT NULL DEFAULT 'blocks'
        CHECK(relationship IN ('blocks', 'related')),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (blocker_task_id, blocked_task_id),
    CHECK(blocker_task_id != blocked_task_id)
);

-- Task activity (audit trail)
CREATE TABLE IF NOT EXISTS task_activity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    session_id TEXT,
    event_id TEXT,
    action TEXT NOT NULL
        CHECK(action IN ('created', 'status_changed', 'updated', 'note_added',
                         'time_logged', 'dependency_added', 'dependency_removed',
                         'moved', 'deleted')),
    old_value TEXT,
    new_value TEXT,
    detail TEXT,
    minutes_logged INTEGER,
    timestamp TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_task_activity_task
    ON task_activity(task_id, id DESC);

-- Full-text search for tasks
CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
    task_id,
    title,
    description,
    notes,
    tags,
    tokenize='porter unicode61'
);

-- FTS sync triggers
CREATE TRIGGER IF NOT EXISTS tasks_fts_insert AFTER INSERT ON tasks
BEGIN
    INSERT INTO tasks_fts(task_id, title, description, notes, tags)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_update AFTER UPDATE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
    INSERT INTO tasks_fts(task_id, title, description, notes, tags)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_delete AFTER DELETE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
END;

-- Areas table
CREATE TABLE IF NOT EXISTS areas (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL DEFAULT 'default',
    title TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'archived')),
    tags TEXT NOT NULL DEFAULT '[]',
    sort_order REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    metadata TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_areas_workspace
    ON areas(workspace_id);
CREATE INDEX IF NOT EXISTS idx_areas_status
    ON areas(status);

-- Full-text search for areas
CREATE VIRTUAL TABLE IF NOT EXISTS areas_fts USING fts5(
    area_id,
    title,
    description,
    tags,
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS areas_fts_insert AFTER INSERT ON areas
BEGIN
    INSERT INTO areas_fts(area_id, title, description, tags)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS areas_fts_update AFTER UPDATE ON areas
BEGIN
    DELETE FROM areas_fts WHERE area_id = OLD.id;
    INSERT INTO areas_fts(area_id, title, description, tags)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), NEW.tags);
END;

CREATE TRIGGER IF NOT EXISTS areas_fts_delete AFTER DELETE ON areas
BEGIN
    DELETE FROM areas_fts WHERE area_id = OLD.id;
END;
";

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn test_migrations_create_all_tables() {
        let conn = setup_db();
        let tables: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='table' \
                 AND name NOT LIKE 'sqlite_%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert!(tables.contains(&"projects".to_string()));
        assert!(tables.contains(&"tasks".to_string()));
        assert!(tables.contains(&"task_dependencies".to_string()));
        assert!(tables.contains(&"task_activity".to_string()));
        assert!(tables.contains(&"areas".to_string()));
    }

    #[test]
    fn test_migrations_create_fts_tables() {
        let conn = setup_db();
        let tables: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='table' \
                 AND name LIKE '%_fts%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert!(tables.iter().any(|t| t.contains("tasks_fts")));
        assert!(tables.iter().any(|t| t.contains("areas_fts")));
    }

    #[test]
    fn test_migrations_idempotent() {
        let conn = setup_db();
        // Run again — should not error
        run_migrations(&conn).unwrap();
    }

    #[test]
    fn test_migrations_indexes_exist() {
        let conn = setup_db();
        let indexes: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='index' \
                 AND name LIKE 'idx_%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert!(indexes.contains(&"idx_tasks_workspace_status".to_string()));
        assert!(indexes.contains(&"idx_tasks_status_priority".to_string()));
        assert!(indexes.contains(&"idx_projects_workspace_status".to_string()));
        assert!(indexes.contains(&"idx_areas_workspace".to_string()));
    }

    #[test]
    fn test_self_dependency_blocked() {
        let conn = setup_db();
        conn.execute(
            "INSERT INTO tasks (id, title) VALUES ('t1', 'Task 1')",
            [],
        )
        .unwrap();

        let result = conn.execute(
            "INSERT INTO task_dependencies (blocker_task_id, blocked_task_id) VALUES ('t1', 't1')",
            [],
        );
        assert!(result.is_err());
    }
}
