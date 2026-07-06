use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::contract::{
    ACTION_SCHEMA_VERSION, EPOCH_SCHEMA_VERSION, EXCLUSION_SCHEMA_VERSION,
    POLICY_SNAPSHOT_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE,
    SNAPSHOT_SCHEMA_VERSION, SURVIVOR_SCHEMA_VERSION, WRITE_SCOPE,
};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_EPOCH_KIND, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_EXCLUSION_KIND, CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_SURVIVOR_KIND,
};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.context_control.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.context_control.idempotency.v1\0";

pub(super) struct SnapshotInput<'a> {
    pub(super) snapshot_id: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) session_id: &'a str,
    pub(super) model: &'a str,
    pub(super) context_window: u64,
    pub(super) estimated_tokens: u64,
    pub(super) turn_count: u32,
    pub(super) message_count: usize,
    pub(super) prompt_blocks: Value,
    pub(super) memory: Value,
    pub(super) resource_refs: Vec<Value>,
    pub(super) execution_refs: Vec<Value>,
    pub(super) epoch_id: &'a str,
    pub(super) created_at: &'a str,
}

pub(super) fn snapshot_record(input: SnapshotInput<'_>) -> Value {
    let tokens_remaining = input.context_window.saturating_sub(input.estimated_tokens);
    #[allow(clippy::cast_precision_loss)]
    let usage_percent = if input.context_window == 0 {
        0.0
    } else {
        input.estimated_tokens as f64 / input.context_window as f64
    };
    json!({
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "state": "available",
        "snapshotId": input.snapshot_id,
        "scope": scope_ref(input.scope),
        "session": {
            "sessionId": input.session_id,
            "model": input.model,
            "contextWindowTokens": input.context_window,
            "estimatedTokens": input.estimated_tokens,
            "tokensRemaining": tokens_remaining,
            "usagePercent": usage_percent,
            "turnCount": input.turn_count,
            "messageCount": input.message_count,
            "currentEpoch": input.epoch_id
        },
        "composition": {
            "promptBlocks": input.prompt_blocks,
            "resourceRefs": input.resource_refs,
            "executionRefs": input.execution_refs,
            "bounded": true,
            "providerSafe": true
        },
        "memory": input.memory,
        "proof": provider_safe_proof(false),
        "createdAt": input.created_at,
        "revision": 1
    })
}

pub(super) struct ActionInput<'a> {
    pub(super) action_id: &'a str,
    pub(super) state: &'a str,
    pub(super) action_kind: &'a str,
    pub(super) reason: &'a str,
    pub(super) actor_kind: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) session_id: &'a str,
    pub(super) snapshot_resource: &'a EngineResource,
    pub(super) snapshot_version: &'a EngineResourceVersion,
    pub(super) expected_effect: &'a str,
    pub(super) result: Value,
    pub(super) audit_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
}

pub(super) fn action_record(input: ActionInput<'_>) -> Value {
    json!({
        "schemaVersion": ACTION_SCHEMA_VERSION,
        "state": input.state,
        "actionId": input.action_id,
        "scope": scope_ref(input.scope),
        "action": {
            "kind": input.action_kind,
            "reason": input.reason,
            "actorKind": input.actor_kind,
            "sessionId": input.session_id,
            "manualConfirmationRequired": input.action_kind == "clear" && input.actor_kind == "system",
            "agentApprovalRequired": false
        },
        "preflight": {
            "snapshot": version_ref(input.snapshot_resource, input.snapshot_version, "preflight_snapshot"),
            "expectedEffect": input.expected_effect,
            "policyProof": {
                "networkPolicy": "none",
                "metadataOnly": true,
                "providerSafeProjection": true,
                "historyDeletionPerformed": false,
                "resourcesDeleted": false
            }
        },
        "result": input.result,
        "auditRefs": input.audit_refs,
        "proof": provider_safe_proof(false),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": 1
    })
}

