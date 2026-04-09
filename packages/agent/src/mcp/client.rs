//! MCP client — stdio and HTTP transport for JSON-RPC communication.
//!
//! Handles protocol initialization with version negotiation, graceful
//! shutdown, and structured error classification for upstream retry logic.

use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

use crate::mcp::types::{
    JsonRpcRequest, JsonRpcResponse, McpServerConfig, McpToolDef, McpToolResult,
    SUPPORTED_PROTOCOL_VERSIONS,
};

/// Classification of MCP client errors for upstream retry decisions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpErrorKind {
    /// Server process exited or connection closed — requires restart.
    ConnectionLost,
    /// Request timed out — may succeed on retry.
    Timeout,
    /// Server returned a JSON-RPC error — retrying won't help.
    Protocol(String),
    /// Transient I/O error — may succeed on retry.
    Transient(String),
    /// Server's protocol version is incompatible.
    VersionMismatch(String),
}

impl std::fmt::Display for McpErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConnectionLost => write!(f, "connection lost"),
            Self::Timeout => write!(f, "request timed out"),
            Self::Protocol(msg) => write!(f, "protocol error: {msg}"),
            Self::Transient(msg) => write!(f, "transient error: {msg}"),
            Self::VersionMismatch(msg) => write!(f, "version mismatch: {msg}"),
        }
    }
}

impl std::error::Error for McpError {}

/// Structured error from MCP client operations.
#[derive(Debug, Clone)]
pub struct McpError {
    /// Name of the MCP server that produced this error.
    pub server: String,
    /// Categorized error kind for programmatic handling.
    pub kind: McpErrorKind,
    /// Human-readable error description.
    pub message: String,
}

impl McpError {
    /// Returns `true` if this error is transient and the operation can be retried.
    pub fn is_retryable(&self) -> bool {
        matches!(self.kind, McpErrorKind::Timeout | McpErrorKind::Transient(_))
    }

    /// Returns `true` if this error indicates the connection is lost and the server must be restarted.
    pub fn requires_restart(&self) -> bool {
        matches!(self.kind, McpErrorKind::ConnectionLost)
    }
}

impl std::fmt::Display for McpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "MCP server '{}': {}", self.server, self.message)
    }
}

impl From<McpError> for String {
    fn from(e: McpError) -> Self {
        e.to_string()
    }
}

/// Timeout for graceful shutdown notification before hard kill (ms).
const GRACEFUL_SHUTDOWN_TIMEOUT_MS: u64 = 2_000;

/// Timeout for the MCP initialization handshake (ms).
///
/// Intentionally longer than typical tool timeouts because it includes
/// process startup overhead (shell init, PATH resolution, etc.).
const INIT_TIMEOUT_MS: u64 = 30_000;

/// MCP client connected to a single server.
///
/// `Debug` is implemented manually because `Transport` holds non-Debug process handles.
pub struct McpClient {
    /// Server name (for logging and tool prefixing).
    pub name: String,
    /// Transport implementation.
    transport: Mutex<Transport>,
    /// Auto-incrementing request ID.
    next_id: AtomicU64,
    /// Tool call timeout.
    tool_timeout_ms: u64,
    /// Protocol version negotiated with the server.
    pub negotiated_version: Mutex<Option<String>>,
}

impl std::fmt::Debug for McpClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpClient")
            .field("name", &self.name)
            .field("tool_timeout_ms", &self.tool_timeout_ms)
            .finish_non_exhaustive()
    }
}

pub(crate) enum Transport {
    /// Stdio transport — communicates via child process stdin/stdout.
    Stdio(Box<StdioTransport>),
    /// HTTP transport — sends requests to a URL.
    Http {
        url: String,
        client: reqwest::Client,
    },
    /// Placeholder for failed servers (never used for I/O).
    Placeholder,
}

pub(crate) struct StdioTransport {
    pub child: Child,
    pub writer: tokio::io::BufWriter<tokio::process::ChildStdin>,
    pub reader: BufReader<tokio::process::ChildStdout>,
}

