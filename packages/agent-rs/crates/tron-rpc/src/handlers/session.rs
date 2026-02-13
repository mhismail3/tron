//! Session handlers: create, resume, list, delete, fork, getHead, getState.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::{require_string_param};
use crate::registry::MethodHandler;

/// Create a new session.
pub struct CreateSessionHandler;

#[async_trait]
impl MethodHandler for CreateSessionHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;
        let model = params
            .as_ref()
            .and_then(|p| p.get("model"))
            .and_then(|v| v.as_str())
            .unwrap_or("claude-sonnet-4-20250514");
        let title = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(|v| v.as_str());

        let session_id = ctx
            .session_manager
            .create_session(model, &working_dir, title)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "sessionId": session_id }))
    }
}

/// Resume an existing session.
pub struct ResumeSessionHandler;

#[async_trait]
impl MethodHandler for ResumeSessionHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let active = ctx.session_manager.resume_session(&session_id).map_err(|e| {
            RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            }
        })?;

        Ok(serde_json::json!({
            "sessionId": session_id,
            "model": active.state.model,
        }))
    }
}

/// List sessions with optional filters.
pub struct ListSessionsHandler;

#[async_trait]
impl MethodHandler for ListSessionsHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let include_archived = params
            .as_ref()
            .and_then(|p| p.get("includeArchived"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);

        let filter = tron_runtime::SessionFilter {
            include_archived,
            limit,
            ..Default::default()
        };

        let sessions = ctx
            .session_manager
            .list_sessions(&filter)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let items: Vec<Value> = sessions
            .into_iter()
            .map(|s| {
                serde_json::json!({
                    "id": s.id,
                    "model": s.latest_model,
                    "title": s.title,
                    "createdAt": s.created_at,
                    "endedAt": s.ended_at,
                })
            })
            .collect();

        Ok(serde_json::json!({ "sessions": items }))
    }
}

/// Delete a session.
pub struct DeleteSessionHandler;

#[async_trait]
impl MethodHandler for DeleteSessionHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        ctx.session_manager
            .delete_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "deleted": true }))
    }
}

/// Fork a session at the current head (or a specific event).
pub struct ForkSessionHandler;

#[async_trait]
impl MethodHandler for ForkSessionHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let title = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(|v| v.as_str());

        let fork_id = ctx
            .session_manager
            .fork_session(&session_id, None, title)
            .map_err(|e| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "sessionId": fork_id }))
    }
}

/// Get the head event ID for a session.
pub struct GetHeadHandler;

#[async_trait]
impl MethodHandler for GetHeadHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        Ok(serde_json::json!({
            "sessionId": session.id,
            "headEventId": session.head_event_id,
        }))
    }
}

/// Get reconstructed state for a session.
pub struct GetStateHandler;

#[async_trait]
impl MethodHandler for GetStateHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let active = ctx.session_manager.resume_session(&session_id).map_err(|e| {
            RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            }
        })?;

        Ok(serde_json::json!({
            "sessionId": session_id,
            "model": active.state.model,
            "turnCount": active.state.turn_count,
            "isEnded": active.state.is_ended,
            "workingDirectory": active.state.working_directory,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
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
        let _ = ctx.session_manager.create_session("m", "/a", Some("s1")).unwrap();
        let _ = ctx.session_manager.create_session("m", "/b", Some("s2")).unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 2);
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
    async fn fork_session_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["sessionId"].is_string());
        let fork_id = result["sessionId"].as_str().unwrap();
        assert_ne!(fork_id, sid);
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
    async fn get_state_not_found() {
        let ctx = make_test_context();
        let err = GetStateHandler
            .handle(Some(json!({"sessionId": "missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }
}
