use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;

pub(super) fn module_dependency_request_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleDependencyRequestResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
        "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
        "owner": projected_owner(payload.get("owner")),
        "dependency": projected_dependency(payload.get("dependency")),
        "needs": projected_needs(payload.get("needs")),
        "parityEvidence": projected_parity(payload.get("parityEvidence")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_dependency_request")]
    })
}

pub(super) fn inspected_module_dependency_request(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "dependencyRequest": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
            "owner": projected_owner(payload.get("owner")),
            "dependency": projected_dependency(payload.get("dependency")),
            "needs": projected_needs(payload.get("needs")),
            "parityEvidence": projected_parity(payload.get("parityEvidence")),
            "evidenceRefs": projected_refs(payload.get("evidenceRefs")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "idempotency": projected_idempotency(payload.get("idempotency")),
            "sideEffectProof": projected_side_effect_proof(payload.get("sideEffectProof")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": projection_policy(),
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

pub(super) fn module_dependency_decision_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleDependencyDecisionResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
        "request": projected_ref(payload.get("request")),
        "owner": projected_owner(payload.get("owner")),
        "dependency": projected_dependency(payload.get("dependency")),
        "decision": projected_decision(payload.get("decision")),
        "policyCandidate": projected_policy_candidate(payload.get("policyCandidate")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_dependency_decision")]
    })
}

pub(super) fn inspected_module_dependency_decision(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "dependencyDecision": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "request": projected_ref(payload.get("request")),
            "owner": projected_owner(payload.get("owner")),
            "dependency": projected_dependency(payload.get("dependency")),
            "needs": projected_needs(payload.get("needs")),
            "parityEvidence": projected_parity(payload.get("parityEvidence")),
            "decision": projected_decision(payload.get("decision")),
            "policyCandidate": projected_policy_candidate(payload.get("policyCandidate")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "idempotency": projected_idempotency(payload.get("idempotency")),
            "sideEffectProof": projected_side_effect_proof(payload.get("sideEffectProof")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": projection_policy(),
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

pub(super) fn module_dependency_policy_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleDependencyPolicyResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "policyId": projected_string(payload, "policyId", PROJECTION_ID_BYTES),
        "decision": projected_ref(payload.get("decision")),
        "owner": projected_owner(payload.get("owner")),
        "dependency": projected_dependency(payload.get("dependency")),
        "activation": projected_activation(payload.get("activation")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_dependency_policy")]
    })
}

pub(super) fn inspected_module_dependency_policy(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "dependencyPolicy": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "policyId": projected_string(payload, "policyId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "decision": projected_ref(payload.get("decision")),
            "request": projected_ref(payload.get("request")),
            "owner": projected_owner(payload.get("owner")),
            "dependency": projected_dependency(payload.get("dependency")),
            "needs": projected_needs(payload.get("needs")),
            "parityEvidence": projected_parity(payload.get("parityEvidence")),
            "activation": projected_activation(payload.get("activation")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "idempotency": projected_idempotency(payload.get("idempotency")),
            "sideEffectProof": projected_side_effect_proof(payload.get("sideEffectProof")),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": projection_policy(),
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_owner(value: Option<&Value>) -> Value {
    let Some(Value::Object(owner)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "moduleRef",
        "proposalRef",
        "validationRef",
        "installRef",
        "runtimeRef",
    ] {
        if let Some(child) = owner.get(key)
            && !child.is_null()
        {
            projected.insert(key.to_owned(), projected_ref(Some(child)));
        }
    }
    Value::Object(projected)
}

fn projected_dependency(value: Option<&Value>) -> Value {
    let Some(Value::Object(dep)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["name", "versionRequirement", "ecosystem"] {
        insert_projected_string(dep, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in [
        "identityRecorded",
        "artifactStored",
        "packageManagerOutputStored",
    ] {
        insert_projected_bool(dep, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_needs(value: Option<&Value>) -> Value {
    let Some(Value::Object(needs)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "rationale",
        "securityNeed",
        "licenseNeed",
        "runtimeNeed",
        "removalPlan",
        "riskClass",
        "reviewStatus",
    ] {
        insert_projected_string(needs, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    Value::Object(projected)
}

fn projected_parity(value: Option<&Value>) -> Value {
    let Some(Value::Object(parity)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["cargoToml", "cargoLock"] {
        if let Some(child) = parity.get(key) {
            projected.insert(key.to_owned(), projected_parity_item(Some(child)));
        }
    }
    for key in [
        "packageManagerExecuted",
        "manifestMutated",
        "lockfileMutated",
    ] {
        insert_projected_bool(parity, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_parity_item(value: Option<&Value>) -> Value {
    let Some(Value::Object(item)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["status", "summary"] {
        insert_projected_string(item, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in [
        "packageManagerExecuted",
        "fileMutated",
        "rawDiffStored",
        "rawFileContentsStored",
    ] {
        insert_projected_bool(item, &mut projected, key);
    }
    if let Some(refs) = item.get("evidenceRefs") {
        projected.insert("evidenceRefs".to_owned(), projected_refs(Some(refs)));
    }
    Value::Object(projected)
}

fn projected_decision(value: Option<&Value>) -> Value {
    let Some(Value::Object(decision)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["state", "result", "reason", "riskClass", "reviewStatus"] {
        insert_projected_string(decision, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in ["metadataOnly", "dependencyRestored", "packageManagerUsed"] {
        insert_projected_bool(decision, &mut projected, key);
    }
    if let Some(refs) = decision.get("denialEvidence") {
        projected.insert("denialEvidence".to_owned(), projected_refs(Some(refs)));
    }
    Value::Object(projected)
}

fn projected_policy_candidate(value: Option<&Value>) -> Value {
    let Some(Value::Object(candidate)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "approvedMetadataPolicyAvailable",
        "active",
        "activationRequired",
    ] {
        insert_projected_bool(candidate, &mut projected, key);
    }
    insert_projected_string(
        candidate,
        &mut projected,
        "networkPolicy",
        PROJECTION_ID_BYTES,
    );
    Value::Object(projected)
}

fn projected_activation(value: Option<&Value>) -> Value {
    let Some(Value::Object(activation)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["reason", "networkPolicy"] {
        insert_projected_string(activation, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in [
        "approvedMetadataPolicyAvailable",
        "active",
        "policyOnly",
        "dependencyRestored",
        "packageManagerUsed",
        "manifestMutated",
        "lockfileMutated",
    ] {
        insert_projected_bool(activation, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_side_effect_proof(value: Option<&Value>) -> Value {
    let Some(Value::Object(proof)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "metadataOnly",
        "dependencyRestorePerformed",
        "packageManagerUsed",
        "manifestMutated",
        "lockfileMutated",
        "activationPerformed",
        "executionPerformed",
        "networkAccessPerformed",
        "repoManagedSkillsTouched",
        "physicalWorkspaceDirectoryCreated",
        "rawCommandsStored",
        "rawLogsStored",
        "fileContentsStored",
        "absolutePathsStored",
        "rawDependencyArtifactsStored",
        "packageManagerOutputStored",
    ] {
        insert_projected_bool(proof, &mut projected, key);
    }
    insert_projected_string(proof, &mut projected, "networkPolicy", PROJECTION_ID_BYTES);
    Value::Object(projected)
}

fn projected_authority(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "grantRedacted",
        "rawAuthorityIdsStored",
        "derivedRuntimeGrantRequired",
        "approvalEvidenceIsAuthority",
        "wildcardGrantsAllowed",
    ] {
        insert_projected_bool(authority, &mut projected, key);
    }
    for key in ["requiredScopes", "resourceKinds"] {
        if let Some(Value::Array(values)) = authority.get(key) {
            projected.insert(
                key.to_owned(),
                Value::Array(
                    values
                        .iter()
                        .take(MAX_PROJECTED_REFS)
                        .filter_map(Value::as_str)
                        .map(|value| projected_text(value, PROJECTION_ID_BYTES))
                        .collect(),
                ),
            );
        }
    }
    Value::Object(projected)
}

fn projected_idempotency(value: Option<&Value>) -> Value {
    let Some(Value::Object(idempotency)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["fingerprint", "fingerprintAlgorithm"] {
        insert_projected_string(idempotency, &mut projected, key, PROJECTION_ID_BYTES);
    }
    for key in ["keyRedacted", "rawKeyStored"] {
        insert_projected_bool(idempotency, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_refs(value: Option<&Value>) -> Value {
    let Some(Value::Array(refs)) = value else {
        return Value::Array(Vec::new());
    };
    Value::Array(
        refs.iter()
            .take(MAX_PROJECTED_REFS)
            .map(|item| projected_ref(Some(item)))
            .collect(),
    )
}

fn projected_ref(value: Option<&Value>) -> Value {
    let Some(Value::Object(reference)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "kind",
        "resourceId",
        "role",
        "schemaId",
        "lifecycle",
        "currentVersionId",
        "versionId",
        "payloadHash",
        "value",
        "summary",
    ] {
        insert_projected_string(reference, &mut projected, key, PROJECTION_ID_BYTES);
    }
    Value::Object(projected)
}

fn projection_policy() -> Value {
    json!({
        "bounded": true,
        "redacted": true,
        "rawLocalPaths": false,
        "rawEnvValues": false,
        "rawSecrets": false,
        "rawCommands": false,
        "rawLogs": false,
        "rawCode": false,
        "rawFileContents": false,
        "rawGrantIds": false,
        "rawAuthorityIds": false,
        "rawDependencyArtifacts": false,
        "packageManagerOutput": false,
        "hiddenChainOfThought": false
    })
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    payload
        .get("state")
        .and_then(Value::as_str)
        .map(|value| projected_text(value, PROJECTION_ID_BYTES))
        .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
}

fn projected_string(payload: &Value, key: &str, max_bytes: usize) -> Value {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|value| projected_text(value, max_bytes))
        .unwrap_or(Value::Null)
}

fn projected_fingerprint(payload: &Value) -> Value {
    payload
        .pointer("/idempotency/fingerprint")
        .and_then(Value::as_str)
        .map(|text| projected_text(text, PROJECTION_ID_BYTES))
        .unwrap_or(Value::Null)
}

fn insert_projected_string(
    source: &Map<String, Value>,
    target: &mut Map<String, Value>,
    key: &str,
    max_bytes: usize,
) {
    if let Some(value) = source.get(key).and_then(Value::as_str) {
        target.insert(key.to_owned(), projected_text(value, max_bytes));
    }
}

fn insert_projected_bool(source: &Map<String, Value>, target: &mut Map<String, Value>, key: &str) {
    if let Some(value) = source.get(key).and_then(Value::as_bool) {
        target.insert(key.to_owned(), json!(value));
    }
}

fn projected_text(value: &str, max_bytes: usize) -> Value {
    if value.len() <= max_bytes {
        return json!(value);
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    json!({
        "preview": &value[..end],
        "truncated": true,
        "bytes": value.len()
    })
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payloadHash": version.content_hash
    })
}
