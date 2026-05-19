use super::support::*;

#[tokio::test]
async fn manager_starts_configured_servers() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![mock_config("mgr-test", &script)];
    let mut manager = McpServerManager::new(configs);

    let discovered = manager.start_all().await;
    let capability_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
    assert_eq!(capability_count, 2);
    assert!(manager.is_connected("mgr-test"));
    assert_eq!(manager.connected_servers().len(), 1);

    let status = manager.status();
    assert_eq!(status.len(), 1);
    assert_eq!(status[0].health, McpServerHealth::Healthy);
    assert_eq!(status[0].capability_count, 2);

    manager.shutdown_all().await;
}

#[tokio::test]
async fn manager_skips_failing_server_continues_others() {
    let good_script =
        mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![
        McpServerConfig {
            name: "bad".into(),
            command: Some("nonexistent_binary_99999".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        },
        mock_config("good", &good_script),
    ];
    let mut manager = McpServerManager::new(configs);

    let discovered = manager.start_all().await;
    let capability_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
    assert_eq!(capability_count, 2);
    assert!(!manager.is_connected("bad"));
    assert!(manager.is_connected("good"));

    let statuses = manager.status();
    let bad_status = statuses.iter().find(|s| s.name == "bad").unwrap();
    assert_eq!(bad_status.health, McpServerHealth::Failed);

    manager.shutdown_all().await;
}

#[tokio::test]
async fn manager_restarts_server() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![mock_config("restart-test", &script)];
    let mut manager = McpServerManager::new(configs);

    let discovered = manager.start_all().await;
    let capability_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
    assert_eq!(capability_count, 2);

    // Manual restart should yield fresh tool defs
    let new_defs = manager.manual_restart("restart-test").await.unwrap();
    assert_eq!(new_defs.len(), 2);
    assert!(manager.is_connected("restart-test"));
    assert_eq!(
        manager.health("restart-test"),
        Some(McpServerHealth::Healthy)
    );

    manager.shutdown_all().await;
}

#[tokio::test]
async fn manager_health_tracking_through_failures() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![mock_config("health-test", &script)];
    let mut manager = McpServerManager::new(configs);
    let _ = manager.start_all().await;

    // Simulate failures
    let h1 = manager.record_failure("health-test", "error 1");
    assert_eq!(h1, McpServerHealth::Degraded);

    let h2 = manager.record_failure("health-test", "error 2");
    assert_eq!(h2, McpServerHealth::Degraded);

    let h3 = manager.record_failure("health-test", "error 3");
    assert_eq!(h3, McpServerHealth::Failed);
    assert!(!manager.is_connected("health-test"));

    // Recovery via record_success (simulating a successful restart)
    manager.record_success("health-test");
    // Note: record_success changes health, but is_connected checks Failed state
    // After recovery, it should be connected again
    assert!(manager.is_connected("health-test"));

    manager.shutdown_all().await;
}

#[tokio::test]
async fn manager_stops_servers_on_shutdown() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![
        mock_config("s1", &script.clone()),
        mock_config("s2", &script),
    ];
    let mut manager = McpServerManager::new(configs);
    let _ = manager.start_all().await;
    assert_eq!(manager.connected_servers().len(), 2);

    manager.shutdown_all().await;
    assert!(manager.connected_servers().is_empty());
}
