//! Notification inbox RPC handlers.
//!
//! Three methods for the iOS notification inbox:
//!
//! - `notifications.list` — List recent `NotifyApp` notifications with read state
//! - `notifications.markRead` — Mark a single notification as read
//! - `notifications.markAllRead` — Mark all unread notifications as read

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{RpcError, to_json_value};
use crate::rpc::handlers::{opt_u64, require_string_param};
use crate::rpc::notification_inbox::NotificationInboxService;
use crate::rpc::registry::MethodHandler;

// ── notifications.list ──────────────────────────────────────────────

/// List recent `NotifyApp` notifications with read state and session context.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "notifications.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit = opt_u64(params.as_ref(), "limit", 50).min(100);
        let pool = ctx.event_store.pool().clone();

        ctx.run_blocking("notifications.list", move || {
            let conn = pool.get().map_err(|e| RpcError::Internal {
                message: format!("Failed to get DB connection: {e}"),
            })?;
            NotificationInboxService::list(&conn, limit)
        })
        .await
        .and_then(|result| to_json_value(&result))
    }
}

// ── notifications.markRead ──────────────────────────────────────────

/// Mark a single notification as read.
pub struct MarkReadHandler;

#[async_trait]
impl MethodHandler for MarkReadHandler {
    #[instrument(skip(self, ctx), fields(method = "notifications.markRead"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let event_id = require_string_param(params.as_ref(), "eventId")?;
        let pool = ctx.event_store.pool().clone();

        ctx.run_blocking("notifications.mark_read", move || {
            let conn = pool.get().map_err(|e| RpcError::Internal {
                message: format!("Failed to get DB connection: {e}"),
            })?;
            NotificationInboxService::mark_read(&conn, &event_id)
        })
        .await
        .and_then(|result| to_json_value(&result))
    }
}

// ── notifications.markAllRead ───────────────────────────────────────

/// Mark all unread `NotifyApp` notifications as read.
pub struct MarkAllReadHandler;

#[async_trait]
impl MethodHandler for MarkAllReadHandler {
    #[instrument(skip(self, ctx), fields(method = "notifications.markAllRead"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let pool = ctx.event_store.pool().clone();

