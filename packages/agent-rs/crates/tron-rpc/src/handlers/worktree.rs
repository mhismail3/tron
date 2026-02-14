//! Worktree handlers: getStatus, commit, merge, list.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get worktree status for a session.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getStatus"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Check if session has worktree.acquired events
        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &["worktree.acquired"], Some(1))
            .unwrap_or_default();

        let has_worktree = !events.is_empty();
        let worktree = if has_worktree {
            events
                .first()
                .and_then(|e| serde_json::from_str::<Value>(&e.payload).ok())
        } else {
            None
        };

        Ok(serde_json::json!({
            "hasWorktree": has_worktree,
            "worktree": worktree,
        }))
    }
}

/// Commit worktree changes.
pub struct CommitHandler;

#[async_trait]
impl MethodHandler for CommitHandler {
    #[instrument(skip(self, _ctx), fields(method = "worktree.commit"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _message = require_string_param(params.as_ref(), "message")?;
        Err(RpcError::NotAvailable {
            message: "Worktree commit not yet available in Rust server".into(),
        })
    }
}

/// Merge worktree.
pub struct MergeHandler;

#[async_trait]
impl MethodHandler for MergeHandler {
    #[instrument(skip(self, _ctx), fields(method = "worktree.merge"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Err(RpcError::NotAvailable {
            message: "Worktree merge not yet available in Rust server".into(),
        })
    }
}

/// List worktrees across all sessions.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        // Query all sessions for worktree.acquired events
        let sessions = ctx
            .session_manager
            .list_sessions(&tron_runtime::SessionFilter {
                include_archived: false,
                ..Default::default()
            })
            .unwrap_or_default();

        let mut worktrees = Vec::new();

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(&session.id, &["worktree.acquired"], Some(1))
                .unwrap_or_default();

            for event in events {
                if let Ok(mut parsed) = serde_json::from_str::<Value>(&event.payload) {
                    if let Some(obj) = parsed.as_object_mut() {
                        let _ = obj.insert("sessionId".into(), serde_json::json!(session.id));
                    }
                    worktrees.push(parsed);
                }
            }
        }

        Ok(serde_json::json!({ "worktrees": worktrees }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_status_no_worktree() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasWorktree"], false);
        assert!(result["worktree"].is_null());
    }

    #[tokio::test]
    async fn commit_not_available() {
        let ctx = make_test_context();
        let err = CommitHandler
            .handle(
                Some(json!({"sessionId": "s1", "message": "test commit"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn commit_missing_message() {
        let ctx = make_test_context();
        let err = CommitHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn merge_not_available() {
        let ctx = make_test_context();
        let err = MergeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn list_worktrees_empty() {
        let ctx = make_test_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert!(result["worktrees"].is_array());
        assert!(result["worktrees"].as_array().unwrap().is_empty());
    }
}
