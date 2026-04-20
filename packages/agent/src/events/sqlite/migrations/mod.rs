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
const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        description: "Complete schema — core tables, FTS, indexes, triggers",
        sql: include_str!("v001_schema.sql"),
    },
    Migration {
        version: 2,
        description: "Prompt Library — history and snippets",
        sql: include_str!("v002_schema.sql"),
    },
    Migration {
        version: 3,
        description: "Remove legacy spell.cast / spell.consumed events",
        sql: include_str!("v003_remove_spells.sql"),
    },
    Migration {
        version: 4,
        description: "Per-session worktree override (sessions.use_worktree)",
        sql: include_str!("v004_session_use_worktree.sql"),
    },
    Migration {
        version: 5,
        description: "Add CHECK (use_worktree IN (0, 1)) to sessions",
        sql: include_str!("v005_sessions_use_worktree_check.sql"),
    },
    Migration {
        version: 6,
        description: "Per-token APNs bundle ID (device_tokens.bundle_id)",
        sql: include_str!("v006_device_token_bundle_id.sql"),
    },
];

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
        assert_eq!(result.applied, 6);
        assert_eq!(result.max_version_applied, 6);

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
            "notification_read_state",
            "prompt_history",
            "prompt_snippets",
            "schema_version",
            "sessions",
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
        assert!(
            !tables.contains(&"tasks_fts".to_string()),
            "tasks_fts should not exist"
        );
        assert!(
            !tables.contains(&"areas_fts".to_string()),
            "areas_fts should not exist"
        );
    }

    #[test]
    fn run_migrations_is_idempotent() {
        let conn = open_memory();
        let first = run_migrations(&conn).unwrap();
        assert_eq!(first.applied, 6);

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
        assert_eq!(current_version(&conn).unwrap(), 6);
    }

    #[test]
    fn latest_version_matches_migrations() {
        assert_eq!(latest_version(), 6);
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

        let (v2, desc2): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 2",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(v2, 2);
        assert!(desc2.contains("Prompt Library"));
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
            "idx_blobs_hash",
            "idx_branches_session",
            "idx_sessions_origin",
            "idx_sessions_source",
            "idx_logs_ios_client_dedup",
            "idx_cron_jobs_enabled_next",
            "idx_cron_runs_job_started",
            "idx_cron_runs_status",
            "idx_cron_runs_created",
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

        // No triggers should exist after cleanup
        let removed = [
            "events_fts_insert",
            "events_fts_delete",
            "areas_fts_insert",
            "areas_fts_update",
            "areas_fts_delete",
            "tasks_fts_insert",
            "tasks_fts_update",
            "tasks_fts_delete",
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
            "use_worktree",
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

    // ── v002 prompt_library tests ─────────────────────────────────────

    #[test]
    fn v002_upgrade_from_v1_preserves_existing_data() {
        // Simulate an existing v1 database: run only v1 and insert a row.
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        let v1 = &MIGRATIONS[0];
        apply_migration(&conn, v1).unwrap();
        assert_eq!(current_version(&conn).unwrap(), 1);

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/v1', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Now run the full migrator — v2 through v6 should apply.
        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 5);
        assert_eq!(result.max_version_applied, 6);

        // v1 data is intact.
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM workspaces WHERE id = 'ws_1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);

        // v2 tables exist.
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        assert!(tables.contains(&"prompt_history".to_string()));
        assert!(tables.contains(&"prompt_snippets".to_string()));
    }

    #[test]
    fn v002_prompt_history_use_count_check_rejects_zero() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at, use_count, char_count)
             VALUES ('p1', 'hello', 'h1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0, 5)",
            [],
        );
        assert!(err.is_err(), "use_count = 0 should be rejected by CHECK");
    }

    #[test]
    fn v002_prompt_history_char_count_check_rejects_zero() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at, use_count, char_count)
             VALUES ('p1', 'hello', 'h1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 0)",
            [],
        );
        assert!(err.is_err(), "char_count = 0 should be rejected by CHECK");
    }

    #[test]
    fn v002_prompt_history_text_hash_unique_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at, use_count, char_count)
             VALUES ('p1', 'hello', 'hash1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 5)",
            [],
        )
        .unwrap();

        let dup = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at, use_count, char_count)
             VALUES ('p2', 'hello again', 'hash1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 11)",
            [],
        );
        assert!(dup.is_err(), "duplicate text_hash should be rejected");
    }

    #[test]
    fn v002_prompt_snippets_name_length_check() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Empty name rejected
        let err_empty = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s1', '', 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        );
        assert!(err_empty.is_err(), "empty snippet name should be rejected");

        // 101-char name rejected
        let long = "a".repeat(101);
        let err_long = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s2', ?1, 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [&long],
        );
        assert!(err_long.is_err(), "101-char snippet name should be rejected");

        // 100-char name accepted
        let max = "a".repeat(100);
        conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s3', ?1, 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [&max],
        )
        .unwrap();
    }

    #[test]
    fn v002_prompt_snippets_text_non_empty_check() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s1', 'n', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        );
        assert!(err.is_err(), "empty snippet text should be rejected");
    }

    #[test]
    fn v002_prompt_snippets_duplicate_names_allowed() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s1', 'Shared', 'a', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s2', 'Shared', 'b', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM prompt_snippets WHERE name = 'Shared'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn v002_prompt_library_indexes_exist() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let indexes: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_prompt_%'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for idx in &[
            "idx_prompt_history_last_used",
            "idx_prompt_history_use_count",
            "idx_prompt_snippets_updated",
        ] {
            assert!(
                indexes.contains(&idx.to_string()),
                "missing index: {idx}"
            );
        }
    }

    // ── v003 spell cleanup tests ──────────────────────────────────────

    #[test]
    fn v003_deletes_legacy_spell_events() {
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        apply_migration(&conn, &MIGRATIONS[0]).unwrap();
        apply_migration(&conn, &MIGRATIONS[1]).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('s1', 'ws1', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('sc1','s1',1,'spell.cast','2025-01-01T00:00:00Z','{}','ws1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('sc2','s1',2,'spell.consumed','2025-01-01T00:00:00Z','{}','ws1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('mu1','s1',3,'message.user','2025-01-01T00:00:00Z','{}','ws1')",
            [],
        )
        .unwrap();

        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 4);
        assert_eq!(result.max_version_applied, 6);

        let spell_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type LIKE 'spell.%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(spell_count, 0);

        let preserved: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE id = 'mu1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(preserved, 1);
    }

    // ── v004 use_worktree tests ───────────────────────────────────────

    #[test]
    fn v004_upgrade_from_v3_adds_use_worktree_column_and_preserves_rows() {
        // Simulate a pre-v004 DB by running v1..v3 only.
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        for migration in &MIGRATIONS[..3] {
            apply_migration(&conn, migration).unwrap();
        }
        assert_eq!(current_version(&conn).unwrap(), 3);

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_legacy', '/tmp/legacy', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_legacy', 'ws_legacy', 'claude-3', '/tmp/legacy', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Upgrade.
        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 3);
        assert_eq!(result.max_version_applied, 6);

        // Pre-existing row gets NULL for the new column.
        let use_worktree: Option<i64> = conn
            .query_row(
                "SELECT use_worktree FROM sessions WHERE id = 'sess_legacy'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(use_worktree.is_none(), "legacy row should have NULL use_worktree");
    }

    #[test]
    fn v004_use_worktree_round_trips_true_false_null() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // Insert three sessions with use_worktree = NULL, 1, 0.
        for (sid, value) in &[
            ("sess_null", "NULL"),
            ("sess_true", "1"),
            ("sess_false", "0"),
        ] {
            conn.execute(
                &format!(
                    "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                           created_at, last_activity_at, use_worktree)
                     VALUES ('{sid}', 'ws_1', 'claude-3', '/tmp/test',
                             '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', {value})"
                ),
                [],
            )
            .unwrap();
        }

        let null_val: Option<i64> = conn
            .query_row("SELECT use_worktree FROM sessions WHERE id = 'sess_null'", [], |r| r.get(0))
            .unwrap();
        let true_val: Option<i64> = conn
            .query_row("SELECT use_worktree FROM sessions WHERE id = 'sess_true'", [], |r| r.get(0))
            .unwrap();
        let false_val: Option<i64> = conn
            .query_row("SELECT use_worktree FROM sessions WHERE id = 'sess_false'", [], |r| r.get(0))
            .unwrap();

        assert!(null_val.is_none());
        assert_eq!(true_val, Some(1));
        assert_eq!(false_val, Some(0));
    }

    // ── v005 use_worktree trigger-based check tests ──────────────────

    #[test]
    fn v005_rejects_invalid_use_worktree_on_insert() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        // 0, 1, and NULL all accepted.
        for value in &["0", "1", "NULL"] {
            let id = format!("sess_{value}");
            conn.execute(
                &format!(
                    "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                           created_at, last_activity_at, use_worktree)
                     VALUES ('{id}', 'ws_1', 'claude-3', '/tmp/test',
                             '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', {value})"
                ),
                [],
            )
            .unwrap_or_else(|e| panic!("value {value} should be accepted: {e}"));
        }

        // 2 must be rejected.
        let err = conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at, use_worktree)
             VALUES ('sess_two', 'ws_1', 'claude-3', '/tmp/test',
                     '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 2)",
            [],
        );
        assert!(err.is_err(), "use_worktree = 2 should be rejected on INSERT");
        let msg = err.unwrap_err().to_string();
        assert!(
            msg.contains("use_worktree must be 0, 1, or NULL"),
            "expected explicit trigger failure, got: {msg}"
        );

        // Negative values rejected.
        let err_neg = conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at, use_worktree)
             VALUES ('sess_neg', 'ws_1', 'claude-3', '/tmp/test',
                     '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', -1)",
            [],
        );
        assert!(err_neg.is_err(), "use_worktree = -1 should be rejected on INSERT");
    }

    #[test]
    fn v005_rejects_invalid_use_worktree_on_update() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at, use_worktree)
             VALUES ('s1', 'ws_1', 'claude-3', '/tmp/test',
                     '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', NULL)",
            [],
        )
        .unwrap();

        // Updating to a valid value works.
        conn.execute("UPDATE sessions SET use_worktree = 1 WHERE id = 's1'", [])
            .unwrap();

        // Updating to an invalid value is rejected.
        let err = conn.execute("UPDATE sessions SET use_worktree = 99 WHERE id = 's1'", []);
        assert!(err.is_err(), "use_worktree = 99 must be rejected on UPDATE");

        // The row's value remains unchanged after the rejected update.
        let val: Option<i64> = conn
            .query_row("SELECT use_worktree FROM sessions WHERE id = 's1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(val, Some(1), "row should retain pre-rejection value");
    }

    #[test]
    fn v005_preserves_existing_session_data_on_upgrade_from_v4() {
        // Simulate a populated v4 database, then upgrade to v5. v005 only
        // adds triggers, so every existing row is untouched.
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        for migration in &MIGRATIONS[..4] {
            apply_migration(&conn, migration).unwrap();
        }
        assert_eq!(current_version(&conn).unwrap(), 4);

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/legacy', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (
                id, workspace_id, latest_model, working_directory,
                created_at, last_activity_at, use_worktree,
                event_count, total_input_tokens, total_cost, tags, source
             ) VALUES
                ('s1','ws_1','m','/p','2025-01-01T00:00:00Z','2025-01-01T00:00:00Z',NULL,
                  5, 1000, 0.50, '[\"a\",\"b\"]', 'project'),
                ('s2','ws_1','m','/p','2025-01-02T00:00:00Z','2025-01-02T00:00:00Z',1,
                  2, 500, 0.25, '[]', 'chat'),
                ('s3','ws_1','m','/p','2025-01-03T00:00:00Z','2025-01-03T00:00:00Z',0,
                  0, 0, 0.0, '[\"c\"]', 'project')",
            [],
        )
        .unwrap();

        // Upgrade to v6.
        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 2);
        assert_eq!(result.max_version_applied, 6);

        // All three rows survive untouched.
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 3);

        let s1_tags: String = conn
            .query_row("SELECT tags FROM sessions WHERE id = 's1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(s1_tags, "[\"a\",\"b\"]");

        let s2_use_worktree: Option<i64> = conn
            .query_row("SELECT use_worktree FROM sessions WHERE id = 's2'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(s2_use_worktree, Some(1));

        // The new triggers exist.
        let triggers: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'trigger'
                 AND name LIKE 'trg_sessions_use_worktree%'
                 ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        assert_eq!(
            triggers,
            vec![
                "trg_sessions_use_worktree_insert".to_string(),
                "trg_sessions_use_worktree_update".to_string()
            ]
        );
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

    // ── v006 bundle_id tests ──────────────────────────────────────────

    #[test]
    fn v006_adds_bundle_id_column_to_device_tokens() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(device_tokens)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(
            columns.contains(&"bundle_id".to_string()),
            "device_tokens missing bundle_id column after v006"
        );
    }

    #[test]
    fn v006_bundle_id_round_trips() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_1', 'aa', 'ios', 'sandbox', 'com.tron.mobile.beta',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        let bundle_id: Option<String> = conn
            .query_row(
                "SELECT bundle_id FROM device_tokens WHERE id = 'dt_1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bundle_id.as_deref(), Some("com.tron.mobile.beta"));
    }

    #[test]
    fn v006_bundle_id_is_nullable() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Omit bundle_id — should default to NULL.
        conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_2', 'bb', 'ios', 'production',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        let bundle_id: Option<String> = conn
            .query_row(
                "SELECT bundle_id FROM device_tokens WHERE id = 'dt_2'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(bundle_id.is_none(), "legacy insert should have NULL bundle_id");
    }

    #[test]
    fn v006_upgrade_from_v5_preserves_existing_tokens() {
        // Simulate a pre-v006 DB: run v1..v5 only, insert a token, then upgrade.
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        for migration in &MIGRATIONS[..5] {
            apply_migration(&conn, migration).unwrap();
        }
        assert_eq!(current_version(&conn).unwrap(), 5);

        conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_legacy', 'cc', 'ios', 'sandbox',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 1);
        assert_eq!(result.max_version_applied, 6);

        // Pre-existing row survives with NULL bundle_id.
        let (token, bundle_id): (String, Option<String>) = conn
            .query_row(
                "SELECT device_token, bundle_id FROM device_tokens WHERE id = 'dt_legacy'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(token, "cc");
        assert!(bundle_id.is_none(), "legacy token should have NULL bundle_id after v006");
    }
}
