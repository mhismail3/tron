use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceEvent, EngineResourceInspection,
    EngineResourceScope, EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor,
    VisibilityScope,
};
use crate::shared::protocol::memory::{MemoryMode, MemoryResourceRef};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::{MEMORY_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(super) fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
    if let Some(session_id) = &invocation.causal_context.session_id {
        EngineResourceScope::Session(session_id.clone())
    } else if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        EngineResourceScope::Workspace(workspace_id.clone())
    } else {
        EngineResourceScope::System
    }
}

pub(super) fn policy_scope_candidates(invocation: &Invocation) -> Vec<EngineResourceScope> {
    let mut scopes = Vec::new();
    if let Some(session_id) = &invocation.causal_context.session_id {
        scopes.push(EngineResourceScope::Session(session_id.clone()));
    }
    if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        scopes.push(EngineResourceScope::Workspace(workspace_id.clone()));
    }
    scopes.push(EngineResourceScope::System);
    scopes
}

pub(super) fn policy_resource_id(scope: &EngineResourceScope) -> String {
    match scope {
        EngineResourceScope::System => "memory_policy:system".to_owned(),
        EngineResourceScope::Workspace(workspace_id) => {
            format!("memory_policy:workspace:{workspace_id}")
        }
        EngineResourceScope::Session(session_id) => format!("memory_policy:session:{session_id}"),
    }
}

pub(super) fn engine_resource_id(engine_id: &str) -> String {
    format!("memory_engine:{engine_id}")
}

pub(super) fn memory_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "promptContentPolicy": "record refs and redacted previews only"
    })
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Option<(String, Value)> {
    let current_id = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current_id)
        .map(|version| (version.version_id.clone(), version.payload.clone()))
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> MemoryResourceRef {
    MemoryResourceRef {
        kind: resource.kind.clone(),
        resource_id: resource.resource_id.clone(),
        version_id: resource.current_version_id.clone(),
        role: role.to_owned(),
    }
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "role": role,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "contentHash": version.content_hash
    })
}

pub(super) async fn publish_lifecycle_event(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    event_type: &str,
    payload: Value,
) -> Result<StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: MEMORY_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
                "memoryContractOnly": true,
                "algorithm": "none",
                "authorityGrant": {
                    "rawIdIncluded": false,
                    "present": true
                },
                "actorId": invocation.causal_context.actor_id.as_str(),
                "payload": payload
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid_params(format!("{field} is required")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    payload
        .get(field)
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.trim().is_empty())
                .map(str::to_owned)
                .ok_or_else(|| invalid_params(format!("{field} must be a non-empty string")))
        })
        .transpose()
}

pub(super) fn optional_array(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => Ok(items.clone()),
        Some(_) => Err(invalid_params(format!("{field} must be an array"))),
    }
}

pub(super) fn required_object(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    optional_object(payload, field)?.ok_or_else(|| invalid_params(format!("{field} is required")))
}

pub(super) fn optional_object(
    payload: &Value,
    field: &str,
) -> Result<Option<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(_)) => Ok(Some(payload[field].clone())),
        Some(_) => Err(invalid_params(format!("{field} must be an object"))),
    }
}

pub(super) fn optional_datetime(
    payload: &Value,
    field: &str,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    optional_string(payload, field)?
        .map(|value| parse_datetime(&value))
        .transpose()
}

pub(super) fn parse_datetime(value: &str) -> Result<DateTime<Utc>, CapabilityError> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|err| invalid_params(format!("invalid datetime {value}: {err}")))
}

pub(super) fn mode_from_payload(payload: &Value) -> Result<MemoryMode, CapabilityError> {
    let mode = required_string(payload, "mode")?;
    mode.parse::<MemoryMode>().map_err(invalid_params)
}

pub(super) fn to_value<T: Serialize>(
    value: &T,
    label: &'static str,
) -> Result<Value, CapabilityError> {
    serde_json::to_value(value)
        .map_err(|err| invalid_params(format!("failed to serialize {label}: {err}")))
}

pub(super) fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

pub(super) fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "source": "engine_invocation_ledger",
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str()
    })]
}

pub(super) fn ensure_body_ref_is_pointer(body_ref: &Value) -> Result<(), CapabilityError> {
    if !body_ref.is_object() {
        return Err(invalid_params("bodyRef must be an object"));
    }
    ensure_body_ref_has_no_inline_content(body_ref, "bodyRef")
}

