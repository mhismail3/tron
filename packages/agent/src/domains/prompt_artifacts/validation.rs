use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const ARTIFACT_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const PREVIEW_MAX_BYTES: usize = 1_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_SUPPORT_REFS: usize = 25;

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
    reject_prompt_body_like(field, trimmed)?;
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
    Ok(trimmed.to_owned())
}

pub(super) fn artifact_kind(payload: &Value) -> Result<String, CapabilityError> {
    let value = bounded_token(
        "artifactKind",
        &required_string(payload, "artifactKind")?,
        TOKEN_MAX_BYTES,
    )?;
    match value.as_str() {
        "history_entry" | "snippet" | "template" | "prompt_reference" => Ok(value),
        _ => Err(invalid(
            "artifactKind must be history_entry, snippet, template, or prompt_reference",
        )),
    }
}

pub(super) fn reject_raw_prompt_artifact_fields(payload: &Value) -> Result<(), CapabilityError> {
    for field in [
        "prompt",
        "promptText",
        "promptBody",
        "rawPrompt",
        "rawPromptBody",
        "body",
        "content",
        "text",
        "messages",
        "modelMessages",
        "providerPayload",
        "rawPayload",
        "payload",
        "snippetBody",
        "templateBody",
        "template",
        "conversation",
        "transcript",
        "autoCapture",
        "automaticCapture",
        "includeInPrompt",
        "promptInjection",
        "injectPrompt",
        "contextInjection",
        "learnedBehavior",
        "code",
        "sourceCode",
        "rawCode",
        "command",
        "shellCommand",
        "stdin",
        "stdout",
        "stderr",
        "absolutePath",
        "rootPath",
        "workingDirectory",
        "cwd",
        "path",
        "paths",
        "url",
        "blob",
        "blobBytes",
        "fileContents",
    ] {
        if payload.get(field).is_some() {
            return Err(invalid(format!(
                "{field} is not accepted; prompt artifact records store metadata, refs, and fingerprints only"
            )));
        }
    }
    Ok(())
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
        .ok_or_else(|| invalid("prompt_artifact_record requires an idempotencyKey"))
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
            invalid("prompt artifact operations require trusted session or workspace scope")
        })
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    let retention_state = optional_string(payload, "retentionState")?
        .map(|value| bounded_token("retentionState", &value, TOKEN_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "active".to_owned());
    match retention_state.as_str() {
        "active" | "archival_candidate" | "retained" => {}
        _ => return Err(invalid("retentionState is unsupported")),
    }
    Ok(json!({
        "privacyClass": "prompt_artifact_metadata",
        "policy": "explicit_opt_in_prompt_artifact_metadata_only",
        "state": retention_state,
        "maxAgeDays": max_age_days,
        "archiveKeepsLifecycleEvidence": true
    }))
}

pub(super) fn optional_ref(payload: &Value, field: &str) -> Result<Option<Value>, CapabilityError> {
    payload
        .get(field)
        .map(|value| sanitize_ref_item(field, value))
        .transpose()
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
        json!(bounded_token("ref.kind", kind, TOKEN_MAX_BYTES)?),
    );
    if item.get("resourceId").is_some() {
        sanitized.insert(
            "resourceId".to_owned(),
            json!(bounded_token("ref.resourceId", id, TOKEN_MAX_BYTES)?),
        );
    } else {
        sanitized.insert(
            "id".to_owned(),
            json!(bounded_token("ref.id", id, TOKEN_MAX_BYTES)?),
        );
    }
    if let Some(role) = item.get("role").and_then(Value::as_str) {
        sanitized.insert(
            "role".to_owned(),
            json!(bounded_token("ref.role", role, TOKEN_MAX_BYTES)?),
        );
    }
    if let Some(version_id) = item.get("versionId").and_then(Value::as_str) {
        sanitized.insert(
            "versionId".to_owned(),
            json!(bounded_token("ref.versionId", version_id, TOKEN_MAX_BYTES)?),
        );
    }
    if item.keys().any(|key| {
        !matches!(
            key.as_str(),
            "kind" | "id" | "resourceId" | "role" | "versionId"
        )
    }) {
        return Err(invalid(format!(
            "{label} may contain only kind, id/resourceId, role, and versionId"
        )));
    }
    Ok(Value::Object(sanitized))
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn reject_secret_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.contains("api_key=")
        || lowered.contains("apikey=")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
        || lowered.contains("api_key:")
        || lowered.contains("apikey:")
        || lowered.contains("password:")
        || lowered.contains("secret:")
        || lowered.contains("token:")
        || lowered.contains("\"token\"")
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(())
}

fn reject_prompt_body_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    for marker in [
        "raw prompt",
        "prompt body",
        "system:",
        "developer:",
        "assistant:",
        "user:",
        "\"role\"",
        "\"messages\"",
        "<|",
        "begin prompt",
        "end prompt",
    ] {
        if lowered.contains(marker) {
            return Err(invalid(format!(
                "{field} must not contain raw prompt or provider-message material"
            )));
        }
    }
    Ok(())
}
