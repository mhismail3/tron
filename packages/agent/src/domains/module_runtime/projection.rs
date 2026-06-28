use serde_json::{Map, Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

const PROJECTION_STRING_BYTES: usize = 512;
const PROJECTION_ID_BYTES: usize = 256;
const PROJECTION_TIMESTAMP_BYTES: usize = 64;
const MAX_PROJECTED_REFS: usize = 25;

pub(super) fn module_runtime_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "moduleRuntimeResourceId": resource.resource_id,
        "state": projected_state(resource, payload),
        "runtimeRequestId": projected_string(payload, "runtimeRequestId", PROJECTION_ID_BYTES),
        "moduleLifecycle": projected_ref(payload.get("moduleLifecycle")),
        "runtime": projected_runtime(payload.get("runtime")),
        "supervision": projected_supervision(payload.get("supervision")),
        "outputArtifactRefs": projected_refs(payload.get("outputArtifactRefs")),
        "idempotencyFingerprint": payload.pointer("/idempotency/fingerprint")
            .and_then(Value::as_str)
            .map(|text| json!(projected_text(text, PROJECTION_ID_BYTES)))
            .unwrap_or(Value::Null),
        "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
        "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
        "resourceRefs": [version_ref(resource, version, "module_runtime_state")]
    })
}

