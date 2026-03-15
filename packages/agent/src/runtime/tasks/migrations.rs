//! SQL DDL for the task management tables.
//!
//! Creates the `tasks`, `task_activity`, and FTS virtual tables.
//! Fresh installs get the simplified v2 schema directly.
//! Existing v1 databases (with projects/areas/dependencies) are
//! migrated by [`run_migration_v2`].

use rusqlite::Connection;

use super::errors::TaskError;

/// Run all task-related migrations.
///
/// Idempotent — safe to call multiple times.
pub fn run_migrations(conn: &Connection) -> Result<(), TaskError> {
    // Check if we have v1 tables by looking for the projects table
    let has_v1_tables = conn
        .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='projects'")
        .and_then(|mut stmt| stmt.exists([]))
        .unwrap_or(false);

    let has_tasks_table = conn
        .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks'")
        .and_then(|mut stmt| stmt.exists([]))
        .unwrap_or(false);

    if has_v1_tables {
        // Existing v1 database — run v2 migration
        run_migration_v2(conn)?;
    } else if !has_tasks_table {
        // Fresh install — create simplified schema directly
        conn.execute_batch(TASKS_SCHEMA_V2)?;
    }
    // else: already at v2, nothing to do — verify by checking for stale support
    else {
        ensure_stale_support(conn)?;
    }

    Ok(())
}

/// Ensure the tasks table supports the 'stale' status.
/// Needed when v2 schema exists but may not have been fully applied.
fn ensure_stale_support(conn: &Connection) -> Result<(), TaskError> {
    // Try inserting and immediately deleting a stale row to verify CHECK allows it
    let stale_ok = conn
        .execute(
            "INSERT INTO tasks (id, title, status) VALUES ('__stale_check__', '__check__', 'stale')",
            [],
        )
        .is_ok();
    if stale_ok {
        let _ = conn.execute("DELETE FROM tasks WHERE id = '__stale_check__'", []);
    } else {
        // CHECK constraint doesn't allow 'stale' — need table rebuild
        rebuild_tasks_table(conn)?;
    }
    Ok(())
}

/// Migrate from v1 (projects/areas/dependencies) to v2 (simplified tasks only).
fn run_migration_v2(conn: &Connection) -> Result<(), TaskError> {
    // Disable FK checks during migration to avoid issues with
    // dropping referenced tables (old tasks FK → areas/projects)
    conn.execute_batch("PRAGMA foreign_keys = OFF;")?;

    conn.execute_batch(
        "
        -- Drop removed tables
        DROP TABLE IF EXISTS task_dependencies;
        DROP TABLE IF EXISTS projects;
        DROP TABLE IF EXISTS areas;
        DROP TABLE IF EXISTS areas_fts;
        ",
    )?;

    // Rebuild tasks table to drop columns and update CHECK constraint
    rebuild_tasks_table(conn)?;

    conn.execute_batch("PRAGMA foreign_keys = ON;")?;

    Ok(())
}

