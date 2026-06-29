use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineHostHandle, Invocation, LinkResources, UpdateResource, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::explanation::{decision_explanation, request_explanation, requirement_summary};
use super::support::*;
use super::types::{
    ApprovalCheckOutcome, ApprovalCheckRequirement, ApprovalCheckResult, ApprovalDecisionRecord,
    ApprovalDecisionRevision, ApprovalDecisionState, ApprovalRequestRecord,
    ApprovalRequestRevision, ApprovalRequestState, DECISION_SCHEMA_VERSION, REQUEST_SCHEMA_VERSION,
};
use super::{
    APPROVAL_DECISION_KIND, APPROVAL_DECISION_SCHEMA_ID, APPROVAL_REQUEST_KIND,
    APPROVAL_REQUEST_SCHEMA_ID, WORKER,
};

/// Create a durable approval request resource and lifecycle stream event.
pub(crate) async fn request_approval_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let now = Utc::now();
    let request = ApprovalRequestRecord {
        schema_version: REQUEST_SCHEMA_VERSION.to_owned(),
        state: ApprovalRequestState::Pending,
        requester: optional_object(payload, "requester")?.unwrap_or_else(|| requester(invocation)),
        action: required_object(payload, "action")?,
        scope: required_object(payload, "scope")?,
        risk_class: required_string(payload, "riskClass")?,
        created_at: now,
        expires_at: required_datetime(payload, "expiresAt")?,
        freshness: optional_object(payload, "freshness")?.unwrap_or_else(|| json!({})),
        evidence_refs: optional_array(payload, "evidenceRefs")?,
        resource_selectors: optional_array(payload, "resourceSelectors")?,
        trace_refs: with_trace_ref(optional_array(payload, "traceRefs")?, invocation),
        replay_refs: with_replay_ref(optional_array(payload, "replayRefs")?, invocation),
        denial_behavior: required_object(payload, "denialBehavior")?,
        idempotency: idempotency(invocation),
        revision: ApprovalRequestRevision {
            number: 1,
            current_version_id: None,
        },
    };
    if request.risk_class.trim().is_empty() {
        return Err(invalid_params("riskClass must not be empty"));
    }

    let request_payload = to_value(&request, "approval request")?;
    let resource_id = optional_string(payload, "requestId")?
        .unwrap_or_else(|| format!("{APPROVAL_REQUEST_KIND}:{}", invocation.id.as_str()));
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: APPROVAL_REQUEST_KIND.to_owned(),
            schema_id: Some(APPROVAL_REQUEST_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("pending".to_owned()),
            policy: approval_policy("request"),
            initial_payload: Some(request_payload.clone()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let request_version_id = resource.current_version_id.clone().ok_or_else(|| {
        invalid_params("approval request resource was created without an initial version")
    })?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "approval.requested",
        json!({
            "requestResourceId": resource.resource_id,
            "requestVersionId": request_version_id,
            "state": "pending",
            "riskClass": request.risk_class,
            "action": request.action,
            "scope": request.scope,
            "resourceSelectors": request.resource_selectors,
            "evidenceRefs": request.evidence_refs,
            "traceRefs": request.trace_refs,
            "replayRefs": request.replay_refs,
            "denialBehavior": request.denial_behavior
        }),
    )
    .await?;

    Ok(json!({
        "schemaVersion": REQUEST_SCHEMA_VERSION,
        "status": "pending",
        "requestResourceId": resource.resource_id,
        "requestVersionId": request_version_id,
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref(&resource, "approval_request")]
    }))
}

