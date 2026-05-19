use super::support::*;

#[tokio::test]
async fn capability_index_populated_at_startup() {
    use crate::domains::mcp::capability_index::McpCapabilityIndex;

    let script = mock_server_script(&default_tools_json(), &default_call_result(), "2024-11-05");
    let configs = vec![mock_config("reg-test", &script)];
    let mut manager = McpServerManager::new(configs);

    let discovered = manager.start_all().await;

    let mut index = McpCapabilityIndex::new();
    for (server, defs) in &discovered {
        index.add_server_tools(server, defs);
    }

    assert_eq!(index.capability_count(), 2);
    let results = index.search("query", None);
    assert!(!results.is_empty());
    assert_eq!(results[0].server, "reg-test");
    assert_eq!(results[0].tool, "query");

    manager.shutdown_all().await;
}
