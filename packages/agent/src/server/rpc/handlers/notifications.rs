//! Notification inbox RPC group.
//!
//! `notifications.list`, `notifications.markRead`, and
//! `notifications.markAllRead` are marker-registered in `handlers::mod` and
//! executed by canonical `notifications::*` engine functions.

#[cfg(test)]
mod tests {
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::RpcRequest;
    use serde_json::{Value, json};

    fn setup_test_data(ctx: &RpcContext) {
        let conn = ctx.event_store.pool().get().unwrap();
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_user', 'ws_1', 'My Session', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at, source)
             VALUES ('sess_cron', 'ws_1', 'Cron: daily report', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 'cron')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at, spawning_session_id)
             VALUES ('sess_sub', 'ws_1', 'Subagent task', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 'sess_user')",
            [],
        )
        .unwrap();
    }

    fn insert_notify_event(
        ctx: &RpcContext,
        event_id: &str,
        session_id: &str,
        tool_call_id: &str,
        timestamp: &str,
        title: &str,
        body: &str,
    ) {
        let conn = ctx.event_store.pool().get().unwrap();
        let payload = json!({
            "tool_call_id": tool_call_id,
            "name": "NotifyApp",
            "arguments": {
                "title": title,
                "body": body,
            },
            "turn": 1,
        });
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, tool_name, tool_call_id)
             VALUES (?1, ?2, ?3, 'tool.call', ?4, ?5, 'ws_1', 'NotifyApp', ?6)",
            [
                event_id,
                session_id,
                "1",
                timestamp,
                &serde_json::to_string(&payload).unwrap() as &str,
                tool_call_id,
            ],
        )
        .unwrap();
    }

    async fn dispatch_notifications_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    #[tokio::test]
    async fn list_empty_db_returns_empty() {
        let ctx = make_test_context();
        let result = dispatch_notifications_ok(&ctx, "notifications.list", json!({})).await;
        assert_eq!(result["notifications"].as_array().unwrap().len(), 0);
        assert_eq!(result["unreadCount"], 0);
    }

    #[tokio::test]
    async fn list_returns_notify_events_with_session_context() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "Test Title",
            "Test Body",
        );

        let result = dispatch_notifications_ok(&ctx, "notifications.list", json!({})).await;
        let notification = &result["notifications"][0];
        assert_eq!(notification["eventId"], "evt_1");
        assert_eq!(notification["title"], "Test Title");
        assert_eq!(notification["body"], "Test Body");
        assert_eq!(notification["isRead"], false);
        assert_eq!(notification["sessionTitle"], "My Session");
        assert_eq!(notification["isUserSession"], true);
        assert_eq!(result["unreadCount"], 1);
    }

    #[tokio::test]
    async fn list_cron_and_subagent_sessions_are_not_user_sessions() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_cron",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "t",
            "b",
        );
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_sub",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "t",
            "b",
        );

        let result = dispatch_notifications_ok(&ctx, "notifications.list", json!({})).await;
        let notifications = result["notifications"].as_array().unwrap();
        assert!(
            notifications
                .iter()
                .all(|entry| entry["isUserSession"] == false)
        );
    }

    #[tokio::test]
    async fn list_respects_limit_and_timestamp_order() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "First",
            "b",
        );
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "Second",
            "b",
        );

        let result =
            dispatch_notifications_ok(&ctx, "notifications.list", json!({"limit": 1})).await;
        let notifications = result["notifications"].as_array().unwrap();
        assert_eq!(notifications.len(), 1);
        assert_eq!(notifications[0]["title"], "Second");
    }

    #[tokio::test]
    async fn mark_read_marks_single_notification() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "t",
            "b",
        );

        let result =
            dispatch_notifications_ok(&ctx, "notifications.markRead", json!({"eventId": "evt_1"}))
                .await;
        assert_eq!(result["success"], true);

        let list = dispatch_notifications_ok(&ctx, "notifications.list", json!({})).await;
        assert_eq!(list["notifications"][0]["isRead"], true);
        assert_eq!(list["unreadCount"], 0);
    }

    #[tokio::test]
    async fn mark_all_read_can_scope_by_session() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "a",
            "b",
        );
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "c",
            "d",
        );

        let result = dispatch_notifications_ok(
            &ctx,
            "notifications.markAllRead",
            json!({"sessionId": "sess_user"}),
        )
        .await;
        assert_eq!(result["marked"], 1);

        let list = dispatch_notifications_ok(&ctx, "notifications.list", json!({})).await;
        assert_eq!(list["unreadCount"], 1);
    }
}
