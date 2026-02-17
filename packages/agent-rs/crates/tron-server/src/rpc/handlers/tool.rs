//! Tool handler: result.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::{require_param, require_string_param};
use crate::rpc::registry::MethodHandler;

/// Submit a tool result back to the agent.
pub struct ToolResultHandler;

#[async_trait]
impl MethodHandler for ToolResultHandler {
    #[instrument(skip(self, ctx), fields(method = "tool.result", tool_call_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let tool_use_id = require_string_param(params.as_ref(), "toolUseId")?;
        let result = require_param(params.as_ref(), "result")?;

        let resolved = ctx
            .orchestrator
            .resolve_tool_call(&tool_use_id, result.clone());

        if resolved {
            Ok(serde_json::json!({
                "success": true,
                "toolCallId": tool_use_id,
            }))
        } else {
            Err(RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("No pending tool call '{tool_use_id}'"),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn tool_result_resolves_pending() {
        let ctx = make_test_context();
        // Register a pending tool call
        let _rx = ctx.orchestrator.register_tool_call("tc_1");

        let result = ToolResultHandler
            .handle(
                Some(json!({
                    "sessionId": "s1",
                    "toolUseId": "tc_1",
                    "result": {"output": "hello"}
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["toolCallId"], "tc_1");
    }

    #[tokio::test]
    async fn tool_result_not_pending() {
        let ctx = make_test_context();
        let err = ToolResultHandler
            .handle(
                Some(json!({
                    "sessionId": "s1",
                    "toolUseId": "nonexistent",
                    "result": null
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
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

    #[tokio::test]
    async fn tool_result_missing_result_param() {
        let ctx = make_test_context();
        let err = ToolResultHandler
            .handle(
                Some(json!({"sessionId": "s1", "toolUseId": "tc_1"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
