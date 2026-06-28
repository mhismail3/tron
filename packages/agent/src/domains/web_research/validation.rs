use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::payload_safety::{
    reject_path_like, reject_prompt_like, reject_provider_visible_token_like, reject_secret_like,
};

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;
pub(super) const MAX_LABELS: usize = 16;

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
    reject_secret_like(field, trimmed)?;
    reject_provider_visible_token_like(field, trimmed)?;
    reject_prompt_like(field, trimmed)?;
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
    reject_secret_like(field, trimmed)?;
    reject_path_like(field, trimmed)?;
    reject_provider_visible_token_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    if let Some(key) = invocation.causal_context.idempotency_key.as_deref() {
        return bounded_token("idempotencyKey", key, IDEMPOTENCY_KEY_MAX_BYTES);
    }
    optional_string(payload, "idempotencyKey")?
        .map(|key| bounded_token("idempotencyKey", &key, IDEMPOTENCY_KEY_MAX_BYTES))
        .transpose()?
        .ok_or_else(|| invalid("web research write operations require an idempotencyKey"))
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
        .ok_or_else(|| invalid("web research requires trusted session or workspace scope"))
}

pub(super) fn request_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    lifecycle_state(
        payload,
        "pending_review",
        &["pending_review", "superseded", "archived"],
    )
}

pub(super) fn review_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    lifecycle_state(
        payload,
        "pending_review",
        &["pending_review", "accepted", "rejected", "archived"],
    )
}

pub(super) fn source_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    lifecycle_state(
        payload,
        "available",
        &["available", "superseded", "archived"],
    )
}

fn lifecycle_state(
    payload: &Value,
    default: &str,
    allowed: &[&str],
) -> Result<String, CapabilityError> {
    let state = optional_string(payload, "lifecycleState")?.unwrap_or_else(|| default.to_owned());
    let state = bounded_token("lifecycleState", &state, TOKEN_MAX_BYTES)?;
    if allowed.contains(&state.as_str()) {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported web research lifecycle {state}"
        )))
    }
}

pub(super) fn labels(payload: &Value, field: &str) -> Result<Vec<String>, CapabilityError> {
    let Some(values) = optional_array(payload, field)? else {
        return Ok(Vec::new());
    };
    if values.len() > MAX_LABELS {
        return Err(invalid(format!(
            "{field} may contain at most {MAX_LABELS} items"
        )));
    }
    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            value
                .as_str()
                .ok_or_else(|| invalid(format!("{field}[{index}] must be a string")))
                .and_then(|value| bounded_token(field, value, TOKEN_MAX_BYTES))
        })
        .collect()
}

pub(super) fn validate_ref_array(
    label: &str,
    refs: &[Value],
    max_items: usize,
) -> Result<Vec<Value>, CapabilityError> {
    if refs.len() > max_items {
        return Err(invalid(format!(
            "{label} may contain at most {max_items} items"
        )));
    }
    refs.iter()
        .map(|value| sanitize_ref_item(label, value))
        .collect()
}

fn sanitize_ref_item(label: &str, value: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(map) = value else {
        return Err(invalid(format!("{label} entries must be objects")));
    };
    let kind = required_map_string(map, label, "kind")?;
    let resource_id = required_map_string(map, label, "resourceId")?;
    let role = map
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("evidence");
    let mut sanitized = Map::new();
    sanitized.insert(
        "kind".to_owned(),
        json!(bounded_token(
            &format!("{label}.kind"),
            kind,
            TOKEN_MAX_BYTES
        )?),
    );
    sanitized.insert(
        "resourceId".to_owned(),
        json!(bounded_token(
            &format!("{label}.resourceId"),
            resource_id,
            TOKEN_MAX_BYTES,
        )?),
    );
    sanitized.insert(
        "role".to_owned(),
        json!(bounded_token(
            &format!("{label}.role"),
            role,
            TOKEN_MAX_BYTES
        )?),
    );
    if let Some(summary) = map.get("summary").and_then(Value::as_str) {
        sanitized.insert(
            "summary".to_owned(),
            json!(bounded_text(
                &format!("{label}.summary"),
                summary,
                SUMMARY_MAX_BYTES,
            )?),
        );
    }
    Ok(Value::Object(sanitized))
}

fn required_map_string<'a>(
    map: &'a Map<String, Value>,
    label: &str,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    map.get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| invalid(format!("{label}.{field} is required")))
}

pub(super) fn validate_request_resource_id(value: &str) -> Result<(), CapabilityError> {
    validate_resource_id(
        "webResearchRequestResourceId",
        value,
        "web_research_request:",
    )
}

pub(super) fn validate_review_resource_id(value: &str) -> Result<(), CapabilityError> {
    validate_resource_id("webResearchReviewResourceId", value, "web_research_review:")
}

pub(super) fn validate_source_resource_id(value: &str) -> Result<(), CapabilityError> {
    validate_resource_id("webResearchSourceResourceId", value, "web_research_source:")
}

fn validate_resource_id(field: &str, value: &str, prefix: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(prefix) {
        return Err(invalid(format!("{field} has unsupported resource kind")));
    }
    bounded_token(field, value, TOKEN_MAX_BYTES).map(|_| ())
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