pub(super) struct EpochInput<'a> {
    pub(super) epoch_id: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) session_id: &'a str,
    pub(super) boundary_event_id: &'a str,
    pub(super) boundary_sequence: i64,
    pub(super) action_resource: &'a str,
    pub(super) created_at: &'a str,
}

pub(super) fn epoch_record(input: EpochInput<'_>) -> Value {
    json!({
        "schemaVersion": EPOCH_SCHEMA_VERSION,
        "state": "active",
        "epochId": input.epoch_id,
        "scope": scope_ref(input.scope),
        "session": {
            "sessionId": input.session_id
        },
        "boundary": {
            "eventId": input.boundary_event_id,
            "sequence": input.boundary_sequence,
            "actionResourceId": input.action_resource,
            "providerContextBeforeBoundaryExcluded": true,
            "historyStillInspectable": true
        },
        "survivorRefs": [
            {"kind": "session_history", "sessionId": input.session_id, "available": true},
            {"kind": "resource_store", "sessionId": input.session_id, "available": true},
            {"kind": "trace_refs", "sessionId": input.session_id, "available": true}
        ],
        "proof": provider_safe_proof(false),
        "createdAt": input.created_at,
        "revision": 1
    })
}

pub(super) struct PolicyRecordInput<'a> {
    pub(super) policy_id: &'a str,
    pub(super) schema_version: &'a str,
    pub(super) state: &'a str,
    pub(super) policy_kind: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) session_id: &'a str,
    pub(super) target_kind: &'a str,
    pub(super) target_ref: &'a str,
    pub(super) label: &'a str,
    pub(super) reason: &'a str,
    pub(super) priority: u64,
    pub(super) actor_kind: &'a str,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn policy_record(input: PolicyRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": input.schema_version,
        "state": input.state,
        "policyId": input.policy_id,
        "scope": scope_ref(input.scope),
        "session": {
            "sessionId": input.session_id
        },
        "target": {
            "kind": input.target_kind,
            "ref": input.target_ref,
            "label": input.label,
            "bodyExcluded": true,
            "providerSafeRefOnly": true
        },
        "policy": {
            "kind": input.policy_kind,
            "reason": input.reason,
            "priority": input.priority,
            "actorKind": input.actor_kind,
            "futureProviderContextBinding": if input.policy_kind == "survivor" {
                "must_preserve_ref"
            } else {
                "must_omit_ref"
            }
        },
        "auditRefs": [],
        "proof": provider_safe_proof(false),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) struct PolicySnapshotInput<'a> {
    pub(super) policy_snapshot_id: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) session_id: &'a str,
    pub(super) survivor_refs: Vec<Value>,
    pub(super) exclusion_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
}

pub(super) fn policy_snapshot_record(input: PolicySnapshotInput<'_>) -> Value {
    json!({
        "schemaVersion": POLICY_SNAPSHOT_SCHEMA_VERSION,
        "state": "available",
        "policySnapshotId": input.policy_snapshot_id,
        "scope": scope_ref(input.scope),
        "session": {
            "sessionId": input.session_id
        },
        "policy": {
            "serverOwned": true,
            "strategyReplaceable": false,
            "summarizerMustConsume": true,
            "survivorCount": input.survivor_refs.len(),
            "exclusionCount": input.exclusion_refs.len()
        },
        "survivorRefs": input.survivor_refs,
        "exclusionRefs": input.exclusion_refs,
        "proof": provider_safe_proof(false),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "createdAt": input.created_at,
        "revision": 1
    })
}

pub(super) fn snapshot_resource_id(session_id: &str, snapshot_id: &str) -> String {
    format!(
        "{CONTEXT_CONTROL_SNAPSHOT_KIND}:{}",
        sha256_hex(format!("session:{session_id}:snapshot:{snapshot_id}").as_bytes())
    )
}

