//! MCP client — stdio and HTTP transport for JSON-RPC communication.

use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tracing::{debug, warn};

use crate::mcp::types::{
    JsonRpcRequest, JsonRpcResponse, McpServerConfig, McpToolDef, McpToolResult,
};

/// MCP client connected to a single server.
pub struct McpClient {
    /// Server name (for logging and tool prefixing).
    pub name: String,
    /// Transport implementation.
    transport: Mutex<Transport>,
    /// Auto-incrementing request ID.
    next_id: AtomicU64,
    /// Tool call timeout.
    tool_timeout_ms: u64,
}

enum Transport {
    /// Stdio transport — communicates via child process stdin/stdout.
    Stdio {
        child: Child,
        writer: tokio::io::BufWriter<tokio::process::ChildStdin>,
        reader: BufReader<tokio::process::ChildStdout>,
    },
    /// HTTP transport — sends requests to a URL.
    Http {
        url: String,
        client: reqwest::Client,
    },
}

impl McpClient {
    /// Create a client with stdio transport (spawn server process).
    pub async fn connect_stdio(config: &McpServerConfig) -> Result<Self, String> {
        let command = config.command.as_ref()
            .ok_or_else(|| "MCP server config must have 'command' for stdio transport".to_string())?;

        let mut cmd = Command::new(command);
        for arg in &config.args {
            let _ = cmd.arg(arg);
        }
        for (key, value) in &config.env {
            let _ = cmd.env(key, value);
        }
        let _ = cmd
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());

        let mut child = cmd.spawn().map_err(|e| {
            format!("Failed to spawn MCP server '{}' (command: {command}): {e}", config.name)
        })?;

        let stdin = child.stdin.take()
            .ok_or_else(|| "Failed to capture MCP server stdin".to_string())?;
        let stdout = child.stdout.take()
            .ok_or_else(|| "Failed to capture MCP server stdout".to_string())?;

        let writer = tokio::io::BufWriter::new(stdin);
        let reader = BufReader::new(stdout);

        debug!(server = %config.name, command, "connected to MCP server via stdio");

        let client = Self {
            name: config.name.clone(),
            transport: Mutex::new(Transport::Stdio { child, writer, reader }),
            next_id: AtomicU64::new(1),
            tool_timeout_ms: config.tool_timeout_ms,
        };

        // Initialize the connection
        client.initialize().await?;

