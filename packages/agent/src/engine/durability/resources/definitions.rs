//! Built-in resource type definitions for the collapsed substrate.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::types::{
    EngineResourceTypeDefinition, EngineResourceVersioningMode, RegisterResourceType,
    UI_SURFACE_KIND, UI_SURFACE_SCHEMA_ID,
};
use super::ui_surface::ui_surface_schema;
use crate::engine::kernel::ids::WorkerId;

use super::agent_record_definitions::agent_record_resource_type_definitions;
use super::worker_schedule_definitions::worker_schedule_resource_type_definitions;

/// Built-in resource kinds for the collapsed modular substrate.
#[must_use]
pub fn builtin_resource_type_definitions() -> Vec<RegisterResourceType> {
    let mut definitions = vec![
        builtin_type(
            "artifact",
            "tron.resource.artifact.v1",
            json!({
                "type": "object",
                "required": ["title", "body"],
                "additionalProperties": true,
                "properties": {
                    "title": {"type": "string"},
                    "body": {},
                    "format": {"type": "string"},
                    "summary": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "promoted", "discarded", "archived"],
            vec![
                "input",
                "produced",
                "candidate_output",
                "promoted_output",
                "supported_by",
                "contradicted_by",
                "supports",
                "supersedes",
                "evidence_for",
                "derived_from",
                "part_of",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "goal",
            "tron.resource.goal.v1",
            json!({
                "type": "object",
                "required": ["intent"],
                "additionalProperties": true,
                "properties": {
                    "intent": {"type": "string"},
                    "successCriteria": {"type": "array", "items": {"type": "string"}},
                    "inputResources": {"type": "array", "items": {"type": "string"}},
                    "expectedOutputKinds": {"type": "array", "items": {"type": "string"}},
                    "constraints": {"type": "object"},
                    "riskBudget": {"type": "object"},
                    "authorityPolicy": {"type": "object"},
                    "retentionPolicy": {"type": "object"},
                    "completionCondition": {"type": "string"}
                }
            }),
            vec!["open", "in_progress", "completed", "failed", "archived"],
            vec![
                "input",
                "subgoal",
                "produced",
                "produces",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "complete": ["resource.write"]}),
        ),
        builtin_type(
            "decision",
            "tron.resource.decision.v1",
            json!({
                "type": "object",
                "required": ["status", "summary"],
                "additionalProperties": true,
                "properties": {
                    "status": {"type": "string"},
                    "summary": {"type": "string"},
                    "promotedResources": {"type": "array", "items": {"type": "string"}},
                    "discardedResources": {"type": "array", "items": {"type": "string"}},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "final", "archived"],
            vec![
                "decides",
                "promotes",
                "discards",
                "supports",
                "supported_by",
                "contradicted_by",
                "derived_from",
                "revokes",
                "supersedes",
                "renewed_by",
                "rotates_from",
                "rotates_to",
                "enforces_revocation",
                "evidence_for",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "claim",
            "tron.resource.claim.v1",
            json!({
                "type": "object",
                "required": ["statement"],
                "additionalProperties": true,
                "properties": {
                    "statement": {"type": "string"},
                    "confidence": {"type": "number"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "claims_about",
                "supported_by",
                "contradicted_by",
                "contradicts",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "evidence",
            "tron.resource.evidence.v1",
            json!({
                "type": "object",
                "required": ["summary"],
                "additionalProperties": true,
                "properties": {
                    "summary": {"type": "string"},
                    "source": {"type": "string"},
                    "resourceRef": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "evidence_for",
                "supported_by",
                "contradicted_by",
                "derived_from",
                "supports",
                "revokes",
                "supersedes",
                "renewed_by",
                "rotates_from",
                "rotates_to",
                "enforces_revocation",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            UI_SURFACE_KIND,
            UI_SURFACE_SCHEMA_ID,
            ui_surface_schema(),
            vec![
                "draft",
                "active",
                "superseded",
                "expired",
                "discarded",
                "damaged",
            ],
            vec![
                "input",
                "produced",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
                "renders",
                "acts_on",
            ],
            json!({
                "read": ["ui.read", "resource.read"],
                "write": ["ui.write", "resource.write"],
                "delete": ["ui.write", "resource.write"]
            }),
        ),
        builtin_type(
            "materialized_file",
            "tron.resource.materialized_file.v1",
            json!({
                "type": "object",
                "required": ["canonicalPath", "relativePath", "entryType", "contentHash", "sizeBytes"],
                "additionalProperties": true,
                "properties": {
                    "canonicalPath": {"type": "string"},
                    "relativePath": {"type": "string"},
                    "entryType": {"type": "string", "enum": ["file", "directory"]},
                    "content": {"type": "string"},
                    "contentHash": {"type": "string"},
                    "sizeBytes": {"type": "integer"},
                    "mimeType": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "draft",
                "materialized",
                "promoted",
                "discarded",
                "damaged",
                "quarantined",
                "archived",
            ],
            vec![
                "applies_patch",
                "derived_from",
                "materializes",
                "produced",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "patch_proposal",
            "tron.resource.patch_proposal.v1",
            json!({
                "type": "object",
                "required": ["targetPath", "diff", "status"],
                "additionalProperties": true,
                "properties": {
                    "targetPath": {"type": "string"},
                    "targetResourceId": {"type": "string"},
                    "baseVersionId": {"type": "string"},
                    "baseContentHash": {"type": "string"},
                    "diff": {"type": "string"},
                    "status": {"type": "string"},
                    "result": {"type": "object"}
                }
            }),
            vec![
                "proposed",
                "applied",
                "merged",
                "rejected",
                "discarded",
                "archived",
            ],
            vec![
                "applies_to",
                "produces",
                "produced",
                "derived_from",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "apply": ["resource.write"]}),
        ),
        builtin_type(
            "capability_definition",
            "tron.resource.capability_definition.v1",
            json!({
                "type": "object",
                "required": ["functionId", "definition"],
                "additionalProperties": true,
                "properties": {
                    "functionId": {"type": "string"},
                    "definition": {"type": "object"},
                    "generatedBy": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "reviewed", "promoted", "discarded", "archived"],
            vec![
                "candidate_output",
                "derived_from",
                "promoted_output",
                "supported_by",
                "evidence_for",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "worker_activation",
            "tron.resource.worker_activation.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "functionId",
                    "workerId",
                    "candidateResourceId",
                    "decisionResourceId",
                    "evidenceResourceIds",
                    "targetVisibility",
                    "scope",
                    "activationReason",
                    "expiresAt",
                    "grantId",
                    "tokenFingerprint",
                    "governanceFingerprint",
                    "expectedFunctionDefinition",
                    "registrationMode",
                    "networkPolicy"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string"},
                    "functionId": {"type": "string"},
                    "workerId": {"type": "string"},
                    "candidateResourceId": {"type": "string"},
                    "decisionResourceId": {"type": "string"},
                    "evidenceResourceIds": {"type": "array", "minItems": 1, "items": {"type": "string"}},
                    "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
                    "scope": {
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {
                            "sessionId": {"type": ["string", "null"]},
                            "workspaceId": {"type": ["string", "null"]}
                        }
                    },
                    "activationReason": {"type": "string"},
                    "expiresAt": {"type": "string"},
                    "grantId": {"type": "string"},
                    "tokenFingerprint": {"type": "string"},
                    "governanceFingerprint": {"type": "string"},
                    "workerProcessResourceId": {"type": "string"},
                    "expectedFunctionDefinition": {"type": "object"},
                    "registrationMode": {"type": "string", "enum": ["volatile"]},
                    "networkPolicy": {"type": "string", "enum": ["loopback"]},
                    "tokenStorage": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "issued",
                "connected",
                "registered",
                "disconnected",
                "expired",
                "revoked",
                "failed",
                "archived",
            ],
            vec![
                "activates",
                "decided_by",
                "supported_by",
                "evidence_for",
                "derived_from",
                "revokes",
                "supersedes",
            ],
            json!({"read": ["resource.read"], "write": ["worker.activate", "resource.write"], "delete": ["worker.activate", "resource.write"]}),
        ),
        builtin_type(
            "worker_launch_plan",
            "tron.resource.worker_launch_plan.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "expectedWorkerId",
                    "expectedFunctionId",
                    "targetVisibility",
                    "scope",
                    "namespace",
                    "executable",
                    "argv",
                    "argvAllowlist",
                    "envAllowlist",
                    "cwdPolicy",
                    "startupTimeoutMs",
                    "stopTimeoutMs",
                    "maxLogCaptureBytes",
                    "activationDeliveryMode",
                    "governance"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string", "enum": ["reviewed"]},
                    "expectedWorkerId": {"type": "string"},
                    "expectedFunctionId": {"type": "string"},
                    "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
                    "scope": {
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {
                            "sessionId": {"type": ["string", "null"]},
                            "workspaceId": {"type": ["string", "null"]}
                        }
                    },
                    "namespace": {"type": "string"},
                    "executable": {
                        "type": "object",
                        "required": ["path", "sha256", "pathPolicy"],
                        "additionalProperties": false,
                        "properties": {
                            "path": {"type": "string"},
                            "sha256": {"type": "string"},
                            "pathPolicy": {"type": "string", "enum": ["absolute_file"]}
                        }
                    },
                    "argv": {"type": "array", "items": {"type": "string"}},
                    "argvAllowlist": {"type": "array", "items": {"type": "string"}},
                    "env": {
                        "type": "object",
                        "additionalProperties": true
                    },
                    "envAllowlist": {"type": "array", "items": {"type": "string"}},
                    "cwd": {"type": ["string", "null"]},
                    "cwdPolicy": {"type": "string", "enum": ["none", "exact"]},
                    "startupTimeoutMs": {"type": "integer"},
                    "stopTimeoutMs": {"type": "integer"},
                    "maxLogCaptureBytes": {"type": "integer"},
                    "activationDeliveryMode": {
                        "type": "string",
                        "enum": ["preissued_bundle", "stdin_activation_bundle_v1"]
                    },
                    "governance": {
                        "type": "object",
                        "required": ["reviewed", "decisionResourceId", "evidenceResourceIds"],
                        "additionalProperties": true,
                        "properties": {
                            "reviewed": {"type": "boolean"},
                            "decisionResourceId": {"type": "string"},
                            "evidenceResourceIds": {"type": "array", "items": {"type": "string"}}
                        }
                    }
                }
            }),
            vec!["draft", "reviewed", "revoked", "archived"],
            vec![
                "launches",
                "activates",
                "decided_by",
                "supported_by",
                "evidence_for",
                "derived_from",
                "revokes",
                "supersedes",
            ],
            json!({"read": ["resource.read"], "write": ["worker.launch", "resource.write"], "delete": ["worker.launch", "resource.write"]}),
        ),
        builtin_type(
            "worker_autostart_plan",
            "tron.resource.worker_autostart_plan.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "triggerId",
                    "launchPlanResourceId",
                    "functionId",
                    "candidateResourceId",
                    "decisionResourceId",
                    "evidenceResourceIds",
                    "targetVisibility",
                    "activationReason",
                    "policy"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string", "enum": ["reviewed"]},
                    "triggerId": {"type": "string"},
                    "launchPlanResourceId": {"type": "string"},
                    "functionId": {"type": "string"},
                    "candidateResourceId": {"type": "string"},
                    "decisionResourceId": {"type": "string"},
                    "evidenceResourceIds": {"type": "array", "minItems": 1, "items": {"type": "string"}},
                    "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
                    "workspaceId": {"type": ["string", "null"]},
                    "expiresAt": {"type": "string"},
                    "activationReason": {"type": "string"},
                    "policy": {
                        "type": "object",
                        "required": ["deliveryMode", "restartPolicy", "duplicatePolicy"],
                        "additionalProperties": false,
                        "properties": {
                            "deliveryMode": {"type": "string", "enum": ["stdin_activation_bundle_v1"]},
                            "restartPolicy": {"type": "string", "enum": ["none"]},
                            "duplicatePolicy": {"type": "string", "enum": ["idempotency_key_replay_v1"]}
                        }
                    }
                }
            }),
            vec!["draft", "reviewed", "revoked", "archived"],
            vec![
                "launches",
                "activates",
                "uses_plan",
                "caused_by",
                "decided_by",
                "supported_by",
                "evidence_for",
                "derived_from",
                "revokes",
                "supersedes",
            ],
            json!({"read": ["resource.read"], "write": ["worker.launch", "worker.activate", "resource.write"], "delete": ["worker.launch", "resource.write"]}),
        ),
        builtin_type(
            "worker_trigger_launch_attempt",
            "tron.resource.worker_trigger_launch_attempt.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "attemptId",
                    "triggerId",
                    "autostartPlanResourceId",
                    "launchPlanResourceId",
                    "functionId",
                    "targetVisibility",
                    "scope",
                    "idempotency",
                    "trace",
                    "policy",
                    "metadata"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string", "enum": [
                        "requested",
                        "activation_issued",
                        "launch_starting",
                        "ready_pending",
                        "failed"
                    ]},
                    "attemptId": {"type": "string"},
                    "triggerId": {"type": "string"},
                    "autostartPlanResourceId": {"type": "string"},
                    "launchPlanResourceId": {"type": "string"},
                    "activationResourceId": {"type": ["string", "null"]},
                    "workerProcessResourceId": {"type": ["string", "null"]},
                    "functionId": {"type": "string"},
                    "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
                    "scope": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "trace": {"type": "object"},
                    "policy": {"type": "object"},
                    "error": {"type": ["object", "null"]},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "requested",
                "activation_issued",
                "launch_starting",
                "ready_pending",
                "failed",
                "archived",
            ],
            vec![
                "caused_by",
                "activates",
                "launches",
                "uses_plan",
                "audits",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["worker.launch", "worker.activate", "resource.write"], "delete": ["worker.launch", "resource.write"]}),
        ),
        builtin_type(
            "worker_process",
            "tron.resource.worker_process.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "activationResourceId",
                    "launchPlanResourceId",
                    "workerProcessResourceId",
                    "workerId",
                    "functionId",
                    "targetVisibility",
                    "namespace",
                    "scope",
                    "launch",
                    "activationHandoff",
                    "process",
                    "readiness",
                    "logs",
                    "exit",
                    "metadata"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string", "enum": [
                        "requested",
                        "starting",
                        "hello_seen",
                        "ready",
                        "unhealthy",
                        "stopping",
                        "stopped",
                        "failed",
                        "killed",
                        "expired",
                        "revoked",
                        "archived"
                    ]},
                    "activationResourceId": {"type": "string"},
                    "launchPlanResourceId": {"type": "string"},
                    "workerProcessResourceId": {"type": "string"},
                    "workerId": {"type": "string"},
                    "functionId": {"type": "string"},
                    "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
                    "namespace": {"type": "string"},
                    "scope": {"type": "object"},
                    "launch": {"type": "object"},
                    "activationHandoff": {"type": "object"},
                    "process": {"type": "object"},
                    "readiness": {"type": "object"},
                    "logs": {"type": "object"},
                    "exit": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "requested",
                "starting",
                "hello_seen",
                "ready",
                "unhealthy",
                "stopping",
                "stopped",
                "failed",
                "killed",
                "expired",
                "revoked",
                "archived",
            ],
            vec![
                "launched_by",
                "activates",
                "uses_plan",
                "audits",
                "derived_from",
                "revokes",
                "supersedes",
            ],
            json!({"read": ["resource.read"], "write": ["worker.launch", "resource.write"], "delete": ["worker.launch", "resource.write"]}),
        ),
    ];
    definitions.extend(agent_record_resource_type_definitions());
    definitions.extend(worker_schedule_resource_type_definitions());
    definitions
}

pub(crate) fn type_definition_from_request(
    request: RegisterResourceType,
    revision: u64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
) -> EngineResourceTypeDefinition {
    EngineResourceTypeDefinition {
        kind: request.kind,
        schema_id: request.schema_id,
        schema: request.schema,
        lifecycle_states: request.lifecycle_states,
        versioning_mode: request.versioning_mode,
        allowed_link_relations: request.allowed_link_relations,
        default_retention: request.default_retention,
        redaction_rules: request.redaction_rules,
        materialization_rules: request.materialization_rules,
        required_capabilities: request.required_capabilities,
        owner_worker_id: request.owner_worker_id,
        revision,
        created_at,
        updated_at,
    }
}

pub(super) fn builtin_type(
    kind: &str,
    schema_id: &str,
    schema: Value,
    lifecycle_states: Vec<&str>,
    allowed_link_relations: Vec<&str>,
    required_capabilities: Value,
) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema,
        lifecycle_states: lifecycle_states.into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: allowed_link_relations
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities,
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
