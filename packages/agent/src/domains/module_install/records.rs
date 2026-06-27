use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::contract::{
    MODULE_INSTALL_DECISION_SCHEMA_VERSION, MODULE_INSTALL_REQUEST_SCHEMA_VERSION, READ_SCOPE,
    RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::{MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_REQUEST_KIND};

const REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.module_install_request.idempotency.v1";
const DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.module_install_decision.idempotency.v1";
const REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.module_install_request.idempotency.v1\0";
const DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.module_install_decision.idempotency.v1\0";

pub(super) struct ModuleInstallRequestInput<'a> {
    pub(super) request_id: &'a str,
    pub(super) state: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) title: &'a str,
    pub(super) summary: &'a str,
    pub(super) validation_report: Value,
    pub(super) dependency_policy_refs: Vec<Value>,
    pub(super) dependency_policy_status: Value,
    pub(super) rollback_proof_refs: Vec<Value>,
    pub(super) rollback_readiness: Value,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn module_install_request_record(input: ModuleInstallRequestInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_INSTALL_REQUEST_SCHEMA_VERSION,
        "state": input.state,
        "requestId": input.request_id,
        "scope": scope_ref(input.scope),
        "identity": {
            "title": input.title,
            "summary": input.summary
        },
        "validationReport": input.validation_report,
        "dependencyPolicy": {
            "refs": input.dependency_policy_refs,
            "status": input.dependency_policy_status["status"],
            "metadataOnly": true,
            "restored": false,
            "packageManagerUsed": false
        },
        "rollback": {
            "proofRefs": input.rollback_proof_refs,
            "status": input.rollback_readiness["status"],
            "metadataOnly": true,
            "rollbackExecuted": false
        },
        "evidenceRefs": input.evidence_refs,
        "installGate": {
            "state": input.state,
            "metadataOnly": true,
            "reviewRequired": true,
            "installPerformed": false,
            "activationPerformed": false,
            "executionPerformed": false,
            "dependencyRestorePerformed": false,
            "networkPolicy": "none",
            "networkAccessPerformed": false
        },
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

pub(super) struct ModuleInstallDecisionInput<'a> {
    pub(super) decision_id: &'a str,
    pub(super) state: &'a str,
    pub(super) decision: &'a str,
    pub(super) reason: &'a str,
    pub(super) denial_evidence: Vec<Value>,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) request_resource: &'a EngineResource,
    pub(super) request_version: &'a EngineResourceVersion,
    pub(super) validation_report: Value,
    pub(super) approval: Value,
    pub(super) dependency_policy_refs: Vec<Value>,
    pub(super) dependency_policy_status: Value,
    pub(super) rollback_proof_refs: Vec<Value>,
    pub(super) rollback_readiness: Value,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn module_install_decision_record(input: ModuleInstallDecisionInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_INSTALL_DECISION_SCHEMA_VERSION,
        "state": input.state,
        "decisionId": input.decision_id,
        "scope": scope_ref(input.scope),
        "request": version_ref(input.request_resource, input.request_version, "install_request"),
        "validationReport": input.validation_report,
        "approval": input.approval,
        "decision": {
            "state": input.state,
            "result": input.decision,
            "reason": input.reason,
            "denialEvidence": input.denial_evidence,
            "metadataOnly": true,
            "installPerformed": false
        },
        "dependencyPolicy": {
            "refs": input.dependency_policy_refs,
            "status": input.dependency_policy_status["status"],
            "metadataOnly": true,
            "restored": false,
            "packageManagerUsed": false
        },
        "rollback": {
            "proofRefs": input.rollback_proof_refs,
            "status": input.rollback_readiness["status"],
            "metadataOnly": true,
            "rollbackExecuted": false
        },
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

pub(super) fn module_install_request_resource_id(
    scope: &EngineResourceScope,
    request_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        MODULE_INSTALL_REQUEST_KIND,
        scope,
        request_id,
        idempotency_key,
    )
}

pub(super) fn module_install_decision_resource_id(
    scope: &EngineResourceScope,
    decision_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        MODULE_INSTALL_DECISION_KIND,
        scope,
        decision_id,
        idempotency_key,
    )
}

fn stable_resource_id(
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

fn idempotency_evidence(idempotency_key: &str, algorithm: &str, domain: &[u8]) -> Value {
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
        "install": "forbidden",
        "activation": "forbidden",
        "execution": "forbidden",
        "commandExecution": "forbidden",
        "dependencyRestore": "forbidden",
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
        "resourceKinds": [MODULE_INSTALL_REQUEST_KIND, MODULE_INSTALL_DECISION_KIND],
        "wildcardGrantsAllowed": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "installPerformed": false,
        "activationPerformed": false,
        "executionPerformed": false,
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

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_trace",
        "id": runtime_ref_fingerprint("trace", invocation.causal_context.trace_id.as_str()),
        "role": "record_trace"
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "id": runtime_ref_fingerprint("invocation", invocation.id.as_str()),
        "role": "record_invocation"
    })]
}

fn runtime_ref_fingerprint(kind: &str, value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"tron.module_install.runtime_ref.v1\0");
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(value.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
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
        "role": role
    })
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role
    })
}
