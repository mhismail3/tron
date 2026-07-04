use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;

pub(super) fn capability_binding_request_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityBindingRequestResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
        "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
        "operation": projected_operation(payload.get("operation")),
        "binding": projected_binding(payload.get("binding")),
        "policyDecision": projected_policy_decision(payload.get("policyDecision")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "capability_binding_request")]
    })
}

pub(super) fn inspected_capability_binding_request(
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
        "bindingRequest": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "requestId": projected_string(payload, "requestId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "title": projected_string(payload, "title", PROJECTION_STRING_BYTES),
            "operation": projected_operation(payload.get("operation")),
            "binding": projected_binding(payload.get("binding")),
            "requirements": projected_requirements(payload.get("requirements")),
            "policyDecision": projected_policy_decision(payload.get("policyDecision")),
            "auditRefs": projected_refs(payload.get("auditRefs")),
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

pub(super) fn capability_binding_decision_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityBindingDecisionResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
        "request": projected_ref(payload.get("request")),
        "operation": projected_operation(payload.get("operation")),
        "binding": projected_binding(payload.get("binding")),
        "decision": projected_decision(payload.get("decision")),
        "policyCandidate": projected_policy_candidate(payload.get("policyCandidate")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "capability_binding_decision")]
    })
}

pub(super) fn inspected_capability_binding_decision(
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
        "bindingDecision": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "decisionId": projected_string(payload, "decisionId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "request": projected_ref(payload.get("request")),
            "operation": projected_operation(payload.get("operation")),
            "binding": projected_binding(payload.get("binding")),
            "requirements": projected_requirements(payload.get("requirements")),
            "decision": projected_decision(payload.get("decision")),
            "policyCandidate": projected_policy_candidate(payload.get("policyCandidate")),
            "auditRefs": projected_refs(payload.get("auditRefs")),
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

pub(super) fn capability_binding_policy_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "capabilityBindingPolicyResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "policyId": projected_string(payload, "policyId", PROJECTION_ID_BYTES),
        "decision": projected_ref(payload.get("decision")),
        "request": projected_ref(payload.get("request")),
        "operation": projected_operation(payload.get("operation")),
        "binding": projected_binding(payload.get("binding")),
        "activation": projected_activation(payload.get("activation")),
        "idempotencyFingerprint": projected_fingerprint(payload),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "capability_binding_policy")]
    })
}

