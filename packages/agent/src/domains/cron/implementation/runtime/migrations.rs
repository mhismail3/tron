//! Cron schema is now part of the central `events::sqlite::migrations::v001_schema.sql`.
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
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn migrations_create_tables() {
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
    fn migrations_create_indexes() {
        let conn = setup_db();
        let indexes: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='index' \
                 AND name LIKE 'idx_cron_%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert!(indexes.contains(&"idx_cron_jobs_enabled_next".to_string()));
        assert!(indexes.contains(&"idx_cron_runs_job_started".to_string()));
        assert!(indexes.contains(&"idx_cron_runs_status".to_string()));
        assert!(indexes.contains(&"idx_cron_runs_created".to_string()));
    }

    #[test]
    fn migrations_idempotent() {
        let conn = setup_db();
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }

    #[test]
    fn cron_runs_on_delete_set_null() {
        let conn = setup_db();

        conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json)
             VALUES ('job1', 'Test', '{}', '{}')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO cron_runs (id, job_id, job_name, status)
             VALUES ('run1', 'job1', 'Test', 'completed')",
            [],
        )
        .unwrap();

        conn.execute("DELETE FROM cron_jobs WHERE id = 'job1'", [])
            .unwrap();

        let (job_id, job_name): (Option<String>, String) = conn
            .query_row(
                "SELECT job_id, job_name FROM cron_runs WHERE id = 'run1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert!(job_id.is_none());
        assert_eq!(job_name, "Test");
    }

    #[test]
    fn cron_runs_status_check_constraint() {
        let conn = setup_db();
        let result = conn.execute(
            "INSERT INTO cron_runs (id, job_name, status) VALUES ('r1', 'x', 'invalid_status')",
            [],
        );
        assert!(result.is_err());
    }

    #[test]
    fn cron_jobs_overlap_policy_check() {
        let conn = setup_db();
        let result = conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, overlap_policy)
             VALUES ('j1', 'x', '{}', '{}', 'invalid')",
            [],
        );
        assert!(result.is_err());
    }

    #[test]
    fn cron_jobs_misfire_policy_check() {
        let conn = setup_db();
        let result = conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, misfire_policy)
             VALUES ('j1', 'x', '{}', '{}', 'invalid')",
            [],
        );
        assert!(result.is_err());
    }
}
