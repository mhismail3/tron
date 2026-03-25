//! MCP protocol types — JSON-RPC messages and tool schemas.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// JSON-RPC 2.0 request.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: u64,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl JsonRpcRequest {
    pub fn new(id: u64, method: impl Into<String>, params: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            method: method.into(),
            params,
        }
    }
}

/// JSON-RPC 2.0 response.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

/// JSON-RPC 2.0 error object.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl std::fmt::Display for JsonRpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "MCP error {}: {}", self.code, self.message)
    }
}

/// MCP tool definition from `tools/list` response.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpToolDef {
    /// Tool name.
    pub name: String,
    /// Tool description.
    #[serde(default)]
    pub description: String,
    /// JSON Schema for input parameters.
    #[serde(default)]
    pub input_schema: Value,
}

/// Result from `tools/call`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpToolResult {
    /// Content blocks returned by the tool.
    #[serde(default)]
    pub content: Vec<McpContentBlock>,
    /// Whether the tool execution resulted in an error.
    #[serde(default)]
    pub is_error: bool,
}

/// Content block in MCP tool results.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum McpContentBlock {
    /// Text content.
    #[serde(rename = "text")]
    Text {
        text: String,
    },
    /// Image content.
    #[serde(rename = "image")]
    Image {
        data: String,
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
    /// Resource content.
    #[serde(rename = "resource")]
    Resource {
        resource: Value,
    },
}

/// MCP server configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct McpServerConfig {
    /// Server name (used as tool name prefix).
    pub name: String,
    /// Command to spawn the server process (stdio transport).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Arguments for the server command.
    #[serde(default)]
    pub args: Vec<String>,
    /// Environment variables for the server process.
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
    /// HTTP URL for HTTP transport (alternative to stdio).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Per-tool-call timeout in milliseconds.
    #[serde(default = "default_tool_timeout")]
    pub tool_timeout_ms: u64,
}

fn default_tool_timeout() -> u64 {
    30_000
}

/// MCP settings configuration.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct McpSettings {
    /// Configured MCP servers.
    #[serde(default)]
    pub servers: Vec<McpServerConfig>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn jsonrpc_request_serialization() {
        let req = JsonRpcRequest::new(1, "tools/list", None);
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["jsonrpc"], "2.0");
        assert_eq!(json["id"], 1);
        assert_eq!(json["method"], "tools/list");
    }

    #[test]
    fn jsonrpc_response_with_result() {
        let json = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {"tools": []}
        });
        let resp: JsonRpcResponse = serde_json::from_value(json).unwrap();
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
    }

    #[test]
    fn jsonrpc_response_with_error() {
        let json = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "error": {"code": -32601, "message": "Method not found"}
        });
        let resp: JsonRpcResponse = serde_json::from_value(json).unwrap();
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, -32601);
    }

    #[test]
    fn mcp_tool_def_deserialization() {
        let json = json!({
            "name": "query",
            "description": "Run SQL query",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "sql": {"type": "string"}
                },
                "required": ["sql"]
            }
        });
        let tool: McpToolDef = serde_json::from_value(json).unwrap();
        assert_eq!(tool.name, "query");
        assert_eq!(tool.description, "Run SQL query");
    }

    #[test]
    fn mcp_tool_result_deserialization() {
        let json = json!({
            "content": [
                {"type": "text", "text": "result data"}
            ],
            "isError": false
        });
        let result: McpToolResult = serde_json::from_value(json).unwrap();
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 1);
    }

    #[test]
    fn mcp_server_config_with_defaults() {
        let json = json!({
            "name": "sqlite",
            "command": "uvx",
            "args": ["mcp-server-sqlite"]
        });
        let config: McpServerConfig = serde_json::from_value(json).unwrap();
        assert_eq!(config.name, "sqlite");
        assert_eq!(config.tool_timeout_ms, 30_000);
    }

    #[test]
    fn mcp_content_block_text() {
        let json = json!({"type": "text", "text": "hello"});
        let block: McpContentBlock = serde_json::from_value(json).unwrap();
        match block {
            McpContentBlock::Text { text } => assert_eq!(text, "hello"),
            _ => panic!("Expected text block"),
        }
    }
}
