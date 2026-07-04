use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::contract::{
    CAPABILITY_BINDING_DECISION_SCHEMA_VERSION, CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
    CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_POLICY_KIND,
    CAPABILITY_BINDING_REQUEST_KIND,
};

const REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_binding_request.idempotency.v1";
const DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_binding_decision.idempotency.v1";
const POLICY_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.capability_binding_policy.idempotency.v1";
const REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_binding_request.idempotency.v1\0";
const DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_binding_decision.idempotency.v1\0";
const POLICY_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.capability_binding_policy.idempotency.v1\0";

pub(super) struct CapabilityBindingRequestInput<'a> {
    pub(super) request_id: &'a str,
    pub(super) state: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) title: &'a str,
    pub(super) operation_name: &'a str,
    pub(super) current_owner: &'a str,
    pub(super) ownership_class: &'a str,
    pub(super) replacement_target: &'a str,
    pub(super) binding_mode: &'a str,
    pub(super) target_ref: Value,
    pub(super) actor_scope: &'a str,
    pub(super) rationale: &'a str,
    pub(super) contract_requirements: Value,
    pub(super) authority_constraints: Value,
    pub(super) stale_version_guard: Value,
    pub(super) rollback_ref: Option<Value>,
    pub(super) disable_ref: Option<Value>,
    pub(super) audit_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn capability_binding_request_record(input: CapabilityBindingRequestInput<'_>) -> Value {
    json!({
        "schemaVersion": CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION,
        "state": input.state,
        "requestId": input.request_id,
        "scope": scope_ref(input.scope),
        "title": input.title,
        "operation": operation_record(
            input.operation_name,
            input.current_owner,
            input.ownership_class,
            input.replacement_target,
        ),
        "binding": {
            "mode": input.binding_mode,
            "targetRef": input.target_ref,
            "actorScope": input.actor_scope,
            "rationale": input.rationale,
            "runtimeRoutingRequested": false,
            "runtimeRoutingEnabled": false,
            "hotSwapRequested": false
        },
        "requirements": {
            "contract": input.contract_requirements,
            "authority": input.authority_constraints,
            "staleVersionGuard": input.stale_version_guard,
            "rollbackRef": input.rollback_ref,
            "disableRef": input.disable_ref
        },
        "policyDecision": {
            "status": "pending_review",
            "replacementAllowed": false,
            "routingEnabled": false,
            "decisionRequired": true
        },
        "auditRefs": input.audit_refs,
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) struct CapabilityBindingDecisionInput<'a> {
    pub(super) decision_id: &'a str,
    pub(super) state: &'a str,
    pub(super) decision: &'a str,
    pub(super) reason: &'a str,
    pub(super) denial_evidence: Vec<Value>,
    pub(super) request_resource: &'a EngineResource,
    pub(super) request_version: &'a EngineResourceVersion,
    pub(super) request_payload: &'a Value,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn capability_binding_decision_record(
    input: CapabilityBindingDecisionInput<'_>,
) -> Value {
    json!({
        "schemaVersion": CAPABILITY_BINDING_DECISION_SCHEMA_VERSION,
        "state": input.state,
        "decisionId": input.decision_id,
        "scope": input.request_payload["scope"],
        "request": version_ref(input.request_resource, input.request_version, "binding_request"),
        "operation": input.request_payload["operation"],
        "binding": input.request_payload["binding"],
        "requirements": input.request_payload["requirements"],
        "decision": {
            "state": input.state,
            "result": input.decision,
            "reason": input.reason,
            "denialEvidence": input.denial_evidence,
            "metadataOnly": true,
            "runtimeRoutingChanged": false,
            "hotSwapPerformed": false
        },
        "policyCandidate": {
            "approvedMetadataPolicyAvailable": input.state == "approved_policy",
            "active": false,
            "activationRequired": input.state == "approved_policy",
            "routingEnabled": false,
            "networkPolicy": "none"
        },
        "auditRefs": input.request_payload["auditRefs"],
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) struct CapabilityBindingPolicyInput<'a> {
    pub(super) policy_id: &'a str,
    pub(super) state: &'a str,
    pub(super) activation_reason: &'a str,
    pub(super) decision_resource: &'a EngineResource,
    pub(super) decision_version: &'a EngineResourceVersion,
    pub(super) decision_payload: &'a Value,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn capability_binding_policy_record(input: CapabilityBindingPolicyInput<'_>) -> Value {
    json!({
        "schemaVersion": CAPABILITY_BINDING_POLICY_SCHEMA_VERSION,
        "state": input.state,
        "policyId": input.policy_id,
        "scope": input.decision_payload["scope"],
        "decision": version_ref(input.decision_resource, input.decision_version, "binding_decision"),
        "request": input.decision_payload["request"],
        "operation": input.decision_payload["operation"],
        "binding": input.decision_payload["binding"],
        "requirements": input.decision_payload["requirements"],
        "activation": {
            "reason": input.activation_reason,
            "approvedMetadataPolicyAvailable": true,
            "active": input.state == "active",
            "policyOnly": true,
            "metadataOnly": true,
            "runtimeRoutingEnabled": false,
            "runtimeRoutingChanged": false,
            "hotSwapPerformed": false,
            "networkPolicy": "none",
            "rollbackRef": input.decision_payload["requirements"]["rollbackRef"],
            "disableRef": input.decision_payload["requirements"]["disableRef"]
        },
        "auditRefs": input.decision_payload["auditRefs"],
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            POLICY_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            POLICY_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) fn capability_binding_request_resource_id(
    scope: &EngineResourceScope,
    request_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_BINDING_REQUEST_KIND,
        scope,
        request_id,
        idempotency_key,
    )
}

pub(super) fn capability_binding_decision_resource_id(
    scope: &EngineResourceScope,
    decision_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        CAPABILITY_BINDING_DECISION_KIND,
        scope,
        decision_id,
        idempotency_key,
    )
}

pub(super) fn capability_binding_policy_resource_id(
    scope: &EngineResourceScope,
    policy_id: &str,
    decision_resource_id: &str,
    idempotency_key: &str,
) -> String {
    let visible = format!("{policy_id}:{decision_resource_id}");
    stable_resource_id(
        CAPABILITY_BINDING_POLICY_KIND,
        scope,
        &visible,
        idempotency_key,
    )
}

pub(super) fn stable_resource_id(
    kind: &str,
    scope: &EngineResourceScope,
    visible_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(visible_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{kind}:{}", hex::encode(hasher.finalize()))
}

fn operation_record(
    operation_name: &str,
    current_owner: &str,
    ownership_class: &str,
    replacement_target: &str,
) -> Value {
    json!({
        "name": operation_name,
        "currentBuiltInOwner": current_owner,
        "ownershipClass": ownership_class,
        "requestedReplacementTarget": replacement_target,
        "currentExecutionOwner": "builtin",
        "dispatchChanged": false
    })
}

pub(super) fn idempotency_evidence(idempotency_key: &str, algorithm: &str, domain: &[u8]) -> Value {
    json!({
        "fingerprint": idempotency_fingerprint(idempotency_key, domain),
        "fingerprintAlgorithm": algorithm,
        "keyRedacted": true,
        "rawKeyStored": false
    })
}

fn idempotency_fingerprint(idempotency_key: &str, domain: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

pub(super) fn resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "metadataOnly": true,
        "runtimeRouting": "forbidden_in_this_slice",
        "hotSwap": "forbidden",
        "moduleActivation": "forbidden",
        "packageManager": "forbidden",
        "networkPolicy": "none",
        "approvalEvidenceIsAuthority": false
    })
}

fn authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "derivedRuntimeGrantRequired": true,
        "approvalEvidenceIsAuthority": false,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [
            CAPABILITY_BINDING_REQUEST_KIND,
            CAPABILITY_BINDING_DECISION_KIND,
            CAPABILITY_BINDING_POLICY_KIND
        ],
        "wildcardGrantsAllowed": false,
        "agentStateInherited": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "runtimeRoutingChanged": false,
        "dispatchTableMutated": false,
        "hotSwapPerformed": false,
        "moduleActivated": false,
        "moduleExecuted": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "manifestMutated": false,
        "lockfileMutated": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false,
        "rawGrantIdsStored": false,
        "rawAuthorityIdsStored": false
    })
}

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({
        "kind": scope.kind(),
        "value": scope.value(),
    })
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "currentVersionId": resource.current_version_id,
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payloadHash": version.content_hash,
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "resourceId": invocation.causal_context.trace_id.as_str(),
        "role": "capability_binding_trace",
        "storedRawPayload": false
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "resourceId": invocation.id.as_str(),
        "role": "capability_binding_replay",
        "idempotent": true,
        "storedRawPayload": false
    })]
}