pub(super) fn inspected_capability_binding_policy(
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
        "bindingPolicy": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "policyId": projected_string(payload, "policyId", PROJECTION_ID_BYTES),
            "scope": projected_ref(payload.get("scope")),
            "decision": projected_ref(payload.get("decision")),
            "request": projected_ref(payload.get("request")),
            "operation": projected_operation(payload.get("operation")),
            "binding": projected_binding(payload.get("binding")),
            "requirements": projected_requirements(payload.get("requirements")),
            "activation": projected_activation(payload.get("activation")),
            "auditRefs": projected_refs(payload.get("auditRefs")),
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

fn projected_operation(value: Option<&Value>) -> Value {
    let Some(Value::Object(operation)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "name",
        "currentBuiltInOwner",
        "ownershipClass",
        "requestedReplacementTarget",
        "currentExecutionOwner",
    ] {
        insert_projected_string(operation, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    insert_projected_bool(operation, &mut projected, "dispatchChanged");
    Value::Object(projected)
}

fn projected_binding(value: Option<&Value>) -> Value {
    let Some(Value::Object(binding)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["mode", "actorScope", "rationale"] {
        insert_projected_string(binding, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(child) = binding.get("targetRef") {
        projected.insert("targetRef".to_owned(), projected_ref(Some(child)));
    }
    for key in [
        "runtimeRoutingRequested",
        "runtimeRoutingEnabled",
        "hotSwapRequested",
    ] {
        insert_projected_bool(binding, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_requirements(value: Option<&Value>) -> Value {
    let Some(Value::Object(requirements)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    if let Some(contract) = requirements.get("contract") {
        projected.insert("contract".to_owned(), projected_contract(Some(contract)));
    }
    if let Some(authority) = requirements.get("authority") {
        projected.insert(
            "authority".to_owned(),
            projected_authority_constraints(Some(authority)),
        );
    }
    if let Some(guard) = requirements.get("staleVersionGuard") {
        projected.insert("staleVersionGuard".to_owned(), projected_guard(Some(guard)));
    }
    for key in ["rollbackRef", "disableRef"] {
        if let Some(child) = requirements.get(key)
            && !child.is_null()
        {
            projected.insert(key.to_owned(), projected_ref(Some(child)));
        }
    }
    Value::Object(projected)
}

fn projected_contract(value: Option<&Value>) -> Value {
    let Some(Value::Object(contract)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    if let Some(refs) = contract.get("contractEvidenceRefs") {
        projected.insert(
            "contractEvidenceRefs".to_owned(),
            projected_refs(Some(refs)),
        );
    }
    if let Some(refs) = contract.get("evidenceRefs") {
        projected.insert("evidenceRefs".to_owned(), projected_refs(Some(refs)));
    }
    insert_projected_string(
        contract,
        &mut projected,
        "evidenceRequirements",
        PROJECTION_STRING_BYTES,
    );
    for key in [
        "providerSafeProjectionRequired",
        "contractCompatible",
        "runtimeParityRequired",
    ] {
        insert_projected_bool(contract, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_authority_constraints(value: Option<&Value>) -> Value {
    let Some(Value::Object(authority)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    insert_projected_string(
        authority,
        &mut projected,
        "networkPolicy",
        PROJECTION_ID_BYTES,
    );
    for key in ["authorityScopes", "resourceKinds", "resourceSelectors"] {
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
    for key in [
        "agentStateInherited",
        "rawGrantIdsStored",
        "wildcardSelectorsAllowed",
    ] {
        insert_projected_bool(authority, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_guard(value: Option<&Value>) -> Value {
    let Some(Value::Object(guard)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["expectedInventoryVersion", "expectedPolicyVersion"] {
        insert_projected_string(guard, &mut projected, key, PROJECTION_ID_BYTES);
    }
    insert_projected_bool(guard, &mut projected, "staleRequestRejected");
    Value::Object(projected)
}

fn projected_policy_decision(value: Option<&Value>) -> Value {
    let Some(Value::Object(decision)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    insert_projected_string(decision, &mut projected, "status", PROJECTION_ID_BYTES);
    for key in ["replacementAllowed", "routingEnabled", "decisionRequired"] {
        insert_projected_bool(decision, &mut projected, key);
    }
    Value::Object(projected)
}

fn projected_decision(value: Option<&Value>) -> Value {
    let Some(Value::Object(decision)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["state", "result", "reason"] {
        insert_projected_string(decision, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(refs) = decision.get("denialEvidence") {
        projected.insert("denialEvidence".to_owned(), projected_refs(Some(refs)));
    }
    for key in ["metadataOnly", "runtimeRoutingChanged", "hotSwapPerformed"] {
        insert_projected_bool(decision, &mut projected, key);
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
        "routingEnabled",
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
        "metadataOnly",
        "runtimeRoutingEnabled",
        "runtimeRoutingChanged",
        "hotSwapPerformed",
    ] {
        insert_projected_bool(activation, &mut projected, key);
    }
    for key in ["rollbackRef", "disableRef"] {
        if let Some(child) = activation.get(key)
            && !child.is_null()
        {
            projected.insert(key.to_owned(), projected_ref(Some(child)));
        }
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
        "runtimeRoutingChanged",
        "dispatchTableMutated",
        "hotSwapPerformed",
        "moduleActivated",
        "moduleExecuted",
        "dependencyRestorePerformed",
        "packageManagerUsed",
        "manifestMutated",
        "lockfileMutated",
        "networkAccessPerformed",
        "repoManagedSkillsTouched",
        "physicalWorkspaceDirectoryCreated",
        "rawCommandsStored",
        "rawLogsStored",
        "fileContentsStored",
        "absolutePathsStored",
        "rawGrantIdsStored",
        "rawAuthorityIdsStored",
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
        "agentStateInherited",
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
        "rawDebugPayloads": false,
        "agentStateInherited": false,
        "runtimeRoutingChanged": false,
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
