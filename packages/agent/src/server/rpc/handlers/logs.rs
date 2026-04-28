//! Logs handler: ingest client logs into the database.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::client_logs::{ClientLogEntry, ClientLogsService};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{RpcError, to_json_value};
use crate::server::rpc::registry::MethodHandler;

/// Ingest structured client logs into the database.
pub struct IngestLogsHandler;

/// Fetch recent server/client logs from the event database.
pub struct RecentLogsHandler;

const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsParams {
    #[serde(default = "default_recent_limit")]
    limit: u32,
}

fn default_recent_limit() -> u32 {
    DEFAULT_RECENT_LIMIT
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsResult {
    entries: Vec<RecentLogEntry>,
    count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogEntry {
    id: i64,
    timestamp: String,
    level: String,
    component: String,
    message: String,
    origin: Option<String>,
    session_id: Option<String>,
    error_message: Option<String>,
}

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

        let pool = ctx.event_store.pool().clone();
        let result = ctx
            .run_blocking("logs.ingest", move || {
                let mut conn = pool.get().map_err(|e| RpcError::Internal {
                    message: format!("Failed to get DB connection: {e}"),
                })?;
                ClientLogsService::ingest(&mut conn, &entries)
            })
            .await?;

        to_json_value(&result)
    }
}

#[async_trait]
impl MethodHandler for RecentLogsHandler {
    #[instrument(skip(self, ctx), fields(method = "logs.recent"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let params: RecentLogsParams = match params {
            Some(value) => serde_json::from_value(value).map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid params: {e}"),
            })?,
            None => RecentLogsParams {
                limit: DEFAULT_RECENT_LIMIT,
            },
        };

        if params.limit > MAX_RECENT_LIMIT {
            return Err(RpcError::InvalidParams {
                message: format!("limit must be <= {MAX_RECENT_LIMIT}"),
            });
        }

        let limit = i64::from(params.limit);
        let pool = ctx.event_store.pool().clone();
        let result = ctx
            .run_blocking("logs.recent", move || {
                let conn = pool.get().map_err(|e| RpcError::Internal {
                    message: format!("Failed to get DB connection: {e}"),
                })?;
                let mut stmt = conn
                    .prepare(
                        "SELECT id, timestamp, level, component, message, origin, session_id, error_message \
                         FROM logs ORDER BY id DESC LIMIT ?1",
                    )
                    .map_err(|e| RpcError::Internal {
                        message: format!("Failed to prepare logs query: {e}"),
                    })?;
                let rows = stmt
                    .query_map([limit], |row| {
                        Ok(RecentLogEntry {
                            id: row.get(0)?,
                            timestamp: row.get(1)?,
                            level: row.get(2)?,
                            component: row.get(3)?,
                            message: row.get(4)?,
                            origin: row.get(5)?,
                            session_id: row.get(6)?,
                            error_message: row.get(7)?,
                        })
                    })
                    .map_err(|e| RpcError::Internal {
                        message: format!("Failed to read logs: {e}"),
                    })?;

                let mut entries: Vec<RecentLogEntry> = rows
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| RpcError::Internal {
                        message: format!("Failed to decode logs: {e}"),
                    })?;
                entries.reverse();
                Ok(RecentLogsResult {
                    count: entries.len(),
                    entries,
                })
            })
            .await?;

        to_json_value(&result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
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
    async fn ingest_logs_accepts_out_of_order_entries() {
        let ctx = make_test_context();

        let first = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "RPC", "message": "newer"}
            ]
        });
        let second = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "RPC", "message": "older"}
            ]
        });

        let first_result = IngestLogsHandler.handle(Some(first), &ctx).await.unwrap();
        let second_result = IngestLogsHandler.handle(Some(second), &ctx).await.unwrap();

        assert_eq!(first_result["inserted"], 1);
        assert_eq!(second_result["inserted"], 1);

        let conn = ctx.event_store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
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

        let result = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        assert_eq!(result["inserted"], 5);
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

        let result = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        assert_eq!(result["inserted"], 1);
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

        let r2 = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();
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
        let r1 = IngestLogsHandler
            .handle(Some(first_batch), &ctx)
            .await
            .unwrap();
        assert_eq!(r1["inserted"], 3);

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

        let result = IngestLogsHandler.handle(Some(params), &ctx).await.unwrap();

        assert_eq!(result["inserted"], 1);
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

    #[tokio::test]
    async fn recent_logs_returns_bounded_chronological_entries() {
        let ctx = make_test_context();
        {
            let conn = ctx.event_store.pool().get().unwrap();
            conn.execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, origin) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                ("2026-04-27T10:00:00.000Z", "info", 30, "server", "first", "server"),
            )
            .unwrap();
            conn.execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, origin) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                ("2026-04-27T10:01:00.000Z", "warn", 40, "server", "second", "server"),
            )
            .unwrap();
            conn.execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, origin) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                ("2026-04-27T10:02:00.000Z", "error", 50, "server", "third", "server"),
            )
            .unwrap();
        }

        let result = RecentLogsHandler
            .handle(Some(json!({ "limit": 2 })), &ctx)
            .await
            .unwrap();

        assert_eq!(result["count"], 2);
        assert_eq!(result["entries"][0]["message"], "second");
        assert_eq!(result["entries"][1]["message"], "third");
        assert_eq!(result["entries"][1]["level"], "error");
    }

    #[tokio::test]
    async fn recent_logs_rejects_excessive_limit() {
        let ctx = make_test_context();
        let err = RecentLogsHandler
            .handle(Some(json!({ "limit": 1_001 })), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
