use super::support::*;

#[tokio::test]
async fn router_call_refreshes_drifted_schema_and_rebuilds_index() {
    use crate::domains::mcp::router::McpRouter;

    // Two tool sets that will drift between calls.
    let first_tools = json!([
        {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}}
    ])
    .to_string();
    let second_tools = json!([
        {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}},
        {"name": "list_tables", "description": "List all tables", "inputSchema": {"type": "object"}}
    ])
    .to_string();

    let tmp_dir = tempfile::tempdir().unwrap();
    let state_file = tmp_dir.path().join("drift-state.txt");
    let script =
        drifting_mock_server_script(state_file.to_str().unwrap(), &first_tools, &second_tools);
    let config = mock_config("drift-srv", &script);
    let tron_home = tmp_dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&tron_home).unwrap();
    let settings_path = tron_home
        .join(crate::shared::paths::dirs::PROFILES)
        .join(crate::shared::profile::USER_PROFILE)
        .join(crate::shared::paths::files::PROFILE_TOML);

    // TTL of 1ms so the second call is *guaranteed* stale enough to trigger
    // a refresh. Startup fetches capabilities once; the first `.call()` refreshes.
    let mut router = McpRouter::new(vec![config], settings_path, 1).await;

    // Initial state: index has one tool from startup.
    let matches = router.search("list", None);
    assert!(
        matches.iter().all(|m| m.tool != "list_tables"),
        "pre-drift index must not contain list_tables"
    );

    // Give the monotonic clock a moment so `tools_refreshed_at.elapsed() >= ttl`.
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;

    // First call forces a stale-schema refresh. The drifting server returns
    // the second tool set on the second `tools/list`; the index must pick
    // up `list_tables`.
    let result = router
        .call("drift-srv", "query", json!({"sql": "SELECT 1"}))
        .await;
    assert!(result.is_ok(), "expected call to succeed: {result:?}");

    // Index must now contain BOTH capabilities.
    let post_drift_matches = router.search("list", None);
    let names: Vec<&str> = post_drift_matches.iter().map(|m| m.tool.as_str()).collect();
    assert!(
        names.contains(&"list_tables"),
        "post-drift index must contain list_tables; got {names:?}"
    );

    router.shutdown_all().await;
}

#[tokio::test]
async fn router_call_without_ttl_does_not_refresh() {
    use crate::domains::mcp::router::McpRouter;

    // Same drifting server, but TTL disabled (0) — the index must remain
    // unchanged even across calls.
    let first_tools = json!([
        {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}}
    ])
    .to_string();
    let second_tools = json!([
        {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}},
        {"name": "list_tables", "description": "List all tables", "inputSchema": {"type": "object"}}
    ])
    .to_string();

    let tmp_dir = tempfile::tempdir().unwrap();
    let state_file = tmp_dir.path().join("drift-state.txt");
    let script =
        drifting_mock_server_script(state_file.to_str().unwrap(), &first_tools, &second_tools);
    let config = mock_config("no-ttl-srv", &script);
    let tron_home = tmp_dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&tron_home).unwrap();
    let settings_path = tron_home
        .join(crate::shared::paths::dirs::PROFILES)
        .join(crate::shared::profile::USER_PROFILE)
        .join(crate::shared::paths::files::PROFILE_TOML);

    let mut router = McpRouter::new(vec![config], settings_path, 0).await;

    let result = router
        .call("no-ttl-srv", "query", json!({"sql": "SELECT 1"}))
        .await;
    assert!(result.is_ok(), "expected call to succeed: {result:?}");

    // TTL disabled → index must NOT see the added tool.
    let matches = router.search("list", None);
    assert!(
        matches.iter().all(|m| m.tool != "list_tables"),
        "TTL=0 must not proactively refresh; list_tables leaked into index"
    );

    router.shutdown_all().await;
}
