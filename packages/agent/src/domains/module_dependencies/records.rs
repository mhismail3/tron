use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::contract::{
    MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION, MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
    MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::{
    MODULE_DEPENDENCY_DECISION_KIND, MODULE_DEPENDENCY_POLICY_KIND, MODULE_DEPENDENCY_REQUEST_KIND,
};

const REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.module_dependency_request.idempotency.v1";
const DECISION_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.module_dependency_decision.idempotency.v1";
const POLICY_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.module_dependency_policy.idempotency.v1";
const REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.module_dependency_request.idempotency.v1\0";
const DECISION_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.module_dependency_decision.idempotency.v1\0";
const POLICY_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] =
    b"tron.module_dependency_policy.idempotency.v1\0";

pub(super) struct ModuleDependencyRequestInput<'a> {
    pub(super) request_id: &'a str,
    pub(super) state: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) title: &'a str,
    pub(super) module_ref: Value,
    pub(super) proposal_ref: Option<Value>,
    pub(super) validation_ref: Option<Value>,
    pub(super) install_ref: Option<Value>,
    pub(super) runtime_ref: Option<Value>,
    pub(super) dependency_name: &'a str,
    pub(super) dependency_version_req: Option<&'a str>,
    pub(super) ecosystem: &'a str,
    pub(super) rationale: &'a str,
    pub(super) security_need: &'a str,
    pub(super) license_need: &'a str,
    pub(super) runtime_need: &'a str,
    pub(super) removal_plan: &'a str,
    pub(super) risk_class: &'a str,
    pub(super) review_status: &'a str,
    pub(super) cargo_toml_evidence: Value,
    pub(super) cargo_lock_evidence: Value,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn module_dependency_request_record(input: ModuleDependencyRequestInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION,
        "state": input.state,
        "requestId": input.request_id,
        "scope": scope_ref(input.scope),
        "title": input.title,
        "owner": {
            "moduleRef": input.module_ref,
            "proposalRef": input.proposal_ref,
            "validationRef": input.validation_ref,
            "installRef": input.install_ref,
            "runtimeRef": input.runtime_ref
        },
        "dependency": {
            "name": input.dependency_name,
            "versionRequirement": input.dependency_version_req,
            "ecosystem": input.ecosystem,
            "identityRecorded": true,
            "artifactStored": false,
            "packageManagerOutputStored": false
        },
        "needs": {
            "rationale": input.rationale,
            "securityNeed": input.security_need,
            "licenseNeed": input.license_need,
            "runtimeNeed": input.runtime_need,
            "removalPlan": input.removal_plan,
            "riskClass": input.risk_class,
            "reviewStatus": input.review_status
        },
        "parityEvidence": {
            "cargoToml": input.cargo_toml_evidence,
            "cargoLock": input.cargo_lock_evidence,
            "packageManagerExecuted": false,
            "manifestMutated": false,
            "lockfileMutated": false
        },
        "evidenceRefs": input.evidence_refs,
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

pub(super) struct ModuleDependencyDecisionInput<'a> {
    pub(super) decision_id: &'a str,
    pub(super) state: &'a str,
    pub(super) decision: &'a str,
    pub(super) reason: &'a str,
    pub(super) risk_class: &'a str,
    pub(super) review_status: &'a str,
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

pub(super) fn module_dependency_decision_record(input: ModuleDependencyDecisionInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION,
        "state": input.state,
        "decisionId": input.decision_id,
        "scope": input.request_payload["scope"],
        "request": version_ref(input.request_resource, input.request_version, "dependency_request"),
        "owner": input.request_payload["owner"],
        "dependency": input.request_payload["dependency"],
        "needs": input.request_payload["needs"],
        "parityEvidence": input.request_payload["parityEvidence"],
        "decision": {
            "state": input.state,
            "result": input.decision,
            "reason": input.reason,
            "riskClass": input.risk_class,
            "reviewStatus": input.review_status,
            "denialEvidence": input.denial_evidence,
            "metadataOnly": true,
            "dependencyRestored": false,
            "packageManagerUsed": false
        },
        "policyCandidate": {
            "approvedMetadataPolicyAvailable": input.state == "approved_policy",
            "active": false,
            "activationRequired": input.state == "approved_policy",
            "networkPolicy": "none"
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

pub(super) struct ModuleDependencyPolicyInput<'a> {
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

pub(super) fn module_dependency_policy_record(input: ModuleDependencyPolicyInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION,
        "state": input.state,
        "policyId": input.policy_id,
        "scope": input.decision_payload["scope"],
        "decision": version_ref(input.decision_resource, input.decision_version, "dependency_decision"),
        "request": input.decision_payload["request"],
        "owner": input.decision_payload["owner"],
        "dependency": input.decision_payload["dependency"],
        "needs": input.decision_payload["needs"],
        "parityEvidence": input.decision_payload["parityEvidence"],
        "activation": {
            "reason": input.activation_reason,
            "approvedMetadataPolicyAvailable": true,
            "active": input.state == "active",
            "policyOnly": true,
            "dependencyRestored": false,
            "packageManagerUsed": false,
            "manifestMutated": false,
            "lockfileMutated": false,
            "networkPolicy": "none"
        },
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

pub(super) fn module_dependency_request_resource_id(
    scope: &EngineResourceScope,
    request_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        MODULE_DEPENDENCY_REQUEST_KIND,
        scope,
        request_id,
        idempotency_key,
    )
}

pub(super) fn module_dependency_decision_resource_id(
    scope: &EngineResourceScope,
    decision_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        MODULE_DEPENDENCY_DECISION_KIND,
        scope,
        decision_id,
        idempotency_key,
    )
}

pub(super) fn module_dependency_policy_resource_id(
    scope: &EngineResourceScope,
    policy_id: &str,
    decision_resource_id: &str,
    idempotency_key: &str,
) -> String {
    let visible = format!("{policy_id}:{decision_resource_id}");
    stable_resource_id(
        MODULE_DEPENDENCY_POLICY_KIND,
        scope,
        &visible,
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
        "dependencyRestore": "forbidden",
        "packageManager": "forbidden",
        "manifestMutation": "forbidden",
        "lockfileMutation": "forbidden",
        "activation": "metadata_policy_only",
        "execution": "forbidden",
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
            MODULE_DEPENDENCY_REQUEST_KIND,
            MODULE_DEPENDENCY_DECISION_KIND,
            MODULE_DEPENDENCY_POLICY_KIND
        ],
        "wildcardGrantsAllowed": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "manifestMutated": false,
        "lockfileMutated": false,
        "activationPerformed": false,
        "executionPerformed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false,
        "rawDependencyArtifactsStored": false,
        "packageManagerOutputStored": false
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
        "role": "module_dependency_trace",
        "storedRawPayload": false
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "resourceId": invocation.id.as_str(),
        "role": "module_dependency_replay",
        "idempotent": true,
        "storedRawPayload": false
    })]
}