/// Rebuild the tasks table with simplified columns and updated CHECK constraint.
fn rebuild_tasks_table(conn: &Connection) -> Result<(), TaskError> {
    // Check if old columns exist to decide what to migrate
    let has_old_columns = conn
        .prepare("SELECT project_id FROM tasks LIMIT 0")
        .is_ok();

    conn.execute_batch("DROP TRIGGER IF EXISTS tasks_fts_insert;")?;
    conn.execute_batch("DROP TRIGGER IF EXISTS tasks_fts_update;")?;
    conn.execute_batch("DROP TRIGGER IF EXISTS tasks_fts_delete;")?;

    if has_old_columns {
        conn.execute_batch(
            "
            CREATE TABLE tasks_v2 (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                active_form TEXT,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','in_progress','completed','cancelled','stale')),
                parent_task_id TEXT REFERENCES tasks_v2(id) ON DELETE CASCADE,
                started_at TEXT,
                completed_at TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                created_by_session_id TEXT,
                last_session_id TEXT,
                last_session_at TEXT,
                metadata TEXT
            );

            INSERT INTO tasks_v2 (id, title, description, active_form, notes, status,
                parent_task_id, started_at, completed_at,
                created_at, updated_at,
                created_by_session_id, last_session_id, last_session_at, metadata)
            SELECT id, title, description, active_form, notes,
                CASE WHEN status = 'backlog' THEN 'pending' ELSE status END,
                parent_task_id, started_at, completed_at,
                created_at, updated_at,
                created_by_session_id, last_session_id, last_session_at, metadata
            FROM tasks;

            DROP TABLE tasks;
            ALTER TABLE tasks_v2 RENAME TO tasks;
            ",
        )?;
    } else {
        // Already has simplified columns but needs CHECK update
        conn.execute_batch(
            "
            CREATE TABLE tasks_v2 (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                active_form TEXT,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','in_progress','completed','cancelled','stale')),
                parent_task_id TEXT REFERENCES tasks_v2(id) ON DELETE CASCADE,
                started_at TEXT,
                completed_at TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                created_by_session_id TEXT,
                last_session_id TEXT,
                last_session_at TEXT,
                metadata TEXT
            );

            INSERT INTO tasks_v2 (id, title, description, active_form, notes, status,
                parent_task_id, started_at, completed_at,
                created_at, updated_at,
                created_by_session_id, last_session_id, last_session_at, metadata)
            SELECT id, title, description, active_form, notes, status,
                parent_task_id, started_at, completed_at,
                created_at, updated_at,
                created_by_session_id, last_session_id, last_session_at, metadata
            FROM tasks;

            DROP TABLE tasks;
            ALTER TABLE tasks_v2 RENAME TO tasks;
            ",
        )?;
    }

    // Recreate indexes
    conn.execute_batch(
        "
        CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
        CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(created_by_session_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_last_session ON tasks(last_session_id);
        ",
    )?;

    // Rebuild FTS
    conn.execute_batch(
        "
        DROP TABLE IF EXISTS tasks_fts;
        CREATE VIRTUAL TABLE tasks_fts USING fts5(
            task_id,
            title,
            description,
            notes,
            tokenize='porter unicode61'
        );

        -- Reindex existing data
        INSERT INTO tasks_fts(task_id, title, description, notes)
        SELECT id, title, COALESCE(description, ''), COALESCE(notes, '')
        FROM tasks;
        ",
    )?;

    // Recreate FTS triggers
    conn.execute_batch(FTS_TRIGGERS)?;

    Ok(())
}

/// Fresh v2 schema for new installs.
const TASKS_SCHEMA_V2: &str = "
-- Tasks table (simplified v2)
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    active_form TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending','in_progress','completed','cancelled','stale')),
    parent_task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
    started_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    created_by_session_id TEXT,
    last_session_id TEXT,
    last_session_at TEXT,
    metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(created_by_session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_last_session ON tasks(last_session_id);

-- Task activity (audit trail)
CREATE TABLE IF NOT EXISTS task_activity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    session_id TEXT,
    event_id TEXT,
    action TEXT NOT NULL
        CHECK(action IN ('created', 'status_changed', 'updated', 'note_added', 'deleted')),
    old_value TEXT,
    new_value TEXT,
    detail TEXT,
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
    tokenize='porter unicode61'
);

-- FTS sync triggers
CREATE TRIGGER IF NOT EXISTS tasks_fts_insert AFTER INSERT ON tasks
BEGIN
    INSERT INTO tasks_fts(task_id, title, description, notes)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''));
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_update AFTER UPDATE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
    INSERT INTO tasks_fts(task_id, title, description, notes)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''));
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_delete AFTER DELETE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
END;
";

