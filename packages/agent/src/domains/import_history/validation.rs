use serde_json::{Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const RECORD_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const LABEL_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_PARENT_REFS: usize = 16;
pub(super) const MAX_CHILD_REFS: usize = 16;
pub(super) const MAX_SUPPORT_REFS: usize = 25;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SubjectKind {
    Session,
    Resource,
}

impl SubjectKind {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Resource => "resource",
        }
    }
}

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

pub(super) fn parse_graph_kind(value: Option<String>) -> Result<String, CapabilityError> {
    let graph_kind = value.unwrap_or_else(|| "session_resource".to_owned());
    if graph_kind != "session_resource" {
        return Err(invalid(
            "graphKind must be session_resource for the generic graph foundation",
        ));
    }
    Ok(graph_kind)
}

pub(super) fn parse_subject_kind(value: Option<String>) -> Result<SubjectKind, CapabilityError> {
    match value.as_deref().unwrap_or("resource") {
        "session" => Ok(SubjectKind::Session),
        "resource" => Ok(SubjectKind::Resource),
        other => Err(invalid(format!("unsupported subjectKind {other}"))),
    }
}

pub(super) fn parse_render_hint(value: Option<String>) -> Result<String, CapabilityError> {
    let render_hint = value.unwrap_or_else(|| "generic_graph".to_owned());
    if render_hint != "generic_graph" {
        return Err(invalid(
            "renderHint must stay generic_graph until native tree proof exists",
        ));
    }
    Ok(render_hint)
}

pub(super) fn reject_raw_import_fields(payload: &Value) -> Result<(), CapabilityError> {
    for field in [
        "rawImportPayload",
        "importPayload",
        "repositoryTree",
        "repositoryContents",
        "treeJson",
        "treeNodes",
        "fileText",
        "fileContents",
        "archiveBytes",
        "diffText",
        "path",
        "paths",
    ] {
        if payload.get(field).is_some() {
            return Err(invalid(format!(
                "{field} is not accepted; import history stores bounded lineage refs only"
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
        .ok_or_else(|| invalid("import_history_record requires an idempotencyKey"))
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
            invalid("import history operations require trusted session or workspace scope")
        })
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    Ok(json!({
        "privacyClass": "import_lineage_metadata",
        "policy": "bounded_lineage_metadata_only",
        "maxAgeDays": max_age_days,
        "archiveKeepsLifecycleEvidence": true
    }))
}

pub(super) fn validate_ref_array(
    label: &str,
    refs: &[Value],
    max_items: usize,
) -> Result<(), CapabilityError> {
    if refs.len() > max_items {
        return Err(invalid(format!(
            "{label} may contain at most {max_items} items"
        )));
    }
    for value in refs {
        validate_ref_item(label, value)?;
    }
    Ok(())
}

pub(super) fn validate_ref_item(label: &str, value: &Value) -> Result<(), CapabilityError> {
    let Value::Object(item) = value else {
        return Err(invalid(format!("{label} items must be objects")));
    };
    let kind = item
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} items require kind")))?;
    let id = item
        .get("id")
        .or_else(|| item.get("resourceId"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} items require id or resourceId")))?;
    let _ = bounded_token("ref.kind", kind, TOKEN_MAX_BYTES)?;
    let _ = bounded_token("ref.id", id, TOKEN_MAX_BYTES)?;
    if let Some(role) = item.get("role").and_then(Value::as_str) {
        let _ = bounded_token("ref.role", role, TOKEN_MAX_BYTES)?;
    }
    if let Some(version_id) = item.get("versionId").and_then(Value::as_str) {
        let _ = bounded_token("ref.versionId", version_id, TOKEN_MAX_BYTES)?;
    }
    if item.len() > 5 {
        return Err(invalid(format!(
            "{label} items may contain only kind, id/resourceId, role, versionId, and metadata"
        )));
    }
    if let Some(metadata) = item.get("metadata") {
        let serialized = serde_json::to_string(metadata)
            .map_err(|error| invalid(format!("serialize {label} metadata: {error}")))?;
        reject_secret_like(label, &serialized)?;
        if serialized.len() > SUMMARY_MAX_BYTES {
            return Err(invalid(format!(
                "{label} metadata exceeds {SUMMARY_MAX_BYTES} bytes"
            )));
        }
    }
    Ok(())
}

pub(super) fn validate_subject(
    invocation: &Invocation,
    subject_kind: SubjectKind,
    subject_id: &str,
) -> Result<(), CapabilityError> {
    let subject_id = bounded_token("subjectId", subject_id, TOKEN_MAX_BYTES)?;
    if subject_kind == SubjectKind::Session {
        let current = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| invalid("session subject requires trusted current session"))?;
        if subject_id != current {
            return Err(invalid(
                "session subject must match the trusted current session",
            ));
        }
    }
    Ok(())
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
        || lowered.contains("\"token\"")
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(())
}
