use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::payload_safety::{
    reject_path_like, reject_prompt_like, reject_provider_visible_token_like, reject_secret_like,
    reject_shell_command_like,
};

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const REQUEST_ID_MAX_BYTES: usize = 160;
pub(super) const DECISION_ID_MAX_BYTES: usize = 160;
pub(super) const POLICY_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;

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

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
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
    reject_secret_like(field, trimmed)?;
    reject_provider_visible_token_like(field, trimmed)?;
    reject_prompt_like(field, trimmed)?;
    reject_shell_command_like(field, trimmed)?;
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
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_provider_visible_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = bounded_token(field, value, max_bytes)?;
    reject_provider_visible_token_like(field, &trimmed)?;
    Ok(trimmed)
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
        .ok_or_else(|| invalid("module dependency write operations require an idempotencyKey"))
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
        .ok_or_else(|| invalid("module dependencies require trusted session or workspace scope"))
}

pub(super) fn request_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(state.as_str(), "pending_review" | "superseded" | "archived") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported module dependency request lifecycle {state}"
        )))
    }
}

pub(super) fn decision_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let decision = required_string(payload, "decision")?;
    if matches!(decision.as_str(), "approved" | "rejected" | "denied") {
        Ok(if decision == "approved" {
            "approved_policy".to_owned()
        } else {
            "rejected".to_owned()
        })
    } else {
        Err(invalid(format!(
            "unsupported module dependency decision {decision}"
        )))
    }
}

pub(super) fn policy_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state = optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "active".to_owned());
    if matches!(state.as_str(), "active" | "superseded" | "archived") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported module dependency policy lifecycle {state}"
        )))
    }
}

pub(super) fn risk_class(payload: &Value) -> Result<String, CapabilityError> {
    let risk = required_string(payload, "riskClass")?;
    if matches!(risk.as_str(), "low" | "medium" | "high" | "critical") {
        bounded_provider_visible_token("riskClass", &risk, TOKEN_MAX_BYTES)
    } else {
        Err(invalid(format!("unsupported riskClass {risk}")))
    }
}

pub(super) fn review_status(payload: &Value) -> Result<String, CapabilityError> {
    let status =
        optional_string(payload, "reviewStatus")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(
        status.as_str(),
        "pending_review" | "approved" | "rejected" | "denied" | "active"
    ) {
        bounded_provider_visible_token("reviewStatus", &status, TOKEN_MAX_BYTES)
    } else {
        Err(invalid(format!("unsupported reviewStatus {status}")))
    }
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

pub(super) fn required_ref(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    sanitize_ref_item(
        field,
        payload
            .get(field)
            .ok_or_else(|| invalid(format!("{field} is required")))?,
    )
}

pub(super) fn optional_ref(payload: &Value, field: &str) -> Result<Option<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => sanitize_ref_item(field, value).map(Some),
    }
}

pub(super) fn parity_evidence(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    let Value::Object(map) = payload
        .get(field)
        .ok_or_else(|| invalid(format!("{field} is required")))?
    else {
        return Err(invalid(format!("{field} must be an object")));
    };
    let status = map
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{field}.status is required")))?;
    if !matches!(
        status,
        "not_applicable" | "present" | "missing" | "drift_detected" | "unchanged"
    ) {
        return Err(invalid(format!("{field}.status has unsupported value")));
    }
    let package_manager_executed = map
        .get("packageManagerExecuted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let file_mutated = map
        .get("fileMutated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if package_manager_executed || file_mutated {
        return Err(invalid(format!(
            "{field} must prove no package manager execution or file mutation"
        )));
    }
    Ok(json!({
        "status": bounded_provider_visible_token(&format!("{field}.status"), status, TOKEN_MAX_BYTES)?,
        "summary": map
            .get("summary")
            .and_then(Value::as_str)
            .map(|value| bounded_text(&format!("{field}.summary"), value, SUMMARY_MAX_BYTES))
            .transpose()?
            .unwrap_or_else(|| "metadata parity evidence recorded without package-manager execution".to_owned()),
        "evidenceRefs": validate_ref_array(
            &format!("{field}.evidenceRefs"),
            map.get("evidenceRefs").and_then(Value::as_array).cloned().unwrap_or_default().as_slice(),
            MAX_REFS,
        )?,
        "packageManagerExecuted": false,
        "fileMutated": false,
        "rawDiffStored": false,
        "rawFileContentsStored": false
    }))
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
        json!(bounded_provider_visible_token(
            &format!("{label}.kind"),
            kind,
            TOKEN_MAX_BYTES,
        )?),
    );
    sanitized.insert(
        "resourceId".to_owned(),
        json!(bounded_provider_visible_token(
            &format!("{label}.resourceId"),
            resource_id,
            TOKEN_MAX_BYTES,
        )?),
    );
    sanitized.insert(
        "role".to_owned(),
        json!(bounded_provider_visible_token(
            &format!("{label}.role"),
            role,
            TOKEN_MAX_BYTES,
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

pub(super) fn validate_module_dependency_request_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_dependency_request:") {
        return Err(invalid(
            "moduleDependencyRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleDependencyRequestResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_dependency_decision_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_dependency_decision:") {
        return Err(invalid(
            "moduleDependencyDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleDependencyDecisionResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_dependency_policy_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_dependency_policy:") {
        return Err(invalid(
            "moduleDependencyPolicyResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleDependencyPolicyResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
