//! Bridge from MCP tools to [`TronTool`] — adapts MCP-discovered tools
//! so they appear as native Tron tools to the LLM.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult};

use crate::mcp::client::{McpClient, McpErrorKind};
use crate::mcp::types::{McpContentBlock, McpToolDef, McpToolResult};
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
    /// Server name (for metadata).
    server_name: String,
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
            server_name: server_name.to_string(),
            description: tool_def.description.clone(),
            input_schema: tool_def.input_schema.clone(),
            client,
        }
    }

    /// The original MCP tool name (without server prefix).
    pub fn mcp_name(&self) -> &str {
        &self.mcp_name
    }

    /// The server name this tool belongs to.
    pub fn server_name(&self) -> &str {
        &self.server_name
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
                self.server_name,
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
            .map_err(|e| {
                let msg = match &e.kind {
                    McpErrorKind::ConnectionLost => format!(
                        "MCP server '{}' is no longer connected. The tool call could not be \
                         completed. The server may restart automatically.",
                        self.server_name,
                    ),
                    McpErrorKind::Timeout => format!(
                        "MCP tool '{}.{}' timed out. The server may be overloaded or the \
                         operation may require more time.",
                        self.server_name, self.mcp_name,
                    ),
                    _ => format!("MCP tool call failed: {e}"),
                };
                ToolError::Internal { message: msg }
            })?;

        Ok(mcp_result_to_tron_result(&result, &self.server_name, &self.mcp_name))
    }
}

/// Convert an MCP tool result to a TronToolResult.
pub fn mcp_result_to_tron_result(result: &McpToolResult, server: &str, tool: &str) -> TronToolResult {
    let content = if result.content.is_empty() {
        "(no output)".to_string()
    } else {
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
        text_parts.join("\n")
    };

    TronToolResult {
        content: ToolResultBody::Blocks(vec![
            crate::core::content::ToolResultContent::text(content),
        ]),
        details: Some(json!({
            "mcpServer": server,
            "mcpTool": tool,
        })),
        is_error: if result.is_error { Some(true) } else { None },
        stop_turn: None,
    }
}

/// Create bridge tools for all tools discovered from an MCP client.
#[allow(dead_code)]
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

    #[test]
    fn empty_schema_handled() {
        let def = McpToolDef {
            name: "noop".into(),
            description: "Do nothing".into(),
            input_schema: json!({}),
        };
        let properties = def.input_schema.get("properties")
            .and_then(Value::as_object)
            .cloned();
        assert!(properties.is_none());
    }

    #[test]
    fn missing_description_handled() {
        let def = McpToolDef {
            name: "silent".into(),
            description: String::new(),
            input_schema: json!({"type": "object"}),
        };
        let desc = format!("[MCP: {}] {}", "test", def.description);
        assert!(desc.starts_with("[MCP: test]"));
    }
}