impl McpClient {
    /// Create a placeholder client for failed servers (never used for I/O).
    ///
    /// Any call to `send_request` will return `ConnectionLost`.
    pub fn failed_placeholder(name: &str) -> Self {
        Self {
            name: name.to_string(),
            transport: Mutex::new(Transport::Placeholder),
            next_id: AtomicU64::new(1),
            tool_timeout_ms: 0,
            negotiated_version: Mutex::new(None),
        }
    }

    /// Create a client with stdio transport (spawn server process).
    pub async fn connect_stdio(config: &McpServerConfig) -> Result<Self, McpError> {
        let command = config.command.as_ref().ok_or_else(|| McpError {
            server: config.name.clone(),
            kind: McpErrorKind::Protocol("missing 'command'".into()),
            message: "MCP server config must have 'command' for stdio transport".into(),
        })?;

        if command.trim().is_empty() {
            return Err(McpError {
                server: config.name.clone(),
                kind: McpErrorKind::Protocol("empty command".into()),
                message: "MCP server 'command' must not be empty".into(),
            });
        }

        if command.contains("..") {
            warn!(
                server = %config.name,
                command,
                "MCP server command contains path traversal"
            );
        }

        let redacted_args = redact_args(&config.args);
        info!(
            server = %config.name,
            command,
            args = %redacted_args,
            "spawning MCP server"
        );

        let mut cmd = Command::new(command);
        for arg in &config.args {
            let _ = cmd.arg(arg);
        }

        // Inject the user's login-shell PATH so that tools installed via nvm,
        // Homebrew, cargo, etc. are discoverable. Without this, launchd gives
        // only a minimal system PATH and binaries like `npx` aren't found.
        if !config.env.contains_key("PATH") {
            let full_path = resolve_login_path();
            if !full_path.is_empty() {
                let _ = cmd.env("PATH", &full_path);
            }
        }
        for (key, value) in &config.env {
            let _ = cmd.env(key, value);
        }
        let _ = cmd
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());

        let mut child = cmd.spawn().map_err(|e| McpError {
            server: config.name.clone(),
            kind: McpErrorKind::Transient(format!("spawn failed: {e}")),
            message: format!(
                "Failed to spawn MCP server '{}' (command: {command}): {e}. \
                 Ensure '{command}' is installed and on PATH.",
                config.name
            ),
        })?;

        let stdin = child.stdin.take().ok_or_else(|| McpError {
            server: config.name.clone(),
            kind: McpErrorKind::Transient("no stdin".into()),
            message: "Failed to capture MCP server stdin".into(),
        })?;
        let stdout = child.stdout.take().ok_or_else(|| McpError {
            server: config.name.clone(),
            kind: McpErrorKind::Transient("no stdout".into()),
            message: "Failed to capture MCP server stdout".into(),
        })?;

        let writer = tokio::io::BufWriter::new(stdin);
        let reader = BufReader::new(stdout);

        debug!(server = %config.name, command, "connected to MCP server via stdio");

        let client = Self {
            name: config.name.clone(),
            transport: Mutex::new(Transport::Stdio(Box::new(StdioTransport { child, writer, reader }))),
            next_id: AtomicU64::new(1),
            tool_timeout_ms: config.tool_timeout_ms,
            negotiated_version: Mutex::new(None),
        };

        client.initialize().await?;

