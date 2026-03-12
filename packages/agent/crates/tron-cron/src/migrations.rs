//! SQL DDL for the cron scheduling tables.
//!
//! Creates `cron_jobs` and `cron_runs` in the same `tron.db` used by
//! events and tasks. Called from `main.rs` after task migrations.

use rusqlite::Connection;

use crate::errors::CronError;

/// Run all cron-related migrations.
///
/// Idempotent — safe to call multiple times (uses `IF NOT EXISTS`).
pub fn run_migrations(conn: &Connection) -> Result<(), CronError> {
    conn.execute_batch(CRON_SCHEMA)?;
    run_v2_migrations(conn)?;
    Ok(())
}

/// V2 migrations: add `tool_restrictions_json` column.
fn run_v2_migrations(conn: &Connection) -> Result<(), CronError> {
    // Check if column already exists
    let has_column: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('cron_jobs') WHERE name = 'tool_restrictions_json'")?
        .query_row([], |row| row.get(0))?;
    if !has_column {
        conn.execute_batch("ALTER TABLE cron_jobs ADD COLUMN tool_restrictions_json TEXT;")?;
    }
    Ok(())
}

const CRON_SCHEMA: &str = r"
-- Job definitions. Definition columns synced FROM config file.
-- Runtime columns managed BY the scheduler.
CREATE TABLE IF NOT EXISTS cron_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    schedule_json TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    delivery_json TEXT NOT NULL DEFAULT '[]',
    overlap_policy TEXT NOT NULL DEFAULT 'skip'
        CHECK(overlap_policy IN ('skip', 'allow')),
    misfire_policy TEXT NOT NULL DEFAULT 'skip'
        CHECK(misfire_policy IN ('skip', 'run_once')),
    max_retries INTEGER NOT NULL DEFAULT 0,
    auto_disable_after INTEGER NOT NULL DEFAULT 0,
    stuck_timeout_secs INTEGER NOT NULL DEFAULT 7200,
    tags TEXT NOT NULL DEFAULT '[]',
    workspace_id TEXT,
    -- Runtime state (scheduler-managed, NOT from config file)
    next_run_at TEXT,
    last_run_at TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    running_since TEXT,
    -- Timestamps
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cron_jobs_enabled_next
    ON cron_jobs(enabled, next_run_at) WHERE enabled = 1;

-- Execution history. Retained as audit trail even after job deletion.
CREATE TABLE IF NOT EXISTS cron_runs (
    id TEXT PRIMARY KEY,
    job_id TEXT REFERENCES cron_jobs(id) ON DELETE SET NULL,
    job_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK(status IN ('running', 'completed', 'failed', 'timed_out', 'skipped', 'cancelled')),
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    duration_ms INTEGER,
    output TEXT,
    output_truncated INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    exit_code INTEGER,
    attempt INTEGER NOT NULL DEFAULT 0,
    session_id TEXT,
    delivery_status TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cron_runs_job_started
    ON cron_runs(job_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_cron_runs_status
    ON cron_runs(status) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS idx_cron_runs_created
    ON cron_runs(created_at);
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
        run_migrations(&conn).unwrap();
        run_migrations(&conn).unwrap();
    }

    #[test]
    fn cron_runs_on_delete_set_null() {
        let conn = setup_db();

        // Insert a job
        conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json)
             VALUES ('job1', 'Test', '{}', '{}')",
            [],
        )
        .unwrap();

        // Insert a run referencing the job
        conn.execute(
            "INSERT INTO cron_runs (id, job_id, job_name, status)
             VALUES ('run1', 'job1', 'Test', 'completed')",
            [],
        )
        .unwrap();

        // Delete the job
        conn.execute("DELETE FROM cron_jobs WHERE id = 'job1'", [])
            .unwrap();

        // Run should still exist with NULL job_id
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