pub(super) fn provider_safe_optional_string(text: &str, max_bytes: usize) -> Option<String> {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.trim().is_empty() || provider_text_is_unsafe(&compact) {
        None
    } else {
        Some(truncate_utf8(&compact, max_bytes))
    }
}

pub(super) fn ensure_provider_safe_text(text: &str, field: &str) -> Result<(), CapabilityError> {
    if provider_text_is_unsafe(text) {
        return Err(invalid_params(format!(
            "{field} cannot contain secret-like material or unsafe paths"
        )));
    }
    Ok(())
}

fn provider_text_is_unsafe(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("bearer ")
        || lower.contains("authorization:")
        || lower.contains("secret=")
        || lower.contains("secret:")
        || lower.contains("token=")
        || lower.contains("token:")
        || lower.starts_with("sk-")
        || text.starts_with('/')
        || text.starts_with("~/")
        || text.contains("://")
        || text.contains(":/")
        || text.contains(":\\")
        || text.contains("../")
        || text.contains("..\\")
}

pub(super) fn truncate_utf8(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_owned();
    }
    let budget = max_bytes.saturating_sub(3);
    let mut end = 0;
    for (index, _) in text.char_indices() {
        if index > budget {
            break;
        }
        end = index;
    }
    if end == 0 {
        "...".to_owned()
    } else {
        format!("{}...", &text[..end])
    }
}

