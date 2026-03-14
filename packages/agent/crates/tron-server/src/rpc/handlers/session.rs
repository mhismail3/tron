//! Session handlers: create, resume, list, delete, fork, getHead, getState, getHistory.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::{opt_bool, opt_string, require_string_param};
use crate::rpc::registry::MethodHandler;
use crate::rpc::session_commands::{CreateSessionRequest, SessionCommandService};
use crate::rpc::session_queries::SessionQueryService;

/// Create a new session.
pub struct CreateSessionHandler;

#[async_trait]
impl MethodHandler for CreateSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;
        let model = opt_string(params.as_ref(), "model")
            .unwrap_or_else(|| "claude-sonnet-4-20250514".to_string());
        let title = opt_string(params.as_ref(), "title");

        SessionCommandService::create(
            ctx,
            CreateSessionRequest {
                working_directory: working_dir,
                model,
                title,
            },
        )
        .await
    }
}

/// Resume an existing session.
pub struct ResumeSessionHandler;

#[async_trait]
impl MethodHandler for ResumeSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.resume", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::resume(ctx, session_id).await
    }
}

/// List sessions with optional filters.
pub struct ListSessionsHandler;

#[async_trait]
impl MethodHandler for ListSessionsHandler {
    #[instrument(skip(self, ctx), fields(method = "session.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let include_archived = opt_bool(params.as_ref(), "includeArchived").unwrap_or(false);

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);
        SessionQueryService::list(ctx, include_archived, limit).await
    }
}

/// Delete a session.
pub struct DeleteSessionHandler;

#[async_trait]
impl MethodHandler for DeleteSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.delete", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::delete(ctx, session_id).await
    }
}

/// Fork a session at the current head (or a specific event).
pub struct ForkSessionHandler;

#[async_trait]
impl MethodHandler for ForkSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.fork", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let from_event_id = opt_string(params.as_ref(), "fromEventId");
        let title = opt_string(params.as_ref(), "title");
        SessionCommandService::fork(ctx, session_id, from_event_id, title).await
    }
}

/// Get the head event ID for a session.
pub struct GetHeadHandler;

#[async_trait]
impl MethodHandler for GetHeadHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHead", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::get_head(ctx, session_id).await
    }
}

/// Get reconstructed state for a session.
pub struct GetStateHandler;

#[async_trait]
impl MethodHandler for GetStateHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::get_state(ctx, session_id).await
    }
}

/// Archive a session.
pub struct ArchiveSessionHandler;

#[async_trait]
impl MethodHandler for ArchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.archive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::archive(ctx, session_id).await
    }
}

/// Get conversation history for a session (reconstructed messages).
pub struct GetHistoryHandler;

#[async_trait]
impl MethodHandler for GetHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHistory", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);

        let before_id = opt_string(params.as_ref(), "beforeId");
        SessionQueryService::get_history(ctx, session_id, limit, before_id).await
    }
}

/// Get or create the default chat session.
pub struct GetChatSessionHandler;

#[async_trait]
impl MethodHandler for GetChatSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getChat"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        SessionCommandService::get_chat(ctx).await
    }
}

/// Reset the chat session: archive the current one and create a fresh replacement.
///
/// Takes no parameters — operates on the singleton chat session. Returns the
/// new session info (same shape as `session.getChat`). Rejects calls when no
/// active chat session exists or when chat mode is disabled.
pub struct ResetChatSessionHandler;

#[async_trait]
impl MethodHandler for ResetChatSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.resetChat"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        SessionCommandService::reset_chat(ctx).await
    }
}

/// Unarchive a session.
pub struct UnarchiveSessionHandler;

