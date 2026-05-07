//! Shared client log ingestion logic used by the canonical capability function.

use crate::core::logging::LogLevel;
use crate::events::PooledConnection;
use serde::{Deserialize, Serialize};

use crate::server::transport::json_rpc::errors::RpcError;

const MAX_INGEST_ENTRIES: usize = 10_000;

/// Maximum stored length for a client-supplied log message. Over-long messages
/// are truncated on ingest with a `[truncated N bytes]` suffix so the table
/// stays responsive to scans and the UI stays readable. iOS stack traces and
/// large payloads are the realistic cause; 8 KB is generous for genuine log
/// lines and prevents a misbehaving client from bloating the DB.
const MAX_MESSAGE_BYTES: usize = 8 * 1024;

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

/// Truncate an over-long log message at a UTF-8 char boundary and append
/// a marker so readers know the cut happened. Short messages are returned
/// as-borrowed (no allocation).
fn truncate_message(message: &str) -> std::borrow::Cow<'_, str> {
    if message.len() <= MAX_MESSAGE_BYTES {
        return std::borrow::Cow::Borrowed(message);
    }
    let dropped = message.len() - MAX_MESSAGE_BYTES;
    let mut cut = MAX_MESSAGE_BYTES;
    while cut > 0 && !message.is_char_boundary(cut) {
        cut -= 1;
    }
    std::borrow::Cow::Owned(format!("{} [truncated {} bytes]", &message[..cut], dropped))
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
            let message = truncate_message(&entry.message);

            count += stmt
                .execute([
                    entry.timestamp.as_str(),
                    level_str.as_str(),
                    level_num.as_str(),
                    component.as_str(),
                    message.as_ref(),
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
    use crate::server::services::test_support::make_test_context;

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

    // ── Message truncation ───────────────────────────────────────────────

    #[test]
    fn truncate_short_message_is_borrow_no_alloc() {
        // Cheap round-trip for the common case; Borrowed proves no alloc happened.
        let short = "hello";
        let out = truncate_message(short);
        assert!(matches!(out, std::borrow::Cow::Borrowed(_)));
        assert_eq!(&*out, short);
    }

    #[test]
    fn truncate_message_at_boundary_is_not_truncated() {
        let at_limit = "x".repeat(MAX_MESSAGE_BYTES);
        let out = truncate_message(&at_limit);
        assert!(matches!(out, std::borrow::Cow::Borrowed(_)));
        assert_eq!(out.len(), MAX_MESSAGE_BYTES);
    }

    #[test]
    fn truncate_over_limit_appends_marker() {
        let big = "x".repeat(MAX_MESSAGE_BYTES + 500);
        let out = truncate_message(&big);
        assert!(matches!(out, std::borrow::Cow::Owned(_)));
        assert!(out.contains("[truncated 500 bytes]"));
        // Truncated body length must respect the cap.
        assert!(out.len() < MAX_MESSAGE_BYTES + 64);
    }

    #[test]
    fn truncate_respects_utf8_char_boundary() {
        // A multi-byte char straddling the boundary must not be split.
        // Each emoji is 4 bytes. Build a string of length > MAX_MESSAGE_BYTES
        // where the byte-exact cut would land mid-char.
        let prefix_bytes = MAX_MESSAGE_BYTES - 1; // force boundary into an emoji
        let prefix = "a".repeat(prefix_bytes);
        let mut msg = prefix;
        msg.push_str(&"\u{1F600}".repeat(100)); // 400 bytes of emoji
        let out = truncate_message(&msg);
        // Re-parsing the result must not error on UTF-8 boundary.
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
        assert!(out.contains("[truncated"));
    }

    #[test]
    fn ingest_stores_truncated_message_with_marker() {
        let ctx = make_test_context();
        let mut conn = ctx.event_store.pool().get().unwrap();
        let huge_message = "y".repeat(MAX_MESSAGE_BYTES + 100);
        let entries = vec![ClientLogEntry {
            timestamp: "2026-03-03T14:30:05.000Z".to_string(),
            level: "info".to_string(),
            category: "RPC".to_string(),
            message: huge_message,
        }];

        let result = ClientLogsService::ingest(&mut conn, &entries).unwrap();
        assert_eq!(result.inserted, 1);

        let stored: String = conn
            .query_row(
                "SELECT message FROM logs WHERE origin = 'ios-client'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            stored.contains("[truncated 100 bytes]"),
            "expected truncation marker in stored message"
        );
        assert!(
            stored.len() <= MAX_MESSAGE_BYTES + 64,
            "stored message should be capped; got {} bytes",
            stored.len()
        );
    }
}