fn ensure_body_ref_has_no_inline_content(value: &Value, path: &str) -> Result<(), CapabilityError> {
    match value {
        Value::Object(object) => {
            for (key, nested) in object {
                let nested_path = format!("{path}.{key}");
                if matches!(key.as_str(), "content" | "text" | "body" | "raw") {
                    return Err(invalid_params(format!(
                        "bodyRef must point to private material and cannot include inline {key} at {nested_path}"
                    )));
                }
                ensure_body_ref_has_no_inline_content(nested, &nested_path)?;
            }
        }
        Value::Array(items) => {
            for (index, nested) in items.iter().enumerate() {
                ensure_body_ref_has_no_inline_content(nested, &format!("{path}[{index}]"))?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn redacted_record_payload(payload: &Value) -> Value {
    json!({
        "schemaVersion": payload.get("schemaVersion").cloned().unwrap_or(Value::Null),
        "subject": redacted_text_field(payload, "subject", 96),
        "scope": redacted_scope(payload.get("scope").unwrap_or(&Value::Null)),
        "preview": redacted_text_field(payload, "preview", 512),
        "bodyRef": redact_body_ref(payload.get("bodyRef").unwrap_or(&Value::Null)),
        "provenance": provider_safe_projection(payload.get("provenance").unwrap_or(&Value::Null), 160, 3),
        "confidence": provider_safe_projection(payload.get("confidence").unwrap_or(&Value::Null), 80, 2),
        "sensitivity": redacted_text_field(payload, "sensitivity", 48),
        "retention": provider_safe_projection(payload.get("retention").unwrap_or(&Value::Null), 160, 3),
        "expiresAt": payload.get("expiresAt").cloned().unwrap_or(Value::Null),
        "sourceRefs": provider_safe_projection(payload.get("sourceRefs").unwrap_or(&json!([])), 160, 3),
        "traceRefs": provider_safe_projection(payload.get("traceRefs").unwrap_or(&json!([])), 160, 3),
        "replayRefs": provider_safe_projection(payload.get("replayRefs").unwrap_or(&json!([])), 160, 3),
        "lifecycle": provider_safe_projection(payload.get("lifecycle").unwrap_or(&Value::Null), 160, 3),
        "migration": provider_safe_projection(payload.get("migration").unwrap_or(&Value::Null), 160, 3),
        "revision": payload.get("revision").cloned().unwrap_or(Value::Null),
        "redaction": {
            "providerSafeProjection": true,
            "rawBodyPointerIncluded": false,
            "unsafeTextRedacted": true
        }
    })
}

pub(super) fn redacted_resource_projection(resource: &EngineResource) -> Value {
    let safe_resource_id = provider_safe_optional_string(&resource.resource_id, 128);
    json!({
        "resourceId": safe_resource_id.clone().map(Value::String).unwrap_or_else(redacted_unsafe_text),
        "resourceIdRedacted": safe_resource_id.is_none(),
        "kind": resource.kind.clone(),
        "schemaId": resource.schema_id.clone(),
        "scope": {
            "kind": resource.scope.kind(),
            "idPresent": !resource.scope.value().is_empty(),
            "rawIdIncluded": false
        },
        "lifecycle": resource.lifecycle.clone(),
        "currentVersionId": resource.current_version_id.clone(),
        "policy": provider_safe_projection(&resource.policy, 120, 2),
        "createdAt": resource.created_at,
        "updatedAt": resource.updated_at,
        "redaction": {
            "ownerActorIdIncluded": false,
            "traceIdIncluded": false,
            "invocationIdIncluded": false
        }
    })
}

pub(super) fn redacted_resource_events(events: &[EngineResourceEvent]) -> Vec<Value> {
    events
        .iter()
        .map(|event| {
            json!({
                "eventId": provider_safe_optional_string(&event.event_id, 96)
                    .map(Value::String)
                    .unwrap_or_else(redacted_unsafe_text),
                "resourceId": provider_safe_optional_string(&event.resource_id, 128)
                    .map(Value::String)
                    .unwrap_or_else(redacted_unsafe_text),
                "eventType": provider_safe_optional_string(&event.event_type, 64)
                    .map(Value::String)
                    .unwrap_or_else(redacted_unsafe_text),
                "payload": provider_safe_projection(&event.payload, 120, 2),
                "occurredAt": event.occurred_at,
                "redaction": {
                    "authorityMetadataIncluded": false,
                    "traceIdIncluded": false,
                    "invocationIdIncluded": false
                }
            })
        })
        .collect()
}

fn redact_body_ref(body_ref: &Value) -> Value {
    let kind = body_ref
        .get("kind")
        .and_then(Value::as_str)
        .and_then(|value| provider_safe_optional_string(value, 48))
        .unwrap_or_else(|| "unknown".to_owned());
    json!({
        "kind": kind,
        "redacted": true,
        "resourceIdPresent": body_ref.get("resourceId").is_some(),
        "contentHashPresent": body_ref.get("contentHash").is_some(),
        "rawPointerIncluded": false
    })
}

fn redacted_scope(scope: &Value) -> Value {
    match scope {
        Value::Object(object) => json!({
            "kind": object
                .get("kind")
                .and_then(Value::as_str)
                .and_then(|value| provider_safe_optional_string(value, 48))
                .unwrap_or_else(|| "unknown".to_owned()),
            "idPresent": object.get("id").is_some(),
            "rawIdIncluded": false
        }),
        _ => Value::Null,
    }
}

fn redacted_text_field(payload: &Value, field: &str, max_bytes: usize) -> Value {
    match payload.get(field).and_then(Value::as_str) {
        Some(text) => provider_safe_optional_string(text, max_bytes)
            .map(Value::String)
            .unwrap_or_else(redacted_unsafe_text),
        None => Value::Null,
    }
}

pub(super) fn provider_safe_projection(
    value: &Value,
    max_text_bytes: usize,
    depth: usize,
) -> Value {
    if depth == 0 {
        return redacted_projection_depth();
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        Value::String(text) => provider_safe_optional_string(text, max_text_bytes)
            .map(Value::String)
            .unwrap_or_else(redacted_unsafe_text),
        Value::Array(items) => Value::Array(
            items
                .iter()
                .take(16)
                .map(|item| provider_safe_projection(item, max_text_bytes, depth - 1))
                .collect(),
        ),
        Value::Object(object) => {
            let mut projected = Map::new();
            for (key, child) in object.iter().take(32) {
                if provider_projection_key_is_sensitive(key) {
                    continue;
                }
                if let Some(safe_key) = provider_safe_optional_string(key, 64) {
                    projected.insert(
                        safe_key,
                        provider_safe_projection(child, max_text_bytes, depth - 1),
                    );
                }
            }
            Value::Object(projected)
        }
    }
}

fn provider_projection_key_is_sensitive(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    if normalized.contains("authority")
        || normalized.contains("grantid")
        || normalized.contains("grantidentifier")
    {
        return true;
    }
    matches!(
        normalized.as_str(),
        "grantmetadata" | "actorid" | "owneractorid" | "subjectactorid"
    )
}

fn redacted_unsafe_text() -> Value {
    json!({
        "redacted": true,
        "reason": "provider_unsafe_text"
    })
}

fn redacted_projection_depth() -> Value {
    json!({
        "redacted": true,
        "reason": "projection_depth_limit"
    })
}
