use serde_json::Value;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, DeliveryMode, FunctionId, Invocation, TraceId,
};
use crate::shared::server::errors::CapabilityError;

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
) -> Result<String, CapabilityError> {
    if let Some(key) = invocation.causal_context.idempotency_key.as_deref() {
        return bounded_token("idempotencyKey", key);
    }
    optional_str(payload, "idempotencyKey")?
        .map(bounded_token_value)
        .transpose()?
        .ok_or_else(|| invalid(format!("{operation} requires an idempotencyKey")))
}

pub(super) fn reason(
    payload: &Value,
    fallback: &str,
    max_reason_bytes: usize,
) -> Result<String, CapabilityError> {
    optional_str(payload, "reason")?
        .map(|value| bounded_text("reason", value, max_reason_bytes))
        .transpose()
        .map(|value| value.unwrap_or_else(|| fallback.to_owned()))
}

pub(super) fn actor_kind(invocation: &Invocation) -> &'static str {
    match invocation.causal_context.actor_kind {
        crate::engine::ActorKind::Agent => "agent",
        crate::engine::ActorKind::System => "system",
        _ => "other",
    }
}

pub(super) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

pub(super) fn optional_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.as_str())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

fn bounded_token_value(value: &str) -> Result<String, CapabilityError> {
    bounded_token("idempotencyKey", value)
}

fn bounded_token(field: &str, value: &str) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.len() > 256
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() > max_bytes {
        return Err(invalid(format!(
            "{field} must be non-empty and at most {max_bytes} bytes"
        )));
    }
    if looks_unsafe(trimmed) {
        return Err(invalid(format!(
            "{field} may not contain raw commands, paths, secrets, or prompt bodies"
        )));
    }
    Ok(trimmed.to_owned())
}

fn looks_unsafe(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.contains("sk-")
        || lower.contains("secret")
        || lower.contains("token=")
        || lower.contains("authorization:")
        || lower.contains("-----begin")
        || lower.contains("system prompt")
        || lower.contains("chain of thought")
        || lower.contains("sudo ")
        || lower.contains("rm -rf")
        || value.contains("/Users/")
        || value.contains("/home/")
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn runtime_error(
    error: crate::domains::agent::r#loop::errors::RuntimeError,
) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("context control runtime compaction persistence failed: {error}"),
    }
}

pub(super) fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn store_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn id_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn system_invocation(
    function_id: &str,
    session_id: &str,
    idempotency_key: &str,
    payload: Value,
) -> Result<Invocation, CapabilityError> {
    let context = crate::engine::CausalContext::new(
        ActorId::new("system:context-control").map_err(id_error)?,
        ActorKind::System,
        AuthorityGrantId::new("system:context-control-runtime").map_err(id_error)?,
        TraceId::generate(),
    )
    .with_session_id(session_id)
    .with_idempotency_key(idempotency_key);
    Ok(Invocation::new_sync(
        FunctionId::new(function_id).map_err(id_error)?,
        payload,
        context,
    )
    .with_delivery_mode(DeliveryMode::Sync))
}

pub(super) fn ui_system_invocation(
    function_id: &str,
    session_id: &str,
    idempotency_key: &str,
    payload: Value,
    parent: &Invocation,
) -> Result<Invocation, CapabilityError> {
    let context = crate::engine::CausalContext::new(
        ActorId::new("system:context-control-ui").map_err(id_error)?,
        ActorKind::System,
        AuthorityGrantId::new("system:context-control-ui").map_err(id_error)?,
        TraceId::generate(),
    )
    .with_session_id(session_id)
    .with_parent_invocation(parent.id.clone())
    .with_idempotency_key(idempotency_key);
    Ok(Invocation::new_sync(
        FunctionId::new(function_id).map_err(id_error)?,
        payload,
        context,
    )
    .with_delivery_mode(DeliveryMode::Sync))
}
