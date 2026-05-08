//! Tool workflow operations.
use super::{
    EngineError, InProcessFunctionHandler, ToolContext, TronTool, async_trait, capability_runtime,
};
use crate::engine::Invocation;
use serde_json::Value;
use serde_json::json;

pub(crate) struct ToolFunctionHandler {
    pub(crate) tool: std::sync::Arc<dyn TronTool>,
}

#[async_trait]
impl InProcessFunctionHandler for ToolFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        let payload = invocation.payload;
        let runtime_id = payload
            .get("__runtimeToolInvocationId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| invocation.id.to_string());
        if let Some(execution) = capability_runtime::take_runtime_tool_execution(&runtime_id) {
            if execution.tool_name != self.tool.name() {
                return Err(EngineError::DomainFailure {
                    domain: "tool".to_owned(),
                    code: "TOOL_RUNTIME_CONTEXT_MISMATCH".to_owned(),
                    message: "tool runtime context was prepared for a different tool".to_owned(),
                    details: Some(json!({
                        "expected": self.tool.name(),
                        "actual": execution.tool_name,
                        "runtimeInvocationId": runtime_id,
                    })),
                });
            }
            let result = execute_tool_with_runtime_context(
                self.tool.as_ref(),
                execution.params,
                &execution.context,
            )
            .await;
            return serde_json::to_value(result).map_err(|error| {
                EngineError::HandlerFailed(format!("failed to serialize tool result: {error}"))
            });
        }

        Err(EngineError::DomainFailure {
            domain: "tool".to_owned(),
            code: "TOOL_RUNTIME_CONTEXT_REQUIRED".to_owned(),
            message: "tool functions require a prepared agent turn runtime context".to_owned(),
            details: Some(json!({
                "tool": self.tool.name(),
                "runtimeInvocationId": runtime_id,
            })),
        })
    }
}

pub(crate) async fn execute_tool_with_runtime_context(
    tool: &dyn TronTool,
    params: Value,
    tool_ctx: &ToolContext,
) -> crate::core::tools::TronToolResult {
    if tool_ctx.cancellation.is_cancelled() {
        return crate::core::tools::error_result("Operation cancelled");
    }
    tokio::select! {
        biased;
        () = tool_ctx.cancellation.cancelled() => {
            crate::core::tools::error_result("Operation cancelled")
        }
        result = tool.execute(params, tool_ctx) => {
            match result {
                Ok(result) => result,
                Err(error) => crate::core::tools::error_result(error.to_string()),
            }
        }
    }
}
