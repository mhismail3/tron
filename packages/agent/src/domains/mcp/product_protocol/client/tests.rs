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
    assert!(
        McpErrorKind::Protocol("bad".into())
            .to_string()
            .contains("bad")
    );
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
        server: "unsupported-version-server".into(),
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
    assert!(
        path.contains("/usr/bin"),
        "PATH should contain /usr/bin: {path}"
    );
}

// ── M27: write-after-death regression guard ─────────────
//
// The stdio transport wraps `ChildStdin` in a `BufWriter` with no internal
// queue beyond the buffer — `write_all` + `write_all(b"\n")` + `flush()`
// are synchronous against the kernel pipe. When the child process is dead,
// `flush()` must observe EPIPE and return an error. The client wrapper at
// `send_request` line 423–443 maps every write/flush error to
// `McpErrorKind::ConnectionLost`.
//
// This test pins that contract: after killing the child, the next
// `send_request` returns `ConnectionLost` within a bounded time rather
// than hanging (the failure mode the plan called out).
#[tokio::test]
async fn write_after_death_returns_connection_lost_not_hangs() {
    use std::time::Duration;

    // Spawn `cat` as a minimal stdio process. `cat` holds stdin open and
    // echoes lines back, so it's a valid "alive" stdio peer we can then
    // kill deterministically.
    let mut child = Command::new("cat")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn cat for test");

    let stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");

    let client = McpClient {
        name: "test-server-dead".to_string(),
        transport: Mutex::new(Transport::Stdio(Box::new(StdioTransport {
            child,
            writer: tokio::io::BufWriter::new(stdin),
            reader: BufReader::new(stdout),
        }))),
        next_id: AtomicU64::new(1),
        tool_timeout_ms: 5_000,
        negotiated_version: Mutex::new(None),
    };

    // Kill the child — simulates the MCP server crashing between requests.
    {
        let mut transport = client.transport.lock().await;
        if let Transport::Stdio(stdio) = &mut *transport {
            stdio.child.kill().await.expect("kill child");
            // Wait for the OS to reap the process so pipe teardown is real
            // rather than racing the next write.
            let _ = stdio.child.wait().await;
        } else {
            panic!("expected stdio transport");
        }
    }

    // Bound the overall wait so a regression (hang) produces a loud failure
    // rather than a silent CI timeout. The write path is synchronous against
    // the kernel pipe after a dead child, so 5s is a generous ceiling.
    let outcome = tokio::time::timeout(
        Duration::from_secs(5),
        client.send_request("tools/list", None),
    )
    .await;

    let result = outcome.expect(
        "send_request must return (error or success) within 5s after child death — \
             hang means the write path is swallowing the broken pipe",
    );

    let err = result.expect_err("write to dead child must fail");
    assert_eq!(
        err.kind,
        McpErrorKind::ConnectionLost,
        "broken pipe after child death must map to ConnectionLost, got {:?}: {}",
        err.kind,
        err.message,
    );
    assert!(
        err.requires_restart(),
        "ConnectionLost must signal restart-required to upstream callers"
    );
}
