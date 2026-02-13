//! Plan handlers: enter, exit, getState.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Enter plan mode for a session.
pub struct EnterPlanHandler;

#[async_trait]
impl MethodHandler for EnterPlanHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "planMode": true }))
    }
}

/// Exit plan mode.
pub struct ExitPlanHandler;

#[async_trait]
impl MethodHandler for ExitPlanHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "planMode": false }))
    }
}

/// Get plan mode state.
pub struct GetPlanStateHandler;

#[async_trait]
impl MethodHandler for GetPlanStateHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "planMode": false }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn enter_plan_success() {
        let ctx = make_test_context();
        let result = EnterPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], true);
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
    async fn exit_plan_success() {
        let ctx = make_test_context();
        let result = ExitPlanHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["planMode"], false);
    }

    #[tokio::test]
    async fn get_plan_state() {
        let ctx = make_test_context();
        let result = GetPlanStateHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.get("planMode").is_some());
    }
}
