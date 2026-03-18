//! Schema migration runner for the event store database.
//!
//! Migrations are embedded at compile time via [`include_str!`] and executed
//! in version order. Each migration runs inside a transaction — a failure
//! rolls back cleanly with no partial schema state.
//!
//! The `schema_version` table tracks which migrations have been applied.
//! Running the migrator is idempotent: already-applied versions are skipped.

use rusqlite::Connection;
use tracing::{debug, info};

use crate::events::errors::{EventStoreError, Result};

/// A single migration with a version number and SQL to execute.
struct Migration {
    version: u32,
    description: &'static str,
    sql: &'static str,
}

/// All migrations in version order.
const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    description: "Complete schema — core tables, FTS, indexes, triggers",
    sql: include_str!("v001_schema.sql"),
}];

/// Result of running migrations.
#[derive(Debug)]
pub struct MigrationResult {
    /// Number of migrations applied.
    pub applied: u32,
    /// Highest version that was newly applied (0 if none).
    pub max_version_applied: u32,
}

/// Run all pending migrations on the given connection.
///
/// Creates the `schema_version` table if it doesn't exist, then applies
/// each migration whose version exceeds the current maximum. Each migration
/// runs in its own transaction.
///
/// # Errors
///
/// Returns [`EventStoreError::Migration`] if any migration SQL fails.
pub fn run_migrations(conn: &Connection) -> Result<MigrationResult> {
    ensure_version_table(conn)?;
    let current = current_version(conn)?;
    let mut applied = 0;
    let mut max_version_applied = 0;

    for migration in MIGRATIONS {
        if migration.version <= current {
            debug!(
                version = migration.version,
                description = migration.description,
                "migration already applied, skipping"
            );
            continue;
        }

        info!(
            version = migration.version,
            description = migration.description,
            "applying migration"
        );

        apply_migration(conn, migration)?;
        applied += 1;
        max_version_applied = migration.version;
    }

    if applied > 0 {
        info!(applied, "migrations complete");
    }

    Ok(MigrationResult {
        applied,
        max_version_applied,
    })
}

/// Return the highest applied migration version, or 0 if none.
pub fn current_version(conn: &Connection) -> Result<u32> {
    let version: u32 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_version",
            [],
            |row| row.get(0),
        )
        .map_err(|e| EventStoreError::Migration {
            message: format!("failed to read schema_version: {e}"),
        })?;
    Ok(version)
}

/// Return the latest migration version defined in code.
pub fn latest_version() -> u32 {
    MIGRATIONS.last().map_or(0, |m| m.version)
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────

fn ensure_version_table(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_version (
           version     INTEGER PRIMARY KEY,
           applied_at  TEXT    NOT NULL,
           description TEXT
         );",
    )
    .map_err(|e| EventStoreError::Migration {
        message: format!("failed to create schema_version table: {e}"),
    })?;
    Ok(())
}

