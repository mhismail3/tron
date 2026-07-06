//! Capability binding, shadow-trial, and route resource definitions.
//!
//! Binding and shadow-trial resources store governance metadata. Route resources
//! are the governed runtime-routing plane: they can activate, disable, and roll
//! back scoped read-only routes without hot-swapping modules, mutating dispatch,
//! running package managers, or accessing networks.

use serde_json::json;

use super::types::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_DECISION_SCHEMA_ID,
    CAPABILITY_BINDING_POLICY_KIND, CAPABILITY_BINDING_POLICY_SCHEMA_ID,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_BINDING_REQUEST_SCHEMA_ID,
    CAPABILITY_REPLACEMENT_CANDIDATE_KIND, CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
    CAPABILITY_ROUTE_ACTIVATION_KIND, CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
    CAPABILITY_ROUTE_BINDING_KIND, CAPABILITY_ROUTE_BINDING_SCHEMA_ID, CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_EVENT_SCHEMA_ID, CAPABILITY_ROUTE_ROLLBACK_KIND,
    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_RUN_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID, EngineResourceVersioningMode, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const CAPABILITY_BINDING_REQUEST_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_binding_request.v1";
pub(crate) const CAPABILITY_BINDING_DECISION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_binding_decision.v1";
pub(crate) const CAPABILITY_BINDING_POLICY_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_binding_policy.v1";
pub(crate) const CAPABILITY_SHADOW_TRIAL_REQUEST_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_shadow_trial_request.v1";
pub(crate) const CAPABILITY_SHADOW_TRIAL_DECISION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_shadow_trial_decision.v1";
pub(crate) const CAPABILITY_SHADOW_TRIAL_RUN_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_shadow_trial_run.v1";
pub(crate) const CAPABILITY_SHADOW_TRIAL_EVIDENCE_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_shadow_trial_evidence.v1";
pub(crate) const CAPABILITY_REPLACEMENT_CANDIDATE_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_replacement_candidate.v1";
pub(crate) const CAPABILITY_ROUTE_BINDING_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_route_binding.v1";
pub(crate) const CAPABILITY_ROUTE_ACTIVATION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_route_activation.v1";
pub(crate) const CAPABILITY_ROUTE_EVENT_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_route_event.v1";
pub(crate) const CAPABILITY_ROUTE_ROLLBACK_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.capability_route_rollback.v1";

pub(super) fn capability_binding_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        binding_request_definition(),
        binding_decision_definition(),
        binding_policy_definition(),
        shadow_trial_request_definition(),
        shadow_trial_decision_definition(),
        shadow_trial_run_definition(),
        shadow_trial_evidence_definition(),
        replacement_candidate_definition(),
        route_binding_definition(),
        route_activation_definition(),
        route_event_definition(),
        route_rollback_definition(),
    ]
}

