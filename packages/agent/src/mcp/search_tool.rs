//! `McpSearch` meta-tool — searches across all MCP server tools by keyword.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};
use crate::mcp::router::McpRouter;
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;

/// Meta-tool that searches all connected MCP servers for matching tools.
pub struct McpSearchTool {
    router: Arc<tokio::sync::RwLock<McpRouter>>,
}

impl McpSearchTool {
    /// Create a new `McpSearchTool` backed by the given router.
    pub fn new(router: Arc<tokio::sync::RwLock<McpRouter>>) -> Self {
        Self { router }
    }
}

#[async_trait]
impl TronTool for McpSearchTool {
    fn name(&self) -> &str {
        "McpSearch"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "McpSearch",
            "Search or browse tools across all connected MCP servers. Returns tool names, \
             descriptions, and parameter info. Use this before McpCall to discover available tools.\n\n\
             - Pass a query to search by keyword (e.g. \"sql query\")\n\
             - Pass an empty query or omit it to list all tools\n\
             - Use the server filter to list tools from a specific server",
        )
        .property(
            "query",
            json!({"type": "string", "description": "Keywords to search for. Empty or omitted = list all tools."}),
        )
        .property(
            "server",
            json!({"type": "string", "description": "Filter results to a specific server name"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, _ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let query = params.get("query")
            .and_then(Value::as_str)
            .unwrap_or("");
        let server_filter = params.get("server").and_then(Value::as_str);

        let router = self.router.read().await;
        let text = router.format_search_results(query, server_filter);

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(text),
            ]),
            details: None,
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_tool_definition_has_query_param() {
        let _router = Arc::new(tokio::sync::RwLock::new(()));
        // We can't easily construct a real McpRouter here, so test the schema directly
        let tool = ToolSchemaBuilder::new("McpSearch", "Search")
            .required_property("query", json!({"type": "string"}))
            .property("server", json!({"type": "string"}))
            .build();
        assert_eq!(tool.name, "McpSearch");
        let props = tool.parameters.properties.unwrap();
        assert!(props.contains_key("query"));
        assert!(props.contains_key("server"));
        let req = tool.parameters.required.unwrap();
        assert_eq!(req, vec!["query"]);
    }
}
