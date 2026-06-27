//! Module install review-gate resource definitions.
//!
//! Install requests and decisions are metadata-only lifecycle gate records.
//! They promote a passed validation report into review and then into an
//! install-candidate or rejected decision with approval evidence, but never
//! install, enable, execute, restore dependencies, run package managers, create
//! physical workspaces, or access networks.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_DECISION_SCHEMA_ID,
    MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_REQUEST_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_INSTALL_REQUEST_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_install_request.v1";
pub(crate) const MODULE_INSTALL_DECISION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_install_decision.v1";

pub(super) fn module_install_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![install_request_definition(), install_decision_definition()]
}

fn install_request_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: MODULE_INSTALL_REQUEST_KIND.to_owned(),
        schema_id: MODULE_INSTALL_REQUEST_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "requestId",
                "scope",
                "identity",
                "validationReport",
                "dependencyPolicy",
                "rollback",
                "evidenceRefs",
                "installGate",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_INSTALL_REQUEST_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["pending_review", "superseded", "archived"]},
                "requestId": {"type": "string"},
                "scope": {"type": "object"},
                "identity": {
                    "type": "object",
                    "required": ["title", "summary"],
                    "additionalProperties": false,
                    "properties": {
                        "title": {"type": "string"},
                        "summary": {"type": "string"}
                    }
                },
                "validationReport": {"type": "object"},
                "dependencyPolicy": {"type": "object"},
                "rollback": {"type": "object"},
                "evidenceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "installGate": {"type": "object"},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "sideEffectProof": side_effect_schema(),
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "pending_review",
            "install_candidate",
            "rejected",
            "superseded",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        allowed_link_relations: [
            "validation_report",
            "dependency_policy",
            "rollback_proof",
            "evidence_for",
            "derived_from",
            "supersedes",
            "decided_by",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": "module_install_request",
            "scope": "session_or_workspace",
            "archiveKeepsReviewEvidence": true
        }),
        redaction_rules: redaction_rules(),
        materialization_rules: materialization_rules(),
        required_capabilities: json!({
            "read": ["module_install.read", "resource.read"],
            "write": ["module_install.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_install").expect("valid static worker id"),
    }
}

fn install_decision_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: MODULE_INSTALL_DECISION_KIND.to_owned(),
        schema_id: MODULE_INSTALL_DECISION_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "decisionId",
                "scope",
                "request",
                "validationReport",
                "approval",
                "decision",
                "dependencyPolicy",
                "rollback",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_INSTALL_DECISION_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["install_candidate", "rejected", "superseded", "archived"]},
                "decisionId": {"type": "string"},
                "scope": {"type": "object"},
                "request": {"type": "object"},
                "validationReport": {"type": "object"},
                "approval": {"type": "object"},
                "decision": {"type": "object"},
                "dependencyPolicy": {"type": "object"},
                "rollback": {"type": "object"},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "sideEffectProof": side_effect_schema(),
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "pending_review",
            "install_candidate",
            "rejected",
            "superseded",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        allowed_link_relations: [
            "decision_for",
            "validation_report",
            "approval_request",
            "approval_decision",
            "dependency_policy",
            "rollback_proof",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": "module_install_decision",
            "scope": "session_or_workspace",
            "archiveKeepsApprovalEvidence": true
        }),
        redaction_rules: redaction_rules(),
        materialization_rules: materialization_rules(),
        required_capabilities: json!({
            "read": ["module_install.read", "resource.read"],
            "write": ["module_install.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_install").expect("valid static worker id"),
    }
}

fn side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "metadataOnly",
            "installPerformed",
            "activationPerformed",
            "executionPerformed",
            "dependencyRestorePerformed",
            "packageManagerUsed",
            "networkPolicy",
            "networkAccessPerformed",
            "repoManagedSkillsTouched",
            "physicalWorkspaceDirectoryCreated",
            "rawCommandsStored",
            "rawLogsStored",
            "fileContentsStored",
            "absolutePathsStored"
        ],
        "additionalProperties": false,
        "properties": {
            "metadataOnly": {"type": "boolean", "const": true},
            "installPerformed": {"type": "boolean", "const": false},
            "activationPerformed": {"type": "boolean", "const": false},
            "executionPerformed": {"type": "boolean", "const": false},
            "dependencyRestorePerformed": {"type": "boolean", "const": false},
            "packageManagerUsed": {"type": "boolean", "const": false},
            "networkPolicy": {"type": "string", "const": "none"},
            "networkAccessPerformed": {"type": "boolean", "const": false},
            "repoManagedSkillsTouched": {"type": "boolean", "const": false},
            "physicalWorkspaceDirectoryCreated": {"type": "boolean", "const": false},
            "rawCommandsStored": {"type": "boolean", "const": false},
            "rawLogsStored": {"type": "boolean", "const": false},
            "fileContentsStored": {"type": "boolean", "const": false},
            "absolutePathsStored": {"type": "boolean", "const": false}
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
        "approval": "evidence_only_not_authority",
        "refs": "resource_backed_bounded_metadata_only"
    })
}

fn materialization_rules() -> serde_json::Value {
    json!({
        "durableOutputsRequireResourceVersion": true,
        "metadataOnly": true,
        "install": "forbidden",
        "installCandidate": "metadata_gate_state_only",
        "activation": "forbidden",
        "execution": "forbidden",
        "commandExecution": "forbidden",
        "dependencyRestore": "forbidden",
        "packageManager": "forbidden",
        "networkPolicy": "none",
        "physicalWorkspaceDirectory": "forbidden",
        "repoManagedSkills": "forbidden",
        "approvalIsAuthority": false,
        "derivedAuthorityRequired": true
    })
}
