//! Task schema is now part of the central `events::sqlite::migrations::v001_schema.sql`.
//!
//! This module is retained only for its tests which verify schema properties
//! via the central migration runner.

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::events::run_migrations(&conn).unwrap();
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
        assert!(!tables.iter().any(|t| t.contains("areas_fts")));
    }

    #[test]
    fn test_migrations_idempotent() {
        let conn = setup_db();
        crate::events::run_migrations(&conn).unwrap();
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

    #[test]
    fn task_setup_uses_central_schema() {
        let conn = setup_db();
        // v2 tasks schema: stale status works, no v1 columns
        conn.execute(
            "INSERT INTO tasks (id, title, status) VALUES ('t_stale', 'X', 'stale')",
            [],
        )
        .unwrap();
        let has_old_col = conn.prepare("SELECT project_id FROM tasks LIMIT 0").is_ok();
        assert!(!has_old_col, "v1 column project_id should not exist");
    }

    #[test]
    fn central_migrations_create_cron_tables() {
        let conn = setup_db();
        let tables: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='table' \
                 AND name LIKE 'cron_%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert!(tables.contains(&"cron_jobs".to_string()));
        assert!(tables.contains(&"cron_runs".to_string()));
    }

    #[test]
    fn central_migrations_create_memory_vectors() {
        let conn = setup_db();
        let has_table: bool = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='memory_vectors'")
            .and_then(|mut stmt| stmt.exists([]))
            .unwrap();
        assert!(has_table);
    }
}