/// Record an idempotent decision bound to the current request revision.
pub(crate) async fn decide_approval_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request_resource_id = required_string(payload, "requestResourceId")?;
    let expected_request_version_id = required_string(payload, "expectedRequestVersionId")?;
    let decision_state = decision_state(required_string(payload, "state")?)?;
    let request_inspection = engine_host
        .inspect_resource(&request_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("approval request {request_resource_id} missing")))?;
    if request_inspection.resource.kind != APPROVAL_REQUEST_KIND {
        return Err(invalid_params(format!(
            "resource {request_resource_id} is not an approval request"
        )));
    }
    let (current_request_version_id, current_request_payload) =
        current_payload(&request_inspection)
            .ok_or_else(|| invalid_params("approval request has no current payload"))?;
    if current_request_version_id != expected_request_version_id {
        return Err(invalid_params(format!(
            "approval request revision conflict: expected {expected_request_version_id}, actual {current_request_version_id}"
        )));
    }
    let mut request_record: ApprovalRequestRecord =
        serde_json::from_value(current_request_payload.clone())
            .map_err(|err| invalid_params(format!("malformed approval request payload: {err}")))?;
    request_record.state = ApprovalRequestState::Decided;
    request_record.revision.number = request_record.revision.number.saturating_add(1);
    request_record.revision.current_version_id = Some(expected_request_version_id.clone());
    let updated_request_version = engine_host
        .update_resource(UpdateResource {
            resource_id: request_resource_id.clone(),
            expected_current_version_id: Some(expected_request_version_id.clone()),
            lifecycle: Some("decided".to_owned()),
            payload: to_value(&request_record, "approval request decision revision")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;

    let decision = ApprovalDecisionRecord {
        schema_version: DECISION_SCHEMA_VERSION.to_owned(),
        request_resource_id: request_resource_id.clone(),
        request_version_id: updated_request_version.version_id.clone(),
        state: decision_state.clone(),
        decision_actor: required_object(payload, "decisionActor")?,
        decided_at: Utc::now(),
        expires_at: required_datetime(payload, "expiresAt")?,
        freshness_until: optional_datetime(payload, "freshnessUntil")?,
        action: optional_object(payload, "action")?
            .unwrap_or_else(|| request_record.action.clone()),
        scope: optional_object(payload, "scope")?.unwrap_or_else(|| request_record.scope.clone()),
        risk_class: optional_string(payload, "riskClass")?
            .unwrap_or_else(|| request_record.risk_class.clone()),
        evidence_refs: merge_arrays(
            request_record.evidence_refs.clone(),
            optional_array(payload, "evidenceRefs")?,
        ),
        resource_selectors: optional_array(payload, "resourceSelectors")?
            .or_if_empty(request_record.resource_selectors.clone()),
        trace_refs: with_trace_ref(
            merge_arrays(
                request_record.trace_refs.clone(),
                optional_array(payload, "traceRefs")?,
            ),
            invocation,
        ),
        replay_refs: with_replay_ref(
            merge_arrays(
                request_record.replay_refs.clone(),
                optional_array(payload, "replayRefs")?,
            ),
            invocation,
        ),
        denial_behavior: optional_object(payload, "denialBehavior")?
            .unwrap_or_else(|| request_record.denial_behavior.clone()),
        idempotency: idempotency(invocation),
        revision: ApprovalDecisionRevision {
            number: 1,
            expected_request_version_id,
            recorded_request_version_id: updated_request_version.version_id.clone(),
        },
    };
    let decision_lifecycle = decision_state.as_lifecycle();
    let decision_payload = to_value(&decision, "approval decision")?;
    let decision_resource_id = format!("{APPROVAL_DECISION_KIND}:{}", invocation.id.as_str());
    let decision_resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(decision_resource_id),
            kind: APPROVAL_DECISION_KIND.to_owned(),
            schema_id: Some(APPROVAL_DECISION_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(decision_lifecycle.to_owned()),
            policy: approval_policy("decision"),
            initial_payload: Some(decision_payload.clone()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let decision_version_id = decision_resource
        .current_version_id
        .clone()
        .ok_or_else(|| {
            invalid_params("approval decision resource was created without an initial version")
        })?;
    engine_host
        .link_resources(LinkResources {
            source_resource_id: decision_resource.resource_id.clone(),
            target_resource_id: request_resource_id.clone(),
            relation: "decision_for".to_owned(),
            metadata: json!({
                "state": decision_lifecycle,
                "requestVersionId": updated_request_version.version_id
            }),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let event_type = match decision_state {
        ApprovalDecisionState::Approved => "approval.decided",
        ApprovalDecisionState::Denied => "approval.denied",
        ApprovalDecisionState::Revoked => "approval.revoked",
    };
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        event_type,
        json!({
            "requestResourceId": request_resource_id,
            "requestVersionId": updated_request_version.version_id,
            "decisionResourceId": decision_resource.resource_id,
            "decisionVersionId": decision_version_id,
            "state": decision_lifecycle,
            "riskClass": decision.risk_class,
            "action": decision.action,
            "scope": decision.scope,
            "resourceSelectors": decision.resource_selectors,
            "evidenceRefs": decision.evidence_refs,
            "traceRefs": decision.trace_refs,
            "replayRefs": decision.replay_refs,
            "denialBehavior": decision.denial_behavior
        }),
    )
    .await?;

    Ok(json!({
        "schemaVersion": DECISION_SCHEMA_VERSION,
        "status": decision_lifecycle,
        "decisionResourceId": decision_resource.resource_id,
        "decisionVersionId": decision_version_id,
        "requestResourceId": request_resource_id,
        "requestVersionId": updated_request_version.version_id,
        "streamCursor": cursor.0,
        "resourceRefs": [
            version_ref(&request_inspection.resource, &updated_request_version, "approval_request"),
            resource_ref(&decision_resource, "approval_decision")
        ]
    }))
}

/// Check approval by payload and return a JSON response.
pub(crate) async fn check_approval_value(
    engine_host: &EngineHostHandle,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let requirement = ApprovalCheckRequirement {
        request_resource_id: required_string(payload, "requestResourceId")?,
        decision_resource_id: optional_string(payload, "decisionResourceId")?,
        action: required_object(payload, "action")?,
        scope: required_object(payload, "scope")?,
        risk_class: required_string(payload, "riskClass")?,
        resource_selectors: optional_array(payload, "resourceSelectors")?,
    };
    to_value(
        &check_approval_at(engine_host, requirement, Utc::now()).await?,
        "approval check",
    )
}

/// Reusable fail-closed approval check for future packages.
pub(crate) async fn check_approval_at(
    engine_host: &EngineHostHandle,
    requirement: ApprovalCheckRequirement,
    now: DateTime<Utc>,
) -> Result<ApprovalCheckResult, CapabilityError> {
    let request_inspection = match engine_host
        .inspect_resource(&requirement.request_resource_id)
        .await
        .map_err(engine_error)?
    {
        Some(inspection) => inspection,
        None => {
            return Ok(check_result(
                ApprovalCheckOutcome::Missing,
                "approval_request_missing",
                json!({"requirement": requirement_summary(&requirement)}),
            ));
        }
    };
    if request_inspection.resource.kind != APPROVAL_REQUEST_KIND {
        return Ok(check_result(
            ApprovalCheckOutcome::Malformed,
            "approval_request_wrong_kind",
            json!({
                "requestResourceId": requirement.request_resource_id,
                "kind": request_inspection.resource.kind
            }),
        ));
    }
    let Some((request_version_id, request_payload)) = current_payload(&request_inspection) else {
        return Ok(check_result(
            ApprovalCheckOutcome::Malformed,
            "approval_request_missing_payload",
            json!({"requestResourceId": requirement.request_resource_id}),
        ));
    };
    let request: ApprovalRequestRecord = match serde_json::from_value(request_payload.clone()) {
        Ok(request) => request,
        Err(err) => {
            return Ok(check_result(
                ApprovalCheckOutcome::Malformed,
                "approval_request_malformed",
                json!({
                    "requestResourceId": requirement.request_resource_id,
                    "requestVersionId": request_version_id,
                    "error": err.to_string()
                }),
            ));
        }
    };
    if now > request.expires_at {
        return Ok(check_result(
            ApprovalCheckOutcome::Expired,
            "approval_request_expired",
            request_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
            ),
        ));
    }
    if freshness_stale_at(&request.freshness).is_some_and(|stale_at| now > stale_at) {
        return Ok(check_result(
            ApprovalCheckOutcome::Stale,
            "approval_request_stale",
            request_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
            ),
        ));
    }
    if let Some(reason) = request_mismatch_reason(&request, &requirement) {
        return Ok(check_result(
            ApprovalCheckOutcome::ScopeMismatch,
            reason,
            request_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
            ),
        ));
    }
    let Some(decision_resource_id) = requirement.decision_resource_id.as_deref() else {
        let outcome = if request.state == ApprovalRequestState::Pending {
            ApprovalCheckOutcome::Pending
        } else {
            ApprovalCheckOutcome::Missing
        };
        let reason = if outcome == ApprovalCheckOutcome::Pending {
            "approval_decision_pending"
        } else {
            "approval_decision_missing"
        };
        return Ok(check_result(
            outcome,
            reason,
            request_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
            ),
        ));
    };
    let decision_inspection = match engine_host
        .inspect_resource(decision_resource_id)
        .await
        .map_err(engine_error)?
    {
        Some(inspection) => inspection,
        None => {
            return Ok(check_result(
                ApprovalCheckOutcome::Missing,
                "approval_decision_missing",
                request_explanation(
                    &requirement,
                    &request_inspection,
                    &request,
                    &request_version_id,
                ),
            ));
        }
    };
    if decision_inspection.resource.kind != APPROVAL_DECISION_KIND {
        return Ok(check_result(
            ApprovalCheckOutcome::Malformed,
            "approval_decision_wrong_kind",
            json!({
                "request": request_explanation(
                    &requirement,
                    &request_inspection,
                    &request,
                    &request_version_id,
                ),
                "decisionResourceId": decision_resource_id,
                "kind": decision_inspection.resource.kind
            }),
        ));
    }
    let Some((decision_version_id, decision_payload)) = current_payload(&decision_inspection)
    else {
        return Ok(check_result(
            ApprovalCheckOutcome::Malformed,
            "approval_decision_missing_payload",
            request_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
            ),
        ));
    };
    let decision: ApprovalDecisionRecord = match serde_json::from_value(decision_payload.clone()) {
        Ok(decision) => decision,
        Err(err) => {
            return Ok(check_result(
                ApprovalCheckOutcome::Malformed,
                "approval_decision_malformed",
                json!({
                    "request": request_explanation(
                        &requirement,
                        &request_inspection,
                        &request,
                        &request_version_id,
                    ),
                    "decisionResourceId": decision_resource_id,
                    "decisionVersionId": decision_version_id,
                    "error": err.to_string()
                }),
            ));
        }
    };
    if decision.request_resource_id != requirement.request_resource_id {
        return Ok(check_result(
            ApprovalCheckOutcome::ScopeMismatch,
            "approval_decision_request_mismatch",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        ));
    }
    if request_version_id != decision.request_version_id {
        return Ok(check_result(
            ApprovalCheckOutcome::Stale,
            "approval_decision_not_bound_to_current_request_revision",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        ));
    }
    if now > decision.expires_at {
        return Ok(check_result(
            ApprovalCheckOutcome::Expired,
            "approval_decision_expired",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        ));
    }
    if decision
        .freshness_until
        .is_some_and(|freshness_until| now > freshness_until)
    {
        return Ok(check_result(
            ApprovalCheckOutcome::Stale,
            "approval_decision_freshness_stale",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        ));
    }
    if let Some(reason) = decision_mismatch_reason(&decision, &requirement) {
        return Ok(check_result(
            ApprovalCheckOutcome::ScopeMismatch,
            reason,
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        ));
    }
    match decision.state {
        ApprovalDecisionState::Approved => Ok(check_result(
            ApprovalCheckOutcome::Approved,
            "approval_decision_approved",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        )),
        ApprovalDecisionState::Denied => Ok(check_result(
            ApprovalCheckOutcome::Denied,
            "approval_decision_denied",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        )),
        ApprovalDecisionState::Revoked => Ok(check_result(
            ApprovalCheckOutcome::Denied,
            "approval_decision_revoked",
            decision_explanation(
                &requirement,
                &request_inspection,
                &request,
                &request_version_id,
                &decision_inspection,
                &decision,
                &decision_version_id,
            ),
        )),
    }
}
