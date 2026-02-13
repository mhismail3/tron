//! Tool handler: result.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Submit a tool result back to the agent.
pub struct ToolResultHandler;

#[async_trait]
impl MethodHandler for ToolResultHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _tool_use_id = require_string_param(params.as_ref(), "toolUseId")?;
        Ok(serde_json::json!({ "accepted": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn tool_result_success() {
        let ctx = make_test_context();
        let result = ToolResultHandler
            .handle(
                Some(json!({"sessionId": "s1", "toolUseId": "tu1"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["accepted"], true);
    }

    #[tokio::test]
    async fn tool_result_missing_params() {
        let ctx = make_test_context();
        let err = ToolResultHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