fn binding_request_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_BINDING_REQUEST_KIND,
        CAPABILITY_BINDING_REQUEST_SCHEMA_ID,
        CAPABILITY_BINDING_REQUEST_PAYLOAD_SCHEMA_VERSION,
        "capability_binding_request",
        ["pending_review", "superseded", "archived"].as_slice(),
        [
            "binding_request_for",
            "target_operation",
            "target_binding",
            "rollback_proof",
            "disable_proof",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "requestId",
                "scope",
                "title",
                "operation",
                "binding",
                "requirements",
                "policyDecision",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "requestId": {"type": "string"},
                "title": {"type": "string"},
                "operation": {"type": "object"},
                "binding": {"type": "object"},
                "requirements": {"type": "object"},
                "policyDecision": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn binding_decision_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_BINDING_DECISION_KIND,
        CAPABILITY_BINDING_DECISION_SCHEMA_ID,
        CAPABILITY_BINDING_DECISION_PAYLOAD_SCHEMA_VERSION,
        "capability_binding_decision",
        ["approved_policy", "rejected", "superseded", "archived"].as_slice(),
        [
            "decision_for",
            "binding_request",
            "binding_policy_candidate",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "decisionId",
                "scope",
                "request",
                "operation",
                "binding",
                "requirements",
                "decision",
                "policyCandidate",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "decisionId": {"type": "string"},
                "request": {"type": "object"},
                "operation": {"type": "object"},
                "binding": {"type": "object"},
                "requirements": {"type": "object"},
                "decision": {"type": "object"},
                "policyCandidate": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn binding_policy_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_BINDING_POLICY_KIND,
        CAPABILITY_BINDING_POLICY_SCHEMA_ID,
        CAPABILITY_BINDING_POLICY_PAYLOAD_SCHEMA_VERSION,
        "capability_binding_policy",
        ["active", "disabled", "superseded", "archived"].as_slice(),
        [
            "policy_for",
            "binding_decision",
            "binding_request",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "policyId",
                "scope",
                "decision",
                "request",
                "operation",
                "binding",
                "requirements",
                "activation",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "policyId": {"type": "string"},
                "decision": {"type": "object"},
                "request": {"type": "object"},
                "operation": {"type": "object"},
                "binding": {"type": "object"},
                "requirements": {"type": "object"},
                "activation": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn shadow_trial_request_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
        CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID,
        CAPABILITY_SHADOW_TRIAL_REQUEST_PAYLOAD_SCHEMA_VERSION,
        "capability_shadow_trial_request",
        ["pending_review", "disabled", "aborted", "archived"].as_slice(),
        [
            "shadow_trial_for",
            "target_operation",
            "candidate_adapter",
            "rollback_proof",
            "disable_proof",
            "abort_proof",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "trialRequestId",
                "scope",
                "title",
                "operation",
                "candidate",
                "requirements",
                "trialDecision",
                "rationale",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "trialRequestId": {"type": "string"},
                "title": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "requirements": {"type": "object"},
                "trialDecision": {"type": "object"},
                "rationale": {"type": "string"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn shadow_trial_decision_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
        CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID,
        CAPABILITY_SHADOW_TRIAL_DECISION_PAYLOAD_SCHEMA_VERSION,
        "capability_shadow_trial_decision",
        [
            "approved_trial",
            "rejected",
            "disabled",
            "aborted",
            "archived",
        ]
        .as_slice(),
        [
            "decision_for",
            "shadow_trial_request",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "trialDecisionId",
                "scope",
                "request",
                "operation",
                "candidate",
                "requirements",
                "decision",
                "runGate",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "trialDecisionId": {"type": "string"},
                "request": {"type": "object"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "requirements": {"type": "object"},
                "decision": {"type": "object"},
                "runGate": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn shadow_trial_run_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_SHADOW_TRIAL_RUN_KIND,
        CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
        CAPABILITY_SHADOW_TRIAL_RUN_PAYLOAD_SCHEMA_VERSION,
        "capability_shadow_trial_run",
        ["passed", "failed", "disabled", "aborted", "archived"].as_slice(),
        [
            "run_for",
            "shadow_trial_decision",
            "shadow_trial_request",
            "shadow_trial_evidence",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "trialRunId",
                "scope",
                "decision",
                "request",
                "operation",
                "candidate",
                "run",
                "evidence",
                "resultControls",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "trialRunId": {"type": "string"},
                "decision": {"type": "object"},
                "request": {"type": "object"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "run": {"type": "object"},
                "evidence": {"type": "object"},
                "resultControls": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn shadow_trial_evidence_definition() -> RegisterResourceType {
    definition(
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_PAYLOAD_SCHEMA_VERSION,
        "capability_shadow_trial_evidence",
        ["accepted", "rejected", "disabled", "aborted", "archived"].as_slice(),
        [
            "evidence_for",
            "shadow_trial_run",
            "shadow_trial_decision",
            "shadow_trial_request",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "trialEvidenceId",
                "scope",
                "run",
                "decision",
                "request",
                "operation",
                "candidate",
                "builtInProjection",
                "candidateProjection",
                "comparison",
                "resultControls",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "trialEvidenceId": {"type": "string"},
                "run": {"type": "object"},
                "decision": {"type": "object"},
                "request": {"type": "object"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "builtInProjection": {"type": "object"},
                "candidateProjection": {"type": "object"},
                "comparison": {"type": "object"},
                "resultControls": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn replacement_candidate_definition() -> RegisterResourceType {
    route_definition(
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
        CAPABILITY_REPLACEMENT_CANDIDATE_PAYLOAD_SCHEMA_VERSION,
        "capability_replacement_candidate",
        ["validated", "rejected", "disabled", "archived"].as_slice(),
        [
            "candidate_for",
            "target_operation",
            "shadow_trial_evidence",
            "module_runtime",
            "module_lifecycle",
            "rollback_proof",
            "disable_proof",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "candidateId",
                "scope",
                "operation",
                "candidate",
                "contract",
                "authority",
                "rollback",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "candidateId": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "contract": {"type": "object"},
                "authority": {"type": "object"},
                "rollback": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn route_binding_definition() -> RegisterResourceType {
    route_definition(
        CAPABILITY_ROUTE_BINDING_KIND,
        CAPABILITY_ROUTE_BINDING_SCHEMA_ID,
        CAPABILITY_ROUTE_BINDING_PAYLOAD_SCHEMA_VERSION,
        "capability_route_binding",
        ["ready", "disabled", "superseded", "archived"].as_slice(),
        [
            "route_for",
            "replacement_candidate",
            "target_operation",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "routeBindingId",
                "scope",
                "operation",
                "candidate",
                "binding",
                "activationGate",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "routeBindingId": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "binding": {"type": "object"},
                "activationGate": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn route_activation_definition() -> RegisterResourceType {
    route_definition(
        CAPABILITY_ROUTE_ACTIVATION_KIND,
        CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
        CAPABILITY_ROUTE_ACTIVATION_PAYLOAD_SCHEMA_VERSION,
        "capability_route_activation",
        [
            "active",
            "disabled",
            "rolled_back",
            "superseded",
            "archived",
        ]
        .as_slice(),
        [
            "activation_for",
            "route_binding",
            "replacement_candidate",
            "target_operation",
            "route_event",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "routeActivationId",
                "scope",
                "operation",
                "candidate",
                "binding",
                "activation",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "routeActivationId": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "binding": {"type": "object"},
                "activation": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn route_event_definition() -> RegisterResourceType {
    route_definition(
        CAPABILITY_ROUTE_EVENT_KIND,
        CAPABILITY_ROUTE_EVENT_SCHEMA_ID,
        CAPABILITY_ROUTE_EVENT_PAYLOAD_SCHEMA_VERSION,
        "capability_route_event",
        [
            "activated",
            "routed",
            "disabled",
            "rolled_back",
            "failed_closed",
            "archived",
        ]
        .as_slice(),
        [
            "event_for",
            "route_activation",
            "route_binding",
            "replacement_candidate",
            "target_operation",
            "trace",
            "evidence_for",
            "derived_from",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "routeEventId",
                "scope",
                "operation",
                "candidate",
                "binding",
                "activation",
                "event",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "routeEventId": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "binding": {"type": "object"},
                "activation": {"type": "object"},
                "event": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn route_rollback_definition() -> RegisterResourceType {
    route_definition(
        CAPABILITY_ROUTE_ROLLBACK_KIND,
        CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID,
        CAPABILITY_ROUTE_ROLLBACK_PAYLOAD_SCHEMA_VERSION,
        "capability_route_rollback",
        ["rolled_back", "rejected", "archived"].as_slice(),
        [
            "rollback_for",
            "route_activation",
            "route_binding",
            "replacement_candidate",
            "target_operation",
            "route_event",
            "evidence_for",
            "derived_from",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion",
                "state",
                "routeRollbackId",
                "scope",
                "operation",
                "candidate",
                "binding",
                "activation",
                "rollback",
                "auditRefs",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "properties": {
                "routeRollbackId": {"type": "string"},
                "operation": {"type": "object"},
                "candidate": {"type": "object"},
                "binding": {"type": "object"},
                "activation": {"type": "object"},
                "rollback": {"type": "object"},
                "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn definition(
    kind: &str,
    schema_id: &str,
    schema_version: &str,
    retention_class: &str,
    lifecycle_states: &[&str],
    link_relations: &[&str],
    extra_schema: serde_json::Value,
) -> RegisterResourceType {
    let mut required = vec!["schemaVersion", "state"];
    if let Some(values) = extra_schema
        .get("required")
        .and_then(serde_json::Value::as_array)
    {
        required = values
            .iter()
            .filter_map(serde_json::Value::as_str)
            .collect::<Vec<_>>();
    }
    let mut properties = json!({
        "schemaVersion": {"type": "string", "const": schema_version},
        "state": {"type": "string", "enum": lifecycle_states},
        "scope": {"type": "object"},
        "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
        "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
        "authority": {"type": "object"},
        "idempotency": {"type": "object"},
        "sideEffectProof": side_effect_schema(),
        "createdAt": {"type": "string"},
        "updatedAt": {"type": "string"},
        "revision": {"type": "integer"}
    });
    if let (Some(base), Some(extra)) = (
        properties.as_object_mut(),
        extra_schema
            .get("properties")
            .and_then(serde_json::Value::as_object),
    ) {
        for (key, value) in extra {
            base.insert(key.clone(), value.clone());
        }
    }
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({
            "type": "object",
            "required": required,
            "additionalProperties": false,
            "properties": properties
        }),
        lifecycle_states: lifecycle_states
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        allowed_link_relations: link_relations
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": retention_class,
            "scope": "session_or_workspace",
            "archiveKeepsReviewEvidence": true
        }),
        redaction_rules: redaction_rules(),
        materialization_rules: materialization_rules(),
        required_capabilities: json!({
            "read": ["capability_binding.read", "resource.read"],
            "write": ["capability_binding.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("capability_binding").expect("valid static worker id"),
    }
}

fn route_definition(
    kind: &str,
    schema_id: &str,
    schema_version: &str,
    retention_class: &str,
    lifecycle_states: &[&str],
    link_relations: &[&str],
    extra_schema: serde_json::Value,
) -> RegisterResourceType {
    let mut required = vec!["schemaVersion", "state"];
    if let Some(values) = extra_schema
        .get("required")
        .and_then(serde_json::Value::as_array)
    {
        required = values
            .iter()
            .filter_map(serde_json::Value::as_str)
            .collect::<Vec<_>>();
    }
    let mut properties = json!({
        "schemaVersion": {"type": "string", "const": schema_version},
        "state": {"type": "string", "enum": lifecycle_states},
        "scope": {"type": "object"},
        "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
        "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
        "idempotency": {"type": "object"},
        "sideEffectProof": route_side_effect_schema(),
        "createdAt": {"type": "string"},
        "updatedAt": {"type": "string"},
        "revision": {"type": "integer"}
    });
    if let (Some(base), Some(extra)) = (
        properties.as_object_mut(),
        extra_schema
            .get("properties")
            .and_then(serde_json::Value::as_object),
    ) {
        for (key, value) in extra {
            base.insert(key.clone(), value.clone());
        }
    }
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({
            "type": "object",
            "required": required,
            "additionalProperties": false,
            "properties": properties
        }),
        lifecycle_states: lifecycle_states
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        allowed_link_relations: link_relations
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": retention_class,
            "scope": "session_or_workspace",
            "archiveKeepsReviewEvidence": true
        }),
        redaction_rules: redaction_rules(),
        materialization_rules: route_materialization_rules(),
        required_capabilities: json!({
            "read": ["capability_binding.read", "resource.read"],
            "write": ["capability_binding.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("capability_binding").expect("valid static worker id"),
    }
}

fn side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "metadataOnly",
            "runtimeRoutingChanged",
            "dispatchTableMutated",
            "hotSwapPerformed",
            "moduleActivated",
            "moduleExecuted",
            "dependencyRestorePerformed",
            "packageManagerUsed",
            "manifestMutated",
            "lockfileMutated",
            "networkPolicy",
            "networkAccessPerformed",
            "repoManagedSkillsTouched",
            "physicalWorkspaceDirectoryCreated",
            "rawCommandsStored",
            "rawLogsStored",
            "fileContentsStored",
            "absolutePathsStored",
            "rawGrantIdsStored",
            "rawAuthorityIdsStored"
        ],
        "additionalProperties": false,
        "properties": {
            "metadataOnly": {"type": "boolean", "const": true},
            "runtimeRoutingChanged": {"type": "boolean", "const": false},
            "dispatchTableMutated": {"type": "boolean", "const": false},
            "hotSwapPerformed": {"type": "boolean", "const": false},
            "moduleActivated": {"type": "boolean", "const": false},
            "moduleExecuted": {"type": "boolean", "const": false},
            "dependencyRestorePerformed": {"type": "boolean", "const": false},
            "packageManagerUsed": {"type": "boolean", "const": false},
            "manifestMutated": {"type": "boolean", "const": false},
            "lockfileMutated": {"type": "boolean", "const": false},
            "networkPolicy": {"type": "string", "const": "none"},
            "networkAccessPerformed": {"type": "boolean", "const": false},
            "repoManagedSkillsTouched": {"type": "boolean", "const": false},
            "physicalWorkspaceDirectoryCreated": {"type": "boolean", "const": false},
            "rawCommandsStored": {"type": "boolean", "const": false},
            "rawLogsStored": {"type": "boolean", "const": false},
            "fileContentsStored": {"type": "boolean", "const": false},
            "absolutePathsStored": {"type": "boolean", "const": false},
            "rawGrantIdsStored": {"type": "boolean", "const": false},
            "rawAuthorityIdsStored": {"type": "boolean", "const": false}
        }
    })
}

fn route_side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "metadataOnly",
            "runtimeRoutingChanged",
            "dispatchTableMutated",
            "hotSwapPerformed",
            "moduleActivated",
            "moduleExecuted",
            "dependencyRestorePerformed",
            "packageManagerUsed",
            "manifestMutated",
            "lockfileMutated",
            "networkPolicy",
            "networkAccessPerformed",
            "repoManagedSkillsTouched",
            "physicalWorkspaceDirectoryCreated",
            "rawCommandsStored",
            "rawLogsStored",
            "fileContentsStored",
            "absolutePathsStored",
            "rawGrantIdsStored",
            "rawAuthorityIdsStored"
        ],
        "additionalProperties": false,
        "properties": {
            "metadataOnly": {"type": "boolean", "const": true},
            "runtimeRoutingChanged": {"type": "boolean"},
            "dispatchTableMutated": {"type": "boolean", "const": false},
            "hotSwapPerformed": {"type": "boolean", "const": false},
            "moduleActivated": {"type": "boolean", "const": false},
            "moduleExecuted": {"type": "boolean", "const": false},
            "dependencyRestorePerformed": {"type": "boolean", "const": false},
            "packageManagerUsed": {"type": "boolean", "const": false},
            "manifestMutated": {"type": "boolean", "const": false},
            "lockfileMutated": {"type": "boolean", "const": false},
            "networkPolicy": {"type": "string", "const": "none"},
            "networkAccessPerformed": {"type": "boolean", "const": false},
            "repoManagedSkillsTouched": {"type": "boolean", "const": false},
            "physicalWorkspaceDirectoryCreated": {"type": "boolean", "const": false},
            "rawCommandsStored": {"type": "boolean", "const": false},
            "rawLogsStored": {"type": "boolean", "const": false},
            "fileContentsStored": {"type": "boolean", "const": false},
            "absolutePathsStored": {"type": "boolean", "const": false},
            "rawGrantIdsStored": {"type": "boolean", "const": false},
            "rawAuthorityIdsStored": {"type": "boolean", "const": false}
        }
    })
}

fn redaction_rules() -> serde_json::Value {
    json!({
        "projection": "metadata_only_provider_safe",
        "neverReturn": [
            "code",
            "sourceCode",
            "prompt",
            "messages",
            "command",
            "rawCommand",
            "env",
            "environmentValues",
            "rawLogs",
            "stdout",
            "stderr",
            "fileContents",
            "absolutePath",
            "unsafePath",
            "grantId",
            "authorityId",
            "rawGrantId",
            "rawAuthorityId",
            "debugPayload",
            "chainOfThought"
        ],
        "refs": "resource_backed_bounded_metadata_only"
    })
}

fn materialization_rules() -> serde_json::Value {
    json!({
        "durableOutputsRequireResourceVersion": true,
        "metadataOnly": true,
        "runtimeRouting": "forbidden_in_this_slice",
        "hotSwap": "forbidden",
        "moduleActivation": "forbidden",
        "packageManager": "forbidden",
        "networkPolicy": "none",
        "physicalWorkspaceDirectory": "forbidden",
        "repoManagedSkills": "forbidden"
    })
}

fn route_materialization_rules() -> serde_json::Value {
    json!({
        "durableOutputsRequireResourceVersion": true,
        "metadataOnly": true,
        "runtimeRouting": "governed_explicit_scoped_reversible",
        "hotSwap": "forbidden",
        "dispatchMutation": "forbidden",
        "moduleActivation": "forbidden",
        "packageManager": "forbidden",
        "networkPolicy": "none",
        "physicalWorkspaceDirectory": "forbidden",
        "repoManagedSkills": "forbidden"
    })
}
