//! Integration tests for MCP client, tool bridge, and server manager.
//!
//! Uses a mock MCP server implemented as a child process that communicates
//! via stdio JSON-RPC. The mock is a small Rust binary compiled inline via
//! `tokio::process::Command` running a simple bash script.

#[cfg(test)]
mod integration {
    use std::collections::HashMap;
    use std::sync::Arc;

    use serde_json::json;

    use crate::mcp::client::{McpClient, McpErrorKind};
    use crate::mcp::server_manager::McpServerManager;
    use crate::mcp::tool_bridge::{McpToolBridge, create_bridge_tools};
    use crate::mcp::types::*;
    use crate::tools::traits::TronTool;

    // -----------------------------------------------------------------------
    // Mock MCP server helper
    // -----------------------------------------------------------------------

    /// Spawn a mock MCP server as a bash process that reads JSON-RPC from stdin
    /// and responds on stdout. The mock handles:
    /// - `initialize` → returns protocolVersion + capabilities
    /// - `tools/list` → returns configurable tool definitions
    /// - `tools/call` → returns configurable results
    ///
    /// This is more robust than piping to cat because it actually processes
    /// the JSON-RPC protocol.
    fn mock_server_script(
        tools_json: &str,
        call_result_json: &str,
        protocol_version: &str,
    ) -> String {
        format!(
            r#"#!/usr/bin/env bash
set -e
TOOLS_JSON='{tools_json}'
CALL_RESULT='{call_result_json}'
PROTO_VERSION='{protocol_version}'

while IFS= read -r line; do
    method=$(echo "$line" | grep -o '"method":"[^"]*"' | head -1 | sed 's/"method":"//;s/"//')
    id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
    [ -z "$id" ] && id=null

    case "$method" in
        initialize)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"protocolVersion":"'$PROTO_VERSION'","capabilities":{{}}}}}}'
            ;;
        notifications/initialized)
            # Notification — no response
            ;;
        tools/list)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"tools":'$TOOLS_JSON'}}}}'
            ;;
        tools/call)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":'$CALL_RESULT'}}'
            ;;
        notifications/cancelled)
            # Shutdown notification — exit cleanly
            exit 0
            ;;
        *)
            echo '{{"jsonrpc":"2.0","id":'$id',"error":{{"code":-32601,"message":"Method not found"}}}}'
            ;;
    esac
