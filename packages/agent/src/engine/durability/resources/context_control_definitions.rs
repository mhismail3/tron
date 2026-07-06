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
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID,
    CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND,
    CONTEXT_SURVIVOR_SCHEMA_ID, EngineResourceVersioningMode, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_snapshot.v1";
pub(crate) const CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_action.v1";
pub(crate) const CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_control_epoch.v1";
pub(crate) const CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION: &str = "tron.context_survivor.v1";
pub(crate) const CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION: &str = "tron.context_exclusion.v1";
pub(crate) const CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.context_policy_snapshot.v1";

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
        policy_record_definition(
            CONTEXT_SURVIVOR_KIND,
            CONTEXT_SURVIVOR_SCHEMA_ID,
            CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION,
            "context_survivor",
            ["active", "disabled", "archived"],
            ["pins_ref", "supports", "derived_from", "evidence_for"],
        ),
        policy_record_definition(
            CONTEXT_EXCLUSION_KIND,
            CONTEXT_EXCLUSION_SCHEMA_ID,
            CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION,
            "context_exclusion",
            ["active", "disabled", "archived"],
            ["excludes_ref", "supports", "derived_from", "evidence_for"],
        ),
        RegisterResourceType {
            kind: CONTEXT_POLICY_SNAPSHOT_KIND.to_owned(),
            schema_id: CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "policySnapshotId",
                    "scope",
                    "session",
                    "policy",
                    "survivorRefs",
                    "exclusionRefs",
                    "proof",
                    "idempotency",
                    "traceRefs",
                    "replayRefs",
                    "createdAt",
                    "revision"
                ],
                "additionalProperties": false,
                "properties": {
                    "schemaVersion": {"type": "string", "const": CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION},
                    "state": {"type": "string", "enum": ["available", "stale", "archived"]},
                    "policySnapshotId": {"type": "string"},
                    "scope": {"type": "object"},
                    "session": {"type": "object"},
                    "policy": {"type": "object"},
                    "survivorRefs": {"type": "array", "maxItems": 50, "items": {"type": "object"}},
                    "exclusionRefs": {"type": "array", "maxItems": 50, "items": {"type": "object"}},
                    "proof": proof_schema(),
                    "idempotency": {"type": "object"},
                    "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                    "createdAt": {"type": "string"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["available", "stale", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            allowed_link_relations: [
                "includes_survivor",
                "includes_exclusion",
                "supports",
                "derived_from",
                "evidence_for",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            default_retention: json!({
                "class": "context_policy_snapshot",
                "scope": "session",
                "archiveKeepsAuditEvidence": true
            }),
            redaction_rules: redaction_rules("context_policy_snapshot_provider_safe"),
            materialization_rules: materialization_rules("context_policy_snapshot_only"),
            required_capabilities: json!({
                "read": ["context_control.read", "resource.read"],
                "write": ["context_control.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("context_control").expect("valid static worker id"),
        },
    ]
}

fn policy_record_definition(
    kind: &'static str,
    schema_id: &'static str,
    schema_version: &'static str,
    class: &'static str,
    states: impl IntoIterator<Item = &'static str>,
    links: impl IntoIterator<Item = &'static str>,
) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "policyId",
                "scope",
                "session",
                "target",
                "policy",
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
                "schemaVersion": {"type": "string", "const": schema_version},
                "state": {"type": "string", "enum": ["active", "disabled", "archived"]},
                "policyId": {"type": "string"},
                "scope": {"type": "object"},
                "session": {"type": "object"},
                "target": {"type": "object"},
                "policy": {"type": "object"},
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
        lifecycle_states: states.into_iter().map(str::to_owned).collect(),
        allowed_link_relations: links.into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        default_retention: json!({
            "class": class,
            "scope": "session",
            "archiveKeepsAuditEvidence": true
        }),
        redaction_rules: redaction_rules(class),
        materialization_rules: materialization_rules(class),
        required_capabilities: json!({
            "read": ["context_control.read", "resource.read"],
            "write": ["context_control.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("context_control").expect("valid static worker id"),
    }
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
