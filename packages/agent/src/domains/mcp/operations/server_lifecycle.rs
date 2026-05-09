//! MCP workflow operations.
use super::McpServerConfig;
use super::{publish_mcp_status_changed, refresh_mcp_tool_catalog, require_router};
use crate::domains::mcp::Deps;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_bool;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn mcp_add_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;
    let command = opt_string(params, "command");
    let url = opt_string(params, "url");
    let enabled = opt_bool(params, "enabled").unwrap_or(true);

    let args: Vec<String> = params
        .and_then(|p| p.get("args"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let env: std::collections::HashMap<String, String> = params
        .and_then(|p| p.get("env"))
        .and_then(Value::as_object)
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();

    let config = McpServerConfig {
        name,
        command,
        args,
        env,
        url,
        tool_timeout_ms: 30_000,
        enabled,
    };

    let mut guard = router.write().await;
    let tool_count = guard
        .add_server(config)
        .await
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({
        "success": true,
        "toolCount": tool_count,
    }))
}

pub(crate) async fn mcp_remove_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .remove_server(&name)
        .await
        .map_err(|message| CapabilityError::Internal { message })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

pub(crate) async fn mcp_enable_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .enable_server(&name)
        .await
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

pub(crate) async fn mcp_disable_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .disable_server(&name)
        .await
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

pub(crate) async fn mcp_restart_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    let tool_count = guard
        .restart_server(&name)
        .await
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({
        "success": true,
        "toolCount": tool_count,
    }))
}

pub(crate) async fn mcp_reload_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?.clone();

    let mut guard = router.write().await;
    let server_count = guard
        .reload_from_settings()
        .await
        .map_err(|e| CapabilityError::Internal { message: e })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({
        "success": true,
        "serverCount": server_count,
    }))
}
