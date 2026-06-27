//! Module dependency request, decision, and policy resource definitions.
//!
//! These resources store dependency rationale and policy metadata only. They
//! never restore dependencies, run package managers, mutate manifests or
//! lockfiles, store raw package-manager output, or access networks.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_DEPENDENCY_DECISION_KIND,
    MODULE_DEPENDENCY_DECISION_SCHEMA_ID, MODULE_DEPENDENCY_POLICY_KIND,
    MODULE_DEPENDENCY_POLICY_SCHEMA_ID, MODULE_DEPENDENCY_REQUEST_KIND,
    MODULE_DEPENDENCY_REQUEST_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_DEPENDENCY_REQUEST_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_dependency_request.v1";
pub(crate) const MODULE_DEPENDENCY_DECISION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_dependency_decision.v1";
pub(crate) const MODULE_DEPENDENCY_POLICY_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_dependency_policy.v1";

pub(super) fn module_dependencies_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        dependency_request_definition(),
        dependency_decision_definition(),
        dependency_policy_definition(),
    ]
}

fn dependency_request_definition() -> RegisterResourceType {
    definition(
        MODULE_DEPENDENCY_REQUEST_KIND,
        MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
        MODULE_DEPENDENCY_REQUEST_PAYLOAD_SCHEMA_VERSION,
        "module_dependency_request",
        ["pending_review", "superseded", "archived"].as_slice(),
        [
            "module_owner",
            "proposal_ref",
            "validation_ref",
            "install_ref",
            "runtime_ref",
            "dependency_request",
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
                "owner",
                "dependency",
                "needs",
                "parityEvidence",
                "evidenceRefs",
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
                "owner": {"type": "object"},
                "dependency": {"type": "object"},
                "needs": {"type": "object"},
                "parityEvidence": {"type": "object"},
                "evidenceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
            }
        }),
    )
}

fn dependency_decision_definition() -> RegisterResourceType {
    definition(
        MODULE_DEPENDENCY_DECISION_KIND,
        MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
        MODULE_DEPENDENCY_DECISION_PAYLOAD_SCHEMA_VERSION,
        "module_dependency_decision",
        ["approved_policy", "rejected", "superseded", "archived"].as_slice(),
        [
            "decision_for",
            "dependency_request",
            "dependency_policy_candidate",
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
                "owner",
                "dependency",
                "needs",
                "parityEvidence",
                "decision",
                "policyCandidate",
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
                "owner": {"type": "object"},
                "dependency": {"type": "object"},
                "needs": {"type": "object"},
                "parityEvidence": {"type": "object"},
                "decision": {"type": "object"},
                "policyCandidate": {"type": "object"}
            }
        }),
    )
}

fn dependency_policy_definition() -> RegisterResourceType {
    definition(
        MODULE_DEPENDENCY_POLICY_KIND,
        MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
        MODULE_DEPENDENCY_POLICY_PAYLOAD_SCHEMA_VERSION,
        "module_dependency_policy",
        ["active", "superseded", "archived"].as_slice(),
        [
            "policy_for",
            "dependency_decision",
            "dependency_request",
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
                "owner",
                "dependency",
                "needs",
                "parityEvidence",
                "activation",
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
                "owner": {"type": "object"},
                "dependency": {"type": "object"},
                "needs": {"type": "object"},
                "parityEvidence": {"type": "object"},
                "activation": {"type": "object"}
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
            "read": ["module_dependencies.read", "resource.read"],
            "write": ["module_dependencies.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_dependencies").expect("valid static worker id"),
    }
}

fn side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "metadataOnly",
            "dependencyRestorePerformed",
            "packageManagerUsed",
            "manifestMutated",
            "lockfileMutated",
            "activationPerformed",
            "executionPerformed",
            "networkPolicy",
            "networkAccessPerformed",
            "repoManagedSkillsTouched",
            "physicalWorkspaceDirectoryCreated",
            "rawCommandsStored",
            "rawLogsStored",
            "fileContentsStored",
            "absolutePathsStored",
            "rawDependencyArtifactsStored",
            "packageManagerOutputStored"
        ],
        "additionalProperties": false,
        "properties": {
            "metadataOnly": {"type": "boolean", "const": true},
            "dependencyRestorePerformed": {"type": "boolean", "const": false},
            "packageManagerUsed": {"type": "boolean", "const": false},
            "manifestMutated": {"type": "boolean", "const": false},
            "lockfileMutated": {"type": "boolean", "const": false},
            "activationPerformed": {"type": "boolean", "const": false},
            "executionPerformed": {"type": "boolean", "const": false},
            "networkPolicy": {"type": "string", "const": "none"},
            "networkAccessPerformed": {"type": "boolean", "const": false},
            "repoManagedSkillsTouched": {"type": "boolean", "const": false},
            "physicalWorkspaceDirectoryCreated": {"type": "boolean", "const": false},
            "rawCommandsStored": {"type": "boolean", "const": false},
            "rawLogsStored": {"type": "boolean", "const": false},
            "fileContentsStored": {"type": "boolean", "const": false},
            "absolutePathsStored": {"type": "boolean", "const": false},
            "rawDependencyArtifactsStored": {"type": "boolean", "const": false},
            "packageManagerOutputStored": {"type": "boolean", "const": false}
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
            "chainOfThought",
            "packageManagerOutput",
            "rawDependencyArtifacts"
        ],
        "refs": "resource_backed_bounded_metadata_only"
    })
}

fn materialization_rules() -> serde_json::Value {
    json!({
        "durableOutputsRequireResourceVersion": true,
        "metadataOnly": true,
        "dependencyRestore": "forbidden",
        "packageManager": "forbidden",
        "manifestMutation": "forbidden",
        "lockfileMutation": "forbidden",
        "policyActivation": "metadata_only",
        "execution": "forbidden",
        "networkPolicy": "none",
        "physicalWorkspaceDirectory": "forbidden",
        "repoManagedSkills": "forbidden"
    })
}
