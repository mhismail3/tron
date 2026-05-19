use super::support::*;

#[tokio::test]
async fn client_connects_to_stdio_server() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
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
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let config = mock_config("discover-test", &script);
    let client = McpClient::connect_stdio(&config).await.unwrap();

    let capabilities = client.list_tools().await.unwrap();
    assert_eq!(capabilities.len(), 2);
    assert_eq!(capabilities[0].name, "query");
    assert_eq!(capabilities[1].name, "list_tables");
    assert_eq!(capabilities[0].description, "Run SQL query");

    client.shutdown().await;
}

#[tokio::test]
async fn client_calls_tool() {
    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
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
    let capabilities = client.list_tools().await.unwrap();
    assert_eq!(capabilities.len(), 1);
    assert_eq!(capabilities[0].name, "test_tool");

    client.shutdown().await;
}

#[tokio::test]
async fn client_handles_error_capability_result() {
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

#[tokio::test]
async fn client_handles_empty_tool_list() {
    let script = mock_server_script("[]", &default_call_result(), "2024-11-05");
    let config = mock_config("empty-tools", &script);
    let client = McpClient::connect_stdio(&config).await.unwrap();

    let capabilities = client.list_tools().await.unwrap();
    assert!(capabilities.is_empty());

    client.shutdown().await;
}
