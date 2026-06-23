use std::path::PathBuf;

use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, RUNTIME_METADATA_WORKING_DIRECTORY,
    StreamCursor, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::JOB_PROCESS_KIND;
use super::errors::{engine_error, internal, invalid_params};
use super::types::{JOB_SCHEMA_VERSION, JobProcessRecord};
use super::{JOBS_LIFECYCLE_TOPIC, WORKER};

pub(super) const DEFAULT_JOB_TIMEOUT_MS: u64 = 30_000;
pub(super) const MAX_JOB_TIMEOUT_MS: u64 = 120_000;
pub(super) const DEFAULT_OUTPUT_BYTES: usize = 20_000;
pub(super) const MAX_OUTPUT_BYTES: usize = 200_000;
pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 500;

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid_params(format!("missing {field}")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid_params(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid_params(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid_params(format!(
            "{field} must be a positive integer"
        ))),
    }
}

pub(super) fn timeout_ms(payload: &Value) -> Result<u64, CapabilityError> {
    Ok(optional_u64(payload, "timeoutMs")?
        .unwrap_or(DEFAULT_JOB_TIMEOUT_MS)
        .clamp(1, MAX_JOB_TIMEOUT_MS))
}

pub(super) fn max_output_bytes(payload: &Value) -> Result<usize, CapabilityError> {
    Ok(optional_u64(payload, "maxOutputBytes")?
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_OUTPUT_BYTES)
        .clamp(1, MAX_OUTPUT_BYTES))
}

pub(super) fn list_limit(payload: &Value) -> Result<usize, CapabilityError> {
    Ok(optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX))
}

pub(super) fn trusted_working_directory(
    invocation: &Invocation,
) -> Result<PathBuf, CapabilityError> {
    let raw = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .ok_or_else(|| invalid_params("job_start requires trusted working directory metadata"))?;
    crate::shared::foundation::paths::normalize_working_directory(raw).map_err(internal)
}

pub(super) fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
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
        .unwrap_or(EngineResourceScope::System)
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
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
}

pub(super) fn resource_policy() -> Value {
    json!({
        "owner": WORKER,
        "retention": "explicit",
        "redaction": {"stdout": "preview_only", "stderr": "preview_only"}
    })
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Option<(String, Value)> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| (version.version_id.clone(), version.payload.clone()))
}

pub(super) async fn require_job(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let job_resource_id = required_string(payload, "jobResourceId")?;
    let inspection = engine_host
        .inspect_resource(&job_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("job resource {job_resource_id} was not found")))?;
    if inspection.resource.kind != JOB_PROCESS_KIND {
        return Err(invalid_params(format!(
            "resource {job_resource_id} is not a job_process resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(inspection)
}

pub(super) fn job_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, JobProcessRecord), CapabilityError> {
    let (version_id, payload) =
        current_payload(inspection).ok_or_else(|| invalid_params("job resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| internal(format!("decode job resource payload: {error}")))?;
    Ok((version_id, record))
}

pub(super) fn already_terminal_response(
    resource: &EngineResource,
    current_version_id: &str,
    record: &JobProcessRecord,
) -> Value {
    json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": "already_terminal",
        "state": record.state.as_str(),
        "jobResourceId": resource.resource_id,
        "jobVersionId": current_version_id,
        "idempotent": true,
        "resourceRefs": [resource_ref(resource, "job_process")]
    })
}

fn ensure_scope(
    invocation: &Invocation,
    resource_scope_value: &EngineResourceScope,
) -> Result<(), CapabilityError> {
    let expected = resource_scope(invocation);
    if &expected != resource_scope_value {
        return Err(invalid_params("job resource is outside invocation scope"));
    }
    Ok(())
}

pub(super) fn to_value<T: Serialize>(value: &T, label: &str) -> Result<Value, CapabilityError> {
    serde_json::to_value(value).map_err(|error| internal(format!("serialize {label}: {error}")))
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

pub(super) async fn publish_lifecycle_event(
    engine_host: &crate::engine::EngineHostHandle,
    invocation: &Invocation,
    event_type: &str,
    payload: Value,
) -> Result<StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: JOBS_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
                "payload": payload
            }),
            visibility: VisibilityScope::Session,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}
