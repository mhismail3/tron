//! Schema migration runner for the event store database.
//!
//! Tron ships a consolidated `v001_schema.sql` for fresh databases, plus
//! small additive follow-up migrations for installs that already recorded v001.
//! There are no table-rebuild migrations or backward-compat branches; each
//! appended migration is idempotent and moves version N-1 to N.
//!
//! The `schema_version` table tracks which migrations have been applied.
//! Running the migrator is idempotent: already-applied versions are skipped.
//!
//! Each migration runs inside a single transaction — a failure rolls back
//! cleanly with no partial schema state. After the transaction commits,
//! `PRAGMA foreign_key_check` runs as a belt-and-suspenders safety net that
//! would surface any dangling references left by a future rebuild-style
//! migration before they reach production.
//!
//! # INVARIANT
//! Every migration SQL file stands alone: it must bring the schema from the
//! state at version N-1 to version N. For the consolidated v001, that means
//! "empty DB → full schema." Editing v001 after a DB has already recorded it
//! as applied will produce inconsistent databases in the wild — add a new
//! migration instead.

use rusqlite::Connection;
use tracing::{debug, info};

use crate::domains::session::event_store::errors::{EventStoreError, Result};

/// A single migration with a version number and SQL to execute.
struct Migration {
    version: u32,
    description: &'static str,
    sql: &'static str,
}

/// All migrations in version order.
///
/// Migrations in application order.
const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        description: "Consolidated schema — all core tables, indexes, and CHECK constraints",
        sql: include_str!("v001_schema.sql"),
    },
    Migration {
        version: 2,
        description: "Constitution audit tables for migrated v001 databases",
        sql: include_str!("v002_constitution_audit.sql"),
    },
    Migration {
        version: 4,
        description: "Session execution profile",
        sql: include_str!("v004_session_profile.sql"),
    },
    Migration {
        version: 5,
        description: "Drop retired profile migration ledger",
        sql: include_str!("v005_drop_profile_migrations.sql"),
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
/// Returns [`EventStoreError::Migration`] if any migration SQL fails or if
/// the post-migration FK check reports any violations.
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

/// Run a single migration inside a transaction, then verify no foreign-key
/// violations were introduced. The FK check is defense-in-depth: a
/// fresh-schema migration cannot produce violations today, but a future
/// rebuild-style migration could, and we want that to fail loudly at the
/// migration point rather than silently ship corruption.
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

    let _inserted = tx
        .execute(
            "INSERT INTO schema_version (version, applied_at, description) VALUES (?1, datetime('now'), ?2)",
            rusqlite::params![migration.version, migration.description],
        )
        .map_err(|e| EventStoreError::Migration {
            message: format!(
                "failed to record v{} in schema_version: {e}",
                migration.version
            ),
        })?;

    // FK sanity check: zero rows ⇒ every FK is satisfied. Any row signals a
    // dangling reference the migration left behind. This is redundant for
    // the consolidated v001 (fresh schema has no rows to point at anything)
    // but is the first line of defense if a future migration rebuilds a
    // table.
    let violations = check_foreign_keys(&tx, migration.version)?;
    if !violations.is_empty() {
        return Err(EventStoreError::Migration {
            message: format!(
                "v{} left {} foreign-key violation(s): {:?}",
                migration.version,
                violations.len(),
                violations
            ),
        });
    }

    tx.commit().map_err(|e| EventStoreError::Migration {
        message: format!("failed to commit v{}: {e}", migration.version),
    })?;

    Ok(())
}

