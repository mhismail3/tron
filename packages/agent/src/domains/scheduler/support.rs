use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, internal, invalid_params};
use super::types::{
    IdempotencyRecord, MissedRunMode, RetentionRecord, ScheduleKind, TargetRecord, TriggerKind,
};
use super::{READ_SCOPE, SCHEDULER_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const TITLE_MAX_CHARS: usize = 240;
pub(super) const REASON_MAX_CHARS: usize = 1_000;
pub(super) const TARGET_IDS_MAX: usize = 20;
pub(super) const TARGET_TOKEN_MAX: usize = 96;
pub(super) const MIN_INTERVAL_SECONDS: u64 = 60;
pub(super) const MAX_INTERVAL_SECONDS: u64 = 366 * 24 * 60 * 60;
pub(super) const DEFAULT_MAX_CATCH_UP_RUNS: u32 = 10;
pub(super) const MAX_CATCH_UP_RUNS: u32 = 100;
pub(super) const DEFAULT_MAX_RUN_RECORDS: u32 = 1_000;
pub(super) const MAX_RUN_RECORDS: u32 = 10_000;
pub(super) const DEFAULT_MAX_AGE_DAYS: u32 = 90;
pub(super) const MAX_AGE_DAYS: u32 = 366;

pub(super) fn require_scope(
    invocation: &Invocation,
    scope: &'static str,
) -> Result<(), CapabilityError> {
    if invocation
        .causal_context
        .authority_scopes
        .iter()
        .any(|actual| actual == scope)
    {
        return Ok(());
    }
    Err(invalid_params(format!(
        "scheduler operation requires explicit {scope} authority scope"
    )))
}

pub(super) fn require_read_scope(invocation: &Invocation) -> Result<(), CapabilityError> {
    if invocation
        .causal_context
        .authority_scopes
        .iter()
        .any(|actual| actual == READ_SCOPE || actual == WRITE_SCOPE)
    {
        return Ok(());
    }
    Err(invalid_params(
        "scheduler read requires explicit scheduler.read or scheduler.write authority scope",
    ))
}

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

pub(super) fn optional_string_array(
    payload: &Value,
    field: &str,
    max_items: usize,
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
                    bounded_token(field, text)
                })
                .collect()
        }
        Some(_) => Err(invalid_params(format!("{field} must be an array"))),
    }
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_chars: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid_params(format!("{field} must not be empty")));
    }
    let count = trimmed.chars().count();
    if count > max_chars {
        return Err(invalid_params(format!(
            "{field} is too large: {count} characters exceeds {max_chars}"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(field: &str, value: &str) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.len() > TARGET_TOKEN_MAX
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid_params(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    Ok(trimmed.to_owned())
}

pub(super) fn parse_datetime(value: &str) -> Result<DateTime<Utc>, CapabilityError> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|error| invalid_params(format!("invalid datetime {value}: {error}")))
}

pub(super) fn optional_datetime(
    payload: &Value,
    field: &str,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    optional_string(payload, field)?
        .as_deref()
        .map(parse_datetime)
        .transpose()
}

pub(super) fn list_limit(payload: &Value) -> Result<usize, CapabilityError> {
    Ok(optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX))
}

pub(super) fn parse_schedule_kind(value: Option<String>) -> Result<ScheduleKind, CapabilityError> {
    match value.as_deref().unwrap_or("reminder") {
        "reminder" => Ok(ScheduleKind::Reminder),
        "monitor" => Ok(ScheduleKind::Monitor),
        "automation" => Ok(ScheduleKind::Automation),
        other => Err(invalid_params(format!("unsupported scheduleKind {other}"))),
    }
}

pub(super) fn parse_trigger_kind(value: Option<String>) -> Result<TriggerKind, CapabilityError> {
    match value.as_deref().unwrap_or("once") {
        "once" => Ok(TriggerKind::Once),
        "interval" => Ok(TriggerKind::Interval),
        other => Err(invalid_params(format!("unsupported triggerType {other}"))),
    }
}

pub(super) fn parse_missed_run_mode(
    value: Option<String>,
) -> Result<MissedRunMode, CapabilityError> {
    match value.as_deref().unwrap_or("fire_once") {
        "skip" => Ok(MissedRunMode::Skip),
        "fire_once" => Ok(MissedRunMode::FireOnce),
        "catch_up" => Ok(MissedRunMode::CatchUp),
        other => Err(invalid_params(format!(
            "unsupported missedRunPolicy {other}"
        ))),
    }
}

pub(super) fn parse_target(value: Value) -> Result<TargetRecord, CapabilityError> {
    let resource_kind = bounded_token(
        "target.resourceKind",
        value
            .get("resourceKind")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid_params("target.resourceKind is required"))?,
    )?;
    let action = bounded_token(
        "target.action",
        value
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("record"),
    )?;
    let resource_ids = optional_string_array(&value, "resourceIds", TARGET_IDS_MAX)?;
    Ok(TargetRecord {
        resource_kind,
        action,
        selector_bound: resource_ids.len() as u32,
        resource_ids,
        dispatch: "record_only".to_owned(),
    })
}

pub(super) fn retention(payload: &Value) -> Result<RetentionRecord, CapabilityError> {
    let max_run_records = optional_u64(payload, "maxRunRecords")?
        .map(|value| value as u32)
        .unwrap_or(DEFAULT_MAX_RUN_RECORDS)
        .clamp(1, MAX_RUN_RECORDS);
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .map(|value| value as u32)
        .unwrap_or(DEFAULT_MAX_AGE_DAYS)
        .clamp(1, MAX_AGE_DAYS);
    Ok(RetentionRecord {
        max_run_records,
        max_age_days,
    })
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
    bounded_token(field, value).map(|_| ())
}

pub(super) fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "actorId": invocation.causal_context.actor_id.as_str(),
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "authorityScopes": invocation.causal_context.authority_scopes,
        "resourceAuthority": {
            "read": READ_SCOPE,
            "write": WRITE_SCOPE,
            "wildcardGrantsAllowed": false
        },
        "providerVisibleTargetExecution": "none"
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
    let version = inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)?;
    Some((current.clone(), version.payload.clone()))
}

pub(super) fn to_value<T: Serialize>(value: &T, label: &str) -> Result<Value, CapabilityError> {
    serde_json::to_value(value).map_err(|error| internal(format!("serialize {label}: {error}")))
}

pub(super) async fn publish_lifecycle_event(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    event_type: &'static str,
    payload: Value,
) -> Result<StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: SCHEDULER_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
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

pub(super) fn resource_ref(resource: &EngineResource, relation: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "relation": relation
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    relation: &str,
) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "relation": relation
    })
}
