//! Operation binding for the MCP worker.

use super::Deps;
use super::operations::*;
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |_invocation, deps| {
            mcp_status_value(deps).await
        },
        "add_server" => |invocation, deps| {
            mcp_add_server_value(Some(&invocation.payload), invocation, deps).await
        },
        "remove_server" => |invocation, deps| {
            mcp_remove_server_value(Some(&invocation.payload), invocation, deps).await
        },
        "enable_server" => |invocation, deps| {
            mcp_enable_server_value(Some(&invocation.payload), invocation, deps).await
        },
        "disable_server" => |invocation, deps| {
            mcp_disable_server_value(Some(&invocation.payload), invocation, deps).await
        },
        "restart_server" => |invocation, deps| {
            mcp_restart_server_value(Some(&invocation.payload), invocation, deps).await
        },
        "reload" => |invocation, deps| {
            mcp_reload_value(invocation, deps).await
        },
        "list_capabilities" => |invocation, deps| {
            mcp_list_capabilities_value(Some(&invocation.payload), deps).await
        },
    ];
}
