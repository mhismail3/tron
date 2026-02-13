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

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        ctx.orchestrator
            .start_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: "SESSION_BUSY".into(),
                message: e.to_string(),
                details: None,
            })?;

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

        let aborted = ctx
            .orchestrator
            .abort(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
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

        let is_busy = ctx.orchestrator.has_active_run(&session_id);
        let run_id = ctx.orchestrator.get_run_id(&session_id);

        Ok(serde_json::json!({
            "sessionId": session_id,
            "busy": is_busy,
            "runId": run_id,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn prompt_returns_acknowledged() {
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
    async fn prompt_generates_unique_run_ids() {
        let ctx = make_test_context();
        let sid1 = ctx
            .session_manager
            .create_session("m", "/tmp/1", Some("t1"))
            .unwrap();
        let sid2 = ctx
            .session_manager
            .create_session("m", "/tmp/2", Some("t2"))
            .unwrap();

        let r1 = PromptHandler
            .handle(Some(json!({"sessionId": sid1, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        let r2 = PromptHandler
            .handle(Some(json!({"sessionId": sid2, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_ne!(r1["runId"], r2["runId"]);
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
    async fn prompt_rejects_busy_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // First prompt succeeds
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        // Second prompt should fail (session busy)
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello again"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    #[tokio::test]
    async fn abort_active_returns_true() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Start a run so there's something to abort
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], true);
    }

    #[tokio::test]
    async fn abort_inactive_returns_false() {
        let ctx = make_test_context();
        let result = AbortHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], false);
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

        // Start a run
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["busy"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn get_state_not_busy() {
        let ctx = make_test_context();
        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["busy"], false);
        assert!(result["runId"].is_null());
    }
}
