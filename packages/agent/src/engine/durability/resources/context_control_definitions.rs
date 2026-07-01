//! Context-control resource definitions.
//!
//! Context-control records are durable, provider-safe metadata for inspecting
//! and changing the active session context epoch. They never store raw prompt
//! bodies, hidden reasoning, commands, logs, local paths, secrets, grants, or
//! authority identifiers.

use serde_json::json;

use super::types::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_EPOCH_SCHEMA_ID, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, EngineResourceVersioningMode, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_snapshot.v1";
pub(crate) const CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_action.v1";
pub(crate) const CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_epoch.v1";

pub(super) fn context_control_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        RegisterResourceType {
            kind: CONTEXT_CONTROL_SNAPSHOT_KIND.to_owned(),
            schema_id: CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "snapshotId",
                    "scope",
                    "session",
                    "composition",
                    "memory",
                    "proof",
                    "createdAt",
                    "revision"
                ],
                "additionalProperties": false,
                "properties": {
                    "schemaVersion": {"type": "string", "const": CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION},
                    "state": {"type": "string", "enum": ["available", "stale", "archived"]},
                    "snapshotId": {"type": "string"},
                    "scope": {"type": "object"},
                    "session": {"type": "object"},
                    "composition": {"type": "object"},
                    "memory": {"type": "object"},
                    "proof": proof_schema(),
                    "createdAt": {"type": "string"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["available", "stale", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            allowed_link_relations: [
                "snapshots",
                "supports",
                "derived_from",
                "evidence_for",
                "supersedes",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            default_retention: json!({
                "class": "context_control_snapshot",
                "scope": "session",
                "archiveKeepsAuditEvidence": true
            }),
            redaction_rules: redaction_rules("snapshot_provider_safe"),
            materialization_rules: materialization_rules("snapshot_only"),
            required_capabilities: json!({
                "read": ["context_control.read", "resource.read"],
                "write": ["context_control.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("context_control").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: CONTEXT_CONTROL_ACTION_KIND.to_owned(),
            schema_id: CONTEXT_CONTROL_ACTION_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "actionId",
                    "scope",
                    "action",
                    "preflight",
                    "result",
                    "auditRefs",
                    "proof",
                    "idempotency",
                    "traceRefs",
                    "replayRefs",
                    "createdAt",
                    "updatedAt",
                    "revision"
                ],
                "additionalProperties": false,
                "properties": {
                    "schemaVersion": {"type": "string", "const": CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION},
                    "state": {"type": "string", "enum": ["requested", "succeeded", "skipped", "failed", "archived"]},
                    "actionId": {"type": "string"},
                    "scope": {"type": "object"},
                    "action": {"type": "object"},
                    "preflight": {"type": "object"},
                    "result": {"type": "object"},
                    "auditRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "proof": proof_schema(),
                    "idempotency": {"type": "object"},
                    "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "createdAt": {"type": "string"},
                    "updatedAt": {"type": "string"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["requested", "succeeded", "skipped", "failed", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            allowed_link_relations: [
                "uses_snapshot",
                "creates_epoch",
                "writes_timeline_event",
                "supports",
                "derived_from",
                "evidence_for",
                "supersedes",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            default_retention: json!({
                "class": "context_control_action",
                "scope": "session",
                "archiveKeepsAuditEvidence": true
            }),
            redaction_rules: redaction_rules("action_audit_provider_safe"),
            materialization_rules: materialization_rules("action_audit_only"),
            required_capabilities: json!({
                "read": ["context_control.read", "resource.read"],
                "write": ["context_control.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("context_control").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: CONTEXT_CONTROL_EPOCH_KIND.to_owned(),
            schema_id: CONTEXT_CONTROL_EPOCH_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "epochId",
                    "scope",
                    "session",
                    "boundary",
                    "survivorRefs",
                    "proof",
                    "createdAt",
                    "revision"
                ],
                "additionalProperties": false,
                "properties": {
                    "schemaVersion": {"type": "string", "const": CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION},
                    "state": {"type": "string", "enum": ["active", "superseded", "archived"]},
                    "epochId": {"type": "string"},
                    "scope": {"type": "object"},
                    "session": {"type": "object"},
                    "boundary": {"type": "object"},
                    "survivorRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "proof": proof_schema(),
                    "createdAt": {"type": "string"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["active", "superseded", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            allowed_link_relations: [
                "created_by",
                "supersedes_epoch",
                "keeps_ref",
                "supports",
                "derived_from",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            default_retention: json!({
                "class": "context_control_epoch",
                "scope": "session",
                "archiveKeepsAuditEvidence": true
            }),
            redaction_rules: redaction_rules("epoch_boundary_provider_safe"),
            materialization_rules: materialization_rules("epoch_boundary_only"),
            required_capabilities: json!({
                "read": ["context_control.read", "resource.read"],
                "write": ["context_control.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("context_control").expect("valid static worker id"),
        },
    ]
}

fn proof_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": [
            "providerSafe",
            "redactionApplied",
            "truncationApplied",
            "hiddenPromptBodiesExcluded",
            "rawSecretsExcluded",
            "rawLogsExcluded",
            "rawCommandsExcluded",
            "rawPathsExcluded",
            "rawGrantIdsExcluded",
            "rawAuthorityIdsExcluded",
            "chainOfThoughtExcluded",
            "networkPolicy"
        ],
        "additionalProperties": false,
        "properties": {
            "providerSafe": {"type": "boolean", "const": true},
            "redactionApplied": {"type": "boolean", "const": true},
            "truncationApplied": {"type": "boolean"},
            "hiddenPromptBodiesExcluded": {"type": "boolean", "const": true},
            "rawSecretsExcluded": {"type": "boolean", "const": true},
            "rawLogsExcluded": {"type": "boolean", "const": true},
            "rawCommandsExcluded": {"type": "boolean", "const": true},
            "rawPathsExcluded": {"type": "boolean", "const": true},
            "rawGrantIdsExcluded": {"type": "boolean", "const": true},
            "rawAuthorityIdsExcluded": {"type": "boolean", "const": true},
            "chainOfThoughtExcluded": {"type": "boolean", "const": true},
            "networkPolicy": {"type": "string", "const": "none"}
        }
    })
}

fn redaction_rules(projection: &str) -> serde_json::Value {
    json!({
        "projection": projection,
        "neverReturn": [
            "systemPrompt",
            "soulPrompt",
            "hiddenPrompt",
            "chainOfThought",
            "thinking",
            "secret",
            "env",
            "absolutePath",
            "rawPath",
            "command",
            "rawCommand",
            "stdout",
            "stderr",
            "rawLog",
            "fileContents",
            "grantId",
            "authorityId",
            "debugPayload"
        ],
        "providerOutput": "bounded_refs_and_labels_only"
    })
}

fn materialization_rules(classification: &str) -> serde_json::Value {
    json!({
        "classification": classification,
        "metadataOnly": true,
        "providerSafeProjectionRequired": true,
        "stateInheritance": "forbidden",
        "agentState": "forbidden",
        "networkPolicy": "none",
        "packageManager": "forbidden",
        "runtimeExecution": "forbidden",
        "rawLogs": "forbidden",
        "rawCommands": "forbidden",
        "secrets": "forbidden",
        "localPaths": "forbidden"
    })
}
