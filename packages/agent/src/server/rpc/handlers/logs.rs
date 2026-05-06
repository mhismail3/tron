//! Logs RPC group.
//!
//! `logs.ingest` and `logs.recent` are marker-registered in `handlers::mod`
//! and executed by engine-owned `rpc::<method>` functions. This module remains
//! as progressive disclosure docs plus wire-compatibility tests for the
//! collapsed logs group.

#[cfg(test)]
mod tests {
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest, RpcResponse};
    use serde_json::{Value, json};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn next_request_id(method: &str) -> String {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(1);
        format!("{method}-{}", NEXT_ID.fetch_add(1, Ordering::SeqCst))
    }

    async fn dispatch_logs_response(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcResponse {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        registry
            .dispatch(
                RpcRequest {
                    id: next_request_id(method),
                    method: method.to_owned(),
                    params,
                },
                ctx,
            )
            .await
    }

    async fn dispatch_logs_ok(ctx: &RpcContext, method: &str, params: Option<Value>) -> Value {
        let response = dispatch_logs_response(ctx, method, params).await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_logs_err(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcErrorBody {
        let response = dispatch_logs_response(ctx, method, params).await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

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

        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;
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
        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(json!({"entries": []}))).await;
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

        let first_result = dispatch_logs_ok(&ctx, "logs.ingest", Some(first)).await;
        let second_result = dispatch_logs_ok(&ctx, "logs.ingest", Some(second)).await;

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
        let err = dispatch_logs_err(&ctx, "logs.ingest", Some(json!({}))).await;
        assert_eq!(err.code, "INVALID_PARAMS");
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

        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;

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

        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;

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
        let err = dispatch_logs_err(&ctx, "logs.ingest", Some(json!({"entries": entries}))).await;
        assert_eq!(err.code, "INVALID_PARAMS");
        assert!(err.message.contains("more than 10000 items"));
    }

    #[tokio::test]
    async fn ingest_logs_dedup_skips_old_entries_with_distinct_request_ids() {
        let ctx = make_test_context();
        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "first"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "second"},
                {"timestamp": "2026-03-03T14:30:05.300Z", "level": "info", "category": "A", "message": "third"},
            ]
        });

        let r1 = dispatch_logs_ok(&ctx, "logs.ingest", Some(params.clone())).await;
        assert_eq!(r1["inserted"], 3);

        let r2 = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;
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
        let r1 = dispatch_logs_ok(&ctx, "logs.ingest", Some(first_batch)).await;
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
        let r2 = dispatch_logs_ok(&ctx, "logs.ingest", Some(second_batch)).await;
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

        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;

        assert_eq!(result["inserted"], 1);
        let conn = ctx.event_store.pool().get().unwrap();
        let level_num: i32 = conn
            .query_row(
                "SELECT level_num FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(level_num, 30);
    }

    #[tokio::test]
    async fn ingest_logs_first_export_no_watermark() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
        drop(conn);

        let params = json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.000Z", "level": "info", "category": "A", "message": "first ever"},
            ]
        });
        let result = dispatch_logs_ok(&ctx, "logs.ingest", Some(params)).await;
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

        let result = dispatch_logs_ok(&ctx, "logs.recent", Some(json!({ "limit": 2 }))).await;

        assert_eq!(result["count"], 2);
        assert_eq!(result["entries"][0]["message"], "second");
        assert_eq!(result["entries"][1]["message"], "third");
        assert_eq!(result["entries"][1]["level"], "error");
    }

    #[tokio::test]
    async fn recent_logs_rejects_excessive_limit() {
        let ctx = make_test_context();
        let err = dispatch_logs_err(&ctx, "logs.recent", Some(json!({ "limit": 1_001 }))).await;

        assert_eq!(err.code, "INVALID_PARAMS");
    }
}
