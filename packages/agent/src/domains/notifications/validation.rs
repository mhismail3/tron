use serde_json::Value;

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const MARK_ALL_LIMIT_MAX: usize = 500;
pub(super) const DEVICE_DELIVERY_LIMIT: usize = 100;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const BODY_MAX_BYTES: usize = 2_000;
pub(super) const REASON_MAX_BYTES: usize = 1_000;
pub(super) const NOTIFICATION_ID_MAX_BYTES: usize = 160;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const DEFAULT_MAX_INBOX_RECORDS: u64 = 500;
pub(super) const MAX_INBOX_RECORDS: u64 = 5_000;

pub(super) const ALLOWED_EVENT_FAMILIES: &[&str] = &[
    "approval",
    "question",
    "goal",
    "schedule",
    "web",
    "git",
    "job",
    "subagent",
    "memory",
    "system",
    "agent_attention",
];

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
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

pub(super) fn optional_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => Ok(Some(items.clone())),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if trimmed.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    let lowered = trimmed.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.contains("api_key=")
        || lowered.contains("apikey=")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.len() > max_bytes
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

pub(super) fn parse_event_family(value: Option<String>) -> Result<String, CapabilityError> {
    let family = value.unwrap_or_else(|| "agent_attention".to_owned());
    let family = bounded_token("family", &family, 64)?;
    if !ALLOWED_EVENT_FAMILIES
        .iter()
        .any(|allowed| *allowed == family)
    {
        return Err(invalid(format!("unsupported notification family {family}")));
    }
    Ok(family)
}

pub(super) fn parse_severity(value: Option<String>) -> Result<String, CapabilityError> {
    match value.as_deref().unwrap_or("info") {
        "info" | "warning" | "action_required" => Ok(value.unwrap_or_else(|| "info".to_owned())),
        other => Err(invalid(format!(
            "unsupported notification severity {other}"
        ))),
    }
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    invocation
        .causal_context
        .idempotency_key
        .clone()
        .or_else(|| optional_string(payload, "idempotencyKey").ok().flatten())
        .ok_or_else(|| invalid("notification writes require an idempotencyKey"))
}

pub(super) fn resource_scope(
    invocation: &Invocation,
) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .ok_or_else(|| {
            invalid("notification operations require trusted session or workspace scope")
        })
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