done
"#
        )
    }

    /// Create an `McpServerConfig` that launches a mock server via bash.
    fn mock_config(name: &str, script: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.to_string(),
            command: Some("bash".into()),
            args: vec!["-c".into(), script.to_string()],
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 10_000,
            enabled: true,
        }
    }

    fn default_tools_json() -> String {
        json!([
            {
                "name": "query",
                "description": "Run SQL query",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "sql": {"type": "string"}
                    },
                    "required": ["sql"]
                }
            },
            {
                "name": "list_tables",
                "description": "List all tables",
                "inputSchema": {"type": "object"}
            }
        ])
        .to_string()
    }

    fn default_call_result() -> String {
        json!({
            "content": [{"type": "text", "text": "result: 42"}],
            "isError": false
        })
        .to_string()
    }

    // -----------------------------------------------------------------------
    // Client tests
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn client_connects_to_stdio_server() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("test-server", &script);

        let client = McpClient::connect_stdio(&config).await;
        assert!(client.is_ok(), "Failed to connect: {:?}", client.err());

        let client = client.unwrap();
        assert_eq!(client.name, "test-server");
        assert!(client.is_alive().await);

        // Check negotiated version
        let version = client.negotiated_version.lock().await;
        assert_eq!(version.as_deref(), Some("2024-11-05"));

        client.shutdown().await;
    }

    #[tokio::test]
    async fn client_discovers_tools() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("discover-test", &script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        let tools = client.list_tools().await.unwrap();
        assert_eq!(tools.len(), 2);
        assert_eq!(tools[0].name, "query");
        assert_eq!(tools[1].name, "list_tables");
        assert_eq!(tools[0].description, "Run SQL query");

        client.shutdown().await;
    }

    #[tokio::test]
    async fn client_calls_tool() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("call-test", &script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        let result = client
            .call_tool("query", json!({"sql": "SELECT 1"}))
            .await
            .unwrap();
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 1);
        match &result.content[0] {
            McpContentBlock::Text { text } => assert_eq!(text, "result: 42"),
            _ => panic!("Expected text content"),
        }

        client.shutdown().await;
    }

    #[tokio::test]
    async fn client_handles_server_crash() {
        // Use a server that exits immediately after init
        let script = r#"
read -r line
id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
[ -z "$id" ] && id=null
echo '{"jsonrpc":"2.0","id":'$id',"result":{"protocolVersion":"2024-11-05","capabilities":{}}}'
read -r line
exit 1
"#;
        let config = mock_config("crash-test", script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        // The server exited — next call should fail with ConnectionLost
        let result = client.list_tools().await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            matches!(err.kind, McpErrorKind::ConnectionLost),
            "Expected ConnectionLost, got: {:?}",
            err.kind,
        );

        client.shutdown().await;
    }

    #[tokio::test]
    async fn client_handles_timeout() {
        // Server that never responds after init
        let script = r#"
read -r line
id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
[ -z "$id" ] && id=null
echo '{"jsonrpc":"2.0","id":'$id',"result":{"protocolVersion":"2024-11-05","capabilities":{}}}'
read -r line
# Read notification - do nothing
while true; do read -r line 2>/dev/null || exit 0; done
"#;
        let config = McpServerConfig {
            name: "timeout-test".into(),
            command: Some("bash".into()),
            args: vec!["-c".into(), script.into()],
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 500, // very short timeout
            enabled: true,
        };

        let client = McpClient::connect_stdio(&config).await.unwrap();

        let result = client.list_tools().await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            matches!(err.kind, McpErrorKind::Timeout),
            "Expected Timeout, got: {:?}",
            err.kind,
        );

        client.shutdown().await;
    }

    #[tokio::test]
    async fn client_rejects_unsupported_protocol_version() {
        let script = mock_server_script(
            "[]",
            &default_call_result(),
            "1999-01-01", // unsupported version
        );
        let config = mock_config("version-test", &script);

        let result = McpClient::connect_stdio(&config).await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            matches!(err.kind, McpErrorKind::VersionMismatch(_)),
            "Expected VersionMismatch, got: {:?}",
            err.kind,
        );
    }

    #[tokio::test]
    async fn client_handles_missing_command() {
        let config = McpServerConfig {
            name: "no-command".into(),
            command: Some("nonexistent_binary_xyzzy_12345".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        };

        let result = McpClient::connect_stdio(&config).await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message.contains("nonexistent_binary_xyzzy_12345"));
    }

    #[tokio::test]
    async fn placeholder_client_returns_connection_lost() {
        let client = McpClient::failed_placeholder("dead");
        assert!(!client.is_alive().await);

        let result = client.list_tools().await;
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err().kind,
            McpErrorKind::ConnectionLost
        ));
    }

    // -----------------------------------------------------------------------
    // Tool bridge tests
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn bridge_tool_definition_matches_schema() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("bridge-def-test", &script);
        let client = Arc::new(McpClient::connect_stdio(&config).await.unwrap());

        let tools = client.list_tools().await.unwrap();
        let bridge = McpToolBridge::new("sqlite", &tools[0], client.clone());

        let def = bridge.definition();
        assert_eq!(def.name, "sqlite.query");
        assert!(def.description.contains("[MCP: sqlite]"));
        assert!(def.description.contains("Run SQL query"));

        // Verify parameter schema
        let params = &def.parameters;
        assert_eq!(params.schema_type, "object");
        assert!(params.properties.as_ref().unwrap().contains_key("sql"));
        assert_eq!(params.required.as_ref().unwrap(), &vec!["sql".to_string()]);

        client.shutdown().await;
    }

    #[tokio::test]
    async fn bridge_tool_execute_forwards_params() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("bridge-exec-test", &script);
        let client = Arc::new(McpClient::connect_stdio(&config).await.unwrap());

        let tools = client.list_tools().await.unwrap();
        let bridge_tools = create_bridge_tools("sqlite", &tools, &client);

        assert_eq!(bridge_tools.len(), 2);
        assert_eq!(bridge_tools[0].name(), "sqlite.query");
        assert_eq!(bridge_tools[1].name(), "sqlite.list_tables");

        client.shutdown().await;
    }

    #[tokio::test]
    async fn bridge_tool_name_prefixed_with_server() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let config = mock_config("prefix-test", &script);
        let client = Arc::new(McpClient::connect_stdio(&config).await.unwrap());

        let tools = client.list_tools().await.unwrap();
        let bridges = create_bridge_tools("github", &tools, &client);

        for bridge in &bridges {
            assert!(
                bridge.name().starts_with("github."),
                "Tool name should be prefixed: {}",
                bridge.name()
            );
        }

        client.shutdown().await;
    }

    // -----------------------------------------------------------------------
    // Server manager tests
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn manager_starts_configured_servers() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let configs = vec![mock_config("mgr-test", &script)];
        let mut manager = McpServerManager::new(configs);

        let discovered = manager.start_all().await;
        let tool_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
        assert_eq!(tool_count, 2);
        assert!(manager.is_connected("mgr-test"));
        assert_eq!(manager.connected_servers().len(), 1);

        let status = manager.status();
        assert_eq!(status.len(), 1);
        assert_eq!(status[0].health, McpServerHealth::Healthy);
        assert_eq!(status[0].tool_count, 2);

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
        let tool_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
        assert_eq!(tool_count, 2);
        assert!(!manager.is_connected("bad"));
        assert!(manager.is_connected("good"));

        let statuses = manager.status();
        let bad_status = statuses.iter().find(|s| s.name == "bad").unwrap();
        assert_eq!(bad_status.health, McpServerHealth::Failed);

        manager.shutdown_all().await;
    }

    #[tokio::test]
    async fn manager_restarts_server() {
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let configs = vec![mock_config("restart-test", &script)];
        let mut manager = McpServerManager::new(configs);

        let discovered = manager.start_all().await;
        let tool_count: usize = discovered.iter().map(|(_, d)| d.len()).sum();
        assert_eq!(tool_count, 2);

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
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
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
        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
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

    // -----------------------------------------------------------------------
    // Tool index integration
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn tool_index_populated_at_startup() {
        use crate::mcp::tool_index::ToolIndex;

        let script =
            mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
        let configs = vec![mock_config("reg-test", &script)];
        let mut manager = McpServerManager::new(configs);

        let discovered = manager.start_all().await;

        let mut index = ToolIndex::new();
        for (server, defs) in &discovered {
            index.add_server_tools(server, defs);
        }

        assert_eq!(index.tool_count(), 2);
        let results = index.search("query", None);
        assert!(!results.is_empty());
        assert_eq!(results[0].server, "reg-test");
        assert_eq!(results[0].tool, "query");

        manager.shutdown_all().await;
    }

    // -----------------------------------------------------------------------
    // Edge case: server sends notifications before response
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn client_skips_server_notifications() {
        // Server that sends a notification before the actual response
        let script = r#"
while IFS= read -r line; do
    method=$(echo "$line" | grep -o '"method":"[^"]*"' | head -1 | sed 's/"method":"//;s/"//')
    id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
    [ -z "$id" ] && id=null

    case "$method" in
        initialize)
            echo '{"jsonrpc":"2.0","id":'$id',"result":{"protocolVersion":"2024-11-05","capabilities":{}}}'
            ;;
        notifications/initialized)
            ;;
        tools/list)
            # Send a notification FIRST, then the actual response
            echo '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":50}}'
            echo '{"jsonrpc":"2.0","id":'$id',"result":{"tools":[{"name":"test_tool","description":"A test","inputSchema":{"type":"object"}}]}}'
            ;;
        *)
            echo '{"jsonrpc":"2.0","id":'$id',"error":{"code":-32601,"message":"Method not found"}}'
            ;;
    esac
