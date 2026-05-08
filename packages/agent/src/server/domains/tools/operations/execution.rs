//! Tool workflow operations.
use super::*;

pub(crate) struct ToolFunctionHandler {
    pub(crate) tool: std::sync::Arc<dyn TronTool>,
    pub(crate) process_manager: Option<std::sync::Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(crate) job_manager: Option<std::sync::Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(crate) output_buffer_registry:
        Option<std::sync::Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub(crate) all_tool_names: Vec<String>,
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

        let params = payload
            .get("params")
            .cloned()
            .unwrap_or_else(|| payload.clone());
        let session_id = payload
            .get("sessionId")
            .and_then(Value::as_str)
            .or(invocation.causal_context.session_id.as_deref())
            .unwrap_or("engine-tool")
            .to_owned();
        let working_directory = payload
            .get("workingDirectory")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_owned();
        let tool_call_id = payload
            .get("toolCallId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| invocation.id.to_string());
        let tool_ctx = ToolContext {
            tool_call_id,
            session_id,
            working_directory,
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: invocation.causal_context.workspace_id.clone(),
            output_tx: None,
            process_manager: self.process_manager.clone(),
            job_manager: self.job_manager.clone(),
            output_buffer_registry: self.output_buffer_registry.clone(),
            event_emitter: None,
            event_persister: None,
            turn: 0,
            all_tool_names: self.all_tool_names.clone(),
        };
        let result = execute_tool_with_runtime_context(self.tool.as_ref(), params, &tool_ctx).await;
        serde_json::to_value(result).map_err(|error| {
            EngineError::HandlerFailed(format!("failed to serialize tool result: {error}"))
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