        Ok(client)
    }

    /// Create a client with HTTP transport.
    pub async fn connect_http(config: &McpServerConfig) -> Result<Self, String> {
        let url = config.url.as_ref()
            .ok_or_else(|| "MCP server config must have 'url' for HTTP transport".to_string())?;

        let http_client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(config.tool_timeout_ms))
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {e}"))?;

        debug!(server = %config.name, url, "connecting to MCP server via HTTP");

        let client = Self {
            name: config.name.clone(),
            transport: Mutex::new(Transport::Http {
                url: url.clone(),
                client: http_client,
            }),
            next_id: AtomicU64::new(1),
            tool_timeout_ms: config.tool_timeout_ms,
        };

        client.initialize().await?;

        Ok(client)
    }

    /// Send the MCP initialize handshake.
    async fn initialize(&self) -> Result<(), String> {
        let result = self.send_request("initialize", Some(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {
                "name": "tron-agent",
                "version": "1.0"
            }
        }))).await?;

        debug!(server = %self.name, result = %result, "MCP server initialized");

        // Send initialized notification
        self.send_notification("notifications/initialized", None).await?;

        Ok(())
    }

    /// Discover available tools from the server.
    pub async fn list_tools(&self) -> Result<Vec<McpToolDef>, String> {
        let result = self.send_request("tools/list", None).await?;

        let tools: Vec<McpToolDef> = result
            .get("tools")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| serde_json::from_value(v.clone()).ok())
                    .collect()
            })
            .unwrap_or_default();

        debug!(server = %self.name, count = tools.len(), "discovered MCP tools");
        Ok(tools)
    }

    /// Call a tool on the server.
    pub async fn call_tool(
        &self,
        tool_name: &str,
        arguments: Value,
    ) -> Result<McpToolResult, String> {
        let result = self.send_request("tools/call", Some(json!({
            "name": tool_name,
            "arguments": arguments,
        }))).await?;

        serde_json::from_value(result.clone())
            .map_err(|e| format!("Failed to parse tool result: {e}"))
    }

    /// Send a JSON-RPC request and wait for the response.
    async fn send_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = JsonRpcRequest::new(id, method, params);

        let mut transport = self.transport.lock().await;

        let response: JsonRpcResponse = match &mut *transport {
            Transport::Stdio { writer, reader, .. } => {
                // Write request as JSON line
                let json_line = serde_json::to_string(&request)
                    .map_err(|e| format!("Failed to serialize request: {e}"))?;
                writer.write_all(json_line.as_bytes()).await
                    .map_err(|e| format!("Failed to write to MCP server: {e}"))?;
                writer.write_all(b"\n").await
                    .map_err(|e| format!("Failed to write newline: {e}"))?;
                writer.flush().await
                    .map_err(|e| format!("Failed to flush to MCP server: {e}"))?;

                // Read response line
                let mut line = String::new();
                let bytes_read = tokio::time::timeout(
                    std::time::Duration::from_millis(self.tool_timeout_ms),
                    reader.read_line(&mut line),
                ).await
                    .map_err(|_| format!("MCP server '{}' timed out after {}ms", self.name, self.tool_timeout_ms))?
                    .map_err(|e| format!("Failed to read from MCP server: {e}"))?;

                if bytes_read == 0 {
                    return Err(format!("MCP server '{}' closed connection (stdin EOF)", self.name));
                }

                serde_json::from_str(line.trim())
                    .map_err(|e| format!("Invalid JSON-RPC response from MCP server: {e}"))?
            }
            Transport::Http { url, client } => {
                let resp = client.post(url.as_str())
                    .json(&request)
                    .send()
                    .await
                    .map_err(|e| format!("HTTP request to MCP server failed: {e}"))?;

                if !resp.status().is_success() {
                    return Err(format!("MCP server returned HTTP {}", resp.status()));
                }

                resp.json().await
                    .map_err(|e| format!("Failed to parse MCP server response: {e}"))?
            }
        };

        // Check for JSON-RPC error
        if let Some(error) = response.error {
            return Err(error.to_string());
        }

        response.result.ok_or_else(|| "MCP server returned no result".to_string())
    }

    /// Send a JSON-RPC notification (no response expected).
    async fn send_notification(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        let notification = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });

        let mut transport = self.transport.lock().await;

        match &mut *transport {
            Transport::Stdio { writer, .. } => {
                let json_line = serde_json::to_string(&notification)
                    .map_err(|e| format!("Failed to serialize notification: {e}"))?;
                writer.write_all(json_line.as_bytes()).await
                    .map_err(|e| format!("Failed to write notification: {e}"))?;
                writer.write_all(b"\n").await
                    .map_err(|e| format!("Failed to write newline: {e}"))?;
                writer.flush().await
                    .map_err(|e| format!("Failed to flush notification: {e}"))?;
            }
            Transport::Http { url, client } => {
                let _ = client.post(url.as_str())
                    .json(&notification)
                    .send()
                    .await;
            }
        }

        Ok(())
    }

    /// Shut down the MCP server connection.
    pub async fn shutdown(&self) {
        let mut transport = self.transport.lock().await;
        match &mut *transport {
            Transport::Stdio { child, .. } => {
                let _ = child.kill().await;
                debug!(server = %self.name, "killed MCP server process");
            }
            Transport::Http { .. } => {
                debug!(server = %self.name, "disconnected from MCP HTTP server");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_id_auto_increments() {
        let counter = AtomicU64::new(1);
        assert_eq!(counter.fetch_add(1, Ordering::Relaxed), 1);
        assert_eq!(counter.fetch_add(1, Ordering::Relaxed), 2);
        assert_eq!(counter.fetch_add(1, Ordering::Relaxed), 3);
    }

    #[test]
    fn jsonrpc_request_format() {
        let req = JsonRpcRequest::new(42, "tools/list", None);
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["jsonrpc"], "2.0");
        assert_eq!(json["id"], 42);
        assert_eq!(json["method"], "tools/list");
        assert!(json.get("params").is_none());
    }

    #[test]
    fn jsonrpc_request_with_params() {
        let req = JsonRpcRequest::new(1, "tools/call", Some(json!({"name": "query"})));
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["params"]["name"], "query");
    }
}
