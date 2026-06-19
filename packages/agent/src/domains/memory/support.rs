use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor, VisibilityScope,
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
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
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
    let Some(object) = body_ref.as_object() else {
        return Err(invalid_params("bodyRef must be an object"));
    };
    for forbidden in ["content", "text", "body", "raw"] {
        if object.contains_key(forbidden) {
            return Err(invalid_params(format!(
                "bodyRef must point to private material and cannot include inline {forbidden}"
            )));
        }
    }
    Ok(())
}

pub(super) fn redacted_record_payload(payload: &Value) -> Value {
    json!({
        "schemaVersion": payload.get("schemaVersion").cloned().unwrap_or(Value::Null),
        "subject": payload.get("subject").cloned().unwrap_or(Value::Null),
        "scope": payload.get("scope").cloned().unwrap_or(Value::Null),
        "preview": payload.get("preview").cloned().unwrap_or(Value::Null),
        "bodyRef": redact_body_ref(payload.get("bodyRef").unwrap_or(&Value::Null)),
        "provenance": payload.get("provenance").cloned().unwrap_or(Value::Null),
        "confidence": payload.get("confidence").cloned().unwrap_or(Value::Null),
        "sensitivity": payload.get("sensitivity").cloned().unwrap_or(Value::Null),
        "retention": payload.get("retention").cloned().unwrap_or(Value::Null),
        "expiresAt": payload.get("expiresAt").cloned().unwrap_or(Value::Null),
        "sourceRefs": payload.get("sourceRefs").cloned().unwrap_or(json!([])),
        "traceRefs": payload.get("traceRefs").cloned().unwrap_or(json!([])),
        "replayRefs": payload.get("replayRefs").cloned().unwrap_or(json!([])),
        "lifecycle": payload.get("lifecycle").cloned().unwrap_or(Value::Null),
        "migration": payload.get("migration").cloned().unwrap_or(Value::Null),
        "revision": payload.get("revision").cloned().unwrap_or(Value::Null)
    })
}

fn redact_body_ref(body_ref: &Value) -> Value {
    let kind = body_ref
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    json!({
        "kind": kind,
        "redacted": true,
        "resourceId": body_ref.get("resourceId").cloned().unwrap_or(Value::Null),
        "contentHash": body_ref.get("contentHash").cloned().unwrap_or(Value::Null)
    })
}
