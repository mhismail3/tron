//! Module lifecycle state resource definition.
//!
//! Lifecycle state records are metadata-only enable/disable/quarantine/rollback
//! transitions for install-candidate modules. They do not install, activate,
//! execute, restore dependencies, run package managers, create physical
//! workspaces, or access networks.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_lifecycle_state.v1";

pub(super) fn module_lifecycle_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: MODULE_LIFECYCLE_STATE_KIND.to_owned(),
        schema_id: MODULE_LIFECYCLE_STATE_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "transitionId",
                "scope",
                "installDecision",
                "transition",
                "previous",
                "approval",
                "rollback",
                "runtimeAuthorization",
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
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["pending", "enabled", "disabled", "quarantined", "rolled_back", "archived"]},
                "transitionId": {"type": "string"},
                "scope": {"type": "object"},
                "installDecision": {"type": "object"},
                "transition": {"type": "object"},
                "previous": {"type": "object"},
                "approval": {"type": "object"},
                "rollback": {"type": "object"},
                "runtimeAuthorization": {"type": "object"},
                "evidenceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
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
            "pending",
            "enabled",
            "disabled",
            "quarantined",
            "rolled_back",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        allowed_link_relations: [
            "install_decision",
            "approval_request",
            "approval_decision",
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
            "class": "module_lifecycle_state",
            "scope": "session_or_workspace",
            "archiveKeepsLifecycleEvidence": true
        }),
        redaction_rules: json!({
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
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "metadataOnly": true,
            "install": "forbidden",
            "activation": "forbidden",
            "execution": "forbidden",
            "commandExecution": "forbidden",
            "dependencyRestore": "forbidden",
            "packageManager": "forbidden",
            "networkPolicy": "none",
            "physicalWorkspaceDirectory": "forbidden",
            "repoManagedSkills": "forbidden",
            "approvalIsAuthority": false,
            "derivedAuthorityRequired": true,
            "runtimeGuard": "fail_closed_disabled_quarantined"
        }),
        required_capabilities: json!({
            "read": ["module_lifecycle.read", "resource.read"],
            "write": ["module_lifecycle.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_lifecycle").expect("valid static worker id"),
    }]
}

fn side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "metadataOnly",
            "installPerformed",
            "activationPerformed",
            "executionPerformed",
            "rollbackExecuted",
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
            "rollbackExecuted": {"type": "boolean", "const": false},
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
