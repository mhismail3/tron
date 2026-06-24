use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, internal, invalid_params};
use super::types::{IdempotencyRecord, QuestionState};
use super::{GOALS_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const OBJECTIVE_MAX_CHARS: usize = 2_000;
pub(super) const PROMPT_MAX_CHARS: usize = 4_000;
pub(super) const ANSWER_MAX_CHARS: usize = 8_000;
pub(super) const REASON_MAX_CHARS: usize = 1_000;
pub(super) const SUMMARY_MAX_CHARS: usize = 240;

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    let value = optional_string(payload, field)?
        .ok_or_else(|| invalid_params(format!("{field} is required")))?;
    if value.trim().is_empty() {
        return Err(invalid_params(format!("{field} must not be empty")));
    }
    Ok(value)
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

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid_params(format!("{field} must be a boolean"))),
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

pub(super) fn list_limit(payload: &Value) -> Result<usize, CapabilityError> {
    Ok(optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX))
}

pub(super) fn optional_array(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => Ok(items.clone()),
        Some(_) => Err(invalid_params(format!("{field} must be an array"))),
    }
}

pub(super) fn optional_string_array(
    payload: &Value,
    field: &str,
    max_items: usize,
    max_chars: usize,
) -> Result<Vec<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => {
            if items.len() > max_items {
                return Err(invalid_params(format!("{field} has too many entries")));
            }
            items
                .iter()
                .map(|value| {
                    let Some(text) = value.as_str() else {
                        return Err(invalid_params(format!("{field} entries must be strings")));
                    };
                    bounded_text(field, text, 1, max_chars)
                })
                .collect()
        }
        Some(_) => Err(invalid_params(format!("{field} must be an array"))),
    }
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
        .map_err(|error| invalid_params(format!("invalid {value}: {error}")))
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    min_chars: usize,
    max_chars: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    let count = trimmed.chars().count();
    if count < min_chars {
        return Err(invalid_params(format!("{field} must not be empty")));
    }
    if count > max_chars {
        return Err(invalid_params(format!(
            "{field} is too large: {count} characters exceeds {max_chars}"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn truncate(value: &str, max_chars: usize) -> (String, bool) {
    let mut out = String::new();
    let mut truncated = false;
    for (index, ch) in value.chars().enumerate() {
        if index >= max_chars {
            truncated = true;
            break;
        }
        out.push(ch);
    }
    (out, truncated)
}

pub(super) fn validate_resource_id(
    field: &str,
    value: &str,
    required_prefix: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with(required_prefix) {
        return Err(invalid_params(format!(
            "{field} must start with {required_prefix}"
        )));
    }
    if value.len() > 160
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid_params(format!("{field} is malformed")));
    }
    Ok(())
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

pub(super) fn ensure_scope(
    invocation: &Invocation,
    actual: &EngineResourceScope,
) -> Result<(), CapabilityError> {
    let expected = resource_scope(invocation);
    if &expected != actual {
        return Err(invalid_params(format!(
            "resource scope mismatch: expected {}:{}, actual {}:{}",
            expected.kind(),
            expected.value(),
            actual.kind(),
            actual.value()
        )));
    }
    Ok(())
}

pub(super) fn scope_record(invocation: &Invocation) -> Value {
    json!({
        "kind": resource_scope(invocation).kind(),
        "value": resource_scope(invocation).value(),
        "sessionId": invocation.causal_context.session_id,
        "workspaceId": invocation.causal_context.workspace_id
    })
}

pub(super) fn actor_record(invocation: &Invocation) -> Value {
    json!({
        "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
        "actorId": invocation.causal_context.actor_id.as_str(),
        "functionId": invocation.function_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "sessionId": invocation.causal_context.session_id,
        "workspaceId": invocation.causal_context.workspace_id
    })
}

pub(super) fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "actorId": invocation.causal_context.actor_id.as_str(),
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "authorityScopes": invocation.causal_context.authority_scopes,
        "answerDoesNotMintAuthority": true
    })
}

pub(super) fn idempotency(invocation: &Invocation) -> IdempotencyRecord {
    IdempotencyRecord {
        key: invocation.causal_context.idempotency_key.clone(),
        invocation_id: invocation.id.as_str().to_owned(),
        function_id: invocation.function_id.as_str().to_owned(),
    }
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

pub(super) fn resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "redaction": "bounded_summary_only"
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

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "role": role,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle
    })
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
        "contentHash": version.content_hash,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle
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
            topic: GOALS_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
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

pub(super) fn to_value<T: Serialize>(value: &T, label: &str) -> Result<Value, CapabilityError> {
    serde_json::to_value(value).map_err(|error| internal(format!("serialize {label}: {error}")))
}

pub(super) fn question_terminal_error(state: &QuestionState) -> CapabilityError {
    invalid_params(format!(
        "question is closed and cannot be answered: {}",
        state.as_str()
    ))
}
