//! Operation binding for the mcp worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "mcp::status" => mcp_status_value(deps).await,
        "mcp::add_server" => mcp_add_server_value(Some(payload), invocation, deps).await,
        "mcp::remove_server" => mcp_remove_server_value(Some(payload), invocation, deps).await,
        "mcp::enable_server" => mcp_enable_server_value(Some(payload), invocation, deps).await,
        "mcp::disable_server" => mcp_disable_server_value(Some(payload), invocation, deps).await,
        "mcp::restart_server" => mcp_restart_server_value(Some(payload), invocation, deps).await,
        "mcp::reload" => mcp_reload_value(invocation, deps).await,
        "mcp::list_tools" => mcp_list_tools_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("mcp method {method} is not engine-owned"),
        }),
    }
}
