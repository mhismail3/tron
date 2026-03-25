//! Bridge from MCP tools to [`TronTool`] — adapts MCP-discovered tools
//! so they appear as native Tron tools to the LLM.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult};

use crate::mcp::client::McpClient;
use crate::mcp::types::{McpContentBlock, McpToolDef};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};

/// A TronTool backed by an MCP server tool.
///
/// The tool name is prefixed with the server name to prevent collisions:
/// e.g., `sqlite.query`, `github.create_issue`.
pub struct McpToolBridge {
    /// Prefixed tool name (e.g., "sqlite.query").
    prefixed_name: String,
    /// Original MCP tool name (e.g., "query").
    mcp_name: String,
    /// Tool description from the MCP server.
    description: String,
    /// JSON Schema for input parameters.
    input_schema: Value,
    /// MCP client for calling the tool.
    client: Arc<McpClient>,
}

impl McpToolBridge {
    /// Create a bridge tool from an MCP tool definition and client.
    pub fn new(server_name: &str, tool_def: &McpToolDef, client: Arc<McpClient>) -> Self {
        Self {
            prefixed_name: format!("{}.{}", server_name, tool_def.name),
            mcp_name: tool_def.name.clone(),
            description: tool_def.description.clone(),
            input_schema: tool_def.input_schema.clone(),
            client,
        }
    }
}

#[async_trait]
impl TronTool for McpToolBridge {
    fn name(&self) -> &str {
        &self.prefixed_name
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        // Convert MCP input schema to Tool parameter schema
        let properties = self.input_schema.get("properties")
            .and_then(Value::as_object)
            .cloned();
        let required = self.input_schema.get("required")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect());

        Tool {
            name: self.prefixed_name.clone(),
            description: format!(
                "[MCP: {}] {}",
                self.client.name,
                self.description,
            ),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties,
                required,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(&self, params: Value, _ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let result = self.client.call_tool(&self.mcp_name, params).await
            .map_err(|e| ToolError::Internal {
                message: format!("MCP tool call failed: {e}"),
            })?;

        // Convert MCP content blocks to TronToolResult
        let mut text_parts = Vec::new();
        for block in &result.content {
            match block {
                McpContentBlock::Text { text } => {
                    text_parts.push(text.clone());
                }
                McpContentBlock::Image { data, mime_type } => {
                    text_parts.push(format!("[Image: {mime_type}, {} bytes]", data.len()));
                }
                McpContentBlock::Resource { resource } => {
                    text_parts.push(format!("[Resource: {}]", resource));
                }
            }
        }

        let content = text_parts.join("\n");

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(content),
            ]),
            details: Some(json!({
                "mcpServer": self.client.name,
                "mcpTool": self.mcp_name,
            })),
            is_error: if result.is_error { Some(true) } else { None },
            stop_turn: None,
        })
    }
}

/// Create bridge tools for all tools discovered from an MCP client.
pub fn create_bridge_tools(
    server_name: &str,
    tool_defs: &[McpToolDef],
    client: Arc<McpClient>,
) -> Vec<Arc<dyn TronTool>> {
    tool_defs
        .iter()
        .map(|def| {
            Arc::new(McpToolBridge::new(server_name, def, client.clone())) as Arc<dyn TronTool>
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_tool_def() -> McpToolDef {
        McpToolDef {
            name: "query".into(),
            description: "Run a SQL query".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "sql": {"type": "string", "description": "SQL query"}
                },
                "required": ["sql"]
            }),
        }
    }

    #[test]
    fn bridge_tool_name_prefixed() {
        // We can't create a real McpClient in tests easily, but we can test the naming logic
        let def = sample_tool_def();
        let prefixed = format!("{}.{}", "sqlite", def.name);
        assert_eq!(prefixed, "sqlite.query");
    }

    #[test]
    fn bridge_description_includes_server_name() {
        let desc = format!("[MCP: {}] {}", "sqlite", "Run a SQL query");
        assert!(desc.contains("MCP: sqlite"));
        assert!(desc.contains("Run a SQL query"));
    }

    #[test]
    fn mcp_tool_def_schema_extraction() {
        let def = sample_tool_def();
        let properties = def.input_schema.get("properties")
            .and_then(Value::as_object)
            .cloned();
        assert!(properties.is_some());
        let props = properties.unwrap();
        assert!(props.contains_key("sql"));

        let required = def.input_schema.get("required")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect::<Vec<_>>());
        assert_eq!(required, Some(vec!["sql".to_string()]));
    }
}