pub(super) fn action_resource_id(
    session_id: &str,
    action_kind: &str,
    idempotency_key: &str,
) -> String {
    format!(
        "{CONTEXT_CONTROL_ACTION_KIND}:{}",
        sha256_hex(
            format!("session:{session_id}:action:{action_kind}:{idempotency_key}").as_bytes()
        )
    )
}

pub(super) fn epoch_resource_id(session_id: &str, epoch_id: &str) -> String {
    format!(
        "{CONTEXT_CONTROL_EPOCH_KIND}:{}",
        sha256_hex(format!("session:{session_id}:epoch:{epoch_id}").as_bytes())
    )
}

pub(super) fn survivor_resource_id(session_id: &str, idempotency_key: &str) -> String {
    format!(
        "{CONTEXT_SURVIVOR_KIND}:{}",
        sha256_hex(format!("session:{session_id}:survivor:{idempotency_key}").as_bytes())
    )
}

pub(super) fn exclusion_resource_id(session_id: &str, idempotency_key: &str) -> String {
    format!(
        "{CONTEXT_EXCLUSION_KIND}:{}",
        sha256_hex(format!("session:{session_id}:exclusion:{idempotency_key}").as_bytes())
    )
}

pub(super) fn policy_snapshot_resource_id(session_id: &str, idempotency_key: &str) -> String {
    format!(
        "{CONTEXT_POLICY_SNAPSHOT_KIND}:{}",
        sha256_hex(format!("session:{session_id}:policy_snapshot:{idempotency_key}").as_bytes())
    )
}

pub(super) fn schema_version_for_policy_kind(kind: &str) -> &'static str {
    if kind == CONTEXT_SURVIVOR_KIND {
        SURVIVOR_SCHEMA_VERSION
    } else {
        EXCLUSION_SCHEMA_VERSION
    }
}

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({
        "kind": scope.kind(),
        "value": scope.value()
    })
}

pub(super) fn resource_policy(kind: &str) -> Value {
    json!({
        "classification": kind,
        "networkPolicy": "none",
        "providerVisible": true,
        "providerSafeProjectionRequired": true,
        "requiredScopes": {
            "read": [READ_SCOPE, RESOURCE_READ_SCOPE],
            "write": [WRITE_SCOPE, RESOURCE_WRITE_SCOPE]
        },
        "forbidden": {
            "agentState": true,
            "stateInheritance": true,
            "rawPromptBodies": true,
            "rawCommands": true,
            "rawLogs": true,
            "rawSecrets": true,
            "rawLocalPaths": true
        }
    })
}

pub(super) fn resource_ref(resource: &EngineResource, relation: &str) -> Value {
    json!({
        "kind": relation,
        "resourceKind": resource.kind,
        "resourceId": resource.resource_id,
        "currentVersionId": resource.current_version_id,
        "lifecycle": resource.lifecycle
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    relation: &str,
) -> Value {
    json!({
        "kind": relation,
        "resourceKind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "lifecycle": resource.lifecycle
    })
}

pub(super) fn provider_safe_proof(truncated: bool) -> Value {
    json!({
        "providerSafe": true,
        "redactionApplied": true,
        "truncationApplied": truncated,
        "hiddenPromptBodiesExcluded": true,
        "rawSecretsExcluded": true,
        "rawLogsExcluded": true,
        "rawCommandsExcluded": true,
        "rawPathsExcluded": true,
        "rawGrantIdsExcluded": true,
        "rawAuthorityIdsExcluded": true,
        "chainOfThoughtExcluded": true,
        "networkPolicy": "none"
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationRef": invocation.id.as_str()
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "idempotencyRecorded": invocation.causal_context.idempotency_key.is_some(),
        "invocationRef": invocation.id.as_str()
    })]
}

fn idempotency_evidence(idempotency_key: &str) -> Value {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(idempotency_key.as_bytes());
    json!({
        "algorithm": IDEMPOTENCY_FINGERPRINT_ALGORITHM,
        "fingerprint": format!("{:x}", hasher.finalize()),
        "rawKeyStored": false
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}
