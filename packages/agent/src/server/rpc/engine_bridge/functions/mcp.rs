use async_trait::async_trait;
use serde_json::{Value, json};

use super::*;

use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, AuthorityRequirement, EffectClass,
    FunctionDefinition, FunctionId, FunctionQuery, IdempotencyContract, InProcessFunctionHandler,
    Provenance, RiskLevel, VisibilityScope,
};
use crate::mcp::types::McpServerConfig;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "mcp.status" => mcp_status_value(deps).await,
        "mcp.addServer" => mcp_add_server_value(Some(payload), invocation, deps).await,
        "mcp.removeServer" => mcp_remove_server_value(Some(payload), invocation, deps).await,
        "mcp.enableServer" => mcp_enable_server_value(Some(payload), invocation, deps).await,
        "mcp.disableServer" => mcp_disable_server_value(Some(payload), invocation, deps).await,
        "mcp.restartServer" => mcp_restart_server_value(Some(payload), invocation, deps).await,
        "mcp.reload" => mcp_reload_value(invocation, deps).await,
        "mcp.listTools" => mcp_list_tools_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("mcp method {method} is not engine-owned"),
        }),
    }
}

fn require_router(
    deps: &RpcEngineDeps,
) -> Result<&Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>, RpcError> {
    deps.mcp_router.as_ref().ok_or(RpcError::Internal {
        message: "MCP is not configured on this server".into(),
    })
}

async fn mcp_status_value(deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let router = require_router(deps)?;
    let guard = router.read().await;
    let status = guard.status();
    serde_json::to_value(status).map_err(|e| RpcError::Internal {
        message: e.to_string(),
    })
}

async fn mcp_add_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
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
        .map_err(|e| RpcError::Internal {
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

async fn mcp_remove_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .remove_server(&name)
        .await
        .map_err(|message| RpcError::Internal { message })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

async fn mcp_enable_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .enable_server(&name)
        .await
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

async fn mcp_disable_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    guard
        .disable_server(&name)
        .await
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({ "success": true }))
}

async fn mcp_restart_server_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?.clone();
    let name = require_string_param(params, "name")?;

    let mut guard = router.write().await;
    let tool_count = guard
        .restart_server(&name)
        .await
        .map_err(|e| RpcError::Internal {
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

async fn mcp_reload_value(
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?.clone();

    let mut guard = router.write().await;
    let server_count = guard
        .reload_from_settings()
        .await
        .map_err(|e| RpcError::Internal { message: e })?;
    drop(guard);

    publish_mcp_status_changed(invocation, deps).await;
    refresh_mcp_tool_catalog(deps).await;

    Ok(json!({
        "success": true,
        "serverCount": server_count,
    }))
}

async fn mcp_list_tools_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let router = require_router(deps)?;
    let server_filter = opt_string(params, "server");

    let guard = router.read().await;
    let matches = guard.search("", server_filter.as_deref());
    drop(guard);
    refresh_mcp_tool_catalog(deps).await;

    serde_json::to_value(matches).map_err(|e| RpcError::Internal {
        message: e.to_string(),
    })
}

async fn publish_mcp_status_changed(invocation: &Invocation, deps: &RpcEngineDeps) {
    let Ok(status) = mcp_status_value(deps).await else {
        return;
    };
    let event = RpcEvent::new("mcp.status_changed", None, Some(status));
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "catalog".to_owned(),
            payload: json!({ "__rpcEvent": event }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "mcp".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}

async fn refresh_mcp_tool_catalog(deps: &RpcEngineDeps) {
    let Some(router) = deps.mcp_router.as_ref() else {
        return;
    };
    let worker_id = super::super::specs::worker_id("mcp").expect("valid static mcp worker id");
    let tools = {
        let guard = router.read().await;
        guard.search("", None)
    };
    let mut live_ids = std::collections::BTreeSet::new();
    for tool in tools {
        let id = mcp_tool_function_id(&tool.server, &tool.tool);
        let Ok(function_id) = FunctionId::new(id) else {
            continue;
        };
        let _ = live_ids.insert(function_id.as_str().to_owned());
        let mut definition = FunctionDefinition::new(
            function_id,
            worker_id.clone(),
            format!("MCP tool {} on server {}", tool.tool, tool.server),
            VisibilityScope::System,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::Medium)
        .with_required_authority(AuthorityRequirement::scope("mcp.write").with_approval_required())
        .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
        .with_provenance(Provenance::system())
        .with_request_schema(json!({
            "type": "object",
            "additionalProperties": true
        }))
        .with_response_schema(json!({
            "type": "object",
            "additionalProperties": true
        }));
        definition.metadata = json!({
            "domainWorker": "mcp",
            "mcpTool": true,
            "server": tool.server,
            "tool": tool.tool,
            "description": tool.description,
            "params": tool.params,
            "canonicalCapability": definition.id.as_str(),
            "effectDefault": "external_side_effect",
        });
        let handler = McpToolFunctionHandler {
            server: definition.metadata["server"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            tool: definition.metadata["tool"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            deps: deps.clone(),
        };
        let _ = deps
            .engine_host
            .register_function(definition, Some(Arc::new(handler)), true)
            .await;
    }
    let actor = ActorContext::new(
        ActorId::new("system").expect("valid static actor id"),
        ActorKind::System,
        AuthorityGrantId::new("mcp-catalog-refresh").expect("valid static grant id"),
    );
    let existing = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            namespace_prefix: Some("mcp::".to_owned()),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .await;
    for function in existing {
        let is_mcp_tool = function
            .metadata
            .get("mcpTool")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if is_mcp_tool && !live_ids.contains(function.id.as_str()) {
            let _ = deps
                .engine_host
                .unregister_function(&function.id, &worker_id)
                .await;
        }
    }
}

fn mcp_tool_function_id(server: &str, tool: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(server.as_bytes());
    hasher.update([0]);
    hasher.update(tool.as_bytes());
    let digest = hasher.finalize();
    format!(
        "mcp::{}__{}__{:02x}{:02x}{:02x}{:02x}",
        sanitize_id_part(server),
        sanitize_id_part(tool),
        digest[0],
        digest[1],
        digest[2],
        digest[3]
    )
}

fn sanitize_id_part(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            output.push(ch.to_ascii_lowercase());
        } else {
            output.push('_');
        }
    }
    let trimmed = output.trim_matches('_');
    if trimmed.is_empty() {
        "unnamed".to_owned()
    } else {
        trimmed.to_owned()
    }
}

struct McpToolFunctionHandler {
    server: String,
    tool: String,
    deps: RpcEngineDeps,
}

#[async_trait]
impl InProcessFunctionHandler for McpToolFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, crate::engine::EngineError> {
        let router = self.deps.mcp_router.as_ref().ok_or_else(|| {
            crate::engine::EngineError::HandlerFailed(
                "MCP is not configured on this server".to_owned(),
            )
        })?;
        let mut guard = router.write().await;
        let result = guard
            .call(&self.server, &self.tool, invocation.payload)
            .await
            .map_err(|error| crate::engine::EngineError::AdapterFailure {
                adapter: "mcp".to_owned(),
                code: "MCP_TOOL_ERROR".to_owned(),
                message: error.to_string(),
                details: Some(json!({
                    "server": self.server,
                    "tool": self.tool,
                })),
            })?;
        serde_json::to_value(result).map_err(|error| {
            crate::engine::EngineError::HandlerFailed(format!(
                "failed to serialize MCP tool result: {error}"
            ))
        })
    }
}