pub(super) fn inspected_module_runtime(
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
        "moduleRuntime": {
            "schemaVersion": projected_string(payload, "schemaVersion", PROJECTION_ID_BYTES),
            "state": projected_state(resource, payload),
            "runtimeRequestId": projected_string(payload, "runtimeRequestId", PROJECTION_ID_BYTES),
            "scope": projected_scope(resource, payload.get("scope")),
            "moduleLifecycle": projected_ref(payload.get("moduleLifecycle")),
            "runtime": projected_runtime(payload.get("runtime")),
            "supervision": projected_supervision(payload.get("supervision")),
            "inputRefs": projected_refs(payload.get("inputRefs")),
            "outputArtifactRefs": projected_refs(payload.get("outputArtifactRefs")),
            "evidenceRefs": projected_refs(payload.get("evidenceRefs")),
            "traceRefs": projected_refs(payload.get("traceRefs")),
            "replayRefs": projected_refs(payload.get("replayRefs")),
            "authority": projected_authority(payload.get("authority")),
            "idempotency": projected_idempotency(payload.get("idempotency")),
            "sideEffectProof": projected_side_effect_proof(payload.get("sideEffectProof")),
            "reason": projected_string(payload, "reason", PROJECTION_STRING_BYTES),
            "createdAt": projected_string(payload, "createdAt", PROJECTION_TIMESTAMP_BYTES),
            "updatedAt": projected_string(payload, "updatedAt", PROJECTION_TIMESTAMP_BYTES),
            "revision": payload.get("revision").and_then(Value::as_u64).map_or(Value::Null, |value| json!(value))
        },
        "projection": projection_policy(),
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn projected_runtime(value: Option<&Value>) -> Value {
    let Some(Value::Object(runtime)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in ["kind", "label"] {
        insert_projected_string(runtime, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    for key in [
        "featureSemanticsOwnedByPackage",
        "supervisorEnvelopeOnly",
        "processLaunched",
        "jobDelegated",
        "jobExposedToProvider",
    ] {
        if let Some(value) = runtime.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    insert_projected_string(
        runtime,
        &mut projected,
        "providerVisibleJobProjection",
        PROJECTION_ID_BYTES,
    );
    Value::Object(projected)
}

fn projected_supervision(value: Option<&Value>) -> Value {
    let Some(Value::Object(supervision)) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    insert_projected_string(supervision, &mut projected, "state", PROJECTION_ID_BYTES);
    for key in [
        "sandbox",
        "network",
        "secrets",
        "timeout",
        "cancellation",
        "shutdown",
        "job",
        "outputCustody",
        "cleanup",
        "programExecution",
    ] {
        if let Some(child) = supervision.get(key) {
            projected.insert(key.to_owned(), projected_policy(child));
        }
    }
    Value::Object(projected)
}

fn projected_policy(value: &Value) -> Value {
    let Value::Object(policy) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for (key, child) in policy {
        match child {
            Value::Bool(flag) => {
                projected.insert(key.clone(), json!(flag));
            }
            Value::Number(number) => {
                projected.insert(key.clone(), json!(number));
            }
            Value::String(text) => {
                projected.insert(
                    key.clone(),
                    json!(projected_text(text, PROJECTION_STRING_BYTES)),
                );
            }
            Value::Object(_) => {
                projected.insert(key.clone(), projected_policy(child));
            }
            _ => {}
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
        "supervisorEnvelopeOnly",
        "installPerformed",
        "activationPerformed",
        "dependencyRestorePerformed",
        "packageManagerUsed",
        "networkAccessPerformed",
        "repoManagedSkillsTouched",
        "physicalWorkspaceDirectoryCreated",
        "ptyAllocated",
        "browserAutomationPerformed",
        "rawCommandsStored",
        "rawLogsStored",
        "rawOutputStored",
        "secretsExposed",
        "fileContentsStored",
        "absolutePathsStored",
    ] {
        if let Some(value) = proof.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    if let Some(value) = proof.get("networkPolicy").and_then(Value::as_str) {
        projected.insert(
            "networkPolicy".to_owned(),
            json!(projected_text(value, PROJECTION_ID_BYTES)),
        );
    }
    Value::Object(projected)
}

fn projected_refs(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Array(items)) => json!({
            "items": items.iter().take(MAX_PROJECTED_REFS).map(projected_ref_item).collect::<Vec<_>>(),
            "total": items.len(),
            "truncated": items.len() > MAX_PROJECTED_REFS
        }),
        _ => json!({"items": [], "total": 0, "truncated": false}),
    }
}

fn projected_ref(value: Option<&Value>) -> Value {
    match value {
        Some(Value::Object(_)) => projected_ref_item(value.unwrap()),
        _ => Value::Null,
    }
}

fn projected_ref_item(value: &Value) -> Value {
    let Value::Object(item) = value else {
        return Value::Null;
    };
    let mut projected = Map::new();
    for key in [
        "kind",
        "id",
        "resourceId",
        "versionId",
        "role",
        "status",
        "fingerprint",
        "summary",
        "state",
    ] {
        insert_projected_string(item, &mut projected, key, PROJECTION_STRING_BYTES);
    }
    if let Some(value) = item.get("allowed").and_then(Value::as_bool) {
        projected.insert("allowed".to_owned(), json!(value));
    }
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
        "lifecycleAuthorizationRequired",
        "wildcardGrantsAllowed",
    ] {
        if let Some(value) = authority.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    for key in ["requiredScopes", "resourceKinds"] {
        if let Some(Value::Array(items)) = authority.get(key) {
            projected.insert(
                key.to_owned(),
                json!(
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(|item| projected_text(item, PROJECTION_ID_BYTES))
                        .collect::<Vec<_>>()
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
        if let Some(value) = idempotency.get(key).and_then(Value::as_bool) {
            projected.insert(key.to_owned(), json!(value));
        }
    }
    Value::Object(projected)
}

fn projected_state(resource: &EngineResource, payload: &Value) -> Value {
    json!({
        "resourceLifecycle": projected_text(&resource.lifecycle, PROJECTION_ID_BYTES),
        "payloadState": payload
            .get("state")
            .and_then(Value::as_str)
            .map(|value| projected_text(value, PROJECTION_ID_BYTES))
            .unwrap_or_else(|| projected_text(&resource.lifecycle, PROJECTION_ID_BYTES))
    })
}

fn projected_scope(resource: &EngineResource, value: Option<&Value>) -> Value {
    let mut scope = Map::new();
    scope.insert("kind".to_owned(), json!(resource.scope.kind()));
    scope.insert("value".to_owned(), json!(resource.scope.value()));
    if let Some(Value::Object(payload_scope)) = value {
        for key in ["kind", "value"] {
            insert_projected_string(payload_scope, &mut scope, key, PROJECTION_ID_BYTES);
        }
    }
    Value::Object(scope)
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role,
        "lifecycle": resource.lifecycle
    })
}

fn projection_policy() -> Value {
    json!({
        "allowlist": "module_runtime_supervisor_redacted_v1",
        "rawPayloadReturned": false,
        "rawCommandsReturned": false,
        "rawLogsReturned": false,
        "rawOutputReturned": false,
        "rawAuthorityIdsReturned": false,
        "absolutePathsReturned": false,
        "providerVisibleOutput": "refs_only"
    })
}

fn projected_string(payload: &Value, key: &str, max_bytes: usize) -> Value {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|text| json!(projected_text(text, max_bytes)))
        .unwrap_or(Value::Null)
}

fn insert_projected_string(
    source: &Map<String, Value>,
    target: &mut Map<String, Value>,
    key: &str,
    max_bytes: usize,
) {
    if let Some(value) = source.get(key).and_then(Value::as_str) {
        target.insert(key.to_owned(), json!(projected_text(value, max_bytes)));
    }
}

fn projected_text(value: &str, max_bytes: usize) -> String {
    let mut output = String::new();
    for ch in value.chars() {
        if output.len() + ch.len_utf8() > max_bytes {
            break;
        }
        output.push(ch);
    }
    output
}
