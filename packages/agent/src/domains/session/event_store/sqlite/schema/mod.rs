//! Current event-store schema installation.
//!
//! Tron supports one consolidated schema. Installation is idempotent and runs
//! in one transaction, followed by a foreign-key integrity check. There is no
//! version ledger or alternate row-shape decoder.

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

    tx.execute_batch(CURRENT_SCHEMA)
        .map_err(|error| EventStoreError::Schema {
            message: format!("failed to install current schema: {error}"),
        })?;

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
