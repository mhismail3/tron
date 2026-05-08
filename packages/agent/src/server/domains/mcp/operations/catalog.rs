//! MCP workflow operations.
use super::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, AuthorityRequirement, EffectClass,
    FunctionDefinition, FunctionId, FunctionQuery, IdempotencyContract, ParamSummary, Provenance,
    RiskLevel, WorkerId,
};
use super::{McpToolFunctionHandler, mcp_status_value, require_router};
use crate::engine::Invocation;
use crate::engine::VisibilityScope;
use crate::server::domains::mcp::Deps;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_string;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) async fn mcp_list_tools_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?;
    let server_filter = opt_string(params, "server");

    let guard = router.read().await;
    let matches = guard.search("", server_filter.as_deref());
    drop(guard);
    refresh_mcp_tool_catalog(deps).await;

    serde_json::to_value(matches).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })
}

pub(crate) async fn publish_mcp_status_changed(invocation: &Invocation, deps: &Deps) {
    let Ok(status) = mcp_status_value(deps).await else {
        return;
    };
    crate::server::domains::mcp::stream::McpStreamPublisher::new(&deps.engine_host)
        .status_changed(invocation, status)
        .await;
}

pub(crate) async fn refresh_mcp_tool_catalog(deps: &Deps) {
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

pub(crate) fn mcp_tool_function_id(server: &str, tool: &str) -> String {
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

pub(crate) fn mcp_model_tool_name(server: &str, tool: &str) -> String {
    format!(
        "mcp_{}_{}",
        sanitize_id_part(server),
        sanitize_id_part(tool)
    )
}

#[derive(Clone, Copy)]
pub(crate) struct McpToolClassification {
    pub(crate) effect_class: EffectClass,
    pub(crate) risk_level: RiskLevel,
    pub(crate) authority_scope: &'static str,
    pub(crate) approval_required: bool,
    pub(crate) reason: &'static str,
    pub(crate) confidence: f64,
}

pub(crate) fn classify_mcp_tool(name: &str, description: &str) -> McpToolClassification {
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

pub(crate) fn token_like_match(text: &str, marker: &str) -> bool {
    text.split(|ch: char| !ch.is_ascii_alphanumeric())
        .any(|token| token == marker || token.starts_with(marker))
}

pub(crate) fn effect_class_label(effect: EffectClass) -> &'static str {
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

pub(crate) fn risk_label(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

pub(crate) fn schema_from_mcp_params(params: &[ParamSummary]) -> Value {
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

pub(crate) fn sanitize_id_part(value: &str) -> String {
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
