//! Current event-store schema installation.
//!
//! Tron supports one consolidated schema. Installation is idempotent and runs
//! in one transaction, followed by a foreign-key integrity check. Additive
//! coordination side tables are therefore repairable on profiles opened by an
//! earlier build without rewriting the existing wait/member audit tables.
//! There is no version ledger or alternate row-shape decoder.

use rusqlite::Connection;

use crate::domains::session::event_store::errors::{EventStoreError, Result};

const CURRENT_SCHEMA: &str = include_str!("current.sql");

/// Ensure every current event-store and shared-storage table exists.
///
/// # Errors
///
/// Returns [`EventStoreError::Schema`] when installation or integrity checking
/// fails.
pub fn ensure_schema(conn: &Connection) -> Result<()> {
    let tx = conn
        .unchecked_transaction()
        .map_err(|error| EventStoreError::Schema {
            message: format!("failed to begin schema transaction: {error}"),
        })?;

    // The core coordination capability stayed unadvertised while its durable
    // provenance columns were hardened. Developer profiles may nevertheless
    // contain the earlier additive tables, so add columns before CURRENT_SCHEMA
    // creates indexes which reference them. No legacy Worker row is rewritten.
    ensure_core_coordination_columns(&tx)?;

    tx.execute_batch(CURRENT_SCHEMA)
        .map_err(|error| EventStoreError::Schema {
            message: format!("failed to install current schema: {error}"),
        })?;

    backfill_core_coordination_trace_owners(&tx)?;

    let violations = foreign_key_violations(&tx)?;
    if !violations.is_empty() {
        return Err(EventStoreError::Schema {
            message: format!(
                "current schema has {} foreign-key violation(s): {:?}",
                violations.len(),
                violations
            ),
        });
    }

    tx.commit().map_err(|error| EventStoreError::Schema {
        message: format!("failed to commit current schema: {error}"),
    })?;

    crate::shared::storage::ensure_storage_schema(conn).map_err(|error| EventStoreError::Schema {
        message: format!("failed to ensure storage schema: {error:#}"),
    })
}

fn ensure_core_coordination_columns(tx: &rusqlite::Transaction<'_>) -> Result<()> {
    if table_exists(tx, "agent_assignments")? {
        add_column_if_missing(
            tx,
            "agent_assignments",
            "autonomous_hop",
            "INTEGER NOT NULL DEFAULT 0 CHECK(autonomous_hop BETWEEN 0 AND 4294967295)",
        )?;
    }
    if table_exists(tx, "agent_wake_intents")? {
        for (column, declaration) in [
            ("trace_id", "TEXT NOT NULL DEFAULT 'legacy-core-trace'"),
            (
                "autonomous_hop",
                "INTEGER NOT NULL DEFAULT 0 CHECK(autonomous_hop BETWEEN 0 AND 4294967295)",
            ),
            ("materialized_message_id", "TEXT"),
            ("delivered_by_lease_id", "TEXT"),
        ] {
            add_column_if_missing(tx, "agent_wake_intents", column, declaration)?;
        }
    }
    Ok(())
}

fn backfill_core_coordination_trace_owners(tx: &rusqlite::Transaction<'_>) -> Result<()> {
    if !table_exists(tx, "agent_coordination_traces")? || !table_exists(tx, "agent_wake_intents")? {
        return Ok(());
    }
    let now = chrono::Utc::now().to_rfc3339();
    let legacy_wakes = {
        let mut statement = tx.prepare(
            "SELECT wake.wake_id,agent.root_agent_id,root.transcript_session_id
             FROM agent_wake_intents wake
             JOIN agents agent ON agent.agent_id=wake.target_agent_id
             JOIN agents root ON root.agent_id=agent.root_agent_id
             WHERE wake.trace_id='legacy-core-trace'",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (wake_id, root_agent_id, root_session_id) in legacy_wakes {
        let trace_id = format!("legacy-core-trace:{wake_id}");
        tx.execute(
            "INSERT OR IGNORE INTO agent_coordination_traces(
                trace_id,root_agent_id,root_session_id,created_at,updated_at
             ) VALUES (?1,?2,?3,?4,?4)",
            rusqlite::params![trace_id, root_agent_id, root_session_id, now],
        )?;
        tx.execute(
            "UPDATE agent_wake_intents SET trace_id=?2 WHERE wake_id=?1",
            rusqlite::params![wake_id, trace_id],
        )?;
    }
    Ok(())
}

fn table_exists(tx: &rusqlite::Transaction<'_>, table: &str) -> Result<bool> {
    tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
        [table],
        |row| row.get(0),
    )
    .map_err(EventStoreError::from)
}

fn add_column_if_missing(
    tx: &rusqlite::Transaction<'_>,
    table: &str,
    column: &str,
    declaration: &str,
) -> Result<()> {
    let mut statement = tx.prepare(&format!("PRAGMA table_info({table})"))?;
    let exists = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .iter()
        .any(|candidate| candidate == column);
    drop(statement);
    if !exists {
        tx.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {declaration};"
        ))?;
    }
    Ok(())
}

fn foreign_key_violations(
    tx: &rusqlite::Transaction<'_>,
) -> Result<Vec<(String, i64, String, i64)>> {
    let mut statement =
        tx.prepare("PRAGMA foreign_key_check")
            .map_err(|error| EventStoreError::Schema {
                message: format!("failed to prepare foreign-key check: {error}"),
            })?;
    statement
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .map_err(|error| EventStoreError::Schema {
            message: format!("failed to read foreign-key check: {error}"),
        })?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(EventStoreError::from)
}

#[cfg(test)]
mod tests;
