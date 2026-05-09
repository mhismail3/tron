//! `McpCall` meta-tool — calls a tool on an MCP server.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::domains::mcp::router::McpRouter;
use crate::domains::mcp::tool_projection::mcp_result_to_tron_result;
use crate::domains::tools::implementations::errors::ToolError;
use crate::domains::tools::implementations::traits::{ToolContext, TronTool};
use crate::domains::tools::implementations::utils::schema::ToolSchemaBuilder;
use crate::shared::tools::{Tool, ToolCategory, TronToolResult, error_result};

/// Meta-tool that calls a specific tool on an MCP server.
pub struct McpCallTool {
    router: Arc<tokio::sync::RwLock<McpRouter>>,
}

impl McpCallTool {
    /// Create a new `McpCallTool` backed by the given router.
    pub fn new(router: Arc<tokio::sync::RwLock<McpRouter>>) -> Self {
        Self { router }
    }
}

#[async_trait]
impl TronTool for McpCallTool {
    fn name(&self) -> &str {
        "McpCall"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "McpCall",
            "Call a tool on an MCP server. Use McpSearch first to find available tools \
             and required parameters.",
        )
        .required_property(
            "server",
            json!({"type": "string", "description": "The MCP server name"}),
        )
        .required_property(
            "tool",
            json!({"type": "string", "description": "The tool name on that server"}),
        )
        .required_property(
            "arguments",
            json!({"type": "object", "description": "Arguments for the tool (see McpSearch for params)"}),
        )
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let Some(server) = params.get("server").and_then(Value::as_str) else {
            return Ok(error_result("Missing required parameter: server"));
        };
        let Some(tool) = params.get("tool").and_then(Value::as_str) else {
            return Ok(error_result("Missing required parameter: tool"));
        };
        let arguments = params.get("arguments").cloned().unwrap_or(json!({}));

        let mut router = self.router.write().await;
        match router.call(server, tool, arguments).await {
            Ok(result) => Ok(mcp_result_to_tron_result(&result, server, tool)),
            Err(e) => Ok(error_result(format!("MCP call failed: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_tool_definition_has_server_tool_arguments_params() {
        let tool = ToolSchemaBuilder::new("McpCall", "Call")
            .required_property("server", json!({"type": "string"}))
            .required_property("tool", json!({"type": "string"}))
            .required_property("arguments", json!({"type": "object"}))
            .build();
        assert_eq!(tool.name, "McpCall");
        let props = tool.parameters.properties.unwrap();
        assert!(props.contains_key("server"));
        assert!(props.contains_key("tool"));
        assert!(props.contains_key("arguments"));
        let req = tool.parameters.required.unwrap();
        assert_eq!(req, vec!["server", "tool", "arguments"]);
    }
}