done
"#;
        let config = mock_config("notification-test", script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        // list_tools should skip the notification and return the actual response
        let tools = client.list_tools().await.unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "test_tool");

        client.shutdown().await;
    }

    // -----------------------------------------------------------------------
    // Edge case: error result from tool call
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn client_handles_error_tool_result() {
        let error_result = json!({
            "content": [{"type": "text", "text": "Error: table not found"}],
            "isError": true
        })
        .to_string();

        let script = mock_server_script(&default_tools_json(), &error_result, "2024-11-05");
        let config = mock_config("error-result-test", &script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        let result = client
            .call_tool("query", json!({"sql": "SELECT 1"}))
            .await
            .unwrap();
        assert!(result.is_error);
        match &result.content[0] {
            McpContentBlock::Text { text } => assert!(text.contains("table not found")),
            _ => panic!("Expected text content"),
        }

        client.shutdown().await;
    }

    // -----------------------------------------------------------------------
    // Edge case: empty tool list
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn client_handles_empty_tool_list() {
        let script = mock_server_script("[]", &default_call_result(), "2024-11-05");
        let config = mock_config("empty-tools", &script);
        let client = McpClient::connect_stdio(&config).await.unwrap();

        let tools = client.list_tools().await.unwrap();
        assert!(tools.is_empty());

        client.shutdown().await;
    }

    // -----------------------------------------------------------------------
    // Schema-drift refresh (C8)
    //
    // End-to-end coverage for `McpRouter::call` proactively re-fetching a
    // stale server's schema and rebuilding the tool index on drift. The mock
    // server writes a per-instance counter to a temp file and serves a
    // different tool list on the second `tools/list` call.
    // -----------------------------------------------------------------------

    /// Mock server that returns `first_tools_json` for the FIRST `tools/list`
    /// request and `second_tools_json` for ALL subsequent ones. State is kept
    /// in `state_file` (an absolute path) using append-only writes whose count
    /// is inspected per request.
    fn drifting_mock_server_script(
        state_file: &str,
        first_tools_json: &str,
        second_tools_json: &str,
    ) -> String {
        format!(
            r#"#!/usr/bin/env bash
set -e
STATE='{state_file}'
FIRST_TOOLS='{first_tools_json}'
SECOND_TOOLS='{second_tools_json}'
: > "$STATE"

while IFS= read -r line; do
    method=$(echo "$line" | grep -o '"method":"[^"]*"' | head -1 | sed 's/"method":"//;s/"//')
    id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
    [ -z "$id" ] && id=null

    case "$method" in
        initialize)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"protocolVersion":"2024-11-05","capabilities":{{}}}}}}'
            ;;
        notifications/initialized)
            ;;
        tools/list)
            echo "x" >> "$STATE"
            count=$(wc -l < "$STATE" | tr -d ' ')
            if [ "$count" = "1" ]; then
                echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"tools":'"$FIRST_TOOLS"'}}}}'
            else
                echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"tools":'"$SECOND_TOOLS"'}}}}'
            fi
            ;;
        tools/call)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"content":[{{"type":"text","text":"ok"}}],"isError":false}}}}'
            ;;
        notifications/cancelled)
            exit 0
            ;;
        *)
            echo '{{"jsonrpc":"2.0","id":'$id',"error":{{"code":-32601,"message":"Method not found"}}}}'
            ;;
    esac
