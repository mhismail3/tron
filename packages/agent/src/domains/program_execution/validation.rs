use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const PROGRAM_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const LABEL_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
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
    reject_execution_text(field, trimmed)?;
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
    reject_execution_text(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn reject_raw_program_execution_fields(payload: &Value) -> Result<(), CapabilityError> {
    for field in [
        "code",
        "source",
        "sourceCode",
        "rawCode",
        "programBody",
        "script",
        "scriptBody",
        "command",
        "commandLine",
        "shell",
        "shellCommand",
        "args",
        "argv",
        "stdin",
        "stdout",
        "stderr",
        "rawStdin",
        "rawStdout",
        "rawStderr",
        "processId",
        "pid",
        "pty",
        "subprocess",
        "execute",
        "run",
        "spawn",
        "install",
        "packageInstall",
        "packageManager",
        "npmInstall",
        "pipInstall",
        "cargoInstall",
        "networkRequest",
        "url",
        "fileWrite",
        "writeFiles",
        "absolutePath",
        "rootPath",
        "workingDirectory",
        "cwd",
        "path",
        "paths",
        "rawPayload",
        "payload",
        "blob",
        "blobBytes",
        "fileContents",
    ] {
        if payload.get(field).is_some() {
            return Err(invalid(format!(
                "{field} is not accepted; program execution records store content-free metadata only"
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
        .ok_or_else(|| invalid("program_execution_record requires an idempotencyKey"))
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
            invalid("program execution operations require trusted session or workspace scope")
        })
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    Ok(json!({
        "privacyClass": "program_execution_metadata",
        "policy": "content_free_program_execution_metadata_only",
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

pub(super) fn resource_limit_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_wall_clock_ms = optional_u64(payload, "maxWallClockMs")?.unwrap_or(0);
    let max_memory_mb = optional_u64(payload, "maxMemoryMb")?.unwrap_or(0);
    let max_output_bytes = optional_u64(payload, "maxOutputBytes")?.unwrap_or(0);
    if max_wall_clock_ms > 3_600_000 || max_memory_mb > 1_048_576 || max_output_bytes > 100_000_000
    {
        return Err(invalid("resource limits exceed metadata envelope bounds"));
    }
    Ok(json!({
        "declaredOnly": true,
        "enforcedByRuntime": false,
        "maxWallClockMs": max_wall_clock_ms,
        "maxMemoryMb": max_memory_mb,
        "maxOutputBytes": max_output_bytes
    }))
}

pub(super) fn io_envelope(payload: &Value) -> Result<Value, CapabilityError> {
    let input_fingerprint = optional_string(payload, "inputFingerprint")?
        .map(|value| bounded_token("inputFingerprint", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let output_fingerprint = optional_string(payload, "outputFingerprint")?
        .map(|value| bounded_token("outputFingerprint", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    Ok(json!({
        "metadataOnly": true,
        "rawStdinStored": false,
        "rawStdoutStored": false,
        "rawStderrStored": false,
        "inputRef": optional_ref(payload, "inputRef")?,
        "outputRef": optional_ref(payload, "outputRef")?,
        "inputFingerprint": input_fingerprint,
        "outputFingerprint": output_fingerprint
    }))
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

fn reject_execution_text(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    for marker in [
        "#!/bin/",
        "#!/usr/bin/",
        "bash -c",
        "sh -c",
        "python -c",
        "node -e",
        "npm install",
        "pip install",
        "cargo install",
        "curl ",
        "wget ",
        "chmod +x",
        "subprocess",
        "child_process",
    ] {
        if lowered.contains(marker) {
            return Err(invalid(format!(
                "{field} must not contain executable command text"
            )));
        }
    }
    Ok(())
}