/// Run `PRAGMA foreign_key_check` and collect any violations.
///
/// Each violation row is `(child_table, rowid, parent_table, fk_id)`.
fn check_foreign_keys(
    tx: &rusqlite::Transaction<'_>,
    version: u32,
) -> Result<Vec<(String, i64, String, i64)>> {
    let mut stmt =
        tx.prepare("PRAGMA foreign_key_check")
            .map_err(|e| EventStoreError::Migration {
                message: format!("failed to prepare foreign_key_check for v{version}: {e}"),
            })?;
    let violations: Vec<(String, i64, String, i64)> = stmt
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .map_err(|e| EventStoreError::Migration {
            message: format!("failed to read foreign_key_check for v{version}: {e}"),
        })?
        .filter_map(std::result::Result::ok)
        .collect();
    Ok(violations)
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

    fn seed_workspace_and_session(conn: &Connection, ws: &str, sess: &str) {
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES (?1, ?2, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            rusqlite::params![ws, format!("/tmp/{ws}")],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at)
             VALUES (?1, ?2, 'claude-3', '/tmp',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            rusqlite::params![sess, ws],
        )
        .unwrap();
    }

    // ── Migrator mechanics ────────────────────────────────────────────────

    #[test]
    fn run_migrations_creates_all_tables() {
        let conn = open_memory();
        let result = run_migrations(&conn).unwrap();
        assert_eq!(result.applied, 4);
        assert_eq!(result.max_version_applied, 5);

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
            "constitution_context_blocks",
            "constitution_home_audit",
            "constitution_resolution_audit",
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
    fn run_migrations_creates_no_fts_tables() {
        // FTS was in the original v001 draft; consolidated schema deliberately
        // omits it. Guard against a future reintroduction without conscious
        // decision.
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let fts: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_fts'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(fts.is_empty(), "no FTS tables should exist; found: {fts:?}");
    }

    #[test]
    fn run_migrations_is_idempotent() {
        let conn = open_memory();
        let first = run_migrations(&conn).unwrap();
        assert_eq!(first.applied, 4);

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
        assert_eq!(current_version(&conn).unwrap(), 5);
    }

    #[test]
    fn latest_version_matches_migrations() {
        assert_eq!(latest_version(), 5);
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
        assert!(
            desc.contains("Consolidated"),
            "description missing expected text: {desc}"
        );

        let (version, desc): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 2",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(version, 2);
        assert!(
            desc.contains("Constitution"),
            "description missing expected text: {desc}"
        );

        let (version, desc): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 4",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(version, 4);
        assert!(
            desc.contains("Session execution profile"),
            "description missing expected text: {desc}"
        );

        let (version, desc): (u32, String) = conn
            .query_row(
                "SELECT version, description FROM schema_version WHERE version = 5",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(version, 5);
        assert!(
            desc.contains("Drop retired profile migration ledger"),
            "description missing expected text: {desc}"
        );
    }

    #[test]
    fn session_profile_migration_backfills_chat_source() {
        let conn = open_memory();
        ensure_version_table(&conn).unwrap();
        for migration in &MIGRATIONS[..2] {
            apply_migration(&conn, migration).unwrap();
        }

        conn.execute(
            "INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
             VALUES ('w1', '/tmp', 'tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions
             (id, workspace_id, latest_model, working_directory, created_at, last_activity_at, source)
             VALUES
             ('normal-session', 'w1', 'm', '/tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL),
             ('chat-session', 'w1', 'm', '/tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'chat')",
            [],
        )
        .unwrap();

        run_migrations(&conn).unwrap();

        let normal_profile: String = conn
            .query_row(
                "SELECT profile FROM sessions WHERE id = 'normal-session'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let chat_profile: String = conn
            .query_row(
                "SELECT profile FROM sessions WHERE id = 'chat-session'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(normal_profile, "normal");
        assert_eq!(chat_profile, "chat");
    }

    #[test]
    fn post_migration_fk_check_accepts_empty_schema() {
        // The safety-net FK check must be a no-op on an empty fresh schema.
        // If this ever regresses, run_migrations() will return Err and every
        // downstream test will fail loudly.
        let conn = open_memory();
        run_migrations(&conn).unwrap(); // unwrap asserts the FK check passed
    }

    // ── Index presence ────────────────────────────────────────────────────

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

        let expected = [
            // events
            "idx_events_session_seq",
            "idx_events_session_sequence_unique",
            // sessions
            "idx_sessions_workspace",
            "idx_sessions_created",
            "idx_sessions_origin",
            "idx_sessions_source",
            "idx_sessions_profile",
            // blobs / branches / workspaces
            "idx_blobs_hash",
            "idx_branches_session",
            "idx_workspaces_path",
            // logs
            "idx_logs_ios_client_dedup",
            // device_tokens
            "idx_device_tokens_identity",
            "idx_device_tokens_session",
            "idx_device_tokens_token",
            "idx_device_tokens_workspace",
            // cron
            "idx_cron_jobs_enabled_next",
            "idx_cron_runs_job_started",
            "idx_cron_runs_status",
            "idx_cron_runs_created",
            // prompt library
            "idx_prompt_history_last_used",
            "idx_prompt_history_use_count",
            "idx_prompt_snippets_updated",
        ];
        for idx in &expected {
            assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
        }

        // Guard against the old (pre-consolidation) noisy indexes sneaking back
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
    fn no_triggers_exist() {
        // Fresh schema uses inline CHECK constraints instead of BEFORE
        // triggers (which v005 used as a workaround for "SQLite cannot ALTER
        // ADD CHECK"). Guard against triggers creeping back.
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let triggers: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(
            triggers.is_empty(),
            "no triggers expected; found: {triggers:?}"
        );
    }

    #[test]
    fn legacy_v1_tables_absent() {
        // Confirm removed tables from prior schema revisions don't leak back
        // through copy-paste.
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for removed in &[
            "projects",
            "areas",
            "tasks",
            "task_dependencies",
            "profile_migrations",
        ] {
            assert!(
                !tables.contains(&removed.to_string()),
                "{removed} should not exist"
            );
        }
    }

    // ── events table column shape + invariants ────────────────────────────

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
    fn events_check_constraint_appears_in_schema() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'events'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert!(
            sql.contains("CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)"),
            "events table missing payload/content_blob CHECK; got: {sql}"
        );
    }

    #[test]
    fn events_null_payload_rejected() {
        // Belt-and-suspenders: payload is NOT NULL at the column level today,
        // so a literal NULL payload is caught by NOT NULL first. If a future
        // change relaxes NOT NULL, the table-level CHECK becomes the binding
        // enforcement. The test's role is that the row is rejected, not which
        // constraint catches it.
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        seed_workspace_and_session(&conn, "ws_1", "s1");

        let err = conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload,
                                 content_blob_id, workspace_id)
             VALUES ('e_empty', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', NULL,
                     NULL, 'ws_1')",
            [],
        );
        assert!(
            err.is_err(),
            "NULL payload + NULL content_blob_id must be rejected"
        );
    }

    #[test]
    fn events_unique_session_sequence_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        seed_workspace_and_session(&conn, "ws_1", "s1");

        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('e1', 's1', 1, 'message.user', '2026-01-01T00:00:00Z',
                     '{\"content\":\"hello\"}', 'ws_1')",
            [],
        )
        .unwrap();

        let duplicate = conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('e2', 's1', 1, 'message.assistant', '2026-01-01T00:00:00Z',
                     '{\"content\":\"world\"}', 'ws_1')",
            [],
        );
        assert!(duplicate.is_err());
    }

    #[test]
    fn events_turn_metadata_columns_are_nullable() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        seed_workspace_and_session(&conn, "ws_1", "s1");

        // Insert event WITHOUT the denormalized columns — they should default to NULL
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_1', 's1', 1, 'message.user', '2025-01-01T00:00:00Z', '{}', 'ws_1')",
            [],
        )
        .unwrap();

        let (model, latency, stop, thinking, provider, cost): (
            Option<String>,
            Option<i64>,
            Option<String>,
            Option<i64>,
            Option<String>,
            Option<f64>,
        ) = conn
            .query_row(
                "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost
                 FROM events WHERE id = 'evt_1'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
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
    fn events_turn_metadata_columns_can_be_populated() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        seed_workspace_and_session(&conn, "ws_1", "s1");

        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id,
                                 model, latency_ms, stop_reason, has_thinking, provider_type, cost)
             VALUES ('evt_1', 's1', 1, 'message.assistant', '2025-01-01T00:00:00Z', '{}', 'ws_1',
                     'claude-opus-4-6', 1500, 'end_turn', 1, 'anthropic', 0.015)",
            [],
        )
        .unwrap();

        let (model, latency, stop, thinking, provider, cost): (
            String,
            i64,
            String,
            i64,
            String,
            f64,
        ) = conn
            .query_row(
                "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost
                 FROM events WHERE id = 'evt_1'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .unwrap();

        assert_eq!(model, "claude-opus-4-6");
        assert_eq!(latency, 1500);
        assert_eq!(stop, "end_turn");
        assert_eq!(thinking, 1);
        assert_eq!(provider, "anthropic");
        assert!((cost - 0.015).abs() < f64::EPSILON);
    }

    // ── events FK behavior (replaces v008 rebuild tests with plain invariants) ─

    #[test]
    fn events_self_referential_parent_id_fk_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        seed_workspace_and_session(&conn, "ws_1", "s1");

        // root event, then child referencing root
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('e_root', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', '{}', 'ws_1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (id, session_id, parent_id, sequence, type, timestamp,
                                 payload, workspace_id)
             VALUES ('e_child', 's1', 'e_root', 2, 'message.assistant', '2026-01-01T00:00:01Z',
                     '{}', 'ws_1')",
            [],
        )
        .unwrap();

        // parent_id pointing at a nonexistent row is rejected
        let err = conn.execute(
            "INSERT INTO events (id, session_id, parent_id, sequence, type, timestamp,
                                 payload, workspace_id)
             VALUES ('e_bad', 's1', 'e_missing', 3, 'message.user', '2026-01-01T00:00:02Z',
                     '{}', 'ws_1')",
            [],
        );
        assert!(err.is_err(), "events.parent_id FK must reject missing id");
    }

    #[test]
    fn branches_fk_to_events_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();
        seed_workspace_and_session(&conn, "ws_1", "s1");

        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('e1', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', '{}', 'ws_1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO branches (id, session_id, name, root_event_id, head_event_id,
                                   created_at, last_activity_at)
             VALUES ('b1', 's1', 'main', 'e1', 'e1',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        let err = conn.execute(
            "INSERT INTO branches (id, session_id, name, root_event_id, head_event_id,
                                   created_at, last_activity_at)
             VALUES ('b_bad', 's1', 'orphan', 'e_missing', 'e_missing',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        );
        assert!(err.is_err(), "branches FK to events must reject missing id");
    }

    // ── sessions shape + use_worktree CHECK ───────────────────────────────

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
            "profile",
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

        for (table, col) in &[("sessions", "origin"), ("logs", "origin")] {
            let cols: Vec<String> = conn
                .prepare(&format!("PRAGMA table_info({table})"))
                .unwrap()
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .filter_map(std::result::Result::ok)
                .collect();
            assert!(
                cols.contains(&(*col).to_string()),
                "{table} table missing {col} column"
            );
        }
    }

    #[test]
    fn sessions_workspace_fk_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let result = conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at)
             VALUES ('sess_1', 'nonexistent', 'claude-3', '/tmp',
                     '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        );
        assert!(result.is_err());
    }

    #[test]
    fn sessions_use_worktree_round_trips_true_false_null() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

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
            .query_row(
                "SELECT use_worktree FROM sessions WHERE id = 'sess_null'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let true_val: Option<i64> = conn
            .query_row(
                "SELECT use_worktree FROM sessions WHERE id = 'sess_true'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let false_val: Option<i64> = conn
            .query_row(
                "SELECT use_worktree FROM sessions WHERE id = 'sess_false'",
                [],
                |r| r.get(0),
            )
            .unwrap();

        assert!(null_val.is_none());
        assert_eq!(true_val, Some(1));
        assert_eq!(false_val, Some(0));
    }

    #[test]
    fn sessions_use_worktree_check_rejects_invalid_on_insert() {
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
        assert!(err.is_err(), "use_worktree = 2 must be rejected on INSERT");
        let msg = err.unwrap_err().to_string();
        assert!(
            msg.contains("CHECK constraint failed") && msg.contains("use_worktree"),
            "expected CHECK failure mentioning use_worktree, got: {msg}"
        );

        // Negative values rejected.
        let err_neg = conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                   created_at, last_activity_at, use_worktree)
             VALUES ('sess_neg', 'ws_1', 'claude-3', '/tmp/test',
                     '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', -1)",
            [],
        );
        assert!(
            err_neg.is_err(),
            "use_worktree = -1 must be rejected on INSERT"
        );
    }

    #[test]
    fn sessions_use_worktree_check_rejects_invalid_on_update() {
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

        // Valid UPDATE succeeds.
        conn.execute("UPDATE sessions SET use_worktree = 1 WHERE id = 's1'", [])
            .unwrap();

        // Invalid UPDATE rejected; pre-existing value preserved.
        let err = conn.execute("UPDATE sessions SET use_worktree = 99 WHERE id = 's1'", []);
        assert!(err.is_err(), "use_worktree = 99 must be rejected on UPDATE");

        let val: Option<i64> = conn
            .query_row(
                "SELECT use_worktree FROM sessions WHERE id = 's1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(val, Some(1), "row should retain pre-rejection value");
    }

    // ── notification_read_state ───────────────────────────────────────────

    #[test]
    fn notification_read_state_insert_and_query() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO notification_read_state (event_id, read_at)
             VALUES ('evt_1', '2026-01-01T00:00:00Z')",
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

    // ── iOS client log dedup ──────────────────────────────────────────────

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

        let dup = conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
             VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
            [],
        );
        assert!(dup.is_err());

        // INSERT OR IGNORE is idempotent.
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

        // Server logs with matching timestamp+component+message insert freely.
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

    // ── device_tokens identity (bundle_id + COALESCE UNIQUE) ──────────────

    #[test]
    fn device_tokens_has_bundle_id_column() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(device_tokens)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert!(columns.contains(&"bundle_id".to_string()));
    }

    #[test]
    fn device_tokens_bundle_id_round_trips() {
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

        let bundle_id: String = conn
            .query_row(
                "SELECT bundle_id FROM device_tokens WHERE id = 'dt_1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bundle_id, "com.tron.mobile.beta");
    }

    /// Post-R5: `bundle_id` is NOT NULL — every registration carries its
    /// APNs topic. An INSERT that omits bundle_id must be rejected by the
    /// schema, so clients cannot register without a bundle and the send
    /// path never needs a topic fallback.
    #[test]
    fn device_tokens_bundle_id_is_not_null() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_2', 'bb', 'ios', 'production',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        );
        assert!(
            err.is_err(),
            "INSERT without bundle_id must be rejected by NOT NULL constraint"
        );

        // Also reject an explicit NULL.
        let err_explicit = conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_null', 'cc', 'ios', 'production', NULL,
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        );
        assert!(
            err_explicit.is_err(),
            "INSERT with explicit NULL bundle_id must be rejected"
        );
    }

    #[test]
    fn device_tokens_unique_allows_same_token_across_workspaces() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/t1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                    ('ws_2', '/t2', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                        bundle_id, created_at, last_used_at, is_active)
             VALUES ('dt_a', 'zz', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                        bundle_id, created_at, last_used_at, is_active)
             VALUES ('dt_b', 'zz', 'ws_2', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        // Full-identity duplicate (same token, same workspace, same bundle) rejected.
        let dup = conn.execute(
            "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                        bundle_id, created_at, last_used_at, is_active)
             VALUES ('dt_dup', 'zz', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        );
        assert!(
            dup.is_err(),
            "duplicate (token, ios, ws_1, bundle) must be rejected by UNIQUE index"
        );
    }

    /// COALESCE(workspace_id, '') collapses NULL to a single canonical
    /// sentinel so a workspace-less token can't register twice as "(token,
    /// ios, NULL, bundle)" (SQLite's native UNIQUE treats NULL as
    /// distinct). `bundle_id` is NOT NULL so only workspace_id needs the
    /// COALESCE widening; a concrete bundle participates in the index
    /// directly.
    #[test]
    fn device_tokens_unique_collapses_null_workspace() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_null1', 'nn', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        let dup = conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                        created_at, last_used_at, is_active)
             VALUES ('dt_null2', 'nn', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        );
        assert!(
            dup.is_err(),
            "two (token, ios, NULL ws, same bundle) rows must be rejected by COALESCE index"
        );
    }

    /// The consolidated schema must NOT carry the legacy narrow
    /// UNIQUE(device_token, platform): two registrations with the same token
    /// and platform but distinct workspaces must both succeed.
    #[test]
    fn device_tokens_no_narrow_unique() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/t1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                    ('ws_2', '/t2', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                        bundle_id, created_at, last_used_at, is_active)
             VALUES ('dt_a', 'aa', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                        bundle_id, created_at, last_used_at, is_active)
             VALUES ('dt_b', 'aa', 'ws_2', 'ios', 'production', 'com.tron.mobile',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap_or_else(|e| panic!("same token in two workspaces must succeed: {e}"));
    }

    #[test]
    fn device_tokens_auxiliary_indexes_exist() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let indexes: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master
                 WHERE type = 'index' AND tbl_name = 'device_tokens' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        for expected in &[
            "idx_device_tokens_identity",
            "idx_device_tokens_session",
            "idx_device_tokens_token",
            "idx_device_tokens_workspace",
        ] {
            assert!(
                indexes.contains(&expected.to_string()),
                "missing {expected}; found: {indexes:?}"
            );
        }
    }

    // ── prompt library ────────────────────────────────────────────────────

    #[test]
    fn prompt_history_use_count_check_rejects_zero() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at,
                                         use_count, char_count)
             VALUES ('p1', 'hello', 'h1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0, 5)",
            [],
        );
        assert!(err.is_err(), "use_count = 0 should be rejected by CHECK");
    }

    #[test]
    fn prompt_history_char_count_check_rejects_zero() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at,
                                         use_count, char_count)
             VALUES ('p1', 'hello', 'h1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 0)",
            [],
        );
        assert!(err.is_err(), "char_count = 0 should be rejected by CHECK");
    }

    #[test]
    fn prompt_history_text_hash_unique_enforced() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at,
                                         use_count, char_count)
             VALUES ('p1', 'hello', 'hash1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 5)",
            [],
        )
        .unwrap();

        let dup = conn.execute(
            "INSERT INTO prompt_history (id, text, text_hash, first_used_at, last_used_at,
                                         use_count, char_count)
             VALUES ('p2', 'hello again', 'hash1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 11)",
            [],
        );
        assert!(dup.is_err());
    }

    #[test]
    fn prompt_snippets_name_length_check() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        // Empty name rejected.
        let err_empty = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s1', '', 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        );
        assert!(err_empty.is_err());

        // 101-char name rejected.
        let long = "a".repeat(101);
        let err_long = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s2', ?1, 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [&long],
        );
        assert!(err_long.is_err());

        // 100-char name accepted.
        let max = "a".repeat(100);
        conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s3', ?1, 'hello', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [&max],
        )
        .unwrap();
    }

    #[test]
    fn prompt_snippets_text_non_empty_check() {
        let conn = open_memory();
        run_migrations(&conn).unwrap();

        let err = conn.execute(
            "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
             VALUES ('s1', 'n', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        );
        assert!(err.is_err());
    }

    #[test]
    fn prompt_snippets_duplicate_names_allowed() {
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
            .query_row(
                "SELECT COUNT(*) FROM prompt_snippets WHERE name = 'Shared'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
    }
}