        Ok(client)
    }

    /// Create a client with HTTP transport.
    pub async fn connect_http(config: &McpServerConfig) -> Result<Self, McpError> {
        let url = config.url.as_ref().ok_or_else(|| McpError {
            server: config.name.clone(),
            kind: McpErrorKind::Protocol("missing 'url'".into()),
            message: "MCP server config must have 'url' for HTTP transport".into(),
        })?;

        let http_client = reqwest::Client::builder()
            .build()
            .map_err(|e| McpError {
                server: config.name.clone(),
                kind: McpErrorKind::Transient(format!("HTTP client: {e}")),
                message: format!("Failed to create HTTP client: {e}"),
            })?;

        debug!(server = %config.name, url, "connecting to MCP server via HTTP");

        let client = Self {
            name: config.name.clone(),
            transport: Mutex::new(Transport::Http {
                url: url.clone(),
                client: http_client,
            }),
            next_id: AtomicU64::new(1),
            tool_timeout_ms: config.tool_timeout_ms,
            negotiated_version: Mutex::new(None),
        };

        client.initialize().await?;

        Ok(client)
    }

    /// Send the MCP initialize handshake with protocol version negotiation.
    async fn initialize(&self) -> Result<(), McpError> {
        let preferred_version = SUPPORTED_PROTOCOL_VERSIONS[0];

        let result = self.send_request_with_timeout("initialize", Some(json!({
            "protocolVersion": preferred_version,
            "capabilities": {},
            "clientInfo": {
                "name": "tron-agent",
                "version": "1.0"
            }
        })), INIT_TIMEOUT_MS).await?;

        // Validate protocol version from server response
        let server_version = result
            .get("protocolVersion")
            .and_then(Value::as_str)
            .unwrap_or("unknown");

        if !SUPPORTED_PROTOCOL_VERSIONS.contains(&server_version) {
            warn!(
                server = %self.name,
                server_version,
                supported = ?SUPPORTED_PROTOCOL_VERSIONS,
                "MCP server returned unsupported protocol version"
            );
            return Err(McpError {
                server: self.name.clone(),
                kind: McpErrorKind::VersionMismatch(server_version.to_string()),
                message: format!(
                    "MCP server '{}' uses protocol version '{server_version}' which is not \
                     in supported versions: {:?}",
                    self.name, SUPPORTED_PROTOCOL_VERSIONS,
                ),
            });
        }

        *self.negotiated_version.lock().await = Some(server_version.to_string());

        debug!(
            server = %self.name,
            version = server_version,
            "MCP server initialized"
        );

        // Send initialized notification
        self.send_notification("notifications/initialized", None).await?;

        Ok(())
    }

    /// Discover available tools from the server.
    pub async fn list_tools(&self) -> Result<Vec<McpToolDef>, McpError> {
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
    ) -> Result<McpToolResult, McpError> {
        let result = self.send_request("tools/call", Some(json!({
            "name": tool_name,
            "arguments": arguments,
        }))).await?;

        serde_json::from_value(result.clone()).map_err(|e| McpError {
            server: self.name.clone(),
            kind: McpErrorKind::Protocol(format!("bad tool result: {e}")),
            message: format!("Failed to parse tool result: {e}"),
        })
    }

    /// Check if the underlying transport is still alive.
    pub async fn is_alive(&self) -> bool {
        let mut transport = self.transport.lock().await;
        match &mut *transport {
            Transport::Placeholder => false,
            Transport::Stdio(stdio) => {
                // try_wait returns Ok(Some(status)) if exited, Ok(None) if still running
                match stdio.child.try_wait() {
                    Ok(Some(_)) | Err(_) => false,
                    Ok(None) => true,
                }
            }
            Transport::Http { .. } => true,
        }
    }

    /// Send a JSON-RPC request and wait for the response.
    async fn send_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, McpError> {
        self.send_request_with_timeout(method, params, self.tool_timeout_ms).await
    }

    /// Send a JSON-RPC request with an explicit timeout.
    async fn send_request_with_timeout(
        &self,
        method: &str,
        params: Option<Value>,
        timeout_ms: u64,
    ) -> Result<Value, McpError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = JsonRpcRequest::new(id, method, params);

        let mut transport = self.transport.lock().await;

        let response: JsonRpcResponse = match &mut *transport {
            Transport::Placeholder => {
                return Err(McpError {
                    server: self.name.clone(),
                    kind: McpErrorKind::ConnectionLost,
                    message: format!("MCP server '{}' is not connected", self.name),
                });
            }
            Transport::Stdio(stdio) => {
                let json_line = serde_json::to_string(&request).map_err(|e| McpError {
                    server: self.name.clone(),
                    kind: McpErrorKind::Protocol(format!("serialize: {e}")),
                    message: format!("Failed to serialize request: {e}"),
                })?;

                // Write request
                if let Err(e) = stdio.writer.write_all(json_line.as_bytes()).await {
                    return Err(McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::ConnectionLost,
                        message: format!("Failed to write to MCP server: {e}"),
                    });
                }
                if let Err(e) = stdio.writer.write_all(b"\n").await {
                    return Err(McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::ConnectionLost,
                        message: format!("Failed to write newline: {e}"),
                    });
                }
                if let Err(e) = stdio.writer.flush().await {
                    return Err(McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::ConnectionLost,
                        message: format!("Failed to flush to MCP server: {e}"),
                    });
                }

                // Read response with timeout, skipping JSON-RPC notifications
                let timeout = std::time::Duration::from_millis(timeout_ms);
                let deadline = tokio::time::Instant::now() + timeout;
                loop {
                    let mut line = String::new();
                    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                    if remaining.is_zero() {
                        return Err(McpError {
                            server: self.name.clone(),
                            kind: McpErrorKind::Timeout,
                            message: format!(
                                "MCP server '{}' timed out after {}ms",
                                self.name, timeout_ms
                            ),
                        });
                    }

                    let bytes_read = tokio::time::timeout(remaining, stdio.reader.read_line(&mut line))
                        .await
                        .map_err(|_| McpError {
                            server: self.name.clone(),
                            kind: McpErrorKind::Timeout,
                            message: format!(
                                "MCP server '{}' timed out after {}ms",
                                self.name, timeout_ms
                            ),
                        })?
                        .map_err(|e| McpError {
                            server: self.name.clone(),
                            kind: McpErrorKind::ConnectionLost,
                            message: format!("Failed to read from MCP server: {e}"),
                        })?;

                    if bytes_read == 0 {
                        return Err(McpError {
                            server: self.name.clone(),
                            kind: McpErrorKind::ConnectionLost,
                            message: format!(
                                "MCP server '{}' closed connection (stdout EOF)",
                                self.name
                            ),
                        });
                    }

                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    // Parse the line — skip server-initiated notifications (no id field)
                    let parsed: Value = serde_json::from_str(trimmed).map_err(|e| McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::Protocol(format!("invalid JSON: {e}")),
                        message: format!("Invalid JSON-RPC response from MCP server: {e}"),
                    })?;

                    // Notifications have no "id" — skip them
                    if parsed.get("id").is_none() || parsed.get("id") == Some(&Value::Null) {
                        debug!(
                            server = %self.name,
                            method = parsed.get("method").and_then(|v| v.as_str()).unwrap_or("unknown"),
                            "skipping server notification"
                        );
                        continue;
                    }

                    break serde_json::from_value(parsed).map_err(|e| McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::Protocol(format!("bad response: {e}")),
                        message: format!("Invalid JSON-RPC response structure: {e}"),
                    })?;
                }
            }
            Transport::Http { url, client } => {
                let resp = client
                    .post(url.as_str())
                    .timeout(std::time::Duration::from_millis(timeout_ms))
                    .json(&request)
                    .send()
                    .await
                    .map_err(|e| {
                        let kind = if e.is_timeout() {
                            McpErrorKind::Timeout
                        } else if e.is_connect() {
                            McpErrorKind::ConnectionLost
                        } else {
                            McpErrorKind::Transient(format!("HTTP: {e}"))
                        };
                        McpError {
                            server: self.name.clone(),
                            kind,
                            message: format!("HTTP request to MCP server failed: {e}"),
                        }
                    })?;

                if !resp.status().is_success() {
                    return Err(McpError {
                        server: self.name.clone(),
                        kind: McpErrorKind::Protocol(format!("HTTP {}", resp.status())),
                        message: format!("MCP server returned HTTP {}", resp.status()),
                    });
                }

                resp.json().await.map_err(|e| McpError {
                    server: self.name.clone(),
                    kind: McpErrorKind::Protocol(format!("bad response body: {e}")),
                    message: format!("Failed to parse MCP server response: {e}"),
                })?
            }
        };

        // Check for JSON-RPC error
        if let Some(error) = response.error {
            return Err(McpError {
                server: self.name.clone(),
                kind: McpErrorKind::Protocol(error.to_string()),
                message: error.to_string(),
            });
        }

        response.result.ok_or_else(|| McpError {
            server: self.name.clone(),
            kind: McpErrorKind::Protocol("no result".into()),
            message: "MCP server returned no result".into(),
        })
    }

    /// Send a JSON-RPC notification (no response expected).
    async fn send_notification(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), McpError> {
        let notification = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });

        let mut transport = self.transport.lock().await;

        match &mut *transport {
            Transport::Placeholder => {}
            Transport::Stdio(stdio) => {
                let json_line = serde_json::to_string(&notification).map_err(|e| McpError {
                    server: self.name.clone(),
                    kind: McpErrorKind::Protocol(format!("serialize: {e}")),
                    message: format!("Failed to serialize notification: {e}"),
                })?;
                // Best-effort — don't fail the caller if notification can't be sent
                let _ = stdio.writer.write_all(json_line.as_bytes()).await;
                let _ = stdio.writer.write_all(b"\n").await;
                let _ = stdio.writer.flush().await;
            }
            Transport::Http { url, client } => {
                let _ = client.post(url.as_str()).json(&notification).send().await;
            }
        }

        Ok(())
    }

    /// Graceful shutdown: send protocol notification, then kill process.
    pub async fn shutdown(&self) {
        // Attempt graceful shutdown notification (best-effort)
        let _ = self.send_notification("notifications/cancelled", Some(json!({
            "reason": "agent shutting down"
        }))).await;

        let mut transport = self.transport.lock().await;
        match &mut *transport {
            Transport::Placeholder => {}
            Transport::Stdio(stdio) => {
                // Shutdown stdin to signal the server
                let _ = stdio.writer.shutdown().await;

                // Wait briefly for graceful exit, then force kill
                let timeout = std::time::Duration::from_millis(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
                if let Ok(Ok(status)) = tokio::time::timeout(timeout, stdio.child.wait()).await {
                    debug!(
                        server = %self.name,
                        code = status.code(),
                        "MCP server exited gracefully"
                    );
                } else {
                    let _ = stdio.child.kill().await;
                    debug!(server = %self.name, "force-killed MCP server process");
                }
            }
            Transport::Http { .. } => {
                debug!(server = %self.name, "disconnected from MCP HTTP server");
            }
        }
    }
}

