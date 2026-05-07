use async_trait::async_trait;
use serde_json::{Value, json};

use super::*;

use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, AuthorityRequirement, EffectClass,
    FunctionDefinition, FunctionId, FunctionQuery, IdempotencyContract, InProcessFunctionHandler,
    Provenance, RiskLevel, VisibilityScope, WorkerId,
};
use crate::mcp::tool_bridge::mcp_result_to_tron_result;
use crate::mcp::tool_index::ParamSummary;
use crate::mcp::types::McpServerConfig;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
) -> Result<&Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>, RpcError> {
    deps.mcp_router.as_ref().ok_or(RpcError::Internal {
        message: "MCP is not configured on this server".into(),
    })
}

async fn mcp_status_value(deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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
    deps: &EngineCapabilityDeps,
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

async fn publish_mcp_status_changed(invocation: &Invocation, deps: &EngineCapabilityDeps) {
    let Ok(status) = mcp_status_value(deps).await else {
        return;
    };
    let event = RpcEvent::new("mcp.status_changed", None, Some(status));
    super::publish_rpc_event_or_broadcast(deps, "mcp", "mcp", event, Some(invocation)).await;
}

async fn refresh_mcp_tool_catalog(deps: &EngineCapabilityDeps) {
    let Some(router) = deps.mcp_router.as_ref() else {
        return;
    };
    let worker_id = WorkerId::new("mcp").expect("valid static mcp worker id");
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
        let classification = classify_mcp_tool(&tool.tool, &tool.description);
        let mut authority = AuthorityRequirement::scope(classification.authority_scope);
        if classification.approval_required {
            authority = authority.with_approval_required();
        }
        let mut definition = FunctionDefinition::new(
            function_id,
            worker_id.clone(),
            format!("MCP tool {} on server {}", tool.tool, tool.server),
            VisibilityScope::System,
            classification.effect_class,
        )
        .with_risk(classification.risk_level)
        .with_required_authority(authority)
        .with_provenance(Provenance::system())
        .with_request_schema(schema_from_mcp_params(&tool.params))
        .with_response_schema(json!({
            "type": "object",
            "additionalProperties": true
        }));
        if classification.effect_class.is_mutating() {
            definition =
                definition.with_idempotency(IdempotencyContract::caller_system_engine_ledger());
        }
        definition.metadata = json!({
            "domainWorker": "mcp",
            "mcpTool": true,
            "modelToolName": mcp_model_tool_name(&tool.server, &tool.tool),
            "toolOrder": 10_000,
            "server": tool.server,
            "tool": tool.tool,
            "description": tool.description,
            "params": serde_json::to_value(&tool.params).unwrap_or_else(|_| json!([])),
            "canonicalCapability": definition.id.as_str(),
            "classifier": {
                "effectClass": effect_class_label(classification.effect_class),
                "risk": risk_label(classification.risk_level),
                "authorityScope": classification.authority_scope,
                "approvalRequired": classification.approval_required,
                "reason": classification.reason,
                "confidence": classification.confidence,
            },
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

fn mcp_model_tool_name(server: &str, tool: &str) -> String {
    format!(
        "mcp_{}_{}",
        sanitize_id_part(server),
        sanitize_id_part(tool)
    )
}

#[derive(Clone, Copy)]
struct McpToolClassification {
    effect_class: EffectClass,
    risk_level: RiskLevel,
    authority_scope: &'static str,
    approval_required: bool,
    reason: &'static str,
    confidence: f64,
}

fn classify_mcp_tool(name: &str, description: &str) -> McpToolClassification {
    let text = format!("{name} {description}").to_lowercase();
    let read_markers = [
        "get", "list", "read", "search", "find", "fetch", "query", "lookup", "inspect", "describe",
        "status",
    ];
    let mutation_markers = [
        "write", "create", "update", "delete", "remove", "send", "run", "execute", "exec", "start",
        "stop", "restart", "kill", "apply", "patch", "edit", "commit", "push", "upload",
        "download", "sync", "publish",
    ];
    if mutation_markers
        .iter()
        .any(|marker| token_like_match(&text, marker))
    {
        return McpToolClassification {
            effect_class: EffectClass::ExternalSideEffect,
            risk_level: RiskLevel::Medium,
            authority_scope: "mcp.write",
            approval_required: true,
            reason: "name_or_description_implies_external_mutation",
            confidence: 0.8,
        };
    }
    if read_markers
        .iter()
        .any(|marker| token_like_match(&text, marker))
    {
        return McpToolClassification {
            effect_class: EffectClass::PureRead,
            risk_level: RiskLevel::Low,
            authority_scope: "mcp.read",
            approval_required: false,
            reason: "name_or_description_looks_read_only",
            confidence: 0.65,
        };
    }
    McpToolClassification {
        effect_class: EffectClass::ExternalSideEffect,
        risk_level: RiskLevel::Medium,
        authority_scope: "mcp.write",
        approval_required: true,
        reason: "unknown_mcp_tool_defaults_to_safe_external_side_effect",
        confidence: 0.5,
    }
}

fn token_like_match(text: &str, marker: &str) -> bool {
    text.split(|ch: char| !ch.is_ascii_alphanumeric())
        .any(|token| token == marker || token.starts_with(marker))
}

fn effect_class_label(effect: EffectClass) -> &'static str {
    match effect {
        EffectClass::PureRead => "pure_read",
        EffectClass::DeterministicCompute => "deterministic_compute",
        EffectClass::DelegatedInvocation => "delegated_invocation",
        EffectClass::IdempotentWrite => "idempotent_write",
        EffectClass::AppendOnlyEvent => "append_only_event",
        EffectClass::ReversibleSideEffect => "reversible_side_effect",
        EffectClass::ExternalSideEffect => "external_side_effect",
        EffectClass::IrreversibleSideEffect => "irreversible_side_effect",
    }
}

fn risk_label(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn schema_from_mcp_params(params: &[ParamSummary]) -> Value {
    let mut properties = serde_json::Map::new();
    let mut required = Vec::new();
    for param in params {
        let mut schema = serde_json::Map::new();
        let _ = schema.insert("type".to_owned(), Value::String(param.param_type.clone()));
        if !param.description.is_empty() {
            let _ = schema.insert(
                "description".to_owned(),
                Value::String(param.description.clone()),
            );
        }
        if param.required {
            required.push(Value::String(param.name.clone()));
        }
        let _ = properties.insert(param.name.clone(), Value::Object(schema));
    }
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": true,
    })
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
    deps: EngineCapabilityDeps,
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
        let tron_result = mcp_result_to_tron_result(&result, &self.server, &self.tool);
        serde_json::to_value(tron_result).map_err(|error| {
            crate::engine::EngineError::HandlerFailed(format!(
                "failed to serialize MCP tool result: {error}"
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifier_marks_obvious_reads_as_low_risk_pure_reads() {
        let classification = classify_mcp_tool("list_projects", "List project metadata");
        assert_eq!(classification.effect_class, EffectClass::PureRead);
        assert_eq!(classification.risk_level, RiskLevel::Low);
        assert_eq!(classification.authority_scope, "mcp.read");
        assert!(!classification.approval_required);
        assert!(classification.confidence >= 0.6);
    }

    #[test]
    fn classifier_marks_mutation_words_as_approval_required_side_effects() {
        let classification = classify_mcp_tool("send_email", "Send a message to a recipient");
        assert_eq!(classification.effect_class, EffectClass::ExternalSideEffect);
        assert_eq!(classification.risk_level, RiskLevel::Medium);
        assert_eq!(classification.authority_scope, "mcp.write");
        assert!(classification.approval_required);
        assert_eq!(
            classification.reason,
            "name_or_description_implies_external_mutation"
        );
    }

    #[test]
    fn classifier_defaults_unknown_tools_to_conservative_side_effects() {
        let classification = classify_mcp_tool("frobnicate", "Perform the server operation");
        assert_eq!(classification.effect_class, EffectClass::ExternalSideEffect);
        assert_eq!(classification.risk_level, RiskLevel::Medium);
        assert_eq!(classification.authority_scope, "mcp.write");
        assert!(classification.approval_required);
        assert_eq!(
            classification.reason,
            "unknown_mcp_tool_defaults_to_safe_external_side_effect"
        );
    }
}
