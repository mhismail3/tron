use serde_json::{Value, json};

use crate::engine::EngineResourceInspection;

use super::types::{ApprovalCheckRequirement, ApprovalDecisionRecord, ApprovalRequestRecord};

pub(super) fn request_explanation(
    requirement: &ApprovalCheckRequirement,
    inspection: &EngineResourceInspection,
    request: &ApprovalRequestRecord,
    request_version_id: &str,
) -> Value {
    json!({
        "requirement": requirement_summary(requirement),
        "request": {
            "resourceId": inspection.resource.resource_id,
            "versionId": request_version_id,
            "state": request.state,
            "expiresAt": request.expires_at,
            "freshness": request.freshness,
            "evidenceRefs": request.evidence_refs,
            "resourceSelectors": request.resource_selectors,
            "traceRefs": request.trace_refs,
            "replayRefs": request.replay_refs,
            "denialBehavior": request.denial_behavior,
            "revision": request.revision
        }
    })
}

pub(super) fn decision_explanation(
    requirement: &ApprovalCheckRequirement,
    request_inspection: &EngineResourceInspection,
    request: &ApprovalRequestRecord,
    request_version_id: &str,
    decision_inspection: &EngineResourceInspection,
    decision: &ApprovalDecisionRecord,
    decision_version_id: &str,
) -> Value {
    json!({
        "requirement": requirement_summary(requirement),
        "request": {
            "resourceId": request_inspection.resource.resource_id,
            "versionId": request_version_id,
            "state": request.state,
            "expiresAt": request.expires_at,
            "freshness": request.freshness,
            "evidenceRefs": request.evidence_refs,
            "resourceSelectors": request.resource_selectors,
            "traceRefs": request.trace_refs,
            "replayRefs": request.replay_refs,
            "denialBehavior": request.denial_behavior,
            "revision": request.revision
        },
        "decision": {
            "resourceId": decision_inspection.resource.resource_id,
            "versionId": decision_version_id,
            "state": decision.state,
            "expiresAt": decision.expires_at,
            "freshnessUntil": decision.freshness_until,
            "evidenceRefs": decision.evidence_refs,
            "resourceSelectors": decision.resource_selectors,
            "traceRefs": decision.trace_refs,
            "replayRefs": decision.replay_refs,
            "denialBehavior": decision.denial_behavior,
            "revision": decision.revision
        }
    })
}

pub(super) fn requirement_summary(requirement: &ApprovalCheckRequirement) -> Value {
    json!({
        "requestResourceId": requirement.request_resource_id,
        "decisionResourceId": requirement.decision_resource_id,
        "action": requirement.action,
        "scope": requirement.scope,
        "riskClass": requirement.risk_class,
        "resourceSelectors": requirement.resource_selectors
    })
}