        ctx.run_blocking("notifications.mark_all_read", move || {
            let conn = pool.get().map_err(|e| RpcError::Internal {
                message: format!("Failed to get DB connection: {e}"),
            })?;
            NotificationInboxService::mark_all_read(&conn)
        })
        .await
        .and_then(|result| to_json_value(&result))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    fn setup_test_data(ctx: &RpcContext) {
        let conn = ctx.event_store.pool().get().unwrap();

        assert_eq!(
            conn.execute(
                "INSERT INTO workspaces (id, path, created_at, last_activity_at)
                 VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        // User session (source=NULL, spawning_session_id=NULL)
        assert_eq!(
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at)
                 VALUES ('sess_user', 'ws_1', 'My Session', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        // Cron session
        assert_eq!(
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at, source)
                 VALUES ('sess_cron', 'ws_1', 'Cron: daily report', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 'cron')",
                [],
            )
            .unwrap(),
            1
        );

        // Subagent session
        assert_eq!(
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at, spawning_session_id)
                 VALUES ('sess_sub', 'ws_1', 'Subagent task', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 'sess_user')",
                [],
            )
            .unwrap(),
            1
        );
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
        assert_eq!(
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
            .unwrap(),
            1
        );
    }

    // ── notifications.list ─────────────────────────────────────────

    #[tokio::test]
    async fn list_empty_db_returns_empty() {
        let ctx = make_test_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["notifications"].as_array().unwrap().len(), 0);
        assert_eq!(result["unreadCount"], 0);
    }

    #[tokio::test]
    async fn list_returns_notify_events() {
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

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notifs = result["notifications"].as_array().unwrap();
        assert_eq!(notifs.len(), 1);
        assert_eq!(notifs[0]["eventId"], "evt_1");
        assert_eq!(notifs[0]["title"], "Test Title");
        assert_eq!(notifs[0]["body"], "Test Body");
        assert_eq!(notifs[0]["isRead"], false);
        assert_eq!(result["unreadCount"], 1);
    }

    #[tokio::test]
    async fn list_includes_session_context() {
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

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notif = &result["notifications"][0];
        assert_eq!(notif["sessionTitle"], "My Session");
        assert_eq!(notif["isUserSession"], true);
    }

    #[tokio::test]
    async fn list_cron_session_not_user_session() {
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

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notif = &result["notifications"][0];
        assert_eq!(notif["isUserSession"], false);
    }

    #[tokio::test]
    async fn list_subagent_session_not_user_session() {
        let ctx = make_test_context();
        setup_test_data(&ctx);
        insert_notify_event(
            &ctx,
            "evt_1",
            "sess_sub",
            "tc_1",
            "2025-01-01T01:00:00Z",
            "t",
            "b",
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notif = &result["notifications"][0];
        assert_eq!(notif["isUserSession"], false);
    }

    #[tokio::test]
    async fn list_filters_only_tool_call_not_tool_result() {
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

        // Insert a tool.result for the same tool_call_id (should NOT appear)
        let conn = ctx.event_store.pool().get().unwrap();
        assert_eq!(
            conn.execute(
                "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, tool_name, tool_call_id)
                 VALUES ('evt_2', 'sess_user', 2, 'tool.result', '2025-01-01T01:00:01Z', '{\"content\":\"ok\"}', 'ws_1', 'NotifyApp', 'tc_1')",
                [],
            )
            .unwrap(),
            1
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["notifications"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn list_ordered_by_timestamp_desc() {
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

        // Second event needs a different sequence for the same session — use a different session
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "Second",
            "b",
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notifs = result["notifications"].as_array().unwrap();
        assert_eq!(notifs[0]["title"], "Second");
        assert_eq!(notifs[1]["title"], "First");
    }

    #[tokio::test]
    async fn list_respects_limit() {
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
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "t",
            "b",
        );

        let result = ListHandler
            .handle(Some(json!({"limit": 1})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["notifications"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn list_unread_count_accurate() {
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
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "t",
            "b",
        );

        // Mark one as read
        let conn = ctx.event_store.pool().get().unwrap();
        assert_eq!(
            conn.execute(
                "INSERT INTO notification_read_state (event_id, read_at) VALUES ('evt_1', '2025-01-03T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["unreadCount"], 1);
        let notifs = result["notifications"].as_array().unwrap();
        // evt_2 is newer, unread
        assert_eq!(notifs[0]["isRead"], false);
        // evt_1 is older, read
        assert_eq!(notifs[1]["isRead"], true);
    }

    #[tokio::test]
    async fn list_handles_malformed_payload_gracefully() {
        let ctx = make_test_context();
        setup_test_data(&ctx);

        // Insert event with malformed payload
        let conn = ctx.event_store.pool().get().unwrap();
        assert_eq!(
            conn.execute(
                "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, tool_name, tool_call_id)
                 VALUES ('evt_bad', 'sess_user', 1, 'tool.call', '2025-01-01T01:00:00Z', 'not-json', 'ws_1', 'NotifyApp', 'tc_bad')",
                [],
            )
            .unwrap(),
            1
        );

        // Insert a good event too
        insert_notify_event(
            &ctx,
            "evt_good",
            "sess_cron",
            "tc_good",
            "2025-01-02T01:00:00Z",
            "Good",
            "b",
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        // Malformed event skipped, good one returned
        let notifs = result["notifications"].as_array().unwrap();
        assert_eq!(notifs.len(), 1);
        assert_eq!(notifs[0]["title"], "Good");
        assert_eq!(result["unreadCount"], 1);
    }

    #[tokio::test]
    async fn list_includes_sheet_content() {
        let ctx = make_test_context();
        setup_test_data(&ctx);

        let conn = ctx.event_store.pool().get().unwrap();
        let payload = json!({
            "arguments": {
                "title": "Report",
                "body": "Daily report ready",
                "sheetContent": "## Summary\n- All good",
            },
            "turn": 1,
        });
        assert_eq!(
            conn.execute(
                "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, tool_name, tool_call_id)
                 VALUES ('evt_1', 'sess_user', 1, 'tool.call', '2025-01-01T01:00:00Z', ?1, 'ws_1', 'NotifyApp', 'tc_1')",
                [&serde_json::to_string(&payload).unwrap() as &str],
            )
            .unwrap(),
            1
        );

        let result = ListHandler.handle(None, &ctx).await.unwrap();
        let notif = &result["notifications"][0];
        assert_eq!(notif["sheetContent"], "## Summary\n- All good");
    }

    // ── notifications.markRead ─────────────────────────────────────

    #[tokio::test]
    async fn mark_read_success() {
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

        let result = MarkReadHandler
            .handle(Some(json!({"eventId": "evt_1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);

        // Verify it shows as read in list
        let list = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["notifications"][0]["isRead"], true);
        assert_eq!(list["unreadCount"], 0);
    }

    #[tokio::test]
    async fn mark_read_idempotent() {
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

        // Mark twice — no error
        let first = MarkReadHandler
            .handle(Some(json!({"eventId": "evt_1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(first["success"], true);
        let result = MarkReadHandler
            .handle(Some(json!({"eventId": "evt_1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn mark_read_nonexistent_event_is_noop() {
        let ctx = make_test_context();
        let result = MarkReadHandler
            .handle(Some(json!({"eventId": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn mark_read_missing_param() {
        let ctx = make_test_context();
        let err = MarkReadHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    // ── notifications.markAllRead ──────────────────────────────────

    #[tokio::test]
    async fn mark_all_read_marks_all_unread() {
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
        insert_notify_event(
            &ctx,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            "t",
            "b",
        );

        let result = MarkAllReadHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["marked"], 2);

        let list = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["unreadCount"], 0);
    }

    #[tokio::test]
    async fn mark_all_read_preserves_already_read() {
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

        // Mark one as read manually
        let conn = ctx.event_store.pool().get().unwrap();
        assert_eq!(
            conn.execute(
                "INSERT INTO notification_read_state (event_id, read_at) VALUES ('evt_1', '2025-01-02T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        // Mark all — should only mark 0 new
        let result = MarkAllReadHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["marked"], 0);

        // Original read_at preserved
        let read_at: String = conn
            .query_row(
                "SELECT read_at FROM notification_read_state WHERE event_id = 'evt_1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(read_at, "2025-01-02T00:00:00Z");
    }

    #[tokio::test]
    async fn mark_all_read_works_when_no_unread() {
        let ctx = make_test_context();
        let result = MarkAllReadHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["marked"], 0);
    }
}