/// Resolve the user's full PATH by spawning a login shell.
///
/// Caches the result so the shell is only invoked once per process lifetime.
/// Returns the empty string if resolution fails (callers fall back to the
/// inherited environment).
fn resolve_login_path() -> String {
    use std::sync::OnceLock;

    static CACHED: OnceLock<String> = OnceLock::new();
    CACHED
        .get_or_init(|| {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "bash".into());
            match std::process::Command::new(&shell)
                .args(["-l", "-c", "echo $PATH"])
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .output()
            {
                Ok(output) if output.status.success() => {
                    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                    debug!(path_len = path.len(), "resolved login-shell PATH for MCP servers");
                    path
                }
                _ => {
                    warn!("failed to resolve login-shell PATH; MCP servers may not find binaries");
                    String::new()
                }
            }
        })
        .clone()
}

/// Redact secret-looking values in MCP server arguments for safe logging.
fn redact_args(args: &[String]) -> String {
    use regex::Regex;
    use std::sync::LazyLock;

    static SECRET_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)(api[_-]?key|secret|token|password|auth)([=:]\s*)(\S+)").unwrap()
    });

    let redacted: Vec<String> = args
        .iter()
        .map(|arg| SECRET_PATTERN.replace_all(arg, "$1$2****").to_string())
        .collect();
    format!("[{}]", redacted.join(", "))
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

    #[test]
    fn error_kind_display() {
        assert_eq!(McpErrorKind::ConnectionLost.to_string(), "connection lost");
        assert_eq!(McpErrorKind::Timeout.to_string(), "request timed out");
        assert!(McpErrorKind::Protocol("bad".into()).to_string().contains("bad"));
    }

    #[test]
    fn error_retryable_classification() {
        let timeout_err = McpError {
            server: "test".into(),
            kind: McpErrorKind::Timeout,
            message: "timed out".into(),
        };
        assert!(timeout_err.is_retryable());
        assert!(!timeout_err.requires_restart());

        let conn_err = McpError {
            server: "test".into(),
            kind: McpErrorKind::ConnectionLost,
            message: "EOF".into(),
        };
        assert!(!conn_err.is_retryable());
        assert!(conn_err.requires_restart());

        let proto_err = McpError {
            server: "test".into(),
            kind: McpErrorKind::Protocol("bad".into()),
            message: "bad response".into(),
        };
        assert!(!proto_err.is_retryable());
        assert!(!proto_err.requires_restart());
    }

    #[test]
    fn error_display_includes_server() {
        let err = McpError {
            server: "sqlite".into(),
            kind: McpErrorKind::Timeout,
            message: "timed out after 30s".into(),
        };
        let display = err.to_string();
        assert!(display.contains("sqlite"));
        assert!(display.contains("timed out"));
    }

    #[test]
    fn version_mismatch_error() {
        let err = McpError {
            server: "legacy".into(),
            kind: McpErrorKind::VersionMismatch("1.0.0".into()),
            message: "unsupported version".into(),
        };
        assert!(!err.is_retryable());
        assert!(!err.requires_restart());
    }

    // ── MCP command validation tests ────────────────────────────

    #[tokio::test]
    async fn empty_command_rejected() {
        let config = McpServerConfig {
            name: "test".into(),
            command: Some("".into()),
            args: vec![],
            env: Default::default(),
            url: None,
            tool_timeout_ms: 5000,
            enabled: true,
        };
        let err = McpClient::connect_stdio(&config).await.unwrap_err();
        assert!(matches!(err.kind, McpErrorKind::Protocol(_)));
        assert!(err.message.contains("empty"));
    }

    #[tokio::test]
    async fn whitespace_command_rejected() {
        let config = McpServerConfig {
            name: "test".into(),
            command: Some("   ".into()),
            args: vec![],
            env: Default::default(),
            url: None,
            tool_timeout_ms: 5000,
            enabled: true,
        };
        let err = McpClient::connect_stdio(&config).await.unwrap_err();
        assert!(matches!(err.kind, McpErrorKind::Protocol(_)));
    }

    #[tokio::test]
    async fn missing_command_rejected() {
        let config = McpServerConfig {
            name: "test".into(),
            command: None,
            args: vec![],
            env: Default::default(),
            url: None,
            tool_timeout_ms: 5000,
            enabled: true,
        };
        let err = McpClient::connect_stdio(&config).await.unwrap_err();
        assert!(matches!(err.kind, McpErrorKind::Protocol(_)));
    }

    #[tokio::test]
    async fn nonexistent_binary_returns_clear_error() {
        let config = McpServerConfig {
            name: "test".into(),
            command: Some("__tron_nonexistent_binary_12345__".into()),
            args: vec![],
            env: Default::default(),
            url: None,
            tool_timeout_ms: 5000,
            enabled: true,
        };
        let err = McpClient::connect_stdio(&config).await.unwrap_err();
        assert!(
            err.message.contains("Ensure") || err.message.contains("Failed to spawn"),
            "Error should guide user: {}",
            err.message
        );
    }

    #[test]
    fn redact_args_masks_api_key() {
        let args = vec!["--api-key=sk-ant-api03-xxxx".into()];
        let result = redact_args(&args);
        assert!(result.contains("****"));
        assert!(!result.contains("sk-ant-api03"));
    }

    #[test]
    fn redact_args_masks_secret() {
        let args = vec!["--secret=mysupersecretvalue".into()];
        let result = redact_args(&args);
        assert!(result.contains("****"));
        assert!(!result.contains("mysupersecretvalue"));
    }

    #[test]
    fn redact_args_masks_token() {
        let args = vec!["--token=ghp_xxxxxxxxxxxxxxxxxxxx".into()];
        let result = redact_args(&args);
        assert!(result.contains("****"));
        assert!(!result.contains("ghp_"));
    }

    #[test]
    fn redact_args_preserves_safe_args() {
        let args = vec!["--port".into(), "8080".into(), "--verbose".into()];
        let result = redact_args(&args);
        assert!(result.contains("--port"));
        assert!(result.contains("8080"));
        assert!(result.contains("--verbose"));
    }

    #[test]
    fn redact_args_empty() {
        let result = redact_args(&[]);
        assert_eq!(result, "[]");
    }

    // ── resolve_login_path tests ────────────────────────────

    #[test]
    fn resolve_login_path_returns_non_empty() {
        let path = resolve_login_path();
        assert!(!path.is_empty(), "login-shell PATH should not be empty");
        assert!(path.contains("/usr/bin"), "PATH should contain /usr/bin: {path}");
    }
}
