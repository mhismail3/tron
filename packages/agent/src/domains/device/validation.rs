use serde_json::Value;

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const DEVICE_ID_MAX_BYTES: usize = 160;
pub(super) const LABEL_MAX_BYTES: usize = 160;
pub(super) const REASON_MAX_BYTES: usize = 1_000;
pub(super) const MAX_EVENT_FAMILIES: usize = 12;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const DEFAULT_MAX_INBOX_RECORDS: u64 = 500;
pub(super) const MAX_INBOX_RECORDS: u64 = 5_000;

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

pub(super) fn optional_string_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<String>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => {
            if items.len() > MAX_EVENT_FAMILIES {
                return Err(invalid(format!(
                    "{field} may contain at most {MAX_EVENT_FAMILIES} entries"
                )));
            }
            items
                .iter()
                .map(|item| {
                    item.as_str()
                        .map(ToOwned::to_owned)
                        .ok_or_else(|| invalid(format!("{field} entries must be strings")))
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Some)
        }
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
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = bounded_text(field, value, max_bytes)?;
    if trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    Ok(trimmed)
}

pub(super) fn parse_platform(value: Option<String>) -> Result<String, CapabilityError> {
    match value.as_deref().unwrap_or("ios") {
        "ios" => Ok("ios".to_owned()),
        other => Err(invalid(format!("unsupported device platform {other}"))),
    }
}

pub(super) fn parse_apns_environment(value: &str) -> Result<String, CapabilityError> {
    match value {
        "development" | "production" => Ok(value.to_owned()),
        other => Err(invalid(format!(
            "unsupported apnsEnvironment {other}; use development or production"
        ))),
    }
}

pub(super) fn validate_apns_token(value: &str) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if !(32..=512).contains(&trimmed.len()) || !trimmed.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(invalid(
            "apnsToken must be 32 to 512 hexadecimal characters",
        ));
    }
    Ok(trimmed.to_ascii_lowercase())
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
        .ok_or_else(|| invalid("device writes require an idempotencyKey"))
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
        .ok_or_else(|| invalid("device operations require trusted session or workspace scope"))
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
