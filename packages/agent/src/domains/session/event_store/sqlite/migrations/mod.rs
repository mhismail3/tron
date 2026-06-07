//! Schema migration runner for the event store database.
//!
//! Tron ships a single `v001_schema.sql` for the primitive branch.
//! There are no old-shape migrations on this clean-break branch.
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
//! The only supported path is empty DB to the primitive schema.

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
const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    description: "Consolidated schema — all core tables, indexes, and CHECK constraints",
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

    crate::shared::storage::ensure_storage_schema(conn).map_err(|error| {
        EventStoreError::Migration {
            message: format!("failed to ensure unified storage payload schema: {error:#}"),
        }
    })?;

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

    // FK sanity check: zero rows means every FK is satisfied. Any row signals a
    // dangling reference the migration left behind.
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
mod tests;
