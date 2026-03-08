//! Logs handler: ingest client logs into the database.

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::Value;
use tracing::instrument;
use tron_core::logging::LogLevel;
use tron_events::PooledConnection;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::registry::MethodHandler;

/// A single log entry sent from the iOS client.
#[derive(Debug, Deserialize)]
struct ClientLogEntry {
    timestamp: String,
    level: String,
    category: String,
    message: String,
}

/// Map an iOS level string to `LogLevel`.
/// iOS sends "verbose" which has no direct match in `from_str_lossy` (it would
/// default to Info), so we handle it explicitly.
fn map_ios_level(s: &str) -> LogLevel {
    match s.to_lowercase().as_str() {
        "verbose" => LogLevel::Trace,
        other => LogLevel::from_str_lossy(other),
    }
}

/// Insert client log entries into the `logs` table with deduplication.
///
/// Reads the high-water mark (`MAX(timestamp)`) for `origin = 'ios-client'`,
/// filters out entries at or before the watermark, then batch-inserts the rest
/// in a single transaction.
///
/// Returns the number of rows actually inserted.
fn insert_client_logs(
    conn: &PooledConnection,
    entries: &[ClientLogEntry],
) -> Result<usize, RpcError> {
    let watermark: Option<String> = conn
        .query_row(
            "SELECT MAX(timestamp) FROM logs WHERE origin = 'ios-client'",
            [],
            |row| row.get(0),
        )
        .map_err(|e| RpcError::Internal {
            message: format!("Failed to query watermark: {e}"),
        })?;

    let new_entries: Vec<&ClientLogEntry> = match watermark.as_deref() {
        Some(wm) => entries.iter().filter(|e| e.timestamp.as_str() > wm).collect(),
        None => entries.iter().collect(),
    };

    if new_entries.is_empty() {
        return Ok(0);
    }

    let tx = conn.unchecked_transaction().map_err(|e| RpcError::Internal {
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
        for entry in &new_entries {
            let level = map_ios_level(&entry.level);
            let component = format!("ios.{}", entry.category);
            let level_str = level.to_string();
            let level_num = level.as_num();

            count += stmt
                .execute([
                    entry.timestamp.as_str(),
                    level_str.as_str(),
                    &level_num.to_string(),
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

/// Ingest structured client logs into the database.
pub struct IngestLogsHandler;

#[async_trait]
impl MethodHandler for IngestLogsHandler {
    #[instrument(skip(self, ctx), fields(method = "logs.ingest"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let entries_val = params
            .as_ref()
            .and_then(|p| p.get("entries"))
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required parameter: entries".to_string(),
            })?;

        let entries: Vec<ClientLogEntry> =
            serde_json::from_value(entries_val.clone()).map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid entries: {e}"),
            })?;

        if entries.len() > 10_000 {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "Too many entries: {} (max 10000)",
                    entries.len()
                ),
            });
        }

        let conn = ctx.event_store.pool().get().map_err(|e| RpcError::Internal {
            message: format!("Failed to get DB connection: {e}"),
        })?;

        let inserted = insert_client_logs(&conn, &entries)?;

        Ok(serde_json::json!({
            "success": true,
            "inserted": inserted,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn ingest_logs_inserts_entries() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "WebSocket", "message": "connected"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "debug", "category": "RPC", "message": "sending ping"},
                {"timestamp": "2026-03-03T14:30:05.300Z", "level": "error", "category": "Network", "message": "timeout"},
            ]
        });

        let result = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["inserted"], 3);

        let conn = ctx.event_store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 3);

        let component: String = conn
            .query_row(
                "SELECT component FROM logs WHERE origin = 'ios-client' ORDER BY timestamp LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(component, "ios.WebSocket");
    }

    #[tokio::test]
    async fn ingest_logs_empty_entries() {
        let ctx = make_test_context();
        let result = IngestLogsHandler
            .handle(Some(json!({"entries": []})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["inserted"], 0);
    }

    #[tokio::test]
    async fn ingest_logs_missing_entries_param() {
        let ctx = make_test_context();
        let err = IngestLogsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn ingest_logs_level_mapping() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.001Z", "level": "verbose", "category": "A", "message": "a"},
                {"timestamp": "2026-03-03T14:30:05.002Z", "level": "debug", "category": "A", "message": "b"},
                {"timestamp": "2026-03-03T14:30:05.003Z", "level": "info", "category": "A", "message": "c"},
                {"timestamp": "2026-03-03T14:30:05.004Z", "level": "warning", "category": "A", "message": "d"},
                {"timestamp": "2026-03-03T14:30:05.005Z", "level": "error", "category": "A", "message": "e"},
            ]
        });

        IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        let conn = ctx.event_store.pool().get().unwrap();
        let mut stmt = conn
            .prepare("SELECT level_num FROM logs WHERE origin = 'ios-client' ORDER BY timestamp")
            .unwrap();
        let levels: Vec<i32> = stmt
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();

        assert_eq!(levels, vec![10, 20, 30, 40, 50]);
    }

    #[tokio::test]
    async fn ingest_logs_component_prefix() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.000Z", "level": "info", "category": "WebSocket", "message": "test"},
            ]
        });

        IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        let conn = ctx.event_store.pool().get().unwrap();
        let component: String = conn
            .query_row(
                "SELECT component FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(component, "ios.WebSocket");
    }

    #[tokio::test]
    async fn ingest_logs_too_many_entries() {
        let ctx = make_test_context();
        let entries: Vec<Value> = (0..10_001)
            .map(|i| {
                json!({"timestamp": format!("2026-03-03T14:30:{:02}.{:03}Z", i / 1000, i % 1000), "level": "info", "category": "A", "message": "x"})
            })
            .collect();
        let err = IngestLogsHandler
            .handle(Some(json!({"entries": entries})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("Too many entries"));
    }

    #[tokio::test]
    async fn ingest_logs_dedup_skips_old_entries() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "first"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "second"},
                {"timestamp": "2026-03-03T14:30:05.300Z", "level": "info", "category": "A", "message": "third"},
            ]
        });

        let r1 = IngestLogsHandler
            .handle(Some(params.clone()), &ctx)
            .await
            .unwrap();
        assert_eq!(r1["inserted"], 3);

        let r2 = IngestLogsHandler
            .handle(Some(params), &ctx)
            .await
            .unwrap();
        assert_eq!(r2["inserted"], 0);
    }

    #[tokio::test]
    async fn ingest_logs_dedup_inserts_only_new() {
        let ctx = make_test_context();

        let first_batch = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "a"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "b"},
                {"timestamp": "2026-03-03T14:30:05.300Z", "level": "info", "category": "A", "message": "c"},
            ]
        });
        IngestLogsHandler
            .handle(Some(first_batch), &ctx)
            .await
            .unwrap();

        let second_batch = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "a"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "b"},
                {"timestamp": "2026-03-03T14:30:05.300Z", "level": "info", "category": "A", "message": "c"},
                {"timestamp": "2026-03-03T14:30:05.400Z", "level": "info", "category": "A", "message": "d"},
                {"timestamp": "2026-03-03T14:30:05.500Z", "level": "info", "category": "A", "message": "e"},
            ]
        });
        let r2 = IngestLogsHandler
            .handle(Some(second_batch), &ctx)
            .await
            .unwrap();
        assert_eq!(r2["inserted"], 2);

        let conn = ctx.event_store.pool().get().unwrap();
        let total: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(total, 5);
    }

    #[tokio::test]
    async fn ingest_logs_unknown_level_defaults_to_info() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.000Z", "level": "custom", "category": "A", "message": "x"},
            ]
        });

        IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        let conn = ctx.event_store.pool().get().unwrap();
        let level_num: i32 = conn
            .query_row(
                "SELECT level_num FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(level_num, 30); // Info
    }

    #[tokio::test]
    async fn ingest_logs_first_export_no_watermark() {
        let ctx = make_test_context();

        // Verify no ios-client logs exist yet
        let conn = ctx.event_store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);

        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.000Z", "level": "info", "category": "A", "message": "first ever"},
            ]
        });
        let result = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["inserted"], 1);
    }
}
