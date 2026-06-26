//! Module authoring resource definitions.
//!
//! Module proposals are inert authoring drafts. They store bounded metadata and
//! refs only; installation, activation, execution, dependency restoration, and
//! prompt inclusion remain outside this resource contract.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_PROPOSAL_KIND, MODULE_PROPOSAL_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_PROPOSAL_PAYLOAD_SCHEMA_VERSION: &str = "tron.module_proposal.v1";

pub(super) fn module_authoring_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: MODULE_PROPOSAL_KIND.to_owned(),
        schema_id: MODULE_PROPOSAL_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "proposalId",
                "scope",
                "identity",
                "intendedModuleRefs",
                "refs",
                "validation",
                "lifecycle",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "safetyProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_PROPOSAL_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["draft", "submitted", "superseded", "archived"]},
                "proposalId": {"type": "string"},
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
                "intendedModuleRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "refs": {
                    "type": "object",
                    "required": ["source", "docs", "tests", "trace", "replay"],
                    "additionalProperties": false,
                    "properties": {
                        "source": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "docs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "tests": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "trace": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "replay": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "validation": {
                    "type": "object",
                    "required": ["status", "placeholder", "checks"],
                    "additionalProperties": false,
                    "properties": {
                        "status": {"type": "string"},
                        "placeholder": {"type": "boolean"},
                        "checks": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "lifecycle": {"type": "object"},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "safetyProof": {
                    "type": "object",
                    "required": [
                        "noInstall",
                        "noExecution",
                        "dependencyRestorePerformed",
                        "packageManagerUsed",
                        "networkPolicy",
                        "networkAccessPerformed",
                        "repoManagedSkillsTouched",
                        "rawProposalBodyStored",
                        "rawPromptStored",
                        "commandsStored",
                        "fileContentsStored",
                        "absolutePathsStored"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "noInstall": {"type": "boolean", "const": true},
                        "noExecution": {"type": "boolean", "const": true},
                        "dependencyRestorePerformed": {"type": "boolean", "const": false},
                        "packageManagerUsed": {"type": "boolean", "const": false},
                        "networkPolicy": {"type": "string", "const": "none"},
                        "networkAccessPerformed": {"type": "boolean", "const": false},
                        "repoManagedSkillsTouched": {"type": "boolean", "const": false},
                        "rawProposalBodyStored": {"type": "boolean", "const": false},
                        "rawPromptStored": {"type": "boolean", "const": false},
                        "commandsStored": {"type": "boolean", "const": false},
                        "fileContentsStored": {"type": "boolean", "const": false},
                        "absolutePathsStored": {"type": "boolean", "const": false}
                    }
                },
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["draft", "submitted", "superseded", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "source",
            "doc",
            "test",
            "intended_module",
            "trace",
            "replay",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "module_authoring_proposal",
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
                "env",
                "dependencyInstall",
                "packageManager",
                "fileContents",
                "absolutePath",
                "grantId",
                "authorityId",
                "rawProposalBody"
            ],
            "refs": "resource_backed_bounded_metadata_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "install": "forbidden",
            "activation": "forbidden",
            "execution": "forbidden",
            "dependencyRestore": "forbidden",
            "networkPolicy": "none",
            "physicalWorkspaceDirectory": "forbidden"
        }),
        required_capabilities: json!({
            "read": ["module_authoring.read", "resource.read"],
            "write": ["module_authoring.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_authoring").expect("valid static worker id"),
    }]
}
