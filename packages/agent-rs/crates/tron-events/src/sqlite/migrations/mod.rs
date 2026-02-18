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

use crate::errors::{EventStoreError, Result};

/// A single migration with a version number and SQL to execute.
struct Migration {
    version: u32,
    description: &'static str,
    sql: &'static str,
}

/// All migrations in version order.
const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        description: "Complete schema — core tables, FTS, indexes, triggers",
        sql: include_str!("v001_schema.sql"),
    },
    Migration {
        version: 2,
        description: "Per-turn metadata columns on events table",
        sql: include_str!("v002_turn_metadata.sql"),
    },
    Migration {
        version: 3,
        description: "Unique per-session event sequence index",
        sql: include_str!("v003_session_sequence_unique.sql"),
    },
];

/// Run all pending migrations on the given connection.
///
/// Creates the `schema_version` table if it doesn't exist, then applies
/// each migration whose version exceeds the current maximum. Each migration
/// runs in its own transaction.
///
/// # Errors
///
/// Returns [`EventStoreError::Migration`] if any migration SQL fails.
pub fn run_migrations(conn: &Connection) -> Result<u32> {
    ensure_version_table(conn)?;
    let current = current_version(conn)?;
    let mut applied = 0;

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
    }

    if applied > 0 {
        info!(applied, "migrations complete");
    }

    Ok(applied)
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
        let applied = run_migrations(&conn).unwrap();
        assert_eq!(applied, 3);

        // Verify core tables exist
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();

        let expected = [
            "areas",
            "blobs",
            "branches",
            "device_tokens",
            "events",
            "logs",
            "projects",
            "schema_version",
            "sessions",
            "task_activity",
            "task_backlog",
            "task_dependencies",
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
            .filter_map(|r| r.ok())
            .collect();

        assert!(tables.contains(&"events_fts".to_string()));
        assert!(tables.contains(&"logs_fts".to_string()));
        assert!(tables.contains(&"tasks_fts".to_string()));
        assert!(tables.contains(&"areas_fts".to_string()));
    }

    #[test]
    fn run_migrations_is_idempotent() {
        let conn = open_memory();
        let first = run_migrations(&conn).unwrap();
        assert_eq!(first, 3);

        let second = run_migrations(&conn).unwrap();
        assert_eq!(second, 0);
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
        assert_eq!(current_version(&conn).unwrap(), 3);
    }

    #[test]
    fn latest_version_matches_migrations() {
        assert_eq!(latest_version(), 3);
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
            .filter_map(|r| r.ok())
            .collect();

        // Spot-check key indexes
        let expected = [
            "idx_events_session_seq",
            "idx_events_parent",
            "idx_events_tool_call_id",
            "idx_sessions_workspace",
            "idx_sessions_created",
            "idx_logs_timestamp",
            "idx_logs_trace_id",
            "idx_tasks_status",
            "idx_areas_workspace",
            "idx_blobs_hash",
            "idx_branches_session",
            // v002 indexes
            "idx_events_model",
            "idx_events_latency",
            // v003 index
            "idx_events_session_sequence_unique",
        ];
        for idx in &expected {
            assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
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
            .filter_map(|r| r.ok())
            .collect();

        let expected = [
            "events_fts_insert",
            "events_fts_delete",
            "logs_fts_insert",
            "logs_fts_delete",
            "tasks_fts_insert",
            "tasks_fts_update",
            "tasks_fts_delete",
            "areas_fts_insert",
            "areas_fts_update",
            "areas_fts_delete",
        ];
        for trigger in &expected {
            assert!(
                triggers.contains(&trigger.to_string()),
                "missing trigger: {trigger}"
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
            .filter_map(|r| r.ok())
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
            // v002 columns
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
            .filter_map(|r| r.ok())
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
        ];
        for col in &expected {
            assert!(
                columns.contains(&col.to_string()),
                "sessions table missing column: {col}"
            );
        }
    }

    #[test]
    fn fts_events_trigger_fires_on_insert() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Insert a workspace and session first (FK constraints)
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

        // Insert an event
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_1', 'sess_1', 1, 'message.user', '2025-01-01T00:00:00Z',
                     '{\"content\": \"hello world\"}', 'ws_1')",
            [],
        )
        .unwrap();

        // Verify FTS was populated
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events_fts WHERE events_fts MATCH 'hello'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn fts_events_trigger_fires_on_delete() {
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
                     '{\"content\": \"hello world\"}', 'ws_1')",
            [],
        )
        .unwrap();

        // Delete the event
        conn.execute("DELETE FROM events WHERE id = 'evt_1'", [])
            .unwrap();

        // FTS entry should be gone
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events_fts WHERE events_fts MATCH 'hello'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
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
    fn v002_schema_version_recorded() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let (version, desc): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 2",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(version, 2);
        assert!(desc.contains("Per-turn metadata"));
    }

    #[test]
    fn v002_new_columns_are_nullable() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Insert a workspace and session for FK constraints
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
    fn v002_new_columns_can_be_populated() {
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

    #[test]
    fn task_self_dependency_rejected() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Insert prerequisites
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tasks (id, workspace_id, title, created_at, updated_at)
             VALUES ('t_1', 'ws_1', 'Test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Self-dependency should fail via CHECK constraint
        let result = conn.execute(
            "INSERT INTO task_dependencies (blocker_task_id, blocked_task_id, created_at)
             VALUES ('t_1', 't_1', '2025-01-01T00:00:00Z')",
            [],
        );
        assert!(result.is_err());
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
}
