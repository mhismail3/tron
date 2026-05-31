use super::*;

/// Build a minimal `McpToolDef` for unit tests that need N placeholder
/// capabilities (where only the count / diff matters, not schema contents).
fn dummy_tool_def(name: &str) -> McpToolDef {
    McpToolDef {
        name: name.to_string(),
        description: String::new(),
        input_schema: serde_json::Value::Null,
    }
}

#[test]
fn new_manager_empty() {
    let manager = McpServerManager::new(Vec::new());
    assert!(manager.connected_servers().is_empty());
    assert_eq!(manager.config_count(), 0);
}

#[test]
fn is_connected_false_when_empty() {
    let manager = McpServerManager::new(Vec::new());
    assert!(!manager.is_connected("sqlite"));
}

#[test]
fn health_none_when_not_configured() {
    let manager = McpServerManager::new(Vec::new());
    assert!(manager.health("sqlite").is_none());
}

#[test]
fn status_empty_when_no_configs() {
    let manager = McpServerManager::new(Vec::new());
    assert!(manager.status().is_empty());
}

#[test]
fn record_success_resets_failures() {
    let mut manager = McpServerManager::new(Vec::new());
    // Manually insert a degraded server state
    let _ = manager.servers.insert(
        "test".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("test")),
            tool_defs: vec![dummy_tool_def("t1"), dummy_tool_def("t2")],
            health: McpServerHealth::Degraded,
            consecutive_failures: 2,
            last_error: Some("timeout".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    manager.record_success("test");
    let state = manager.servers.get("test").unwrap();
    assert_eq!(state.health, McpServerHealth::Healthy);
    assert_eq!(state.consecutive_failures, 0);
    assert!(state.last_error.is_none());
}

#[test]
fn record_failure_degrades_then_fails() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "test".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("test")),
            tool_defs: vec![dummy_tool_def("t1")],
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    // First failure → Degraded
    let h1 = manager.record_failure("test", "timeout");
    assert_eq!(h1, McpServerHealth::Degraded);
    assert_eq!(manager.servers.get("test").unwrap().consecutive_failures, 1);

    // Second failure → still Degraded
    let h2 = manager.record_failure("test", "timeout again");
    assert_eq!(h2, McpServerHealth::Degraded);

    // Third failure → Failed (MAX_CONSECUTIVE_FAILURES = 3)
    let h3 = manager.record_failure("test", "still timing out");
    assert_eq!(h3, McpServerHealth::Failed);
    assert!(!manager.is_connected("test"));
}

