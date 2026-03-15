//! Shared client log ingestion logic used by the RPC handler.

use serde::{Deserialize, Serialize};
use crate::core::logging::LogLevel;
use crate::events::PooledConnection;

use crate::server::rpc::errors::RpcError;

const MAX_INGEST_ENTRIES: usize = 10_000;

/// A single log entry sent from the iOS client.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub(crate) struct ClientLogEntry {
    pub(crate) timestamp: String,
    pub(crate) level: String,
    pub(crate) category: String,
    pub(crate) message: String,
}

/// RPC response for client log ingestion.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ClientLogIngestResult {
    pub(crate) success: bool,
    pub(crate) inserted: usize,
}

/// Shared synchronous service for client log ingestion.
pub(crate) struct ClientLogsService;

impl ClientLogsService {
    /// Insert client log entries into the `logs` table with deduplication.
    ///
    /// Uses the partial unique index on `(timestamp, component, message)` for
    /// `origin = 'ios-client'`, so out-of-order delivery remains correct and
    /// duplicate replays are ignored at insert time.
    pub(crate) fn ingest(
        conn: &mut PooledConnection,
        entries: &[ClientLogEntry],
    ) -> Result<ClientLogIngestResult, RpcError> {
        if entries.len() > MAX_INGEST_ENTRIES {
            return Err(RpcError::InvalidParams {
                message: format!("Too many entries: {} (max 10000)", entries.len()),
            });
        }

        let inserted = insert_client_logs(conn, entries)?;
        Ok(ClientLogIngestResult {
            success: true,
            inserted,
        })
    }
}

/// Map an iOS level string to `LogLevel`.
///
/// iOS sends `"verbose"` which has no direct match in `from_str_lossy` (it
/// would default to `Info`), so we handle it explicitly.
fn map_ios_level(s: &str) -> LogLevel {
    match s.to_lowercase().as_str() {
        "verbose" => LogLevel::Trace,
        other => LogLevel::from_str_lossy(other),
    }
}

fn insert_client_logs(
    conn: &mut PooledConnection,
    entries: &[ClientLogEntry],
) -> Result<usize, RpcError> {
    if entries.is_empty() {
        return Ok(0);
    }

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| RpcError::Internal {
            message: format!("Failed to begin transaction: {e}"),
        })?;

    let inserted = {
        let mut stmt = tx
            .prepare_cached(
                "INSERT OR IGNORE INTO logs (timestamp, level, level_num, component, message, origin) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 'ios-client')",
            )
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to prepare statement: {e}"),
            })?;

        let mut count = 0usize;
        for entry in entries {
            let level = map_ios_level(&entry.level);
            let component = format!("ios.{}", entry.category);
            let level_str = level.to_string();
            let level_num = level.as_num().to_string();

            count += stmt
                .execute([
                    entry.timestamp.as_str(),
                    level_str.as_str(),
                    level_num.as_str(),
                    component.as_str(),
                    entry.message.as_str(),
                ])
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to insert log entry: {e}"),
                })?;
        }
        count
    };

    tx.commit().map_err(|e| RpcError::Internal {
        message: format!("Failed to commit transaction: {e}"),
    })?;

    Ok(inserted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[test]
    fn ingest_deduplicates_replayed_rows() {
        let ctx = make_test_context();
        let mut conn = ctx.event_store.pool().get().unwrap();
        let entries = vec![
            ClientLogEntry {
                timestamp: "2026-03-03T14:30:05.100Z".to_string(),
                level: "info".to_string(),
                category: "RPC".to_string(),
                message: "a".to_string(),
            },
            ClientLogEntry {
                timestamp: "2026-03-03T14:30:05.200Z".to_string(),
                level: "info".to_string(),
                category: "RPC".to_string(),
                message: "b".to_string(),
            },
        ];

        let first = ClientLogsService::ingest(&mut conn, &entries).unwrap();
        let second = ClientLogsService::ingest(&mut conn, &entries).unwrap();

        assert_eq!(first.inserted, 2);
        assert_eq!(second.inserted, 0);
    }

    #[test]
    fn ingest_rejects_oversized_batches() {
        let ctx = make_test_context();
        let mut conn = ctx.event_store.pool().get().unwrap();
        let entries: Vec<_> = (0..=MAX_INGEST_ENTRIES)
            .map(|i| ClientLogEntry {
                timestamp: format!("2026-03-03T14:30:{:02}.{:03}Z", i / 1000, i % 1000),
                level: "info".to_string(),
                category: "RPC".to_string(),
                message: format!("message-{i}"),
            })
            .collect();

        let error = ClientLogsService::ingest(&mut conn, &entries).unwrap_err();
        assert_eq!(error.code(), "INVALID_PARAMS");
        assert!(error.to_string().contains("Too many entries"));
    }

    #[test]
    fn ingest_maps_verbose_to_trace() {
        let ctx = make_test_context();
        let mut conn = ctx.event_store.pool().get().unwrap();
        let entries = vec![ClientLogEntry {
            timestamp: "2026-03-03T14:30:05.100Z".to_string(),
            level: "verbose".to_string(),
            category: "RPC".to_string(),
            message: "trace me".to_string(),
        }];

        let result = ClientLogsService::ingest(&mut conn, &entries).unwrap();
        assert_eq!(result.inserted, 1);

        let level_num: i32 = conn
            .query_row(
                "SELECT level_num FROM logs WHERE origin = 'ios-client'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(level_num, 10);
    }
}
