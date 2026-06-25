use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const PREVIEW_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const LABEL_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const PATH_MAX_BYTES: usize = 240;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_PATH_ENTRIES: usize = 100;
pub(super) const MAX_TOTAL_ENTRIES: u64 = 100_000;
pub(super) const MAX_DEPTH: u64 = 64;
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

pub(super) fn bounded_relative_path(field: &str, value: &str) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > PATH_MAX_BYTES
        || trimmed.starts_with('/')
        || trimmed.starts_with('~')
        || trimmed.starts_with("./")
        || trimmed.contains('\\')
        || trimmed.contains("//")
        || trimmed.contains(':')
    {
        return Err(invalid(format!(
            "{field} must be a bounded normalized relative path"
        )));
    }
    if trimmed
        .split('/')
        .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    {
        return Err(invalid(format!(
            "{field} must not contain empty, current, or parent path segments"
        )));
    }
    reject_secret_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn reject_raw_import_preview_fields(payload: &Value) -> Result<(), CapabilityError> {
    for field in [
        "rawImportPayload",
        "importPayload",
        "rawPreviewPayload",
        "previewPayload",
        "importPreview",
        "applyImport",
        "executeImport",
        "importExecution",
        "writeFiles",
        "checkout",
        "merge",
        "conflictResolution",
        "gitCommand",
        "commitMessage",
        "repositoryContents",
        "rawRepositoryContents",
        "rawRepositoryTree",
        "treeJson",
        "treeNodes",
        "fileText",
        "fileContents",
        "blob",
        "blobBytes",
        "blobContents",
        "archiveBytes",
        "diffText",
        "absolutePath",
        "rootPath",
        "workingDirectory",
        "cwd",
        "path",
        "paths",
    ] {
        if payload.get(field).is_some() {
            return Err(invalid(format!(
                "{field} is not accepted; import previews store bounded refs and metadata only"
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
        .ok_or_else(|| invalid("import_preview_record requires an idempotencyKey"))
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
            invalid("import preview operations require trusted session or workspace scope")
        })
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    Ok(json!({
        "privacyClass": "import_preview_metadata",
        "policy": "content_free_import_preview_metadata_only",
        "maxAgeDays": max_age_days,
        "archiveKeepsLifecycleEvidence": true
    }))
}

pub(super) fn required_ref(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    let value = payload
        .get(field)
        .ok_or_else(|| invalid(format!("{field} is required")))?;
    sanitize_ref_item(field, value)
}

pub(super) fn required_ref_kind(
    payload: &Value,
    field: &str,
    expected_kind: &str,
    expected_id_prefix: &str,
) -> Result<Value, CapabilityError> {
    let sanitized = required_ref(payload, field)?;
    let actual_kind = sanitized
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{field} requires kind")))?;
    if actual_kind != expected_kind {
        return Err(invalid(format!(
            "{field} must reference {expected_kind} resources only"
        )));
    }
    let actual_id = sanitized
        .get("resourceId")
        .or_else(|| sanitized.get("id"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{field} requires id or resourceId")))?;
    if !actual_id.starts_with(expected_id_prefix) {
        return Err(invalid(format!(
            "{field} id must start with {expected_id_prefix}"
        )));
    }
    Ok(sanitized)
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

pub(super) fn validate_path_entries(items: &[Value]) -> Result<Vec<Value>, CapabilityError> {
    if items.len() > MAX_PATH_ENTRIES {
        return Err(invalid(format!(
            "pathEntries may contain at most {MAX_PATH_ENTRIES} items"
        )));
    }
    items
        .iter()
        .enumerate()
        .map(|(index, value)| sanitize_path_entry(index, value))
        .collect()
}

pub(super) fn preview_counts(
    payload: &Value,
    path_entries_len: usize,
) -> Result<Value, CapabilityError> {
    let total_entries = optional_u64(payload, "totalEntries")?.unwrap_or(path_entries_len as u64);
    if total_entries > MAX_TOTAL_ENTRIES {
        return Err(invalid(format!(
            "totalEntries may not exceed {MAX_TOTAL_ENTRIES}"
        )));
    }
    let added_entries = bounded_count(payload, "addedEntries", total_entries)?;
    let modified_entries = bounded_count(payload, "modifiedEntries", total_entries)?;
    let removed_entries = bounded_count(payload, "removedEntries", total_entries)?;
    let renamed_entries = bounded_count(payload, "renamedEntries", total_entries)?;
    let max_depth = optional_u64(payload, "maxDepth")?
        .unwrap_or_else(|| inferred_depth(payload))
        .min(MAX_DEPTH);
    Ok(json!({
        "totalEntries": total_entries,
        "pathEntriesStored": path_entries_len,
        "addedEntries": added_entries,
        "modifiedEntries": modified_entries,
        "removedEntries": removed_entries,
        "renamedEntries": renamed_entries,
        "maxDepth": max_depth
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

fn sanitize_path_entry(index: usize, value: &Value) -> Result<Value, CapabilityError> {
    let label = format!("pathEntries[{index}]");
    let Value::Object(item) = value else {
        return Err(invalid(format!("{label} must be an object")));
    };
    let path = item
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label}.path is required")))?;
    let kind = item
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    if !matches!(
        kind,
        "file" | "directory" | "symlink" | "submodule" | "unknown"
    ) {
        return Err(invalid(format!("{label}.kind is unsupported")));
    }
    let mut sanitized = Map::new();
    sanitized.insert(
        "path".to_owned(),
        json!(bounded_relative_path(&format!("{label}.path"), path)?),
    );
    sanitized.insert("kind".to_owned(), json!(kind));
    for key in ["mode", "objectRef", "contentHash", "changeKind"] {
        if let Some(value) = item.get(key).and_then(Value::as_str) {
            sanitized.insert(
                key.to_owned(),
                json!(bounded_token(
                    &format!("{label}.{key}"),
                    value,
                    TOKEN_MAX_BYTES
                )?),
            );
        }
    }
    if let Some(size_bytes) = item.get("sizeBytes") {
        let size = size_bytes
            .as_u64()
            .ok_or_else(|| invalid(format!("{label}.sizeBytes must be a positive integer")))?;
        sanitized.insert("sizeBytes".to_owned(), json!(size));
    }
    if item.keys().any(|key| {
        !matches!(
            key.as_str(),
            "path" | "kind" | "mode" | "objectRef" | "contentHash" | "changeKind" | "sizeBytes"
        )
    }) {
        return Err(invalid(format!(
            "{label} may contain only path, kind, mode, objectRef, contentHash, changeKind, and sizeBytes"
        )));
    }
    Ok(Value::Object(sanitized))
}

fn bounded_count(payload: &Value, field: &str, total_entries: u64) -> Result<u64, CapabilityError> {
    let value = optional_u64(payload, field)?.unwrap_or(0);
    if value > total_entries {
        return Err(invalid(format!("{field} may not exceed totalEntries")));
    }
    Ok(value)
}

fn inferred_depth(payload: &Value) -> u64 {
    payload
        .get("pathEntries")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries
                .iter()
                .filter_map(|entry| entry.get("path").and_then(Value::as_str))
                .map(|path| path.split('/').count() as u64)
                .max()
        })
        .unwrap_or(0)
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
