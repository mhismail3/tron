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

use crate::domains::mcp::types::{
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
    /// Server has exhausted its auto-restart budget and will not be retried
    /// until the user explicitly issues a manual restart. Emitted by
    /// `McpServerManager::try_auto_restart` when health is already `Failed`.
    PermanentlyFailed,
}

impl std::fmt::Display for McpErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConnectionLost => write!(f, "connection lost"),
            Self::Timeout => write!(f, "request timed out"),
            Self::Protocol(msg) => write!(f, "protocol error: {msg}"),
            Self::Transient(msg) => write!(f, "transient error: {msg}"),
            Self::VersionMismatch(msg) => write!(f, "version mismatch: {msg}"),
            Self::PermanentlyFailed => {
                write!(f, "server permanently failed — manual restart required")
            }
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
        matches!(
            self.kind,
            McpErrorKind::Timeout | McpErrorKind::Transient(_)
        )
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
    /// Capability invocation timeout.
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

        // Inject the user's login-shell PATH so that capabilities installed via nvm,
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
            transport: Mutex::new(Transport::Stdio(Box::new(StdioTransport {
                child,
                writer,
                reader,
            }))),
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

        let http_client = reqwest::Client::builder().build().map_err(|e| McpError {
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

        let result = self
            .send_request_with_timeout(
                "initialize",
                Some(json!({
                    "protocolVersion": preferred_version,
                    "capabilities": {},
                    "clientInfo": {
                        "name": "tron-agent",
                        "version": "1.0"
                    }
                })),
                INIT_TIMEOUT_MS,
            )
            .await?;

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
        self.send_notification("notifications/initialized", None)
            .await?;

        Ok(())
    }

    /// Discover available capabilities from the server.
    pub async fn list_tools(&self) -> Result<Vec<McpToolDef>, McpError> {
        let result = self.send_request("tools/list", None).await?;

        let capabilities: Vec<McpToolDef> = result
            .get("tools")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| match serde_json::from_value::<McpToolDef>(v.clone()) {
                        Ok(def) => Some(def),
                        Err(e) => {
                            tracing::warn!(
                                server = %self.name,
                                error = %e,
                                tool_preview = %v.get("name")
                                    .and_then(|n| n.as_str())
                                    .unwrap_or("<unknown>"),
                                "MCP server returned malformed tool definition; dropping entry"
                            );
                            None
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();

        debug!(server = %self.name, count = capabilities.len(), "discovered MCP tools");
        Ok(capabilities)
    }

    /// Call a tool on the server.
    pub async fn call_tool(
        &self,
        tool_name: &str,
        arguments: Value,
    ) -> Result<McpToolResult, McpError> {
        let result = self
            .send_request(
                "tools/call",
                Some(json!({
                    "name": tool_name,
                    "arguments": arguments,
                })),
            )
            .await?;

        serde_json::from_value(result.clone()).map_err(|e| McpError {
            server: self.name.clone(),
            kind: McpErrorKind::Protocol(format!("bad capability result: {e}")),
            message: format!("Failed to parse capability result: {e}"),
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
    async fn send_request(&self, method: &str, params: Option<Value>) -> Result<Value, McpError> {
        self.send_request_with_timeout(method, params, self.tool_timeout_ms)
            .await
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

                    let bytes_read =
                        tokio::time::timeout(remaining, stdio.reader.read_line(&mut line))
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
    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), McpError> {
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
        let _ = self
            .send_notification(
                "notifications/cancelled",
                Some(json!({
                    "reason": "agent shutting down"
                })),
            )
            .await;

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
                    debug!(
                        path_len = path.len(),
                        "resolved login-shell PATH for MCP servers"
                    );
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
#[path = "client/tests.rs"]
mod tests;
