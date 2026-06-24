use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{
    EngineError, EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor, UpdateResource,
    VisibilityScope, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::types::{AnswerRecord, AuthorityRecord, GoalRecord, IdempotencyRecord, QuestionRecord};
use super::{GOAL_KIND, GOALS_LIFECYCLE_TOPIC, USER_QUESTION_KIND, WORKER};

pub(super) const DEFAULT_LIST_LIMIT: usize = 50;
pub(super) const MAX_LIST_LIMIT: usize = 500;
pub(super) const MAX_TEXT_CHARS: usize = 8_000;
pub(super) const SUMMARY_CHARS: usize = 240;

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    let value =
        optional_string(payload, field)?.ok_or_else(|| invalid(format!("missing {field}")))?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if trimmed.chars().count() > MAX_TEXT_CHARS {
        return Err(invalid(format!(
            "{field} exceeds {MAX_TEXT_CHARS} character limit"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn required_reason(payload: &Value) -> Result<String, CapabilityError> {
    required_string(payload, "reason")
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_bool(
    payload: &Value,
    field: &str,
    default: bool,
) -> Result<bool, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn string_array(payload: &Value, field: &str) -> Result<Vec<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| match value {
                Value::String(text) if !text.trim().is_empty() => {
                    Ok(truncate_chars(text.trim(), SUMMARY_CHARS).0)
                }
                Value::String(_) => Err(invalid(format!("{field} entries must not be empty"))),
                _ => Err(invalid(format!("{field} entries must be strings"))),
            })
            .collect(),
        Some(_) => Err(invalid(format!("{field} must be an array of strings"))),
    }
}

pub(super) fn value_array(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(values)) => Ok(values.clone()),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn object_value(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(json!({})),
        Some(Value::Object(_)) => Ok(payload[field].clone()),
        Some(_) => Err(invalid(format!("{field} must be an object"))),
    }
}

pub(super) fn list_limit(payload: &Value) -> Result<usize, CapabilityError> {
    match payload.get("limit") {
        None | Some(Value::Null) => Ok(DEFAULT_LIST_LIMIT),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(|value| (value as usize).clamp(1, MAX_LIST_LIMIT))
            .ok_or_else(|| invalid("limit must be a positive integer")),
        Some(_) => Err(invalid("limit must be a positive integer")),
    }
}

pub(super) fn expected_question_version(payload: &Value) -> Result<String, CapabilityError> {
    required_string(payload, "expectedQuestionVersionId")
}

pub(super) fn idempotency(invocation: &Invocation, payload: &Value) -> IdempotencyRecord {
    IdempotencyRecord {
        key: invocation.causal_context.idempotency_key.clone(),
        payload_key: payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

pub(super) fn authority(invocation: &Invocation) -> AuthorityRecord {
    AuthorityRecord {
        actor_id: invocation.causal_context.actor_id.as_str().to_owned(),
        authority_grant_id: invocation
            .causal_context
            .authority_grant_id
            .as_str()
            .to_owned(),
        authority_scopes: invocation.causal_context.authority_scopes.clone(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    }
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
    scope: &EngineResourceScope,
    noun: &str,
) -> Result<(), CapabilityError> {
    let expected = resource_scope(invocation);
    if &expected != scope {
        return Err(invalid(format!(
            "{noun} resource is outside invocation scope"
        )));
    }
    Ok(())
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
        "retention": "project",
        "redaction": {"text": "bounded_preview"}
    })
}

pub(super) fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
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

pub(super) fn goal_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, GoalRecord), CapabilityError> {
    let (version_id, payload) =
        current_payload(inspection).ok_or_else(|| invalid("goal resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| internal(format!("decode goal resource payload: {error}")))?;
    Ok((version_id, record))
}

pub(super) fn question_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, QuestionRecord), CapabilityError> {
    let (version_id, payload) =
        current_payload(inspection).ok_or_else(|| invalid("question resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| internal(format!("decode question resource payload: {error}")))?;
    Ok((version_id, record))
}

pub(super) async fn require_goal(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let goal_resource_id = required_string(payload, "goalResourceId")?;
    let inspection = engine_host
        .inspect_resource(&goal_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("goal resource {goal_resource_id} was not found")))?;
    if inspection.resource.kind != GOAL_KIND {
        return Err(invalid(format!(
            "resource {goal_resource_id} is not a goal resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope, "goal")?;
    Ok(inspection)
}

pub(super) async fn require_question(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let question_resource_id = required_string(payload, "questionResourceId")?;
    let inspection = engine_host
        .inspect_resource(&question_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| {
            invalid(format!(
                "question resource {question_resource_id} was not found"
            ))
        })?;
    if inspection.resource.kind != USER_QUESTION_KIND {
        return Err(invalid(format!(
            "resource {question_resource_id} is not a user_question resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope, "question")?;
    Ok(inspection)
}

pub(super) fn goal_summary(
    resource: &EngineResource,
    version_id: &str,
    record: &GoalRecord,
) -> Value {
    let (objective_preview, objective_truncated) = truncate_chars(&record.objective, SUMMARY_CHARS);
    json!({
        "goalResourceId": resource.resource_id,
        "goalVersionId": version_id,
        "state": record.state.as_str(),
        "objectivePreview": objective_preview,
        "objectiveTruncated": objective_truncated,
        "queueRefs": bounded_values(&record.queue_refs, 8).0,
        "queueRefsTruncated": bounded_values(&record.queue_refs, 8).1,
        "questionCount": record.question_refs.len(),
        "answerCount": record.answer_refs.len(),
        "revision": record.revision,
        "createdAt": record.created_at,
        "updatedAt": record.updated_at
    })
}

pub(super) fn question_summary(
    resource: &EngineResource,
    version_id: &str,
    record: &QuestionRecord,
) -> Value {
    let (prompt_preview, prompt_truncated) = truncate_chars(&record.prompt, SUMMARY_CHARS);
    json!({
        "questionResourceId": resource.resource_id,
        "questionVersionId": version_id,
        "goalResourceId": record.goal_resource_id,
        "state": record.state.as_str(),
        "promptPreview": prompt_preview,
        "promptTruncated": prompt_truncated,
        "expiresAt": record.expires_at,
        "revision": record.revision,
        "createdAt": record.created_at,
        "updatedAt": record.updated_at
    })
}

pub(super) fn bounded_values(values: &[Value], limit: usize) -> (Vec<Value>, bool) {
    let truncated = values.len() > limit;
    (values.iter().take(limit).cloned().collect(), truncated)
}

pub(super) fn truncate_chars(text: &str, max_chars: usize) -> (String, bool) {
    let mut iter = text.chars();
    let truncated: String = iter.by_ref().take(max_chars).collect();
    let was_truncated = iter.next().is_some();
    (truncated, was_truncated)
}

pub(super) fn to_value<T: Serialize>(value: &T, label: &str) -> Result<Value, CapabilityError> {
    serde_json::to_value(value).map_err(|error| internal(format!("serialize {label}: {error}")))
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

pub(super) async fn update_goal_record(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    goal_resource_id: &str,
    expected_current_version_id: Option<String>,
    record: &GoalRecord,
) -> Result<EngineResourceVersion, CapabilityError> {
    engine_host
        .update_resource(UpdateResource {
            resource_id: goal_resource_id.to_owned(),
            expected_current_version_id,
            lifecycle: Some(record.state.as_str().to_owned()),
            payload: to_value(record, "goal update")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

pub(super) async fn update_question_record(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    question_resource_id: &str,
    expected_current_version_id: Option<String>,
    record: &QuestionRecord,
) -> Result<EngineResourceVersion, CapabilityError> {
    engine_host
        .update_resource(UpdateResource {
            resource_id: question_resource_id.to_owned(),
            expected_current_version_id,
            lifecycle: Some(record.state.as_str().to_owned()),
            payload: to_value(record, "question update")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

pub(super) fn malformed_id(
    value: &str,
    expected_prefix: &str,
    label: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with(expected_prefix)
        || value.chars().any(char::is_whitespace)
        || value.contains("..")
    {
        return Err(invalid(format!("{label} is malformed")));
    }
    Ok(())
}

pub(super) fn answer_summary(
    record: &AnswerRecord,
    resource: &EngineResource,
    version: &EngineResourceVersion,
) -> Value {
    json!({
        "answerResourceId": resource.resource_id,
        "answerVersionId": version.version_id,
        "questionResourceId": record.question_resource_id,
        "goalResourceId": record.goal_resource_id,
        "textPreview": record.text_preview,
        "textTruncated": record.text_truncated,
        "reason": record.reason,
        "createdAt": record.created_at,
        "revision": record.revision
    })
}

pub(super) fn engine_error(error: EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
