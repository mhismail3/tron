#![allow(unused_imports)]

pub(super) use crate::domains::mcp::capability_index::McpCapabilityIndex;
pub(super) use crate::domains::mcp::client::{McpClient, McpErrorKind};
pub(super) use crate::domains::mcp::router::McpRouter;
pub(super) use crate::domains::mcp::server_manager::McpServerManager;
pub(super) use crate::domains::mcp::types::*;
pub(super) use serde_json::json;
pub(super) use std::collections::HashMap;

/// Spawn a mock MCP server as a bash process that reads JSON-RPC from stdin
/// and responds on stdout.
pub(super) fn mock_server_script(
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
            ;;
        tools/list)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":{{"tools":'$TOOLS_JSON'}}}}'
            ;;
        tools/call)
            echo '{{"jsonrpc":"2.0","id":'$id',"result":'$CALL_RESULT'}}'
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

pub(super) fn mock_config(name: &str, script: &str) -> McpServerConfig {
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

pub(super) fn default_tools_json() -> String {
    json!([
        {
            "name": "query",
            "description": "Run SQL query",
            "inputSchema": {
                "type": "object",
                "properties": {"sql": {"type": "string"}},
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

pub(super) fn default_call_result() -> String {
    json!({
        "content": [{"type": "text", "text": "result: 42"}],
        "isError": false
    })
    .to_string()
}

/// Mock server that returns `first_tools_json` for the first `tools/list`
/// request and `second_tools_json` for subsequent requests.
pub(super) fn drifting_mock_server_script(
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
