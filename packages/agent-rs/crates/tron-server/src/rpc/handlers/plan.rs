//! Plan handlers: enter, exit, getState.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Enter plan mode for a session.
pub struct EnterPlanHandler;

#[async_trait]
impl MethodHandler for EnterPlanHandler {
    #[instrument(skip(self, ctx), fields(method = "plan.enter"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ctx.session_manager.set_plan_mode(&session_id, true);
        Ok(serde_json::json!({ "planMode": true }))
    }
}

/// Exit plan mode.
pub struct ExitPlanHandler;

#[async_trait]
impl MethodHandler for ExitPlanHandler {
    #[instrument(skip(self, ctx), fields(method = "plan.exit"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ctx.session_manager.set_plan_mode(&session_id, false);
        Ok(serde_json::json!({ "planMode": false }))
    }
}

/// Get plan mode state.
pub struct GetPlanStateHandler;

#[async_trait]
impl MethodHandler for GetPlanStateHandler {
    #[instrument(skip(self, ctx), fields(method = "plan.getState"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let in_plan_mode = ctx.session_manager.is_plan_mode(&session_id);
        Ok(serde_json::json!({ "planMode": in_plan_mode }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn enter_plan_sets_true() {
        let ctx = make_test_context();
        let result = EnterPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], true);
        assert!(ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn enter_plan_missing_session() {
        let ctx = make_test_context();
        let err = EnterPlanHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn exit_plan_sets_false() {
        let ctx = make_test_context();
        ctx.session_manager.set_plan_mode("s1", true);
        let result = ExitPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], false);
        assert!(!ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn get_state_reads_actual_state() {
        let ctx = make_test_context();
        // Default is false
        let result = GetPlanStateHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], false);

        // Set to true
        ctx.session_manager.set_plan_mode("s1", true);
        let result = GetPlanStateHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], true);
    }

    #[tokio::test]
    async fn toggle_round_trip() {
        let ctx = make_test_context();

        let _ = EnterPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(ctx.session_manager.is_plan_mode("s1"));

        let _ = ExitPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(!ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn different_sessions_independent() {
        let ctx = make_test_context();
        ctx.session_manager.set_plan_mode("s1", true);
        ctx.session_manager.set_plan_mode("s2", false);

        assert!(ctx.session_manager.is_plan_mode("s1"));
        assert!(!ctx.session_manager.is_plan_mode("s2"));
    }

    #[tokio::test]
    async fn missing_session_defaults_to_false() {
        let ctx = make_test_context();
        let result = GetPlanStateHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], false);
    }
}
