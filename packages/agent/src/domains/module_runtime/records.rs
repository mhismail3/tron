use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::MODULE_RUNTIME_STATE_KIND;
use super::contract::{
    MODULE_RUNTIME_STATE_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE,
    WORKER, WRITE_SCOPE,
};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.module_runtime_state.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.module_runtime_state.idempotency.v1\0";

pub(super) struct ModuleRuntimeRecordInput<'a> {
    pub(super) runtime_request_id: &'a str,
    pub(super) state: &'a str,
    pub(super) reason: &'a str,
    pub(super) runtime_kind: &'a str,
    pub(super) runtime_label: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) lifecycle_authorization: Value,
    pub(super) input_refs: Vec<Value>,
    pub(super) output_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) timeout_ms: u64,
    pub(super) timeout_at: &'a str,
    pub(super) cancellation: Value,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn module_runtime_record(input: ModuleRuntimeRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_RUNTIME_STATE_SCHEMA_VERSION,
        "state": input.state,
        "runtimeRequestId": input.runtime_request_id,
        "scope": scope_ref(input.scope),
        "moduleLifecycle": input.lifecycle_authorization,
        "runtime": {
            "kind": input.runtime_kind,
            "label": input.runtime_label,
            "featureSemanticsOwnedByPackage": true,
            "supervisorEnvelopeOnly": true,
            "processLaunched": false,
            "jobExposedToProvider": false
        },
        "supervision": {
            "state": input.state,
            "sandbox": {"label": "metadata_only", "pty": false, "browserAutomation": false},
            "network": {"policy": "none", "accessPerformed": false},
            "secrets": {"available": false, "rawValuesStored": false},
            "timeout": {"timeoutMs": input.timeout_ms, "deadlineAt": input.timeout_at, "state": "armed"},
            "cancellation": input.cancellation,
            "shutdown": {"state": "cancel_on_shutdown", "recorded": true}
        },
        "inputRefs": input.input_refs,
        "outputArtifactRefs": input.output_refs,
        "evidenceRefs": input.evidence_refs,
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "sideEffectProof": side_effect_proof(),
        "reason": input.reason,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

pub(super) fn module_runtime_resource_id(
    scope: &EngineResourceScope,
    lifecycle_resource_id: &str,
    runtime_request_id: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(lifecycle_resource_id.as_bytes());
    hasher.update(b":");
    hasher.update(runtime_request_id.as_bytes());
    format!(
        "{}:{}",
        MODULE_RUNTIME_STATE_KIND,
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
        "kind": MODULE_RUNTIME_STATE_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "supervisorEnvelopeOnly": true,
        "install": "forbidden",
        "activation": "forbidden",
        "dependencyRestore": "forbidden",
        "networkPolicy": "none",
        "rawRuntimeMaterial": "forbidden",
        "providerOutput": "refs_only"
    })
}

fn authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "derivedRuntimeGrantRequired": true,
        "lifecycleAuthorizationRequired": true,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [MODULE_RUNTIME_STATE_KIND, crate::engine::MODULE_LIFECYCLE_STATE_KIND],
        "wildcardGrantsAllowed": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "supervisorEnvelopeOnly": true,
        "installPerformed": false,
        "activationPerformed": false,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false,
        "ptyAllocated": false,
        "browserAutomationPerformed": false,
        "rawCommandsStored": false,
        "rawLogsStored": false,
        "rawOutputStored": false,
        "secretsExposed": false,
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
        "role": "runtime_trace"
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "invocation",
        "id": invocation.id.as_str(),
        "role": "runtime_invocation"
    })]
}
