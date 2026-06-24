use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{
    EngineHostHandle, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, StreamCursor, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::types::{
    ApprovalCheckOutcome, ApprovalCheckRequirement, ApprovalCheckResult, ApprovalDecisionRecord,
    ApprovalDecisionState, ApprovalIdempotency, ApprovalRequestRecord, CHECK_SCHEMA_VERSION,
};
use super::{APPROVAL_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(super) fn decision_state(value: String) -> Result<ApprovalDecisionState, CapabilityError> {
    match value.as_str() {
        "approved" => Ok(ApprovalDecisionState::Approved),
        "denied" => Ok(ApprovalDecisionState::Denied),
        "revoked" => Ok(ApprovalDecisionState::Revoked),
        other => Err(invalid_params(format!(
            "unsupported approval decision state {other}"
        ))),
    }
}

impl ApprovalDecisionState {
    pub(super) fn as_lifecycle(&self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Denied => "denied",
            Self::Revoked => "revoked",
        }
    }
}

pub(super) fn request_mismatch_reason(
    request: &ApprovalRequestRecord,
    requirement: &ApprovalCheckRequirement,
) -> Option<&'static str> {
    if request.action != requirement.action {
        return Some("approval_request_action_mismatch");
    }
    if request.scope != requirement.scope {
        return Some("approval_request_scope_mismatch");
    }
    if request.risk_class != requirement.risk_class {
        return Some("approval_request_risk_mismatch");
    }
    if request.resource_selectors != requirement.resource_selectors {
        return Some("approval_request_resource_selector_mismatch");
    }
    None
}

pub(super) fn decision_mismatch_reason(
    decision: &ApprovalDecisionRecord,
    requirement: &ApprovalCheckRequirement,
) -> Option<&'static str> {
    if decision.action != requirement.action {
        return Some("approval_decision_action_mismatch");
    }
    if decision.scope != requirement.scope {
        return Some("approval_decision_scope_mismatch");
    }
    if decision.risk_class != requirement.risk_class {
        return Some("approval_decision_risk_mismatch");
    }
    if decision.resource_selectors != requirement.resource_selectors {
        return Some("approval_decision_resource_selector_mismatch");
    }
    None
}

pub(super) fn check_result(
    outcome: ApprovalCheckOutcome,
    reason: impl Into<String>,
    explanation: Value,
) -> ApprovalCheckResult {
    let allowed = outcome == ApprovalCheckOutcome::Approved;
    ApprovalCheckResult {
        schema_version: CHECK_SCHEMA_VERSION.to_owned(),
        allowed,
        outcome,
        reason: reason.into(),
        explanation,
    }
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Option<(String, Value)> {
    let current_id = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current_id)
        .map(|version| (version.version_id.clone(), version.payload.clone()))
}

pub(super) fn freshness_stale_at(freshness: &Value) -> Option<DateTime<Utc>> {
    ["staleAt", "freshnessUntil"]
        .iter()
        .find_map(|key| freshness.get(*key).and_then(Value::as_str))
        .and_then(|value| parse_datetime(value).ok())
}

pub(super) async fn publish_lifecycle_event(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    event_type: &str,
    payload: Value,
) -> Result<StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: APPROVAL_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
                "approvalIsAuthority": false,
                "executionAuthoritySource": "engine_authority_grant",
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

pub(super) fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
    if let Some(session_id) = &invocation.causal_context.session_id {
        EngineResourceScope::Session(session_id.clone())
    } else if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        EngineResourceScope::Workspace(workspace_id.clone())
    } else {
        EngineResourceScope::System
    }
}

pub(super) fn approval_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "approvalIsAuthority": false,
        "executionAuthoritySource": "engine_authority_grant"
    })
}

pub(super) fn requester(invocation: &Invocation) -> Value {
    json!({
        "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
        "actorId": invocation.causal_context.actor_id.as_str(),
        "functionId": invocation.function_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "sessionId": invocation.causal_context.session_id,
        "workspaceId": invocation.causal_context.workspace_id
    })
}

pub(super) fn idempotency(invocation: &Invocation) -> ApprovalIdempotency {
    ApprovalIdempotency {
        key: invocation.causal_context.idempotency_key.clone(),
        invocation_id: invocation.id.as_str().to_owned(),
        function_id: invocation.function_id.as_str().to_owned(),
    }
}

pub(super) fn with_trace_ref(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.push(json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    }));
    refs
}

pub(super) fn with_replay_ref(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.push(json!({
        "source": "engine_invocation_ledger",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    }));
    refs
}

pub(super) fn resource_ref(resource: &EngineResource, label: &str) -> Value {
    json!({
        "role": label,
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
    label: &str,
) -> Value {
    json!({
        "role": label,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle
    })
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

pub(super) fn required_object(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    let value = optional_object(payload, field)?
        .ok_or_else(|| invalid_params(format!("{field} is required")))?;
    if value.as_object().is_some_and(|object| !object.is_empty()) {
        Ok(value)
    } else {
        Err(invalid_params(format!(
            "{field} must be a non-empty object"
        )))
    }
}

pub(super) fn optional_object(
    payload: &Value,
    field: &str,
) -> Result<Option<Value>, CapabilityError> {
    payload
        .get(field)
        .map(|value| {
            if value.as_object().is_some() {
                Ok(value.clone())
            } else {
                Err(invalid_params(format!("{field} must be an object")))
            }
        })
        .transpose()
}

pub(super) fn optional_array(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    payload
        .get(field)
        .map(|value| {
            value
                .as_array()
                .cloned()
                .ok_or_else(|| invalid_params(format!("{field} must be an array")))
        })
        .transpose()
        .map(Option::unwrap_or_default)
}

pub(super) fn required_datetime(
    payload: &Value,
    field: &str,
) -> Result<DateTime<Utc>, CapabilityError> {
    let value = required_string(payload, field)?;
    parse_datetime(&value).map_err(|err| invalid_params(format!("{field} must be RFC3339: {err}")))
}

pub(super) fn optional_datetime(
    payload: &Value,
    field: &str,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    optional_string(payload, field)?
        .map(|value| {
            parse_datetime(&value)
                .map_err(|err| invalid_params(format!("{field} must be RFC3339: {err}")))
        })
        .transpose()
}

fn parse_datetime(value: &str) -> Result<DateTime<Utc>, chrono::ParseError> {
    DateTime::parse_from_rfc3339(value).map(|value| value.with_timezone(&Utc))
}

pub(super) fn to_value<T: Serialize>(value: &T, label: &str) -> Result<Value, CapabilityError> {
    serde_json::to_value(value)
        .map_err(|err| invalid_params(format!("failed to serialize {label}: {err}")))
}

pub(super) fn merge_arrays(mut left: Vec<Value>, right: Vec<Value>) -> Vec<Value> {
    left.extend(right);
    left
}

pub(super) trait EmptyVecFallback {
    fn if_empty_then(self, fallback: Vec<Value>) -> Vec<Value>;
}

impl EmptyVecFallback for Vec<Value> {
    fn if_empty_then(self, fallback: Vec<Value>) -> Vec<Value> {
        if self.is_empty() { fallback } else { self }
    }
}
