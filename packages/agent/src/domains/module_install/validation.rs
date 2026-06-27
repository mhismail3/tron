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
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;
pub(super) const PREVIEW_MAX_BYTES: usize = 280;

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
        .ok_or_else(|| invalid("module_install write operations require an idempotencyKey"))
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
        .ok_or_else(|| invalid("module install requires trusted session or workspace scope"))
}

pub(super) fn request_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(state.as_str(), "pending_review" | "superseded" | "archived") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported module install request lifecycle {state}"
        )))
    }
}

pub(super) fn decision_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state = required_string(payload, "decision")?;
    if matches!(state.as_str(), "approved" | "rejected" | "denied") {
        Ok(if state == "approved" {
            "install_candidate".to_owned()
        } else {
            "rejected".to_owned()
        })
    } else {
        Err(invalid(format!(
            "unsupported module install decision {state}"
        )))
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

pub(super) fn validate_dependency_policy_status(payload: &Value) -> Result<Value, CapabilityError> {
    let status = optional_string(payload, "dependencyPolicyStatus")?
        .unwrap_or_else(|| "not_required".to_owned());
    if !matches!(
        status.as_str(),
        "not_required" | "linked" | "satisfied" | "blocked"
    ) {
        return Err(invalid(format!(
            "unsupported dependencyPolicyStatus {status}"
        )));
    }
    Ok(json!({
        "status": bounded_provider_visible_token("dependencyPolicyStatus", &status, TOKEN_MAX_BYTES)?,
        "metadataOnly": true,
        "restored": false,
        "packageManagerUsed": false
    }))
}

pub(super) fn validate_rollback_readiness(payload: &Value) -> Result<Value, CapabilityError> {
    let readiness =
        optional_string(payload, "rollbackReadiness")?.unwrap_or_else(|| "not_proven".to_owned());
    if !matches!(readiness.as_str(), "not_proven" | "ready" | "blocked") {
        return Err(invalid(format!(
            "unsupported rollbackReadiness {readiness}"
        )));
    }
    Ok(json!({
        "status": bounded_provider_visible_token("rollbackReadiness", &readiness, TOKEN_MAX_BYTES)?,
        "metadataOnly": true,
        "rollbackExecuted": false
    }))
}

pub(super) fn validate_approval_refs(
    payload: &Value,
) -> Result<(String, Option<String>), CapabilityError> {
    let request_resource_id = required_string(payload, "approvalRequestResourceId")?;
    validate_approval_request_resource_id(&request_resource_id)?;
    let decision_resource_id = optional_string(payload, "approvalDecisionResourceId")?
        .map(|id| {
            validate_approval_decision_resource_id(&id)?;
            Ok::<_, CapabilityError>(id)
        })
        .transpose()?;
    Ok((request_resource_id, decision_resource_id))
}

pub(super) fn validate_module_validation_report_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_validation_report:") {
        return Err(invalid(
            "moduleValidationReportResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleValidationReportResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_install_request_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_install_request:") {
        return Err(invalid(
            "moduleInstallRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleInstallRequestResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_install_decision_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_install_decision:") {
        return Err(invalid(
            "moduleInstallDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleInstallDecisionResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_approval_request_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("approval_request:") {
        return Err(invalid(
            "approvalRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("approvalRequestResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

pub(super) fn validate_approval_decision_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("approval_decision:") {
        return Err(invalid(
            "approvalDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("approvalDecisionResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

fn sanitize_ref_item(label: &str, value: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(item) = value else {
        return Err(invalid(format!("{label} must be an object")));
    };
    let kind = item
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires kind")))?;
    let id = item
        .get("id")
        .or_else(|| item.get("resourceId"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires id or resourceId")))?;
    let mut sanitized = Map::new();
    sanitized.insert(
        "kind".to_owned(),
        json!(bounded_provider_visible_token(
            "ref.kind",
            kind,
            TOKEN_MAX_BYTES
        )?),
    );
    if item.get("resourceId").is_some() {
        sanitized.insert(
            "resourceId".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.resourceId",
                id,
                TOKEN_MAX_BYTES
            )?),
        );
    } else {
        sanitized.insert(
            "id".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.id",
                id,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    if let Some(role) = item.get("role").and_then(Value::as_str) {
        sanitized.insert(
            "role".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.role",
                role,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    if let Some(version_id) = item.get("versionId").and_then(Value::as_str) {
        sanitized.insert(
            "versionId".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.versionId",
                version_id,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    for key in ["status", "fingerprint", "preview", "summary"] {
        if let Some(value) = item.get(key).and_then(Value::as_str) {
            let sanitized_value = if matches!(key, "preview" | "summary") {
                bounded_text(&format!("ref.{key}"), value, PREVIEW_MAX_BYTES)?
            } else {
                bounded_provider_visible_token(&format!("ref.{key}"), value, TOKEN_MAX_BYTES)?
            };
            sanitized.insert(key.to_owned(), json!(sanitized_value));
        }
    }
    if item.keys().any(|key| {
        !matches!(
            key.as_str(),
            "kind"
                | "id"
                | "resourceId"
                | "role"
                | "versionId"
                | "status"
                | "fingerprint"
                | "preview"
                | "summary"
        )
    }) {
        return Err(invalid(format!(
            "{label} may contain only kind, id/resourceId, role, versionId, status, fingerprint, preview, and summary"
        )));
    }
    Ok(Value::Object(sanitized))
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
