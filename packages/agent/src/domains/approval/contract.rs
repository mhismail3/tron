use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{DurableOutputContract, EffectClass, IdempotencyContract, RiskLevel};

use super::{
    APPROVAL_DECISION_KIND, APPROVAL_LIFECYCLE_TOPIC, APPROVAL_REQUEST_KIND, CHECK_FUNCTION,
    DECIDE_FUNCTION, READ_SCOPE, REQUEST_FUNCTION, WORKER, WRITE_SCOPE,
};

/// Canonical approval capability contracts.
pub(crate) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            REQUEST_FUNCTION,
            WORKER,
            EffectClass::AppendOnlyEvent,
            RiskLevel::Low,
            Some(WRITE_SCOPE),
        )
        .description("Create a durable approval request resource with explicit expiry, evidence, and denial behavior.")
        .tags(vec!["approval", "freshness", "request", "evidence", "resource"])
        .examples(vec![json!({
            "action": {"kind": "future_tool", "operation": "write_file"},
            "scope": {"kind": "workspace", "id": "example-workspace"},
            "riskClass": "high",
            "expiresAt": "2026-06-19T20:00:00Z",
            "denialBehavior": {"mode": "fail_closed"}
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "evidence_write_only",
            "sideEffects": ["resource:create", "stream:publish"],
            "approvalIsAuthority": false
        }))
        .request_schema(request_schema())
        .response_schema(request_response_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .output_contract(DurableOutputContract::resource_backed([
            APPROVAL_REQUEST_KIND,
        ]))
        .stream_topics(vec![APPROVAL_LIFECYCLE_TOPIC])
        .presentation_hints(json!({"systemImage": "checkmark.shield"}))
        .build()?,
        CapabilityContract::new(
            DECIDE_FUNCTION,
            WORKER,
            EffectClass::AppendOnlyEvent,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description("Record an idempotent approval decision bound to a current approval request revision.")
        .tags(vec!["approval", "freshness", "decision", "idempotency", "resource"])
        .examples(vec![json!({
            "requestResourceId": "approval_request:...",
            "expectedRequestVersionId": "ver_...",
            "state": "approved",
            "decisionActor": {"kind": "user", "id": "operator"},
            "expiresAt": "2026-06-19T20:00:00Z"
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "decision_evidence_write_only",
            "sideEffects": ["resource:create", "resource:update", "resource:link", "stream:publish"],
            "approvalIsAuthority": false
        }))
        .request_schema(decide_schema())
        .response_schema(decide_response_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .output_contract(DurableOutputContract::resource_backed([
            APPROVAL_DECISION_KIND,
            APPROVAL_REQUEST_KIND,
        ]))
        .stream_topics(vec![APPROVAL_LIFECYCLE_TOPIC])
        .presentation_hints(json!({"systemImage": "person.crop.circle.badge.checkmark"}))
        .build()?,
        CapabilityContract::new(
            CHECK_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Fail-closed approval freshness check for one intended action, scope, risk, and resource selector set.")
        .tags(vec!["approval", "freshness", "check", "fail-closed", "replay"])
        .examples(vec![json!({
            "requestResourceId": "approval_request:...",
            "decisionResourceId": "approval_decision:...",
            "action": {"kind": "future_tool", "operation": "write_file"},
            "scope": {"kind": "workspace", "id": "example-workspace"},
            "riskClass": "high"
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "fail_closed_read",
            "sideEffects": [],
            "approvalIsAuthority": false
        }))
        .request_schema(check_schema())
        .response_schema(check_response_schema())
        .presentation_hints(json!({"systemImage": "shield.lefthalf.filled"}))
        .build()?,
    ])
}

fn request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["action", "scope", "riskClass", "expiresAt", "denialBehavior"],
        "additionalProperties": false,
        "properties": {
            "requestId": {"type": "string"},
            "requester": {"type": "object"},
            "action": {"type": "object"},
            "scope": {"type": "object"},
            "riskClass": {"type": "string"},
            "expiresAt": {"type": "string"},
            "freshness": {"type": "object"},
            "evidenceRefs": {"type": "array"},
            "resourceSelectors": {"type": "array"},
            "traceRefs": {"type": "array"},
            "replayRefs": {"type": "array"},
            "denialBehavior": {"type": "object"}
        }
    })
}

fn decide_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "requestResourceId",
            "expectedRequestVersionId",
            "state",
            "decisionActor",
            "expiresAt"
        ],
        "additionalProperties": false,
        "properties": {
            "requestResourceId": {"type": "string"},
            "expectedRequestVersionId": {"type": "string"},
            "state": {"type": "string", "enum": ["approved", "denied", "revoked"]},
            "decisionActor": {"type": "object"},
            "expiresAt": {"type": "string"},
            "freshnessUntil": {"type": "string"},
            "action": {"type": "object"},
            "scope": {"type": "object"},
            "riskClass": {"type": "string"},
            "evidenceRefs": {"type": "array"},
            "resourceSelectors": {"type": "array"},
            "traceRefs": {"type": "array"},
            "replayRefs": {"type": "array"},
            "denialBehavior": {"type": "object"}
        }
    })
}

fn check_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["requestResourceId", "action", "scope", "riskClass"],
        "additionalProperties": false,
        "properties": {
            "requestResourceId": {"type": "string"},
            "decisionResourceId": {"type": "string"},
            "action": {"type": "object"},
            "scope": {"type": "object"},
            "riskClass": {"type": "string"},
            "resourceSelectors": {"type": "array"}
        }
    })
}

fn request_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "requestResourceId", "requestVersionId", "streamCursor", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "requestResourceId": {"type": "string"},
            "requestVersionId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn decide_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "decisionResourceId", "decisionVersionId", "requestResourceId", "requestVersionId", "streamCursor", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "decisionResourceId": {"type": "string"},
            "decisionVersionId": {"type": "string"},
            "requestResourceId": {"type": "string"},
            "requestVersionId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn check_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "allowed", "outcome", "reason", "explanation"],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"type": "string"},
            "allowed": {"type": "boolean"},
            "outcome": {"type": "string"},
            "reason": {"type": "string"},
            "explanation": {"type": "object"}
        }
    })
}