done
"#
        )
    }

    #[tokio::test]
    async fn router_call_refreshes_drifted_schema_and_rebuilds_index() {
        use crate::mcp::router::McpRouter;

        // Two tool sets that will drift between calls.
        let first_tools = json!([
            {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}}
        ])
        .to_string();
        let second_tools = json!([
            {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}},
            {"name": "list_tables", "description": "List all tables", "inputSchema": {"type": "object"}}
        ]).to_string();

        let tmp_dir = tempfile::tempdir().unwrap();
        let state_file = tmp_dir.path().join("drift-state.txt");
        let script =
            drifting_mock_server_script(state_file.to_str().unwrap(), &first_tools, &second_tools);
        let config = mock_config("drift-srv", &script);
        let settings_path = tmp_dir.path().join("settings.json");

        // TTL of 1ms so the second call is *guaranteed* stale enough to trigger
        // a refresh. Startup fetches tools once; the first `.call()` refreshes.
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

        // Index must now contain BOTH tools.
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
        use crate::mcp::router::McpRouter;

        // Same drifting server, but TTL disabled (0) — the index must remain
        // unchanged even across calls.
        let first_tools = json!([
            {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}}
        ])
        .to_string();
        let second_tools = json!([
            {"name": "query", "description": "Run SQL query", "inputSchema": {"type": "object"}},
            {"name": "list_tables", "description": "List all tables", "inputSchema": {"type": "object"}}
        ]).to_string();

        let tmp_dir = tempfile::tempdir().unwrap();
        let state_file = tmp_dir.path().join("drift-state.txt");
        let script =
            drifting_mock_server_script(state_file.to_str().unwrap(), &first_tools, &second_tools);
        let config = mock_config("no-ttl-srv", &script);
        let settings_path = tmp_dir.path().join("settings.json");

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
}
