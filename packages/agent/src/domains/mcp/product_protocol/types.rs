//! MCP protocol types — JSON-RPC messages and capability schemas.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// JSON-RPC 2.0 request.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    /// JSON-RPC version string (always "2.0").
    pub jsonrpc: String,
    /// Request ID for correlating responses.
    pub id: u64,
    /// Method name to invoke.
    pub method: String,
    /// Optional method parameters.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl JsonRpcRequest {
    /// Create a new JSON-RPC 2.0 request.
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
    /// JSON-RPC version string (always "2.0").
    pub jsonrpc: String,
    /// Request ID this response corresponds to.
    pub id: Option<u64>,
    /// Successful result value (mutually exclusive with `error`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Error object (mutually exclusive with `result`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

/// JSON-RPC 2.0 error object.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcError {
    /// Numeric error code.
    pub code: i64,
    /// Human-readable error message.
    pub message: String,
    /// Optional additional error data.
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
    /// Capability name.
    pub name: String,
    /// ModelCapability description.
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
    /// Whether the capability invocation resulted in an error.
    #[serde(default)]
    pub is_error: bool,
}

/// Content block in MCP capability results.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum McpContentBlock {
    /// Text content.
    #[serde(rename = "text")]
    Text {
        /// The text string.
        text: String,
    },
    /// Image content.
    #[serde(rename = "image")]
    Image {
        /// Base64-encoded image data.
        data: String,
        /// MIME type of the image (e.g., "image/png").
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
    /// Resource content.
    #[serde(rename = "resource")]
    Resource {
        /// Resource payload as a JSON value.
        resource: Value,
    },
}

/// MCP server configuration.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerConfig {
    /// Server name (used as capability id prefix).
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
    /// Per-capability-invocation timeout in milliseconds.
    #[serde(default = "default_tool_timeout", alias = "tool_timeout_ms")]
    pub tool_timeout_ms: u64,
    /// Whether this server is enabled. Disabled servers are not started.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_tool_timeout() -> u64 {
    30_000
}

fn default_enabled() -> bool {
    true
}

/// MCP settings configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpSettings {
    /// Configured MCP servers.
    #[serde(default)]
    pub servers: Vec<McpServerConfig>,
    /// Proactive schema-refresh TTL in milliseconds.
    ///
    /// Each MCP invocation re-fetches a server's tool list if more than
    /// this many ms have elapsed since the previous refresh. On drift, the
    /// tool index is rebuilt so subsequent capability search results see the
    /// live schema.
    ///
    /// `0` disables proactive refresh entirely (cache is only rebuilt at
    /// startup and on manual restart). Default: 30 seconds.
    #[serde(
        default = "default_schema_refresh_ttl_ms",
        alias = "schema_refresh_ttl_ms"
    )]
    pub schema_refresh_ttl_ms: u64,
}

impl Default for McpSettings {
    fn default() -> Self {
        Self {
            servers: Vec::new(),
            schema_refresh_ttl_ms: default_schema_refresh_ttl_ms(),
        }
    }
}

fn default_schema_refresh_ttl_ms() -> u64 {
    30_000
}

/// Health state for a single MCP server.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum McpServerHealth {
    /// Connected and responsive.
    Healthy,
    /// Experienced transient failures but still operational.
    Degraded,
    /// Exceeded max failures — capabilities disabled until manual restart.
    Failed,
}

/// Status snapshot for a single MCP server.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerStatus {
    /// Server name.
    pub name: String,
    /// Current health state.
    pub health: McpServerHealth,
    /// Number of capabilities registered by this server.
    pub capability_count: usize,
    /// Number of consecutive failures since last success.
    pub consecutive_failures: u32,
    /// Most recent error message, if any.
    pub last_error: Option<String>,
    /// ISO-8601 timestamp when the server connected.
    pub connected_at: Option<String>,
}

/// Maximum consecutive failures before a server is marked [`McpServerHealth::Failed`].
pub const MAX_CONSECUTIVE_FAILURES: u32 = 3;

