//! Agent handlers: prompt, abort, getState.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _prompt = require_string_param(params.as_ref(), "prompt")?;

        // Verify the session exists
        let _ = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        Ok(serde_json::json!({
            "acknowledged": true,
            "runId": run_id,
        }))
    }
}

/// Abort a running agent in a session.
pub struct AbortHandler;

#[async_trait]
impl MethodHandler for AbortHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let aborted = ctx.orchestrator.abort(&session_id).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        Ok(serde_json::json!({ "aborted": aborted }))
    }
}

/// Get the current agent state for a session.
pub struct GetAgentStateHandler;

#[async_trait]
impl MethodHandler for GetAgentStateHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let is_busy = ctx.orchestrator.is_session_busy(&session_id);

        Ok(serde_json::json!({
            "sessionId": session_id,
            "busy": is_busy,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn prompt_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn prompt_missing_session_id() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(Some(json!({"prompt": "hi"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_missing_prompt() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_session_not_found() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(
                Some(json!({"sessionId": "nonexistent", "prompt": "hi"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn abort_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], true);
    }

    #[tokio::test]
    async fn abort_missing_param() {
        let ctx = make_test_context();
        let err = AbortHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_state_busy() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // Session is active so busy = true
        assert_eq!(result["busy"], true);
    }

    #[tokio::test]
    async fn get_state_not_busy() {
        let ctx = make_test_context();
        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["busy"], false);
    }
}