#[test]
fn status_reports_all_configured_servers() {
    let configs = vec![
        McpServerConfig {
            name: "a".into(),
            command: Some("echo".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        },
        McpServerConfig {
            name: "b".into(),
            command: None,
            args: Vec::new(),
            env: HashMap::new(),
            url: Some("http://localhost:5000".into()),
            tool_timeout_ms: 10_000,
            enabled: true,
        },
    ];

    let manager = McpServerManager::new(configs);
    let statuses = manager.status();
    assert_eq!(statuses.len(), 2);
    assert_eq!(statuses[0].name, "a");
    assert_eq!(statuses[1].name, "b");
    // Both should be Failed since they were never started
    assert_eq!(statuses[0].health, McpServerHealth::Failed);
}

#[tokio::test]
async fn start_all_with_no_servers() {
    let mut manager = McpServerManager::new(Vec::new());
    let capabilities = manager.start_all().await;
    assert!(capabilities.is_empty());
}

#[tokio::test]
async fn start_all_with_invalid_command_skips() {
    let configs = vec![McpServerConfig {
        name: "bad-server".into(),
        command: Some("nonexistent-mcp-binary-12345".into()),
        args: Vec::new(),
        env: HashMap::new(),
        url: None,
        tool_timeout_ms: 5_000,
        enabled: true,
    }];
    let mut manager = McpServerManager::new(configs);
    let capabilities = manager.start_all().await;
    assert!(capabilities.is_empty());
    assert!(!manager.is_connected("bad-server"));
    // Should be tracked as Failed
    assert_eq!(manager.health("bad-server"), Some(McpServerHealth::Failed));
}

#[tokio::test]
async fn shutdown_all_no_panic_when_empty() {
    let mut manager = McpServerManager::new(Vec::new());
    manager.shutdown_all().await;
}

#[test]
fn connected_servers_excludes_failed() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "healthy".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("healthy")),
            tool_defs: vec![
                dummy_tool_def("a"),
                dummy_tool_def("b"),
                dummy_tool_def("c"),
            ],
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );
    let _ = manager.servers.insert(
        "broken".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("broken")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: 3,
            last_error: Some("crashed".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );
    let _ = manager.servers.insert(
        "degraded".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("degraded")),
            tool_defs: vec![dummy_tool_def("d")],
            health: McpServerHealth::Degraded,
            consecutive_failures: 1,
            last_error: Some("timeout".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    let connected = manager.connected_servers();
    assert_eq!(connected.len(), 2);
    assert!(connected.contains(&"healthy"));
    assert!(connected.contains(&"degraded"));
    assert!(!connected.contains(&"broken"));
}

#[test]
fn client_returns_none_for_failed() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "failed".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("failed")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: 3,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
            tools_refreshed_at: Instant::now(),
        },
    );
    assert!(manager.client("failed").is_none());
    assert!(manager.client("nonexistent").is_none());
}

#[tokio::test]
async fn restart_unknown_server_returns_error() {
    let mut manager = McpServerManager::new(Vec::new());
    let result = manager.manual_restart("nonexistent").await;
    assert!(result.is_err());
}

// ── Saturating counter + auto-refusal ────────────────────────────────

#[test]
fn record_failure_counter_saturates_at_u32_max() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: u32::MAX,
            last_error: None,
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );
    let _ = manager.record_failure("s", "more");
    assert_eq!(
        manager.servers.get("s").unwrap().consecutive_failures,
        u32::MAX
    );
}

#[tokio::test]
async fn try_auto_restart_refuses_when_failed() {
    let mut manager = McpServerManager::new(vec![McpServerConfig {
        name: "s".into(),
        command: Some("nonexistent-mcp-binary".into()),
        args: Vec::new(),
        env: HashMap::new(),
        url: None,
        tool_timeout_ms: 5_000,
        enabled: true,
    }]);
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("hit cap".into()),
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    let err = manager.try_auto_restart("s").await.unwrap_err();
    assert!(matches!(err.kind, McpErrorKind::PermanentlyFailed));
    // Counter must not have been incremented by the refusal.
    assert_eq!(
        manager.servers.get("s").unwrap().consecutive_failures,
        MAX_CONSECUTIVE_FAILURES
    );
}

#[tokio::test]
async fn try_auto_restart_proceeds_when_degraded() {
    // Configured but pointing at a nonexistent binary, so the restart will
    // fail — we just want to confirm the refusal gate does NOT fire for
    // Degraded health.
    let mut manager = McpServerManager::new(vec![McpServerConfig {
        name: "s".into(),
        command: Some("nonexistent-mcp-binary".into()),
        args: Vec::new(),
        env: HashMap::new(),
        url: None,
        tool_timeout_ms: 5_000,
        enabled: true,
    }]);
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Degraded,
            consecutive_failures: 1,
            last_error: None,
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    let err = manager.try_auto_restart("s").await.unwrap_err();
    // Degraded → attempted restart → transient/connection error, NOT refusal.
    assert!(!matches!(err.kind, McpErrorKind::PermanentlyFailed));
}