#[async_trait]
impl MethodHandler for UnarchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.unarchive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::unarchive(ctx, session_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn create_session_success() {
        let ctx = make_test_context();
        let result = CreateSessionHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["sessionId"].is_string());
    }

    #[tokio::test]
    async fn create_session_missing_working_dir() {
        let ctx = make_test_context();
        let err = CreateSessionHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn create_session_with_model_and_title() {
        let ctx = make_test_context();
        let result = CreateSessionHandler
            .handle(
                Some(json!({
                    "workingDirectory": "/tmp",
                    "model": "claude-opus-4-20250514",
                    "title": "my session"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["sessionId"].is_string());
    }

    #[tokio::test]
    async fn resume_session_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let result = ResumeSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "model");
    }

    #[tokio::test]
    async fn resume_session_not_found() {
        let ctx = make_test_context();
        let err = ResumeSessionHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_sessions_empty() {
        let ctx = make_test_context();
        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["sessions"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_sessions_populated() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();
        let _ = ctx
            .session_manager
            .create_session("m", "/b", Some("s2"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn list_sessions_has_cache_tokens() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("cacheReadTokens").is_some());
        assert!(session.get("cacheCreationTokens").is_some());
        assert!(session["cacheReadTokens"].is_number());
        assert!(session["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn list_sessions_has_last_turn_input_tokens() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("lastTurnInputTokens").is_some());
        assert!(session["lastTurnInputTokens"].is_number());
    }

    #[tokio::test]
    async fn list_sessions_has_message_previews() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        // Add a user message
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello user"}),
                parent_id: None,
            })
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("lastUserPrompt").is_some());
        assert!(session.get("lastAssistantResponse").is_some());
    }

    #[tokio::test]
    async fn list_sessions_empty_previews() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        // No messages → null previews
        assert!(session["lastUserPrompt"].is_null());
        assert!(session["lastAssistantResponse"].is_null());
    }

    #[tokio::test]
    async fn list_sessions_cost_field() {
        use tron_events::sqlite::repositories::session::{IncrementCounters, SessionRepo};

        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        // Simulate accumulated cost from turns
        let conn = ctx.event_store.pool().get().unwrap();
        let _ = SessionRepo::increment_counters(
            &conn,
            &sid,
            &IncrementCounters {
                cost: Some(0.42),
                ..Default::default()
            },
        )
        .unwrap();
        drop(conn);

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!((session["cost"].as_f64().unwrap() - 0.42).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn delete_session_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = DeleteSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    #[tokio::test]
    async fn delete_session_missing_param() {
        let ctx = make_test_context();
        let err = DeleteSessionHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn fork_returns_new_session_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["newSessionId"].is_string());
        let fork_id = result["newSessionId"].as_str().unwrap();
        assert_ne!(fork_id, sid);
    }

    #[tokio::test]
    async fn fork_returns_forked_from_session_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["forkedFromSessionId"].as_str().unwrap(), sid);
    }

    #[tokio::test]
    async fn fork_returns_event_ids() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // forkedFromEventId and rootEventId should be real strings, not null
        assert!(
            result["forkedFromEventId"].is_string(),
            "forkedFromEventId should be a string, got: {}",
            result["forkedFromEventId"]
        );
        assert!(
            result["rootEventId"].is_string(),
            "rootEventId should be a string, got: {}",
            result["rootEventId"]
        );
        assert!(!result["forkedFromEventId"].as_str().unwrap().is_empty());
        assert!(!result["rootEventId"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn fork_from_specific_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Append two events so we can fork from the first one (not HEAD)
        let first = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "first"}),
                parent_id: None,
            })
            .unwrap();
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({"text": "second"}),
                parent_id: None,
            })
            .unwrap();

        let result = ForkSessionHandler
            .handle(
                Some(json!({"sessionId": sid, "fromEventId": first.id})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(
            result["forkedFromEventId"].as_str().unwrap(),
            first.id,
            "should fork from the specified event, not HEAD"
        );
    }

    #[tokio::test]
    async fn fork_without_from_event_id_forks_from_head() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Get the HEAD event ID
        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        let head_event_id = session.head_event_id.unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(
            result["forkedFromEventId"].as_str().unwrap(),
            head_event_id,
            "fork without fromEventId should fork from HEAD"
        );
    }

    #[tokio::test]
    async fn get_head_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHeadHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["sessionId"].as_str().unwrap(), sid);
    }

    #[tokio::test]
    async fn get_head_not_found() {
        let ctx = make_test_context();
        let err = GetHeadHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_state_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("my-model", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "my-model");
        assert_eq!(result["turnCount"], 0);
    }

    #[tokio::test]
    async fn get_state_has_workspace_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp/workspace", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["workspaceId"], "/tmp/workspace");
    }

    #[tokio::test]
    async fn get_state_has_cache_read_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheReadTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_has_cache_creation_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_token_usage_complete() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let tu = &result["tokenUsage"];
        assert!(tu["inputTokens"].is_number());
        assert!(tu["outputTokens"].is_number());
        assert!(tu["cacheReadTokens"].is_number());
        assert!(tu["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_not_found() {
        let ctx = make_test_context();
        let err = GetStateHandler
            .handle(Some(json!({"sessionId": "missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // ── Session lifecycle events ──

    #[tokio::test]
    async fn create_session_emits_event() {
        let ctx = make_test_context();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = CreateSessionHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_created");
    }

    #[tokio::test]
    async fn archive_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = ArchiveSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_archived");
    }

    #[tokio::test]
    async fn unarchive_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();
        ctx.session_manager.archive_session(&sid).unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = UnarchiveSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_unarchived");
    }

    #[tokio::test]
    async fn fork_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_forked");
        // Verify forked event has newSessionId
        let new_id = result["newSessionId"].as_str().unwrap();
        assert!(!new_id.is_empty());
    }

    #[tokio::test]
    async fn delete_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = DeleteSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_deleted");
    }

    // ── session.getHistory tests ──

    #[tokio::test]
    async fn get_history_empty_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["messages"].as_array().unwrap().is_empty());
        assert_eq!(result["hasMore"], false);
    }

    #[tokio::test]
    async fn get_history_with_messages() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({"text": "world"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
    }

    #[tokio::test]
    async fn get_history_returns_has_more() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        for _ in 0..5 {
            let _ = ctx
                .event_store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MessageUser,
                    payload: json!({"text": "msg"}),
                    parent_id: None,
                })
                .unwrap();
        }

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid, "limit": 3})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_history_before_id_pagination() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let e1 = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "first"}),
                parent_id: None,
            })
            .unwrap();
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "second"}),
                parent_id: None,
            })
            .unwrap();

        // Get history before the second message
        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid, "beforeId": e1.id})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        // beforeId cuts off at (but not including) e1
        assert!(messages.is_empty());
    }

    #[tokio::test]
    async fn get_history_missing_session() {
        let ctx = make_test_context();
        let err = GetHistoryHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_history_message_shape() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert!(msg["id"].is_string());
        assert_eq!(msg["role"], "user");
        assert!(msg["content"].is_object());
        assert!(msg["timestamp"].is_string());
    }

    #[tokio::test]
    async fn get_history_tool_result_has_tool_call_id_at_top() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "result data", "isError": false}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["toolCallId"], "tc1",
            "toolCallId should be hoisted to message level"
        );
    }

    #[tokio::test]
    async fn get_history_tool_result_content_preserved() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "file contents", "isError": false}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(msg["content"]["content"], "file contents");
    }

    #[tokio::test]
    async fn get_history_tool_result_has_is_error() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "error msg", "isError": true}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["isError"], true,
            "isError should be hoisted to message level"
        );
    }

    #[tokio::test]
    async fn get_history_assistant_latency_preserved() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({
                    "content": [{"type": "text", "text": "hello"}],
                    "latency": 1234
                }),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["content"]["latency"], 1234,
            "latency should be preserved in content"
        );
    }

    #[tokio::test]
    async fn get_history_includes_tool_results() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // User message
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"content": "read a file"}),
                parent_id: None,
            })
            .unwrap();

        // Assistant message with tool_use block
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "tool_use", "id": "tc1", "name": "Read", "arguments": {"path": "/tmp/test"}}]}),
            parent_id: None,
        }).unwrap();

        // Tool result (persisted as tool.result)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolResult,
            payload: json!({"toolCallId": "tc1", "content": "file contents here", "isError": false}),
            parent_id: None,
        }).unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(
            messages.len(),
            3,
            "should include user, assistant, and tool result"
        );
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[1]["role"], "assistant");
        assert_eq!(messages[2]["role"], "tool");
        assert_eq!(messages[2]["content"]["toolCallId"], "tc1");
        assert_eq!(messages[2]["content"]["content"], "file contents here");
    }

    // ── Optimistic context event tests ──

    async fn wait_for_event_count(
        ctx: &RpcContext,
        session_id: &str,
        event_types: &[&str],
        expected: usize,
    ) -> Vec<tron_events::sqlite::row_types::EventRow> {
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let events = ctx
                    .event_store
                    .get_events_by_type(session_id, event_types, Some(10))
                    .unwrap();
                if events.len() >= expected {
                    break events;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("timed out waiting for optimistic context events")
    }

    #[tokio::test]
    async fn create_session_emits_rules_loaded_when_rules_exist() {
        // Set up a temp dir with a CLAUDE.md file
        let tmp =
            std::env::temp_dir().join(format!("tron-session-test-rules-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

        let ctx = make_test_context();
        let mut rx = ctx.orchestrator.subscribe();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();

        // Check persisted rules.loaded event
        let rules_events = wait_for_event_count(&ctx, sid, &["rules.loaded"], 1).await;
        assert_eq!(
            rules_events.len(),
            1,
            "rules.loaded should be persisted once"
        );

        // Check broadcast events: session_created then rules_loaded
        let e1 = rx.try_recv().unwrap();
        assert_eq!(e1.event_type(), "session_created");
        let e2 = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match rx.try_recv() {
                    Ok(event) => break event,
                    Err(tokio::sync::broadcast::error::TryRecvError::Empty) => {
                        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                    }
                    Err(err) => panic!("unexpected broadcast error: {err}"),
                }
            }
        })
        .await
        .expect("timed out waiting for rules_loaded broadcast");
        assert_eq!(e2.event_type(), "rules_loaded");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn create_session_no_rules_event_when_no_rules() {
        let tmp = std::env::temp_dir().join(format!(
            "tron-session-test-norules-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let ctx = make_test_context();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();

        let rules_events = ctx
            .event_store
            .get_events_by_type(sid, &["rules.loaded"], Some(10))
            .unwrap();
        assert!(
            rules_events.is_empty(),
            "no rules.loaded event when no rules files exist"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn create_session_rules_loaded_has_correct_total_files() {
        let tmp =
            std::env::temp_dir().join(format!("tron-session-test-rcount-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

        let ctx = make_test_context();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();
        let rules_events = wait_for_event_count(&ctx, sid, &["rules.loaded"], 1).await;
        let payload: serde_json::Value = serde_json::from_str(&rules_events[0].payload).unwrap();
        // At least 1 file (the project rules); may also have global rules
        assert!(
            payload["totalFiles"].as_u64().unwrap() >= 1,
            "totalFiles should be >= 1, got: {}",
            payload["totalFiles"]
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn create_session_emits_memory_loaded_when_workspace_has_memory() {
        let tmp =
            std::env::temp_dir().join(format!("tron-session-test-memory-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let working_dir = tmp.to_string_lossy().to_string();

        let ctx = make_test_context();
        let existing = ctx
            .session_manager
            .create_session("m", &working_dir, Some("existing"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &existing,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "title": "Existing memory",
                "entryType": "lesson",
                "input": "Already learned this"
            }),
            parent_id: None,
        });

        let mut rx = ctx.orchestrator.subscribe();

        let result = CreateSessionHandler
            .handle(Some(json!({"workingDirectory": working_dir})), &ctx)
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();
        let memory_events = wait_for_event_count(&ctx, sid, &["memory.loaded"], 1).await;
        let payload: serde_json::Value = serde_json::from_str(&memory_events[0].payload).unwrap();
        assert_eq!(payload["count"], 1);
        assert!(payload["tokens"].as_u64().unwrap() > 0);

        let e1 = rx.try_recv().unwrap();
        assert_eq!(e1.event_type(), "session_created");
        let e2 = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match rx.try_recv() {
                    Ok(event) if event.event_type() == "memory_loaded" => break event,
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::TryRecvError::Empty) => {
                        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                    }
                    Err(err) => panic!("unexpected broadcast error: {err}"),
                }
            }
        })
        .await
        .expect("timed out waiting for memory_loaded broadcast");
        assert_eq!(e2.event_type(), "memory_loaded");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── session.getChat tests ──

    #[tokio::test]
    async fn get_chat_session_creates_on_first_call() {
        let ctx = make_test_context();
        let result = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        assert!(result["sessionId"].is_string());
        assert_eq!(result["created"], true);
        assert_eq!(result["isChat"], true);
    }

    #[tokio::test]
    async fn get_chat_session_returns_existing() {
        let ctx = make_test_context();
        let r1 = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let r2 = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(r1["sessionId"], r2["sessionId"]);
        assert_eq!(r2["created"], false);
    }

    #[tokio::test]
    async fn list_sessions_includes_chat_with_is_chat_field() {
        let ctx = make_test_context();
        let chat = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let chat_id = chat["sessionId"].as_str().unwrap();

        let _ = ctx
            .session_manager
            .create_session("m", "/tmp", Some("normal"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let sessions = result["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 2);

        let chat_entry = sessions.iter().find(|s| s["sessionId"] == chat_id).unwrap();
        assert_eq!(chat_entry["isChat"], true);
        assert_eq!(chat_entry["source"], "chat");

        let normal_entry = sessions.iter().find(|s| s["sessionId"] != chat_id).unwrap();
        assert_eq!(normal_entry["isChat"], false);
        assert!(normal_entry["source"].is_null());
    }

    // ── Chat session protection tests ──

    #[tokio::test]
    async fn delete_chat_session_blocked() {
        let ctx = make_test_context();
        let chat = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let chat_id = chat["sessionId"].as_str().unwrap();

        let err = DeleteSessionHandler
            .handle(Some(json!({"sessionId": chat_id})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "CHAT_SESSION_PROTECTED");
    }

    #[tokio::test]
    async fn archive_chat_session_blocked() {
        let ctx = make_test_context();
        let chat = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let chat_id = chat["sessionId"].as_str().unwrap();

        let err = ArchiveSessionHandler
            .handle(Some(json!({"sessionId": chat_id})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "CHAT_SESSION_PROTECTED");
    }

    // ── session.resetChat tests ──

    #[tokio::test]
    async fn reset_chat_creates_new_session() {
        let ctx = make_test_context();
        let original = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let original_id = original["sessionId"].as_str().unwrap();

        let result = ResetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let new_id = result["sessionId"].as_str().unwrap();

        assert_ne!(new_id, original_id);
        assert_eq!(result["previousSessionId"], original_id);
        assert_eq!(result["isChat"], true);
        assert_eq!(result["messageCount"], 0);
    }

    #[tokio::test]
    async fn reset_chat_archives_old_session() {
        let ctx = make_test_context();
        let original = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let original_id = original["sessionId"].as_str().unwrap();

        let _ = ResetChatSessionHandler.handle(None, &ctx).await.unwrap();

        // Old session should be archived (ended_at set)
        let old = ctx
            .session_manager
            .get_session(original_id)
            .unwrap()
            .unwrap();
        assert!(
            old.ended_at.is_some(),
            "old chat session should be archived"
        );
    }

    #[tokio::test]
    async fn reset_chat_new_session_is_chat() {
        let ctx = make_test_context();
        let _ = GetChatSessionHandler.handle(None, &ctx).await.unwrap();

        let result = ResetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let new_id = result["sessionId"].as_str().unwrap();

        assert!(ctx.session_manager.is_chat_session(new_id));
    }

    #[tokio::test]
    async fn reset_chat_get_chat_returns_new_session() {
        let ctx = make_test_context();
        let _ = GetChatSessionHandler.handle(None, &ctx).await.unwrap();

        let reset = ResetChatSessionHandler.handle(None, &ctx).await.unwrap();
        let new_id = reset["sessionId"].as_str().unwrap();

        // getChat should now return the new session
        let get = GetChatSessionHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(get["sessionId"], new_id);
        assert_eq!(get["created"], false);
    }

    #[tokio::test]
    async fn reset_chat_fails_without_existing_chat() {
        let ctx = make_test_context();
        // No chat session created — reset should fail
        let err = ResetChatSessionHandler
            .handle(None, &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn reset_chat_emits_archive_and_create_events() {
        let ctx = make_test_context();
        let _ = GetChatSessionHandler.handle(None, &ctx).await.unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = ResetChatSessionHandler.handle(None, &ctx).await.unwrap();

        let e1 = rx.try_recv().unwrap();
        assert_eq!(e1.event_type(), "session_archived");
        let e2 = rx.try_recv().unwrap();
        assert_eq!(e2.event_type(), "session_created");
    }
}
