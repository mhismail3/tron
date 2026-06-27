//! Module runtime supervisor resource definition.
//!
//! Runtime state records are provider-safe supervision envelopes for enabled
//! modules. They store bounded refs and execution labels only; raw commands,
//! paths, logs, output, secrets, package-manager activity, and network access
//! are outside the resource contract.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_RUNTIME_STATE_KIND, MODULE_RUNTIME_STATE_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION: &str = "tron.module_runtime_state.v1";

pub(super) fn module_runtime_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: MODULE_RUNTIME_STATE_KIND.to_owned(),
        schema_id: MODULE_RUNTIME_STATE_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "runtimeRequestId",
                "scope",
                "moduleLifecycle",
                "runtime",
                "supervision",
                "inputRefs",
                "outputArtifactRefs",
                "evidenceRefs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "reason",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["requested", "running", "cancelled", "timed_out", "completed", "failed", "archived"]},
                "runtimeRequestId": {"type": "string"},
                "scope": {"type": "object"},
                "moduleLifecycle": {"type": "object"},
                "runtime": {"type": "object"},
                "supervision": {"type": "object"},
                "inputRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "outputArtifactRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "evidenceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "sideEffectProof": side_effect_schema(),
                "reason": {"type": "string"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "requested",
            "running",
            "cancelled",
            "timed_out",
            "completed",
            "failed",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        allowed_link_relations: [
            "module_lifecycle_state",
            "runtime_input",
            "runtime_output",
            "execution_artifact",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": "module_runtime_state",
            "scope": "session_or_workspace",
            "archiveKeepsRuntimeEvidence": true
        }),
        redaction_rules: json!({
            "projection": "supervisor_envelope_provider_safe",
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
                "stdin",
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
            "providerOutput": "resource_refs_only",
            "refs": "resource_backed_bounded_metadata_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "supervisorEnvelopeOnly": true,
            "lifecycleAuthorization": "enabled_required",
            "install": "forbidden",
            "activation": "forbidden",
            "dependencyRestore": "forbidden",
            "packageManager": "forbidden",
            "networkPolicy": "none",
            "pty": "forbidden_by_default",
            "browserAutomation": "forbidden_by_default",
            "rawCommands": "forbidden",
            "rawLogs": "forbidden",
            "rawOutput": "forbidden",
            "secrets": "forbidden",
            "providerOutput": "refs_only"
        }),
        required_capabilities: json!({
            "read": ["module_runtime.read", "resource.read"],
            "write": ["module_runtime.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_runtime").expect("valid static worker id"),
    }]
}

fn side_effect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "supervisorEnvelopeOnly",
            "installPerformed",
            "activationPerformed",
            "dependencyRestorePerformed",
            "packageManagerUsed",
            "networkPolicy",
            "networkAccessPerformed",
            "repoManagedSkillsTouched",
            "physicalWorkspaceDirectoryCreated",
            "ptyAllocated",
            "browserAutomationPerformed",
            "rawCommandsStored",
            "rawLogsStored",
            "rawOutputStored",
            "secretsExposed",
            "fileContentsStored",
            "absolutePathsStored"
        ],
        "additionalProperties": false,
        "properties": {
            "supervisorEnvelopeOnly": {"type": "boolean", "const": true},
            "installPerformed": {"type": "boolean", "const": false},
            "activationPerformed": {"type": "boolean", "const": false},
            "dependencyRestorePerformed": {"type": "boolean", "const": false},
            "packageManagerUsed": {"type": "boolean", "const": false},
            "networkPolicy": {"type": "string", "const": "none"},
            "networkAccessPerformed": {"type": "boolean", "const": false},
            "repoManagedSkillsTouched": {"type": "boolean", "const": false},
            "physicalWorkspaceDirectoryCreated": {"type": "boolean", "const": false},
            "ptyAllocated": {"type": "boolean", "const": false},
            "browserAutomationPerformed": {"type": "boolean", "const": false},
            "rawCommandsStored": {"type": "boolean", "const": false},
            "rawLogsStored": {"type": "boolean", "const": false},
            "rawOutputStored": {"type": "boolean", "const": false},
            "secretsExposed": {"type": "boolean", "const": false},
            "fileContentsStored": {"type": "boolean", "const": false},
            "absolutePathsStored": {"type": "boolean", "const": false}
        }
    })
}