#[tokio::test]
async fn manual_restart_always_attempts_even_when_failed() {
    // Manual restart should bypass the refusal gate and attempt a real
    // reconnection. We can't run a real MCP server here, so we just check
    // the error kind is from the connection attempt (Transient), not the
    // refusal path (PermanentlyFailed).
    let mut manager = McpServerManager::new(vec![McpServerConfig {
        name: "s".into(),
        command: Some("nonexistent-mcp-binary".into()),
        args: Vec::new(),
        env: HashMap::new(),
        url: None,
        tool_timeout_ms: 5_000,
        enabled: true,
    }]);
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("hit cap".into()),
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    let err = manager.manual_restart("s").await.unwrap_err();
    assert!(!matches!(err.kind, McpErrorKind::PermanentlyFailed));
}

#[tokio::test]
async fn restart_counter_increments_saturating_on_failure() {
    // Configured; nonexistent binary makes connect fail.
    let mut manager = McpServerManager::new(vec![McpServerConfig {
        name: "s".into(),
        command: Some("nonexistent-mcp-binary".into()),
        args: Vec::new(),
        env: HashMap::new(),
        url: None,
        tool_timeout_ms: 5_000,
        enabled: true,
    }]);
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Degraded,
            consecutive_failures: u32::MAX,
            last_error: None,
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );

    let _ = manager.manual_restart("s").await;
    // Still saturated; must not have overflowed.
    assert_eq!(
        manager.servers.get("s").unwrap().consecutive_failures,
        u32::MAX
    );
}

// ── Schema-refresh TTL (C8) ──────────────────────────────────────────
//
// The drift-detection path is exercised end-to-end in
// [`crate::domains::mcp::tests::integration`] with a mock MCP server whose
// `tools/list` changes between calls. The tests here pin down the TTL
// gating and early-return contracts that don't need a live server.

#[tokio::test]
async fn refresh_schemas_if_stale_unknown_server_returns_none() {
    let mut manager = McpServerManager::new(Vec::new());
    let result = manager
        .refresh_schemas_if_stale("ghost", Duration::from_millis(1))
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn refresh_schemas_if_stale_within_ttl_is_noop() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: vec![dummy_tool_def("a")],
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "t".into(),
            tools_refreshed_at: Instant::now(),
        },
    );
    // Fresh timestamp, large TTL → no refresh triggered and no list_tools
    // call is attempted against the placeholder client (which would error).
    let result = manager
        .refresh_schemas_if_stale("s", Duration::from_secs(3600))
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn refresh_schemas_if_stale_skips_failed_server() {
    let mut manager = McpServerManager::new(Vec::new());
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: Vec::new(),
            health: McpServerHealth::Failed,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("cap".into()),
            connected_at: "t".into(),
            // Intentionally stale — the Failed gate must short-circuit first.
            tools_refreshed_at: Instant::now() - Duration::from_secs(600),
        },
    );
    let result = manager
        .refresh_schemas_if_stale("s", Duration::from_millis(1))
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn refresh_schemas_past_ttl_on_dead_client_bumps_timestamp_and_returns_none() {
    // The placeholder client always errors on list_capabilities. Verify the
    // refresh path swallows the error, bumps the timestamp to avoid
    // hammering, and returns Ok(None) so callers continue with cached.
    let mut manager = McpServerManager::new(Vec::new());
    let past = Instant::now() - Duration::from_secs(600);
    let _ = manager.servers.insert(
        "s".into(),
        ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_defs: vec![dummy_tool_def("cached")],
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "t".into(),
            tools_refreshed_at: past,
        },
    );
    let result = manager
        .refresh_schemas_if_stale("s", Duration::from_millis(1))
        .await
        .unwrap();
    assert!(
        result.is_none(),
        "list_tools failure must surface as Ok(None)"
    );
    // Cached tool_defs must be preserved on refresh failure.
    assert_eq!(
        manager.tool_defs_for_test("s").unwrap().len(),
        1,
        "cached tool_defs must survive a failed refresh"
    );
    // Timestamp must have been bumped forward from the stale value.
    let after = manager.servers.get("s").unwrap().tools_refreshed_at;
    assert!(
        after > past,
        "timestamp must advance after a refresh attempt"
    );
}
