use serde_json::{Value, json};

use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, EffectClass, EngineResourceScope,
    FunctionHealth, FunctionQuery, Invocation, RiskLevel, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{invalid_params, policy_error};

pub(super) fn query_from_payload(
    payload: &Value,
    actor: ActorContext,
) -> Result<FunctionQuery, CapabilityError> {
    Ok(FunctionQuery {
        actor: Some(actor),
        visibility: optional_str(payload, "visibility")?
            .map(parse_visibility)
            .transpose()?,
        namespace_prefix: optional_str(payload, "namespacePrefix")?.map(str::to_owned),
        text: optional_str(payload, "text")?.map(str::to_owned),
        effect_class: optional_str(payload, "effectClass")?
            .map(parse_effect)
            .transpose()?,
        max_risk: optional_str(payload, "maxRisk")?
            .map(parse_risk)
            .transpose()?,
        health: optional_str(payload, "health")?
            .map(parse_health)
            .transpose()?,
        include_internal: payload
            .get("includeInternal")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

pub(super) fn query_echo(payload: &Value, limit: usize) -> Value {
    json!({
        "text": payload.get("text").cloned().unwrap_or(Value::Null),
        "namespacePrefix": payload.get("namespacePrefix").cloned().unwrap_or(Value::Null),
        "visibility": payload.get("visibility").cloned().unwrap_or(Value::Null),
        "effectClass": payload.get("effectClass").cloned().unwrap_or(Value::Null),
        "maxRisk": payload.get("maxRisk").cloned().unwrap_or(Value::Null),
        "health": payload.get("health").cloned().unwrap_or(Value::Null),
        "limit": limit
    })
}

pub(super) fn actor_context(invocation: &Invocation) -> ActorContext {
    ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: invocation.causal_context.actor_kind.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: invocation.causal_context.authority_scopes.clone(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    }
}

pub(super) fn privileged_actor_context() -> ActorContext {
    ActorContext::new(
        ActorId::new("system:catalog_discovery").expect("valid static actor id"),
        ActorKind::System,
        AuthorityGrantId::new("engine-system").expect("valid static grant id"),
    )
}

pub(super) fn ensure_catalog_visibility(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
    kind: &str,
    id: &str,
) -> Result<(), CapabilityError> {
    if catalog_visibility_visible(visibility, session_id, workspace_id, actor) {
        return Ok(());
    }
    Err(policy_error(format!("{kind} {id} is not visible")))
}

pub(super) fn report_scope(invocation: &Invocation) -> EngineResourceScope {
    if let Some(session_id) = &invocation.causal_context.session_id {
        return EngineResourceScope::Session(session_id.clone());
    }
    if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        return EngineResourceScope::Workspace(workspace_id.clone());
    }
    EngineResourceScope::System
}

pub(super) fn include_protected_counts(payload: &Value) -> bool {
    payload
        .get("includeProtectedCounts")
        .and_then(Value::as_bool)
        .unwrap_or(true)
}

pub(super) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| invalid_params(format!("{field} is required")))
}

pub(super) fn optional_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(invalid_params(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_limit(payload: &Value) -> Result<Option<usize>, CapabilityError> {
    match payload.get("limit") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => {
            let Some(raw) = value.as_u64() else {
                return Err(invalid_params("limit must be a positive integer"));
            };
            if !(1..=500).contains(&raw) {
                return Err(invalid_params("limit must be between 1 and 500"));
            }
            Ok(Some(raw as usize))
        }
        Some(_) => Err(invalid_params("limit must be a positive integer")),
    }
}

pub(super) fn visibility_key(value: &VisibilityScope) -> &'static str {
    value.as_str()
}

pub(super) fn effect_key(value: EffectClass) -> &'static str {
    match value {
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

pub(super) fn risk_key(value: RiskLevel) -> &'static str {
    match value {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

pub(super) fn health_key(value: &FunctionHealth) -> &'static str {
    match value {
        FunctionHealth::Healthy => "healthy",
        FunctionHealth::Degraded => "degraded",
        FunctionHealth::Unhealthy => "unhealthy",
        FunctionHealth::Unknown => "unknown",
    }
}

fn catalog_visibility_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
) -> bool {
    match visibility {
        VisibilityScope::Internal => actor.actor_kind.is_admin_like(),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(actor.actor_kind, ActorKind::Client) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(actor.actor_kind, ActorKind::Worker) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, ActorKind::Agent) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
    }
}

fn parse_visibility(value: &str) -> Result<VisibilityScope, CapabilityError> {
    Ok(match normalize_key(value).as_str() {
        "internal" => VisibilityScope::Internal,
        "session" => VisibilityScope::Session,
        "workspace" => VisibilityScope::Workspace,
        "system" => VisibilityScope::System,
        "client" => VisibilityScope::Client,
        "worker" => VisibilityScope::Worker,
        "agent" => VisibilityScope::Agent,
        "admin" => VisibilityScope::Admin,
        _ => return Err(invalid_params(format!("unsupported visibility {value}"))),
    })
}

fn parse_effect(value: &str) -> Result<EffectClass, CapabilityError> {
    Ok(match normalize_key(value).as_str() {
        "pureread" => EffectClass::PureRead,
        "deterministiccompute" => EffectClass::DeterministicCompute,
        "delegatedinvocation" => EffectClass::DelegatedInvocation,
        "idempotentwrite" => EffectClass::IdempotentWrite,
        "appendonlyevent" => EffectClass::AppendOnlyEvent,
        "reversiblesideeffect" => EffectClass::ReversibleSideEffect,
        "externalsideeffect" => EffectClass::ExternalSideEffect,
        "irreversiblesideeffect" => EffectClass::IrreversibleSideEffect,
        _ => return Err(invalid_params(format!("unsupported effectClass {value}"))),
    })
}

fn parse_risk(value: &str) -> Result<RiskLevel, CapabilityError> {
    Ok(match normalize_key(value).as_str() {
        "low" => RiskLevel::Low,
        "medium" => RiskLevel::Medium,
        "high" => RiskLevel::High,
        "critical" => RiskLevel::Critical,
        _ => return Err(invalid_params(format!("unsupported maxRisk {value}"))),
    })
}

fn parse_health(value: &str) -> Result<FunctionHealth, CapabilityError> {
    Ok(match normalize_key(value).as_str() {
        "healthy" => FunctionHealth::Healthy,
        "degraded" => FunctionHealth::Degraded,
        "unhealthy" => FunctionHealth::Unhealthy,
        "unknown" => FunctionHealth::Unknown,
        _ => return Err(invalid_params(format!("unsupported health {value}"))),
    })
}

fn normalize_key(value: &str) -> String {
    value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .map(|ch| ch.to_ascii_lowercase())
        .collect()
}