/// Base delay for exponential backoff on restart (milliseconds).
pub const BACKOFF_BASE_MS: u64 = 1_000;

/// Maximum backoff delay (milliseconds).
pub const BACKOFF_MAX_MS: u64 = 30_000;

/// Supported MCP protocol versions (newest first).
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &["2025-03-26", "2024-11-05"];

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
    fn mcp_capability_result_deserialization() {
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
        assert!(config.enabled);
    }

    #[test]
    fn mcp_settings_use_camel_case_wire_names() {
        let settings = McpSettings {
            servers: vec![McpServerConfig {
                name: "devtools".to_string(),
                command: Some("npx".to_string()),
                args: vec!["chrome-devtools-mcp".to_string()],
                env: Default::default(),
                url: None,
                tool_timeout_ms: 12_345,
                enabled: true,
            }],
            schema_refresh_ttl_ms: 54_321,
        };

        let json = serde_json::to_value(&settings).unwrap();

        assert_eq!(json["schemaRefreshTtlMs"], 54_321);
        assert!(json.get("schema_refresh_ttl_ms").is_none());
        assert_eq!(json["servers"][0]["toolTimeoutMs"], 12_345);
        assert!(json["servers"][0].get("tool_timeout_ms").is_none());
    }

    #[test]
    fn mcp_settings_accept_snake_case_profile_keys() {
        let json = json!({
            "schema_refresh_ttl_ms": 54_321,
            "servers": [{
                "name": "devtools",
                "command": "npx",
                "tool_timeout_ms": 12_345
            }]
        });

        let settings: McpSettings = serde_json::from_value(json).unwrap();

        assert_eq!(settings.schema_refresh_ttl_ms, 54_321);
        assert_eq!(settings.servers[0].tool_timeout_ms, 12_345);
    }

    #[test]
    fn mcp_server_config_disabled() {
        let json = json!({
            "name": "disabled",
            "command": "echo",
            "enabled": false
        });
        let config: McpServerConfig = serde_json::from_value(json).unwrap();
        assert!(!config.enabled);
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

    #[test]
    fn server_health_serialization() {
        let status = McpServerStatus {
            name: "sqlite".into(),
            health: McpServerHealth::Healthy,
            capability_count: 3,
            consecutive_failures: 0,
            last_error: None,
            connected_at: Some("2026-03-25T10:00:00Z".into()),
        };
        let json = serde_json::to_value(&status).unwrap();
        assert_eq!(json["health"], "healthy");
        assert_eq!(json["capabilityCount"], 3);
    }

    #[test]
    fn server_health_degraded_with_error() {
        let status = McpServerStatus {
            name: "github".into(),
            health: McpServerHealth::Degraded,
            capability_count: 5,
            consecutive_failures: 2,
            last_error: Some("connection reset".into()),
            connected_at: Some("2026-03-25T09:00:00Z".into()),
        };
        assert_eq!(status.health, McpServerHealth::Degraded);
        assert_eq!(status.consecutive_failures, 2);
    }

    #[test]
    fn server_health_failed() {
        let status = McpServerStatus {
            name: "broken".into(),
            health: McpServerHealth::Failed,
            capability_count: 0,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("command not found".into()),
            connected_at: None,
        };
        assert_eq!(status.health, McpServerHealth::Failed);
        assert_eq!(status.consecutive_failures, MAX_CONSECUTIVE_FAILURES);
    }

    #[test]
    fn backoff_constants_valid() {
        const _: () = assert!(BACKOFF_BASE_MS > 0);
        const _: () = assert!(BACKOFF_MAX_MS > BACKOFF_BASE_MS);
        const _: () = assert!(MAX_CONSECUTIVE_FAILURES > 0);
    }

    #[test]
    fn supported_protocol_versions_not_empty() {
        assert!(!SUPPORTED_PROTOCOL_VERSIONS.is_empty());
        assert!(SUPPORTED_PROTOCOL_VERSIONS.contains(&"2024-11-05"));
    }
}