fn apply_migration(conn: &Connection, migration: &Migration) -> Result<()> {
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| EventStoreError::Migration {
            message: format!(
                "failed to begin transaction for v{}: {e}",
                migration.version
            ),
        })?;

    tx.execute_batch(migration.sql)
        .map_err(|e| EventStoreError::Migration {
            message: format!(
                "migration v{} ({}) failed: {e}",
                migration.version, migration.description
            ),
        })?;

    let _ = tx.execute(
        "INSERT INTO schema_version (version, applied_at, description) VALUES (?1, datetime('now'), ?2)",
        rusqlite::params![migration.version, migration.description],
    )
    .map_err(|e| EventStoreError::Migration {
        message: format!("failed to record v{} in schema_version: {e}", migration.version),
    })?;

    tx.commit().map_err(|e| EventStoreError::Migration {
        message: format!("failed to commit v{}: {e}", migration.version),
    })?;

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn open_memory() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA foreign_keys = ON;",
        )
        .unwrap();
        conn
    }

    #[test]
    fn run_migrations_creates_all_tables() {
        let conn = open_memory();
        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 1);
        assert_eq!(result.max_version_applied, 1);

        // Verify core tables exist
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        let expected = [
            "blobs",
            "branches",
            "cron_jobs",
            "cron_runs",
            "device_tokens",
            "events",
            "logs",
            "memory_vectors",
            "notification_read_state",
            "schema_version",
            "sessions",
            "task_activity",
            "task_backlog",
            "tasks",
            "workspaces",
        ];
        for table in &expected {
            assert!(
                tables.contains(&table.to_string()),
                "missing table: {table}"
            );
        }
    }

    #[test]
    fn run_migrations_creates_fts_tables() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_fts'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(
            !tables.contains(&"events_fts".to_string()),
            "events_fts should not exist"
        );
        assert!(
            !tables.contains(&"logs_fts".to_string()),
            "logs_fts should not exist"
        );
        assert!(tables.contains(&"tasks_fts".to_string()));
        assert!(
            !tables.contains(&"areas_fts".to_string()),
            "areas_fts should not exist"
        );
    }

    #[test]
    fn run_migrations_is_idempotent() {
        let conn = open_memory();
        let first = run_migrations(&conn).unwrap();
        assert_eq!(first.applied, 1);

        let second = run_migrations(&conn).unwrap();
        assert_eq!(second.applied, 0);
        assert_eq!(second.max_version_applied, 0);
    }

    #[test]
    fn current_version_starts_at_zero() {
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        assert_eq!(current_version(&conn).unwrap(), 0);
    }

    #[test]
    fn current_version_after_migration() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        assert_eq!(current_version(&conn).unwrap(), 1);
    }

    #[test]
    fn latest_version_matches_migrations() {
        assert_eq!(latest_version(), 1);
    }

    #[test]
    fn schema_version_records_applied_migration() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let (version, desc): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(version, 1);
        assert!(desc.contains("Complete schema"));
    }

    #[test]
    fn indexes_are_created() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let indexes: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        // Spot-check key indexes
        let expected = [
            "idx_events_session_seq",
            "idx_events_session_sequence_unique",
            "idx_sessions_workspace",
            "idx_sessions_created",
            "idx_tasks_status",
            "idx_blobs_hash",
            "idx_branches_session",
            "idx_sessions_origin",
            "idx_sessions_source",
            "idx_logs_ios_client_dedup",
            "idx_cron_jobs_enabled_next",
            "idx_cron_runs_job_started",
            "idx_cron_runs_status",
            "idx_cron_runs_created",
            "idx_mv_event",
            "idx_mv_workspace",
            "idx_mv_type",
        ];
        for idx in &expected {
            assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
        }

        // Verify removed indexes are gone (logs query indexes and most events indexes stripped)
        let removed = [
            "idx_logs_timestamp",
            "idx_logs_trace_id",
            "idx_logs_origin",
            "idx_logs_session_time",
            "idx_logs_level_time",
            "idx_logs_component_time",
            "idx_logs_workspace_time",
            "idx_logs_parent_trace",
            "idx_events_parent",
            "idx_events_type",
            "idx_events_tool_call_id",
            "idx_events_model",
            "idx_events_latency",
            "idx_events_timestamp",
            "idx_logs_event",
        ];
        for idx in &removed {
            assert!(
                !indexes.contains(&idx.to_string()),
                "{idx} should not exist"
            );
        }
    }

    #[test]
    fn triggers_are_created() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let triggers: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        let expected = [
            "tasks_fts_insert",
            "tasks_fts_update",
            "tasks_fts_delete",
        ];
        for trigger in &expected {
            assert!(
                triggers.contains(&trigger.to_string()),
                "missing trigger: {trigger}"
            );
        }

        // Verify removed triggers are gone
        let removed = [
            "events_fts_insert",
            "events_fts_delete",
            "areas_fts_insert",
            "areas_fts_update",
            "areas_fts_delete",
        ];
        for trigger in &removed {
            assert!(
                !triggers.contains(&trigger.to_string()),
                "{trigger} should not exist"
            );
        }
    }

    #[test]
    fn events_table_has_expected_columns() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(events)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        let expected = [
            "id",
            "session_id",
            "parent_id",
            "sequence",
            "depth",
            "type",
            "timestamp",
            "payload",
            "content_blob_id",
            "workspace_id",
            "role",
            "tool_name",
            "tool_call_id",
            "turn",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_creation_tokens",
            "checksum",
            "model",
            "latency_ms",
            "stop_reason",
            "has_thinking",
            "provider_type",
            "cost",
        ];
        for col in &expected {
            assert!(
                columns.contains(&col.to_string()),
                "events table missing column: {col}"
            );
        }
    }

    #[test]
    fn sessions_table_has_expected_columns() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(sessions)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        let expected = [
            "id",
            "workspace_id",
            "head_event_id",
            "root_event_id",
            "title",
            "latest_model",
            "working_directory",
            "parent_session_id",
            "fork_from_event_id",
            "created_at",
            "last_activity_at",
            "ended_at",
            "event_count",
            "turn_count",
            "total_input_tokens",
            "total_output_tokens",
            "total_cost",
            "total_cache_read_tokens",
            "total_cache_creation_tokens",
            "spawning_session_id",
            "spawn_type",
            "spawn_task",
            "origin",
            "source",
        ];
        for col in &expected {
            assert!(
                columns.contains(&col.to_string()),
                "sessions table missing column: {col}"
            );
        }
    }

    #[test]
    fn origin_columns_exist_in_sessions_and_logs() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // sessions.origin
        let sessions_cols: Vec<String> = conn
            .prepare("PRAGMA table_info(sessions)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        assert!(
            sessions_cols.contains(&"origin".to_string()),
            "sessions table missing origin column"
        );

        // logs.origin
        let logs_cols: Vec<String> = conn
            .prepare("PRAGMA table_info(logs)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        assert!(
            logs_cols.contains(&"origin".to_string()),
            "logs table missing origin column"
        );
    }

    #[test]
    fn foreign_keys_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Attempting to insert a session with non-existent workspace should fail
        let result = conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'nonexistent', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        );
        assert!(result.is_err());
    }

    #[test]
    fn turn_metadata_columns_are_nullable() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Insert event WITHOUT new columns — they should default to NULL
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_1', 'sess_1', 1, 'message.user', '2025-01-01T00:00:00Z', '{}', 'ws_1')",
            [],
        )
        .unwrap();

        // Verify all new columns are NULL
        let (model, latency, stop, thinking, provider, cost): (
            Option<String>, Option<i64>, Option<String>, Option<i64>, Option<String>, Option<f64>,
        ) = conn
            .query_row(
                "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost FROM events WHERE id = 'evt_1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
            )
            .unwrap();

        assert!(model.is_none());
        assert!(latency.is_none());
        assert!(stop.is_none());
        assert!(thinking.is_none());
        assert!(provider.is_none());
        assert!(cost.is_none());
    }

    #[test]
    fn turn_metadata_columns_can_be_populated() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Insert event WITH all new columns populated
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id,
                                 model, latency_ms, stop_reason, has_thinking, provider_type, cost)
             VALUES ('evt_1', 'sess_1', 1, 'message.assistant', '2025-01-01T00:00:00Z', '{}', 'ws_1',
                     'claude-opus-4-6', 1500, 'end_turn', 1, 'anthropic', 0.015)",
            [],
        )
        .unwrap();

        let (model, latency, stop, thinking, provider, cost): (
            String, i64, String, i64, String, f64,
        ) = conn
            .query_row(
                "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost FROM events WHERE id = 'evt_1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
            )
            .unwrap();

        assert_eq!(model, "claude-opus-4-6");
        assert_eq!(latency, 1500);
        assert_eq!(stop, "end_turn");
        assert_eq!(thinking, 1);
        assert_eq!(provider, "anthropic");
        assert!((cost - 0.015).abs() < f64::EPSILON);
    }

    // ── Consolidated schema tests ──────────────────────────────────────

    #[test]
    fn consolidated_schema_no_v1_tables() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for removed in &["projects", "areas", "task_dependencies"] {
            assert!(
                !tables.contains(&removed.to_string()),
                "{removed} should not exist"
            );
        }
    }

    #[test]
    fn consolidated_schema_tasks_v2_columns() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(tasks)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        let expected = [
            "id", "title", "description", "active_form", "notes", "status",
            "parent_task_id", "started_at", "completed_at", "created_at",
            "updated_at", "created_by_session_id", "last_session_id",
            "last_session_at", "metadata",
        ];
        for col in &expected {
            assert!(columns.contains(&col.to_string()), "missing column: {col}");
        }

        let removed = [
            "project_id", "workspace_id", "area_id", "priority", "source",
            "tags", "due_date", "deferred_until", "estimated_minutes",
            "actual_minutes", "sort_order",
        ];
        for col in &removed {
            assert!(!columns.contains(&col.to_string()), "{col} should not exist");
        }
    }

    #[test]
    fn consolidated_schema_tasks_stale_status() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        conn.execute(
            "INSERT INTO tasks (id, title, status) VALUES ('t_stale', 'Test', 'stale')",
            [],
        )
        .unwrap();
    }

    #[test]
    fn consolidated_schema_tasks_backlog_status_rejected() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        let result = conn.execute(
            "INSERT INTO tasks (id, title, status) VALUES ('t_bl', 'Test', 'backlog')",
            [],
        );
        assert!(result.is_err());
    }

    #[test]
    fn consolidated_schema_task_activity_v2() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(task_activity)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(!columns.contains(&"minutes_logged".to_string()));

        // Insert a task for FK
        conn.execute(
            "INSERT INTO tasks (id, title) VALUES ('t1', 'Test')",
            [],
        )
        .unwrap();

        // Positive: valid actions
        for action in &["created", "status_changed", "updated", "note_added", "deleted"] {
            conn.execute(
                &format!(
                    "INSERT INTO task_activity (task_id, action) VALUES ('t1', '{action}')"
                ),
                [],
            )
            .unwrap();
        }

        // Negative: v1-only actions
        for action in &["time_logged", "dependency_added", "moved"] {
            let result = conn.execute(
                &format!(
                    "INSERT INTO task_activity (task_id, action) VALUES ('t1', '{action}')"
                ),
                [],
            );
            assert!(result.is_err(), "action {action} should be rejected");
        }
    }

    #[test]
    fn consolidated_schema_cron_tables_exist() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'cron_%'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(tables.contains(&"cron_jobs".to_string()));
        assert!(tables.contains(&"cron_runs".to_string()));
    }

    #[test]
    fn consolidated_schema_cron_has_tool_restrictions() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(cron_jobs)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(columns.contains(&"tool_restrictions_json".to_string()));
    }

    #[test]
    fn consolidated_schema_cron_indexes() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let indexes: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_cron_%'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for idx in &[
            "idx_cron_jobs_enabled_next",
            "idx_cron_runs_job_started",
            "idx_cron_runs_status",
            "idx_cron_runs_created",
        ] {
            assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
        }
    }

    #[test]
    fn consolidated_schema_cron_constraints() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Positive: valid values
        conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, overlap_policy, misfire_policy)
             VALUES ('j1', 'x', '{}', '{}', 'skip', 'run_once')",
            [],
        )
        .unwrap();

        // Negative: invalid overlap_policy
        let r = conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, overlap_policy)
             VALUES ('j2', 'x', '{}', '{}', 'invalid')",
            [],
        );
        assert!(r.is_err());

        // Negative: invalid misfire_policy
        let r = conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, misfire_policy)
             VALUES ('j3', 'x', '{}', '{}', 'invalid')",
            [],
        );
        assert!(r.is_err());

        // Negative: invalid run status
        let r = conn.execute(
            "INSERT INTO cron_runs (id, job_name, status) VALUES ('r1', 'x', 'invalid')",
            [],
        );
        assert!(r.is_err());
    }

    #[test]
    fn consolidated_schema_cron_on_delete_set_null() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO cron_jobs (id, name, schedule_json, payload_json)
             VALUES ('job1', 'Test', '{}', '{}')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO cron_runs (id, job_id, job_name) VALUES ('run1', 'job1', 'Test')",
            [],
        )
        .unwrap();
        conn.execute("DELETE FROM cron_jobs WHERE id = 'job1'", [])
            .unwrap();

        let job_id: Option<String> = conn
            .query_row(
                "SELECT job_id FROM cron_runs WHERE id = 'run1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(job_id.is_none());
    }

    #[test]
    fn consolidated_schema_memory_vectors_exists() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(memory_vectors)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for col in &[
            "id", "event_id", "workspace_id", "chunk_type",
            "chunk_index", "entry_type", "created_at", "embedding",
        ] {
            assert!(columns.contains(&col.to_string()), "missing column: {col}");
        }
    }

    #[test]
    fn consolidated_schema_memory_vectors_indexes() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let indexes: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_mv_%'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for idx in &["idx_mv_event", "idx_mv_workspace", "idx_mv_type"] {
            assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
        }
    }

    #[test]
    fn consolidated_schema_tasks_fts_only() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(tables.contains(&"tasks_fts".to_string()));
        assert!(!tables.contains(&"areas_fts".to_string()));
    }

    #[test]
    fn consolidated_schema_tasks_fts_triggers() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let triggers: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for t in &["tasks_fts_insert", "tasks_fts_update", "tasks_fts_delete"] {
            assert!(triggers.contains(&t.to_string()), "missing trigger: {t}");
        }
        for t in &["areas_fts_insert", "areas_fts_update", "areas_fts_delete"] {
            assert!(!triggers.contains(&t.to_string()), "{t} should not exist");
        }
    }

    #[test]
    fn consolidated_schema_tasks_parent_fk() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

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
    fn consolidated_schema_tasks_parent_cascade_delete() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

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
        conn.execute("DELETE FROM tasks WHERE id = 'parent'", [])
            .unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM tasks WHERE id = 'child'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn unique_session_sequence_constraint_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_1', 'sess_1', 1, 'message.user', '2025-01-01T00:00:00Z',
                     '{\"content\": \"hello\"}', 'ws_1')",
            [],
        )
        .unwrap();

        let duplicate = conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_2', 'sess_1', 1, 'message.assistant', '2025-01-01T00:00:00Z',
                     '{\"content\": \"world\"}', 'ws_1')",
            [],
        );

        assert!(duplicate.is_err());
    }

    #[test]
    fn notification_read_state_table_exists() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(
            tables.contains(&"notification_read_state".to_string()),
            "missing table: notification_read_state"
        );
    }

    #[test]
    fn notification_read_state_insert_and_query() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO notification_read_state (event_id, read_at) VALUES ('evt_1', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        let (event_id, read_at): (String, String) = conn
            .query_row(
                "SELECT event_id, read_at FROM notification_read_state WHERE event_id = 'evt_1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(event_id, "evt_1");
        assert_eq!(read_at, "2026-01-01T00:00:00Z");
    }

    #[test]
    fn ios_client_dedup_index_prevents_duplicates() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
             VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
            [],
        )
        .unwrap();

        // Exact duplicate should fail
        let dup = conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
             VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
            [],
        );
        assert!(dup.is_err());

        // INSERT OR IGNORE should succeed silently
        conn.execute(
            "INSERT OR IGNORE INTO logs (timestamp, level, level_num, component, message, origin)
             VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
            [],
        )
        .unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn ios_dedup_does_not_affect_server_logs() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Server logs with same timestamp+component+message should be fine
        for origin in &["localhost:9847", "localhost:9846"] {
            conn.execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
                 VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'EventStore', 'test', ?1)",
                [origin],
            )
            .unwrap();
        }

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin != 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
    }
}