const FTS_TRIGGERS: &str = "
CREATE TRIGGER IF NOT EXISTS tasks_fts_insert AFTER INSERT ON tasks
BEGIN
    INSERT INTO tasks_fts(task_id, title, description, notes)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''));
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_update AFTER UPDATE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
    INSERT INTO tasks_fts(task_id, title, description, notes)
    VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''),
            COALESCE(NEW.notes, ''));
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_delete AFTER DELETE ON tasks
BEGIN
    DELETE FROM tasks_fts WHERE task_id = OLD.id;
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
    fn test_migrations_create_tables() {
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

        assert!(tables.contains(&"tasks".to_string()));
        assert!(tables.contains(&"task_activity".to_string()));
        // v1 tables should NOT exist
        assert!(!tables.contains(&"projects".to_string()));
        assert!(!tables.contains(&"areas".to_string()));
        assert!(!tables.contains(&"task_dependencies".to_string()));
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
        // areas_fts should NOT exist
        assert!(!tables.iter().any(|t| t.contains("areas_fts")));
    }

    #[test]
    fn test_migrations_idempotent() {
        let conn = setup_db();
        // Run again — should not error
        run_migrations(&conn).unwrap();
    }

    #[test]
    fn test_stale_status_accepted() {
        let conn = setup_db();
        conn.execute(
            "INSERT INTO tasks (id, title, status) VALUES ('t1', 'Test', 'stale')",
            [],
        )
        .unwrap();
        let status: String = conn
            .query_row("SELECT status FROM tasks WHERE id = 't1'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(status, "stale");
    }

    #[test]
    fn test_fts_triggers_work() {
        let conn = setup_db();
        conn.execute(
            "INSERT INTO tasks (id, title) VALUES ('t1', 'authentication bug fix')",
            [],
        )
        .unwrap();
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM tasks_fts WHERE tasks_fts MATCH 'authentication'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_v2_migration_from_v1_db() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();

        // Create v1 schema manually
        conn.execute_batch(V1_SCHEMA).unwrap();

        // Insert some v1 data
        conn.execute(
            "INSERT INTO projects (id, title) VALUES ('proj-1', 'Project 1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tasks (id, title, project_id, status, priority, source, tags) \
             VALUES ('t1', 'Task 1', 'proj-1', 'backlog', 'high', 'agent', '[]')",
            [],
        )
        .unwrap();

        // Run v2 migration
        run_migrations(&conn).unwrap();

        // Projects table should be gone
        let has_projects = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='projects'")
            .and_then(|mut stmt| stmt.exists([]))
            .unwrap_or(false);
        assert!(!has_projects);

        // Task should survive with backlog mapped to pending
        let status: String = conn
            .query_row("SELECT status FROM tasks WHERE id = 't1'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(status, "pending");

        // Stale should work
        conn.execute(
            "INSERT INTO tasks (id, title, status) VALUES ('t2', 'Test', 'stale')",
            [],
        )
        .unwrap();
    }

    #[test]
    fn test_v2_migration_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();

        // Create v1 schema
        conn.execute_batch(V1_SCHEMA).unwrap();

        // Run migration twice
        run_migrations(&conn).unwrap();
        run_migrations(&conn).unwrap();
    }

    #[test]
    fn test_parent_task_self_reference_survives() {
        let conn = setup_db();
        conn.execute(
            "INSERT INTO tasks (id, title) VALUES ('parent', 'Parent')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tasks (id, title, parent_task_id) VALUES ('child', 'Child', 'parent')",
            [],
        )
        .unwrap();
        let parent: String = conn
            .query_row(
                "SELECT parent_task_id FROM tasks WHERE id = 'child'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(parent, "parent");
    }

    // V1 schema for testing migration path
    const V1_SCHEMA: &str = "
        CREATE TABLE projects (
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

        CREATE TABLE tasks (
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

        CREATE TABLE task_dependencies (
            blocker_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            blocked_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            relationship TEXT NOT NULL DEFAULT 'blocks',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (blocker_task_id, blocked_task_id)
        );

        CREATE TABLE task_activity (
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

        CREATE TABLE areas (
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

        CREATE VIRTUAL TABLE tasks_fts USING fts5(
            task_id, title, description, notes, tags,
            tokenize='porter unicode61'
        );

        CREATE VIRTUAL TABLE areas_fts USING fts5(
            area_id, title, description, tags,
            tokenize='porter unicode61'
        );
    ";
}
