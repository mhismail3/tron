//! Built-in procedural state resource definitions.
//!
//! The procedural record contract is intentionally inert: it stores
//! provenance/eval/status metadata for skills, rules, hooks, and procedures,
//! but does not define triggers, prompt injection, learned behavior, or any
//! activation path.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, PROCEDURAL_ACTIVATION_DECISION_KIND,
    PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID, PROCEDURAL_ACTIVATION_REQUEST_KIND,
    PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID, PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const PROCEDURAL_ACTIVATION_REQUEST_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.procedural_activation_request.v1";
pub(crate) const PROCEDURAL_ACTIVATION_DECISION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.procedural_activation_decision.v1";

pub(super) fn procedural_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        procedural_record_definition(),
        activation_request_definition(),
        activation_decision_definition(),
    ]
}

fn procedural_record_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: PROCEDURAL_RECORD_KIND.to_owned(),
        schema_id: PROCEDURAL_RECORD_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "proceduralKind",
                "identity",
                "summary",
                "status",
                "provenance",
                "eval",
                "activation",
                "sourceRefs",
                "traceRefs",
                "replayRefs",
                "validationEvidence",
                "review",
                "triggerDeclarations",
                "conflictMetadata",
                "orderingMetadata",
                "scopedAuthorityProof",
                "boundedRefs",
                "idempotency",
                "providerProjection",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "proceduralKind": {"type": "string", "enum": ["skill", "rule", "hook", "procedure"]},
                "identity": {"type": "object"},
                "summary": {"type": "string"},
                "status": {"type": "string", "enum": ["draft", "candidate", "validated", "disabled", "stale", "archived"]},
                "provenance": {"type": "object"},
                "eval": {"type": "object"},
                "activation": {"type": "object"},
                "sourceRefs": {"type": "array"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "validationEvidence": {"type": "object"},
                "review": {"type": "object"},
                "triggerDeclarations": {"type": "array"},
                "conflictMetadata": {"type": "object"},
                "orderingMetadata": {"type": "object"},
                "scopedAuthorityProof": {"type": "object"},
                "boundedRefs": {"type": "array"},
                "idempotency": {"type": "object"},
                "providerProjection": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: vec![
            "draft".to_owned(),
            "candidate".to_owned(),
            "validated".to_owned(),
            "disabled".to_owned(),
            "stale".to_owned(),
            "archived".to_owned(),
        ],
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: vec![
            "source_resource".to_owned(),
            "evaluated_by".to_owned(),
            "supersedes".to_owned(),
            "derived_from".to_owned(),
            "evidence_for".to_owned(),
        ],
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({
            "projection": "metadata_only",
            "body": "not_provider_visible",
            "activation": "proof_only"
        }),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["procedural.read", "resource.read"],
            "write": ["procedural.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("procedural").expect("valid static worker id"),
    }
}

fn activation_request_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: PROCEDURAL_ACTIVATION_REQUEST_KIND.to_owned(),
        schema_id: PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "requestId",
                "scope",
                "proceduralRecord",
                "requestedAction",
                "review",
                "validationEvidenceRefs",
                "triggerDeclarations",
                "conflictMetadata",
                "orderingMetadata",
                "scopedAuthorityProof",
                "rollbackProofRefs",
                "traceRefs",
                "replayRefs",
                "boundedRefs",
                "idempotency",
                "safetyProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": PROCEDURAL_ACTIVATION_REQUEST_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["pending_review", "withdrawn", "superseded", "archived"]},
                "requestId": {"type": "string"},
                "scope": {"type": "object"},
                "proceduralRecord": {"type": "object"},
                "requestedAction": {"type": "string", "enum": ["activate", "deactivate", "rollback"]},
                "review": {"type": "object"},
                "validationEvidenceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "triggerDeclarations": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "conflictMetadata": {"type": "object"},
                "orderingMetadata": {"type": "object"},
                "scopedAuthorityProof": {"type": "object"},
                "rollbackProofRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "boundedRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "idempotency": {"type": "object"},
                "safetyProof": {"type": "object"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["pending_review", "withdrawn", "superseded", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "requests_activation_for",
            "requests_deactivation_for",
            "requests_rollback_for",
            "evidence_for",
            "trace",
            "replay",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "procedural_activation_request"}),
        redaction_rules: json!({
            "projection": "metadata_only_provider_safe",
            "rawProceduralBody": "forbidden",
            "commands": "forbidden",
            "paths": "forbidden",
            "grantIds": "forbidden"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "activation": "review_only",
            "execution": "forbidden",
            "networkPolicy": "none",
            "repoManagedSkills": "forbidden"
        }),
        required_capabilities: json!({
            "read": ["procedural.read", "resource.read"],
            "write": ["procedural.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("procedural").expect("valid static worker id"),
    }
}

fn activation_decision_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: PROCEDURAL_ACTIVATION_DECISION_KIND.to_owned(),
        schema_id: PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "decisionId",
                "scope",
                "activationRequest",
                "proceduralRecord",
                "decision",
                "decisionReason",
                "activationResult",
                "rollbackProofRefs",
                "deactivationProofRefs",
                "traceRefs",
                "replayRefs",
                "boundedRefs",
                "idempotency",
                "safetyProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": PROCEDURAL_ACTIVATION_DECISION_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["approved", "denied", "deactivated", "rollback_required", "archived"]},
                "decisionId": {"type": "string"},
                "scope": {"type": "object"},
                "activationRequest": {"type": "object"},
                "proceduralRecord": {"type": "object"},
                "decision": {"type": "string", "enum": ["approve_activation", "deny_activation", "approve_deactivation", "approve_rollback"]},
                "decisionReason": {"type": "string"},
                "activationResult": {"type": "object"},
                "rollbackProofRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "deactivationProofRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "boundedRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "idempotency": {"type": "object"},
                "safetyProof": {"type": "object"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "approved",
            "denied",
            "deactivated",
            "rollback_required",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "decides",
            "activation_for",
            "deactivation_for",
            "rollback_for",
            "evidence_for",
            "trace",
            "replay",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "procedural_activation_decision"}),
        redaction_rules: json!({
            "projection": "metadata_only_provider_safe",
            "activationProof": "decision_only",
            "rawProceduralBody": "forbidden",
            "commands": "forbidden",
            "paths": "forbidden",
            "grantIds": "forbidden"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "activation": "decision_record_only",
            "execution": "forbidden",
            "networkPolicy": "none",
            "repoManagedSkills": "forbidden"
        }),
        required_capabilities: json!({
            "read": ["procedural.read", "resource.read"],
            "write": ["procedural.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("procedural").expect("valid static worker id"),
    }
}
