use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::MODULE_LIFECYCLE_STATE_KIND;
use super::contract::{
    MODULE_LIFECYCLE_STATE_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE,
    WORKER, WRITE_SCOPE,
};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.module_lifecycle_state.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.module_lifecycle_state.idempotency.v1\0";

pub(super) struct ModuleLifecycleRecordInput<'a> {
    pub(super) transition_id: &'a str,
    pub(super) action: &'a str,
    pub(super) state: &'a str,
    pub(super) reason: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) install_decision: Value,
    pub(super) previous_state: Option<&'a str>,
    pub(super) previous_version_id: Option<&'a str>,
    pub(super) approval: Value,
    pub(super) rollback_proof_refs: Vec<Value>,
    pub(super) rollback_readiness: Value,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn module_lifecycle_record(input: ModuleLifecycleRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_LIFECYCLE_STATE_SCHEMA_VERSION,
        "state": input.state,
        "transitionId": input.transition_id,
        "scope": scope_ref(input.scope),
        "installDecision": input.install_decision,
        "transition": {
            "action": input.action,
            "from": input.previous_state,
            "to": input.state,
            "reason": input.reason,
            "metadataOnly": true,
            "stateMutationOnly": true,
            "activationPerformed": false,
            "executionPerformed": false,
            "rollbackExecuted": false
        },
        "previous": {
            "state": input.previous_state,
            "versionId": input.previous_version_id,
            "currentVersionRevalidated": input.previous_version_id.is_some()
        },
        "approval": input.approval,
        "rollback": {
            "proofRefs": input.rollback_proof_refs,
            "status": input.rollback_readiness["status"],
            "metadataOnly": true,
            "rollbackExecuted": false
        },
        "runtimeAuthorization": {
            "failClosed": true,
            "enabledAllowsRuntime": input.state == "enabled",
            "disabledDenied": input.state == "disabled",
            "quarantinedDenied": input.state == "quarantined",
            "rolledBackDenied": input.state == "rolled_back"
        },
        "evidenceRefs": input.evidence_refs,
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) fn module_lifecycle_resource_id(
    scope: &EngineResourceScope,
    install_decision_resource_id: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(install_decision_resource_id.as_bytes());
    format!(
        "{}:{}",
        MODULE_LIFECYCLE_STATE_KIND,
        hex::encode(hasher.finalize())
    )
}

fn idempotency_evidence(idempotency_key: &str) -> Value {
    json!({
        "fingerprint": idempotency_fingerprint(idempotency_key),
        "fingerprintAlgorithm": IDEMPOTENCY_FINGERPRINT_ALGORITHM,
        "keyRedacted": true,
        "rawKeyStored": false
    })
}

pub(super) fn idempotency_fingerprint(idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

pub(super) fn resource_policy() -> Value {
    json!({
        "owner": WORKER,
        "kind": MODULE_LIFECYCLE_STATE_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "metadataOnly": true,
        "install": "forbidden",
        "activation": "forbidden",
        "execution": "forbidden",
        "commandExecution": "forbidden",
        "dependencyRestore": "forbidden",
        "networkPolicy": "none",
        "approvalEvidenceIsAuthority": false,
        "runtimeGuard": "fail_closed_disabled_quarantined"
    })
}

fn authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "derivedRuntimeGrantRequired": true,
        "approvalEvidenceIsAuthority": false,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [MODULE_LIFECYCLE_STATE_KIND],
        "wildcardGrantsAllowed": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "installPerformed": false,
        "activationPerformed": false,
        "executionPerformed": false,
        "rollbackExecuted": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false
    })
}

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "lifecycle": resource.lifecycle,
        "versionId": resource.current_version_id
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
        "versionId": version.version_id,
        "role": role,
        "lifecycle": resource.lifecycle
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "id": invocation.causal_context.trace_id.as_str(),
        "role": "lifecycle_trace"
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "invocation",
        "id": invocation.id.as_str(),
        "role": "lifecycle_invocation"
    })]
}
